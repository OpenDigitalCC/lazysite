package LazysiteTest::OdooOps::Where;

# Test pack (SM1280): a read that answers what it was given - whether the call came
# from inside the binding's address list (`onsite`, a yes/no parameter the server
# sets) and a note the request may send - so a test sees exactly what reached the
# operation, and that nothing else did.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name    { 'shop.where' }
sub summary    { 'Says whether the call came from inside the address list it was told about' }
sub params     { return { onsite => { type => 'bool', default => 0 }, note => { type => 'str', default => '' } } }
sub read_scope { return { 'x.product' => ['search_read'] } }

sub report {
    my ($self) = @_;
    return { rows => [ { onsite => $self->param('onsite') ? 1 : 0, note => $self->param("note") // "" } ] };
}

1;
