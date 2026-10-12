#!/usr/bin/perl
# SM747 CU / Q1 - THE ANONYMOUS WRITE PATH, ADVERSARIALLY.
#
# The ruling: a visitor adds to a basket and Odoo holds it as a quotation, with
# nobody confirming. Two visitors share one connection user, so Odoo cannot
# tell them apart; lazysite must. Each attack below is one a visitor can make
# with nothing but requests:
#
#   * add to another visitor's basket, by naming its key in a field;
#   * read another visitor's basket, the same way;
#   * confirm another visitor's plan, or find plans by guessing ids;
#   * forge a visitor key the server never minted.
#
# Each must fail, and the visitor's own basket must work.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo          ();
use Lazysite::Odoo::Visitor ();

my ( $d, $fake ) = shop_ready();
$Lazysite::Odoo::Visitor::DOCROOT = $d;
bind( $d, id => 'add', operation => 'shop.add', modes => 'public', apply => 'immediate',
    params => 'product=product, qty=qty', visitor_param => 'basket_key' );
bind( $d, id => 'basket', operation => 'shop.basket', modes => 'public', visitor_param => 'basket_key' );
bind( $d, id => 'add-later', operation => 'shop.add', modes => 'public',
    params => 'product=product', visitor_param => 'basket_key' );

my ($alice) = Lazysite::Odoo::Visitor::mint();
my ($bob)   = Lazysite::Odoo::Visitor::mint();

sub as {
    my ( $key, $id, $input, %o ) = @_;
    my ( undef, $r ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding($id);
            Lazysite::Odoo::call( $b, $input, mode => 'public', visitor_key => $key,
                ip => '198.51.100.1', strict => 1, %o );
    } );
    return $r;
}

sub lines_for {
    my ($key) = @_;
    return [ grep { $_->{basket_key} eq $key }
        map { $fake->record( 'x.basket', $_ ) } @{ $fake->all_ids('x.basket') } ];
}

subtest 'a visitor adds to their own basket, unattended (Q1)' => sub {
    my $r = as( $alice, 'add', { product => 1, qty => 2 } );
    ok( $r->{ok},      'applied' ) or diag explain $r;
    ok( $r->{applied}, 'in the same request' );
    is( $r->{result}{counts}{done},    1, 'one change done' );
    is( scalar @{ lines_for($alice) }, 1, 'a line in Alice\'s basket' );
    $r = as( $alice, 'add', { product => 1, qty => 1 } );
    is( lines_for($alice)->[0]{qty}, 3, 'adding again raises the quantity' );
    unlike( JSON::PP::encode_json($r), qr{/tmp/|lazysite/odoo}, 'no host path in the answer' );
};

subtest 'Bob cannot add to Alice\'s basket by naming her key' => sub {
    my $r = as( $bob, 'add', { product => 2, basket_key => $alice } );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error}, qr/does not take: basket_key/, 'the key is not a field a request may send' );
    is( scalar @{ lines_for($alice) }, 1, 'Alice\'s basket is as it was' );

    # And a form, which drops unmapped fields rather than refusing: the
    # server's key still stands.
    $r = as( $bob, 'add', { product => 2, basket_key => $alice }, strict => 0 );
    ok( $r->{ok}, 'a form-style post goes through' ) or diag explain $r;
    is( scalar @{ lines_for($alice) }, 1, 'but not into Alice\'s basket' );
    is( scalar @{ lines_for($bob) },   1, 'into Bob\'s' );
};

subtest 'Bob cannot read Alice\'s basket' => sub {
    my $r = as( $bob, 'basket', {} );
    ok( $r->{ok}, 'Bob reads a basket' );
    is_deeply( [ map { $_->{product_id} } @{ $r->{report}{rows} } ], [2], 'his own, and only his' );
    $r = as( $bob, 'basket', { basket_key => $alice } );
    ok( !$r->{ok}, 'naming Alice\'s key is refused' );
};

subtest 'a key the server did not mint is no visitor at all' => sub {
    my $forged = 'f' x 64;
    my $cookie = "$Lazysite::Odoo::Visitor::COOKIE=$forged." . ( '0' x 64 );
    is( Lazysite::Odoo::Visitor::key_from_cookie($cookie), undef, 'the endpoint would find no key' );
    my $r = as( undef, 'add', { product => 1 } );
    ok( !$r->{ok}, 'and with no key the basket binding refuses' );
    like( $r->{error}, qr/no visitor key/, 'saying why' );
};

subtest 'Bob cannot confirm Alice\'s plan, nor find plans by guessing' => sub {
    my $plan = as( $alice, 'add-later', { product => 2 } );
    ok( $plan->{planned}, 'Alice has a plan waiting' ) or diag explain $plan;
    like( $plan->{plan}, qr/\A[0-9a-f]{32}\z/, 'its id is 128 random bits' );
    ok( !exists $plan->{preview}{changes}[0]{vals}, 'the preview carries no values' );

    my ( undef, $r ) = quiet( sub { Lazysite::Odoo::confirm( $plan->{plan}, mode => 'public', visitor_key => $bob ) } );
    is( $r->{kind}, 'not-found', 'Bob confirming it: not found' );
    my ( undef, $g ) = quiet( sub { Lazysite::Odoo::confirm( '0' x 32, mode => 'public', visitor_key => $bob ) } );
    is( $g->{error}, $r->{error}, 'exactly what an id that does not exist gets' );
    my ( undef, $m ) = quiet( sub { Lazysite::Odoo::confirm( '../../etc', mode => 'public', visitor_key => $bob ) } );
    is( $m->{error},                   $r->{error}, 'and a malformed one' );
    is( scalar @{ lines_for($alice) }, 1,           'Alice\'s basket unchanged' );

    my ( undef, $ok ) = quiet( sub { Lazysite::Odoo::confirm( $plan->{plan}, mode => 'public', visitor_key => $alice ) } );
    ok( $ok->{ok}, 'Alice confirms her own' ) or diag explain $ok;
    is( scalar @{ lines_for($alice) }, 2, 'and her basket has the new line' );
};

subtest 'the records name visitors by hash' => sub {
    open my $fh, '<', Lazysite::Odoo::calls_file() or die $!;
    my $all = do { local $/; <$fh> };
    close $fh;
    unlike( $all, qr/\Q$alice\E|\Q$bob\E/, 'no visitor key in the call record' );
    like( $all, qr/"visitor":"\Q${\ Lazysite::Odoo::Visitor::visitor_id($alice) }\E"/, 'Alice by her hash' );
    my @audit = glob("$d/lazysite/odoo/plans/*/audit.jsonl");
    ok( scalar @audit, 'OOM wrote its own audit beside each plan' );
    my $oom = join '', map { open my $a, '<', $_; local $/; <$a> } @audit;
    unlike( $oom, qr/\Q$alice\E/, 'and it holds no visitor key either' );
    like( $oom, qr/"actor":"visitor:/, 'it names the visitor as the actor' );
};

done_testing();
