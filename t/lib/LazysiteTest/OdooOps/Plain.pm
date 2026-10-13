package LazysiteTest::OdooOps::Plain;

# Test pack (SM747 R wiring): a read that is not meant for display - rows and
# nothing else, as an operation that has not adopted the shape returns them.
# Its report must reach every door exactly as it is.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name    { 'shop.plain' }
sub summary    { 'Rows, no descriptors' }
sub read_scope { return { 'x.product' => ['search_read'] } }

sub report {
    my ($self) = @_;
    return { rows => $self->model('x.product')->search_read( [], ['name'] ), fields => [qw(name)] };
}

1;
