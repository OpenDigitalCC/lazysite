package LazysiteTest::OdooOps::Mixed;

# Test pack (SM1193): a write of two changes, one that Odoo accepts (a rename of a
# product) and one the fake Odoo is told to refuse (the basket line's create), in
# that order, so the first is done when the second fails.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name { 'shop.mixed' }
sub summary { 'Rename a product and add a basket line' }
sub params  { return { title => { type => 'str', default => 'Renamed' } } }
sub read_scope  { return { 'x.product' => ['search_read'] } }
sub write_scope { return { 'x.product' => ['write'], 'x.basket' => ['create'] } }

sub plan {
    my ($self) = @_;
    my $plan = $self->new_plan( input_count => 2 );
    $plan->add( bucket => 'rename', action => 'write', model => 'x.product', id => 1, key => 'rename:1',
        vals => { name => $self->param('title') } );
    $plan->add( bucket => 'line', action => 'create', model => 'x.basket', key => 'line:1',
        vals => { basket_key => 'k', product_id => 1, qty => 1 } );
    return $plan;
}

1;
