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

    my $t0 = Time::HiRes::time();
    my $result;
    my $ok = eval { $result = $self->{inner}->call( $service, $method, @params ); 1 };
    my $ms = int( ( Time::HiRes::time() - $t0 ) * 1000 );
    if ($ok) {
        $self->_audit( $service, $model, $mmethod // $method, 'answered', undef, $ms );
        return $result;
    }
    my $err = $@;
    my ( $outcome, $cat ) = ( 'transport', undef );
    if ( blessed($err) && $err->isa('Odoo::Error') ) {
        $outcome = $err->kind eq 'fault' ? 'fault' : $err->kind eq 'refused' ? 'refused' : 'transport';
        $cat     = $err->fault_category;
    }
    $self->_audit( $service, $model, $mmethod // $method, $outcome, $cat, $ms );
    die $err;
}

sub _audit ($self, $service, $model, $method, $outcome, $cat, $ms) {
    return if !$self->{audit};
    $self->{audit}->record(
        actor   => $self->{actor},
        login   => $self->{login},
        service => $service,
        model   => $model,
        method  => $method,
        op      => $self->{op},
        outcome => $outcome,
        ( defined $cat ? ( fault_category => $cat ) : () ),
        ms => $ms,
    );
}

1;
