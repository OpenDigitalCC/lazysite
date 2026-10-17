package LazysiteTest::OdooOps::Ship;

# Test pack (SM1171, OOM Lab L-13): a write whose plan holds one change for a
# reason, makes one record, and carries out one custom change that answers a
# `returned` value (a backorder's name, in the Lab's picking app). `size`
# makes that value as large as the test needs. The changes carry values the
# caller did not send (`note`, `secret`), which must never reach a page.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name { 'shop.ship' }
sub summary { 'Hold a line, make one, and answer a backorder' }

sub params {
    return {
        product => { type => 'int', required => 1 },
        size    => { type => 'int', default  => 0 },
    };
}
sub read_scope  { return { 'x.product' => ['search_read'] } }
sub write_scope { return { 'x.basket' => ['create'] } }

sub plan {
    my ($self) = @_;
    my $pid  = $self->param('product');
    my $plan = $self->new_plan( input_count => 3 );
    $plan->add( bucket => 'short', action => 'hold', model => 'x.basket', id => 7,
        reason => "only 1 of product $pid on hand", vals => { note => 'internal-note-hold' } );
    $plan->add( bucket => 'new-line', action => 'create', model => 'x.basket',
        vals => { basket_key => 'ship', product_id => $pid, qty => 1 } );
    $plan->add( bucket => 'backorder', action => 'custom', handler => 'shop.ship', kind => 'backorder',
        model => 'x.basket', id => 9, vals => { size => $self->param('size'), secret => 'internal-secret-vals' } );
    return $plan;
}

sub apply_custom {
    my ( $class, $client, $c ) = @_;
    my $n = $c->{vals}{size};
    return { id => $c->{id}, returned => ( $n ? 'x' x $n : 'BO/00042' ), after => undef };
}

1;
