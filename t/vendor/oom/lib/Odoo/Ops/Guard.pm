package Odoo::Ops::Guard;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Scalar::Util qw(blessed);
use Time::HiRes ();

use Odoo::Error;

=head1 NAME

Odoo::Ops::Guard - scope enforcement and audit at the transport

=head1 SYNOPSIS

    my $guard = Odoo::Ops::Guard->new(inner => $jsonrpc, audit => $audit,
                                      actor => 'sjm', login => 'crm-user');
    my $odoo  = Odoo::Client->new(..., transport => $guard);

    $guard->with_scope({ 'crm.lead' => ['search_read'] }, 'crm.export', sub {
        ...   # only crm.lead.search_read (plus the base scope) leaves
    });

=head1 DESCRIPTION

Wraps a real transport, so it sees every call whichever layer made it
- Model, Record, or a raw C<execute_kw>. An C<object.execute_kw> call
whose model and method are outside the current scope dies as kind
C<refused> (code C<scope>) before any byte leaves: the enforcement
SM747 OB2 asks for, placed where it cannot be bypassed from above.

The base scope, always allowed: the C<common> service (version,
authenticate), C<fields_get> on any model (introspection needs no
rights and reveals no records), C<res.users.read> (whoami) and
C<ir.model.fields> C<search_read> and C<search_count> (whether any model's fields have changed, which the field cache checks). Outside
C<with_scope> nothing else is allowed.

Every call, allowed or refused, writes one audit record.

=cut

sub new ($class, %args) {
    Odoo::Error->throw( kind => 'config', message => 'guard needs an inner transport' )
        if !eval { $args{inner}->can('call') };
    return bless {
        inner => $args{inner},
        audit => $args{audit},
        actor => $args{actor},
        login => $args{login},
        scope => undef,
        op    => undef,
    }, $class;
}

sub name  ($self) { 'guard(' . ( eval { $self->{inner}->name } // '?' ) . ')' }
sub inner ($self) { $self->{inner} }
sub set_audit ($self, $audit) { $self->{audit} = $audit }

# the operation whose scope is in force (undef outside one)
sub op ($self) { $self->{op} }

=head2 with_scope(\%scope, $op_name, $code)

Runs C<$code> with C<%scope> (physical model => [methods]) in force,
restoring the previous scope afterwards, even on die.

=cut

sub with_scope ($self, $scope, $op, $code) {
    my %norm;
    for my $model ( keys %$scope ) {
        $norm{$model}{$_} = 1 for @{ $scope->{$model} };
    }
    my ( $was_scope, $was_op ) = ( $self->{scope}, $self->{op} );
    $self->{scope} = \%norm;
    $self->{op}    = $op;
    # the guard of the service credential a run acting for a person holds stands under the same scope
    $_->{scope} = \%norm, $_->{op} = $op for $self->_twins;
    my ( @r, $want );
    $want = wantarray;    # wantarray inside the eval is the eval's own context
    my $ok  = eval { @r = $want ? $code->() : scalar $code->(); 1 };
    my $err = $@;
    ( $self->{scope}, $self->{op} ) = ( $was_scope, $was_op );
    ( $_->{scope}, $_->{op} ) = ( $was_scope, $was_op ) for $self->_twins;
    die $err if !$ok;
    return $want ? @r : $r[0];
}

=head2 attach_twin($guard)

Makes $guard follow this guard's scope and operation, now and under every
C<with_scope> from here on: the guard of the service credential of a run that acts
for a person is held to the scope the operation declared, as the person's is.

=head2 acting(\%who, $client)

C<< $guard->acting( { login, via }, 'person' ) >> makes every audit record of this guard
say whose run it is: C<login> the person's, C<via> the service login, C<acts_for 1>
and C<client> (C<person> or C<service>) the connection that made the call. Undef ends it.

=cut

sub attach_twin ($self, $twin) {
    push @{ $self->{twins} }, $twin;
    ( $twin->{scope}, $twin->{op} ) = ( $self->{scope}, $self->{op} );
    return;
}

sub _twins ($self) { return @{ $self->{twins} // [] } }

sub acting ($self, $who = undef, $client = undef) {
    ( $self->{acting}, $self->{acting_client} ) = ( $who, $client );
    return;
}

# the transport this guard wraps (a client may need to ask it about
# its session)
sub inner_transport ($self) { $self->{inner} }

=head2 derive($inner, login => $login)

A guard around another transport (a web session for one user) that
carries this guard's audit sink, actor, scope and operation, so calls
made as that user are held to the same scope and recorded in the same
audit. C<login> names the user the calls are made as.

=cut

sub derive ($self, $inner, %args) {
    my $d = ref($self)->new(
        inner => $inner,
        audit => $self->{audit},
        actor => $self->{actor},
        login => $args{login} // $self->{login},
    );
    $d->{scope} = $self->{scope};
    $d->{no_check} = $self->{no_check};
    $d->{op}    = $self->{op};
    return $d;
}

# The calls every scope allows (see the DESCRIPTION).
sub base_allows ($class, $model, $method) {
    return 1 if $method eq 'fields_get';
    return 1 if $model eq 'res.users' && $method eq 'read';
    # the date a model's field definitions last changed: what a kept fields_get is checked against
    return 1 if $model eq 'ir.model.fields' && ($method eq 'search_read' || $method eq 'search_count');
    return 0;
}

sub allows ($self, $model, $method) {
    return 1 if $self->base_allows( $model, $method );
    return !!( $self->{scope} && $self->{scope}{$model} && $self->{scope}{$model}{$method} );
}

# the calls the custom change being applied declared, as "model.method" => 1; set by the runner under OOM_STRICT_CALLS
our $DECLARED;

sub call ($self, $service, $method, @params) {
    # audit_required: once a line could not be written, no further call is made
    $self->{audit}->ready if $self->{audit} && !$self->{no_check};
    my ( $model, $mmethod );
    if ( $service eq 'object' && $method eq 'execute_kw' ) {
        ( $model, $mmethod ) = @params[ 3, 4 ];
        if ( !$self->allows( $model, $mmethod ) ) {
            $self->_audit( $service, $model, $mmethod, 'refused', undef, 0 );
            Odoo::Error->throw(
                kind    => 'refused',
                code    => 'scope',
                message => "call $model.$mmethod is outside the scope of "
                    . ( $self->{op} // 'any operation' ),
            );
        }
    }
    elsif ( $service ne 'common' ) {
        $self->_audit( $service, undef, $method, 'refused', undef, 0 );
        Odoo::Error->throw(
            kind    => 'refused',
            code    => 'scope',
            message => "service $service.$method is not permitted",
        );
    }

    # a custom change that declared its calls makes no other (OOM_STRICT_CALLS=1, which the offline suite sets)
    if ( $DECLARED && defined $model && !$DECLARED->{"$model.$mmethod"} && !$self->base_allows( $model, $mmethod ) ) {
        $self->_audit( $service, $model, $mmethod, 'refused', undef, 0 );
        Odoo::Error->throw( kind => 'usage', message => "call $model.$mmethod is not among the calls the change declared (calls => [[model, method], ...])" );
    }

    # the field list a read asked for: in the audit, and in the fix line of an access fault
    my $asked = $mmethod && $mmethod =~ /^(?:read|search_read)\z/ ? _asked( $mmethod, @params[ 5, 6 ] ) : undef;
    my $t0 = Time::HiRes::time();
    my $result;
    my $ok = eval { $result = $self->{inner}->call( $service, $method, @params ); 1 };
    my $ms = int( ( Time::HiRes::time() - $t0 ) * 1000 );
    if ($ok) {
        $self->_audit( $service, $model, $mmethod // $method, 'answered', undef, $ms, $asked );
        return $result;
    }
    my $err = $@;
    my ( $outcome, $cat ) = ( 'transport', undef );
    if ( blessed($err) && $err->isa('Odoo::Error') ) {
        $outcome = $err->kind eq 'fault' ? 'fault' : $err->kind eq 'refused' ? 'refused' : 'transport';
        $cat     = $err->fault_category;
        $err->{reading} //= "$model.$mmethod" . ( $asked && @$asked ? ' fields ' . join( ',', @$asked ) : '' )
            if defined $cat && $cat eq 'access' && defined $model && defined $mmethod;
    }
    $self->_audit( $service, $model, $mmethod // $method, $outcome, $cat, $ms, $asked );
    die $err;
}

# The field names of a read or search_read call: the second positional argument or the
# fields keyword. undef when it named none (Odoo then chooses).
sub _asked ($method, $args, $kw) {
    my $f = ref $kw eq 'HASH' ? $kw->{fields} : undef;
    $f //= $args->[1] if ref $args eq 'ARRAY' && $method eq 'read';
    return ref $f eq 'ARRAY' && @$f ? [ map { "$_" } @$f ] : undef;
}

=head2 hold_access_fault, release_access_fault(%extra)

For the tolerant read of the mailing pack: after C<hold_access_fault> the
audit record of the next read refused for want of rights is kept back, and
C<release_access_fault> writes it with the extra keys given
(C<< refused_fields => [...] >>), so the record of the first, refused read
says which fields were refused although the reads that found out were
made after it. A record held is always written: by the release, and at the
latest when the guard goes.

=cut

sub hold_access_fault ($self) { $self->{hold} = [] }

sub release_access_fault ($self, %extra) {
    my $held = delete $self->{hold};
    $self->{audit}->record( %$_, %extra ) for $self->{audit} ? @{ $held // [] } : ();
    return;
}

sub DESTROY ($self) { local $@; eval { $self->release_access_fault } }

=head2 audit_web($label, $outcome, $ms)

One audit record for a request that is not an RPC call (a report route
fetched over the web session). It names the label and the outcome, never
the content. With C<second_factor> (and, for a refused
code, C<fault_category>) it records the two-factor step of a sign-in.

=cut

sub audit_web ($self, $label, $outcome, $ms, %extra) {
    $self->_audit( 'web', undef, $label, $outcome, $extra{fault_category}, $ms, undef, $extra{second_factor} );
    return;
}

=head2 route($path, $code)

Runs C<$code>, the call of the web route C<$path>, when the operation in
force declared that path (C<routes> of L<Odoo::Ops::Operation>; the scope holds
them under C<web.route>). Any other path is refused C<scope> before a byte
leaves, and the refusal is audited as every other. The call is audited as
C<route PATH> with its outcome, never its parameters or its answer.

=cut

sub route ($self, $path, $code) {
    if ( !$self->allows( 'web.route', $path ) ) {
        $self->_audit( 'web', undef, "route $path", 'refused', undef, 0 );
        Odoo::Error->throw(
            kind    => 'refused',
            code    => 'scope',
            message => "route $path is outside the scope of " . ( $self->{op} // 'any operation' ),
            fix     => "declare the path in the operation's routes => [ '$path' ]",
        );
    }
    $self->{audit}->ready if $self->{audit} && !$self->{no_check};
    my $t0 = Time::HiRes::time();
    my @r  = eval { $code->() };
    my $err = $@;
    my $ms  = int( ( Time::HiRes::time() - $t0 ) * 1000 );
    if ($err) {
        my $cat = blessed($err) && $err->isa('Odoo::Error') && $err->kind eq 'fault' ? $err->fault_category : undef;
        $self->_audit( 'web', undef, "route $path", ( blessed($err) && $err->isa('Odoo::Error') && $err->kind eq 'fault' ? 'fault' : 'transport' ), $cat, $ms );
        die $err;
    }
    $self->_audit( 'web', undef, "route $path", 'answered', undef, $ms );
    return $r[0];
}

sub _audit ($self, $service, $model, $method, $outcome, $cat, $ms, $asked = undef, $second_factor = undef) {
    return if !$self->{audit};
    my $is_read = defined $model && defined $method && $method =~ /^(?:read|search_read)\z/ && $service eq 'object';
    my $acting = $self->{acting};
    my %rec = (
        actor   => $self->{actor},
        login   => ( $acting && defined $acting->{login} ? $acting->{login} : $self->{login} ),
        ( $acting ? ( via => $acting->{via}, acts_for => 1, client => $self->{acting_client} ) : () ),
        ( defined $self->{for_login} ? ( for_login => $self->{for_login} ) : () ),
        service => $service,
        model   => $model,
        method  => $method,
        op      => $self->{op},
        outcome => $outcome,
        ( defined $cat ? ( fault_category => $cat ) : () ),
        # null when the call named no fields: Odoo then chose them
        ( $is_read ? ( fields => $asked ) : () ),
        ( defined $second_factor ? ( second_factor => $second_factor ) : () ),
        ms => $ms,
    );
    # the first refused read while the tolerant read waits to say which fields were refused
    if ( $self->{hold} && !@{ $self->{hold} } && $is_read && defined $cat && $cat eq 'access' ) {
        $rec{ts} = $self->{audit}->now;
        push @{ $self->{hold} }, \%rec;
        return;
    }
    $self->{audit}->record(%rec);
}

1;
