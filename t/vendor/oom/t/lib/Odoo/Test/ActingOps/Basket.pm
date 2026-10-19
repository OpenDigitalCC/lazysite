package Odoo::Test::ActingOps::Basket;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use parent 'Odoo::Ops::Operation';

# A test operation that acts for a person (docs/specs/core-36.md, C-1): with no order it makes a draft quotation
# for the person's own partner, with the service credential; with an order it writes that order's note, after
# own() has said the order is the person's. The params partner_id, login and uid are plain data a caller may send;
# they never say who the person is. ODOO_OPS_NAMESPACES=Odoo::Test::ActingOps.

sub op_name ($class) { 'acting.basket' }
sub summary ($class) { 'Test: a draft quotation, or an order note, for the person the request is' }
sub pack ($class) { undef }
sub acts_for ($class) { 1 }
sub params ($class) {
    {   order      => { type => 'int',  help => 'an order to write the note of; none makes a quotation' },
        note       => { type => 'str',  default => 'from the basket' },
        partner_id => { type => 'int',  help => 'data only: never the person' },
        login      => { type => 'str',  help => 'data only: never the person' },
        uid        => { type => 'int',  help => 'data only: never the person' },
    };
}
sub read_scope ($class) { { 'sale.order' => ['read'] } }
sub write_scope ($class) { { 'sale.order' => [ 'create', 'write' ] } }
sub buckets ($class) { [ { name => 'create', meaning => 'a draft quotation for the person' }, { name => 'note', meaning => 'the note of one of the person\'s orders' } ] }

sub plan ($self) {
    my $plan = $self->new_plan( input_count => 1 );
    if ( defined( my $order = $self->param('order') ) ) {
        my ($id) = $self->own( model => 'sale.order', ids => [$order], field => 'partner_id' );
        my $now = $self->service_client->model('sale.order')->read_one( $id, ['note'] );
        $plan->add( bucket => 'note', action => 'write', model => 'sale.order', id => $id, key => "order:$id",
            vals => { note => $self->param('note') }, before => { note => $now->{note} } );
    }
    else {
        $plan->add( bucket => 'create', action => 'create', model => 'sale.order', key => 'quotation',
            vals => { partner_id => $self->person->{partner_id}, note => $self->param('note') }, readback => [qw(partner_id note)] );
    }
    return $plan;
}

1;
