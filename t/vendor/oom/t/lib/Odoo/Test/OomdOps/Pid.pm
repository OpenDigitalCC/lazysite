package Odoo::Test::OomdOps::Pid;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';
use Time::HiRes ();

use parent 'Odoo::Ops::Operation';

# Reads that touch no server, for the tests of the resident daemon (ODOO_OPS_NAMESPACES=Odoo::Test::OomdOps):
# which process answered, a pause, and a worker that dies.

sub op_name ($class) { 'oomd.pid' }
sub summary ($class) { 'Which process answered, for tests of oomd' }
sub params  ($class) {
    return {
        echo    => { type => 'str', default => '', help => 'a string handed back' },
        seconds => { type => 'str', default => '0', help => 'wait this long first' },
        crash   => { type => 'bool', default => 0, help => 'the process dies before it answers' },
    };
}
sub report ($self) {
    kill 'KILL', $$ if $self->param('crash');
    Time::HiRes::sleep( $self->param('seconds') ) if $self->param('seconds');
    return { count => 1, rows => [ { pid => $$, echo => $self->param('echo') } ] };
}

1;
