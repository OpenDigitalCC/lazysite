package Odoo::Test::ActingFake;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Test::FakeOdoo;

# A small shop-shaped world for the operations that act for a person (docs/specs/core-36.md, C-1): three
# customers and a service login, each with a key, and an order of each customer. One fake, whichever context
# asks (OOM_OPS_TEST_TRANSPORT=Odoo::Test::ActingFake, or transport => world()).
#
#   uid 3 shopsvc (the service)        partner 90
#   uid 7 alice@x.example  (consumer)  partner 70, commercial 70       order 100
#   uid 8 ben@bramble.example (contact) partner 71, commercial 700     order 101 is Bramble's (partner 700)
#   uid 9 carol@y.example  (consumer)  partner 72, commercial 72       order 102

our $FAKE;
our %KEY = ( 'shopsvc' => 'KEY-SVC-SECRET-0003', 'alice@x.example' => 'KEY-ALICE-0001', 'ben@bramble.example' => 'KEY-BEN-0002', 'carol@y.example' => 'KEY-CAROL-0004' );

sub world ($class = __PACKAGE__) {
    my $c   = sub { { type => 'char', store => 1 } };
    my $m2o = sub ($rel) { { type => 'many2one', relation => $rel, store => 1 } };
    my $f = Odoo::Test::FakeOdoo->new(
        series  => 16,
        secrets => { tester => 'pw' },
        fields  => {
            'res.users'   => { login => $c->(), name => $c->(), partner_id => $m2o->('res.partner'), active => { type => 'boolean', store => 1 } },
            'res.partner' => { name => $c->(), commercial_partner_id => $m2o->('res.partner') },
            'sale.order'  => { name => $c->(), note => $c->(), partner_id => $m2o->('res.partner'), create_uid => $m2o->('res.users') },
        },
        records => {
            'res.partner' => [
                { id => 70,  name => 'Alice Consumer',  commercial_partner_id => 70 },
                { id => 71,  name => 'Ben Baker',       commercial_partner_id => 700 },
                { id => 700, name => 'Bramble Bakery',  commercial_partner_id => 700 },
                { id => 72,  name => 'Carol Other',     commercial_partner_id => 72 },
                { id => 90,  name => 'Shop Service',    commercial_partner_id => 90 },
            ],
            'res.users' => [
                { id => 2, login => 'tester',              name => 'Tester', partner_id => 90, active => 1 },
                { id => 3, login => 'shopsvc',             name => 'Shop Service', partner_id => 90, active => 1 },
                { id => 7, login => 'alice@x.example',     name => 'Alice', partner_id => 70, active => 1 },
                { id => 8, login => 'ben@bramble.example', name => 'Ben', partner_id => 71, active => 1 },
                { id => 9, login => 'carol@y.example',     name => 'Carol', partner_id => 72, active => 1 },
            ],
            'sale.order' => [
                { id => 100, name => 'S00100', partner_id => 70,  note => 'alice first' },
                { id => 101, name => 'S00101', partner_id => 700, note => 'bramble first' },
                { id => 102, name => 'S00102', partner_id => 72,  note => 'carol first' },
            ],
        },
    );
    $f->add_key( $_ => $KEY{$_} ) for keys %KEY;
    return $FAKE = $f;
}

sub context_args ($class, %o) { return ( transport => $FAKE, retries => [0] ) }
sub finish { }

1;
