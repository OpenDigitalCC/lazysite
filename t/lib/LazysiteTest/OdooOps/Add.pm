package LazysiteTest::OdooOps::Add;

# Test pack (SM747): add a product to a visitor's basket - a WRITE operation,
# the Q1 ruling's case. It also declares a json and a path parameter so the
# engine's refusal to let a request feed either can be tested against a real
# declaration.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name { 'shop.add' }
sub summary { 'Add a product to a basket' }

sub params {
    return {
        basket_key => { type => 'str', required => 1 },
        product    => { type => 'int', required => 1 },
        qty        => { type => 'int', default  => 1 },
        filter     => { type => 'json' },
        journal    => { type => 'path' },
    };
}
sub read_scope { return { 'x.basket' => ['search_read'], 'x.product' => ['search_read'] } }
sub write_scope { return { 'x.basket' => [ 'create', 'write' ] } }

sub plan {
    my ($self) = @_;
    my $key    = $self->param('basket_key');
    my $pid    = $self->param('product');
    my $plan   = $self->new_plan( input_count => 1 );
    my $have = $self->model('x.product')->search_read( [ [ 'id', '=', $pid ] ], ['name'] );
    if ( !@$have ) {
        $plan->add( bucket => 'no-such-product', action => 'skip', reason => "no product $pid" );
        return $plan;
    }
    my $line = $self->model('x.basket')
        ->search_read( [ [ 'basket_key', '=', $key ], [ 'product_id', '=', $pid ] ], ['qty'] );
    if (@$line) {
        $plan->add( bucket => 'more', action => 'write', model => 'x.basket', id => $line->[0]{id},
            vals   => { qty => $line->[0]{qty} + $self->param('qty') },
            before => { qty => $line->[0]{qty} } );
    }
    else {
        $plan->add( bucket => 'new-line', action => 'create', model => 'x.basket',
            vals => { basket_key => $key, product_id => $pid, qty => $self->param('qty') } );
    }
    return $plan;
}

1;
