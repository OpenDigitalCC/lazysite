package Odoo::Test::ActingOps::Who;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use parent 'Odoo::Ops::Operation';

# A test read that acts for a person: who Odoo says the request is, and which uid each client is.

sub op_name ($class) { 'acting.who' }
sub summary ($class) { 'Test: the person of the request and the uid of each client' }
sub pack ($class) { undef }
sub acts_for ($class) { 1 }
sub params ($class) {
    {   partner_id => { type => 'int', help => 'data only: never the person' },
        read       => { type => 'int', help => 'an order id: read its note through the service credential (Pack->service_read)' },
    };
}
sub read_scope ($class) { { 'sale.order' => ['search_read'] } }

use Odoo::Ops::Pack;

sub report ($self) {
    my %r = ( person => $self->person, client_uid => $self->client->uid, service_uid => $self->service_client->uid );
    if ( defined $self->param('read') ) {
        my $got = Odoo::Ops::Pack->service_read( $self, 'core.read', model => 'sale.order', fields => 'note', ids => $self->param('read') );
        $r{read} = $got->{rows};
    }
    return \%r;
}

1;
