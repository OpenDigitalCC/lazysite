package LazysiteTest::OdooOps::Basket;

# Test pack (SM747): a visitor's basket, read by the key the server minted.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name    { 'shop.basket' }
sub summary    { 'The lines in one basket' }
sub params     { return { basket_key => { type => 'str', required => 1 } } }
sub read_scope { return { 'x.basket' => ['search_read'] } }

sub report {
    my ($self) = @_;
    my $rows = $self->model('x.basket')->search_read(
        [ [ 'basket_key', '=', $self->param('basket_key') ] ],
        [ 'product_id', 'qty' ] );
    return { rows => $rows };
}

1;
