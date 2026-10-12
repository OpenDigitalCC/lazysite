#!/usr/bin/perl
# SM747 E (R5: "All operations should also be mcp tools"): a signed-in caller -
# the control API's odoo-run, or an MCP agent's odoo_run - reaches an Odoo
# operation through a BINDING, under the binding's modes, callers and caps, as
# a page does. It is never a visitor: a binding that works on a visitor's key
# is neither offered nor run on this door.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo ();

my ( $d, $fake ) = shop_ready();
bind( $d, id => 'list', operation => 'shop.products', modes => 'authenticated', callers => 'staff',
    params => 'n=limit' );
bind( $d, id => 'order', operation => 'shop.add', modes => 'authenticated', callers => 'staff',
    params => 'product=product', fixed => 'basket_key=counter' );
bind( $d, id => 'shop-public', operation => 'shop.products', modes => 'public' );
bind( $d, id => 'basket', operation => 'shop.basket', modes => 'authenticated, public', callers => 'staff',
    visitor_param => 'basket_key' );

my %SAM = ( user => 'sam', groups => ['staff'], caps => {}, ip => '192.0.2.5', channel => 'api' );
my %EVE = ( user => 'eve', groups => ['other'], caps => {}, ip => '192.0.2.6', channel => 'api' );

sub act { my ( $name, @a ) = @_; return ( quiet( sub { Lazysite::Odoo->can($name)->(@a) } ) )[1] }

subtest 'the bindings a caller may run, and only those' => sub {
    my $r   = act( 'action_odoo_bindings', %SAM );
    my %ids = map { $_->{id} => $_ } @{ $r->{bindings} };
    is_deeply( [ sort keys %ids ], [qw(list order)], 'its own callers\' bindings, no public-only one, no visitor one' );
    is( $ids{order}{writes}, 1, 'a write is marked' );
    is_deeply( [ sort keys %{ $ids{order}{params} } ], ['product'], 'with the fields it takes' );
    is( $ids{list}{summary}, 'The products on sale', 'and what it does' );
    is_deeply( act( 'action_odoo_bindings', %EVE )->{bindings}, [], 'a caller in no binding\'s callers sees none' );
    is( scalar @{ act( 'action_odoo_bindings', %EVE, caps => { manage_connectors => 1 } )->{bindings} }, 2,
        'the override capability sees what it may run' );
};

subtest 'a read runs, as the connection user, and is recorded as the account' => sub {
    my $r = act( 'action_odoo_run', 'list', { n => 1 }, %SAM );
    ok( $r->{ok}, 'answered' ) or diag explain $r;
    is( scalar @{ $r->{report}{rows} }, 1, 'with the mapped field applied' );
    my $rec = Lazysite::Odoo::read_calls()->[0];
    is( $rec->{actor}, 'sam',             'the record names the account' );
    is( $rec->{mode},  'authenticated',   'in authenticated mode' );
    is( $rec->{login}, 'site-connection', 'as the connection user' );
};

subtest 'the binding decides who' => sub {
    my $r = act( 'action_odoo_run', 'list', {}, %EVE );
    is( $r->{kind}, 'mode', 'a caller outside the callers is refused by the gate' );
    $r = act( 'action_odoo_run', 'shop-public', {}, %SAM );
    is( $r->{kind}, 'mode', 'a public-only binding is not this door\'s' );
    $r = act( 'action_odoo_run', 'basket', {}, %SAM );
    is( $r->{kind}, 'mode', 'a visitor\'s binding is refused' );
    like( $r->{error}, qr/never a visitor's/, 'and says this door is never a visitor\'s' );
    $r = act( 'action_odoo_run', 'list', { n => 1, extra => 2 }, %SAM );
    like( $r->{error}, qr/does not take: extra/, 'an unmapped field is refused by name' );
    $r = act( 'action_odoo_run', 'nope', {}, %SAM );
    is( $r->{kind}, 'not-found', 'an unknown binding' );
    $r = act( 'action_odoo_run', 'list', [1], %SAM );
    is( $r->{kind}, 'invalid', 'params that are not an object' );
};

subtest 'a write plans, and only its maker confirms' => sub {
    my $p = act( 'action_odoo_run', 'order', { product => 1 }, %SAM );
    ok( $p->{planned}, 'a plan' ) or diag explain $p;
    my $other = act( 'action_odoo_confirm', $p->{plan}, %SAM, user => 'tom' );
    is( $other->{kind}, 'not-found', 'another account cannot confirm it' );
    my $c = act( 'action_odoo_confirm', $p->{plan}, %SAM );
    ok( $c->{applied}, 'its maker applies it' ) or diag explain $c;
    is( scalar @{ $fake->all_ids('x.basket') },                 1, 'and it is in Odoo' );
    is( act( 'action_odoo_confirm', $p->{plan}, %SAM )->{kind}, 'applied', 'once' );
};

done_testing();
