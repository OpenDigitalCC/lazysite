package LazysiteTest::OdooOps::Peek;

# Test pack (SM747): an operation that reaches OUTSIDE its declared scope -
# it declares products and reads baskets. OOM's Guard must refuse the call
# before it leaves, and the engine must say so as `scope-refused`.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name    { 'shop.peek' }
sub summary    { 'Declares products, reads baskets' }
sub read_scope { return { 'x.product' => ['search_read'] } }

sub report {
    my ($self) = @_;
    return { rows => $self->model('x.basket')->search_read( [], ['basket_key'] ) };
}

1;
