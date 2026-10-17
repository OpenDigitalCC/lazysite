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
rights and reveals no records), and C<res.users.read> (whoami). Outside
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
    local $self->{scope} = \%norm;
    local $self->{op}    = $op;
    return $code->();
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
    $d->{op}    = $self->{op};
    return $d;
}

sub allows ($self, $model, $method) {
    return 1 if $method eq 'fields_get';
    return 1 if $model eq 'res.users' && $method eq 'read';
    return !!( $self->{scope} && $self->{scope}{$model} && $self->{scope}{$model}{$method} );
}

sub call ($self, $service, $method, @params) {
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
the content.

=cut

sub audit_web ($self, $label, $outcome, $ms) {
    $self->_audit( 'web', undef, $label, $outcome, undef, $ms );
    return;
}

sub _audit ($self, $service, $model, $method, $outcome, $cat, $ms, $asked = undef) {
    return if !$self->{audit};
    my $is_read = defined $model && defined $method && $method =~ /^(?:read|search_read)\z/ && $service eq 'object';
    my %rec = (
        actor   => $self->{actor},
        login   => $self->{login},
        ( defined $self->{for_login} ? ( for_login => $self->{for_login} ) : () ),
        service => $service,
        model   => $model,
        method  => $method,
        op      => $self->{op},
        outcome => $outcome,
        ( defined $cat ? ( fault_category => $cat ) : () ),
        # null when the call named no fields: Odoo then chose them
        ( $is_read ? ( fields => $asked ) : () ),
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
