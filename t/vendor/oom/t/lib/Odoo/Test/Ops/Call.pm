package Odoo::Test::Ops::Call;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use parent 'Odoo::Ops::Operation';

# A write of one change of any action on any model, declaring only what its parameters say, for the
# tests of the call read-back and of the plan-time scope check (ODOO_OPS_NAMESPACES=Odoo::Test::Ops).
# declare lists the methods the scope names for the model; the plan always uses the change it is told to.

sub op_name ($class) { 'test.call' }
sub summary ($class) { 'One change of any action, with the scope the caller declares, for tests' }
sub pack    ($class) { undef }
sub params  ($class) {
    {   model   => { type => 'str', required => 1, help => 'the physical model' },
        id      => { type => 'int', required => 1, help => 'the record' },
        action  => { type => 'str', default => 'call', help => 'call, write, create or unlink' },
        method  => { type => 'str', help => 'the method of a call' },
        declare => { type => 'list', default => '', help => 'the methods the scope names for the model' },
        verify  => { type => 'json', help => 'a verify block for the call' },
    };
}
sub read_scope  ($class) { {} }
sub write_scope ($class) { { 'x.y' => ['z'] } }
sub writes      ($class) { 1 }
sub buckets ($class) { [ { name => 'change', meaning => 'the one change' } ] }
sub holds   ($class) { [] }

sub scope_for ($self, $phase) {
    return {} if $phase ne 'apply';
    return { $self->param('model') => [ @{ $self->param('declare') } ] };
}

sub plan ($self) {
    my $plan = $self->new_plan( input_count => 1 );
    my $a = $self->param('action');
    $plan->add( bucket => 'change', action => $a, model => $self->param('model'), key => "$a:" . $self->param('id'),
        ( $a eq 'create' ? () : ( id => $self->param('id') ) ),
        ( $a eq 'call' ? ( method => $self->param('method'), ids => [ $self->param('id') ] ) : () ),
        ( $a eq 'write' ? ( vals => { name => 'x' } ) : () ),
        ( $a eq 'create' ? ( vals => { name => 'x' } ) : () ),
        ( $self->param('verify') ? ( verify => $self->param('verify') ) : () ) );
    return $plan;
}

1;
