package LazysiteTest::OdooOps::Order;

# Test pack (SM1166): an order with a declared list of lines - a WRITE operation
# whose `lines` parameter is OOM 0.32's `rows` type, capped at 3.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name { 'shop.order' }
sub summary { 'Order several products at once' }

sub params {
    return {
        basket_key => { type => 'str', required => 1 },
        lines      => { type => 'rows', required => 1, max => 3,
            row => { product_id => 'int', qty => 'int', note => 'str?', gift => 'bool?' } },
    };
}
sub read_scope  { return { 'x.basket' => ['search_read'] } }
sub write_scope { return { 'x.basket' => [ 'create', 'write' ] } }

sub plan {
    my ($self) = @_;
    my $plan = $self->new_plan( input_count => scalar @{ $self->param("lines") } );
    for my $l ( @{ $self->param('lines') } ) {
        $plan->add( bucket => 'new-line', action => 'create', model => 'x.basket',
            vals => { basket_key => $self->param('basket_key'), product_id => $l->{product_id}, qty => $l->{qty} } );
    }
    return $plan;
}

1;
