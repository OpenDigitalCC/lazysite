#!/usr/bin/perl
# SM747 E-Q1 (as recommended, approved 2026-10-13): A BINDING WITH A `domain:`
# RUNS ONLY FOR REQUESTS ON THAT DOMAIN; one without stays instance-wide.
#
# SM1051 gave every handler a domain, governing who edits it and which forms
# bind it. Before this, the RUNNING door ignored it: a page on another site, or
# an agent confined to another domain, ran a domain's binding by naming its id.
# The rule, in the one function that sends (Lazysite::Odoo::call) and so on
# every door:
#
#   * a request on a host (a page, the page endpoint, a form): that host must
#     be the binding's domain;
#   * a signed-in caller with no host (the control API, MCP): the caller must
#     reach the domain, by SM976's one rule - an unconfined operator does;
#   * the schedule: no request, no host, so the binding runs - the operator
#     scheduled it;
#   * none of these said: refused, never assumed.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Odoo ();

my ( $d, $fake ) = shop_ready();
File::Path::make_path( "$d/sites/shop", "$d/sites/other" );
open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "alias_hosts: shop.example, other.example\n"
    . "alias.shop.example.content_root: sites/shop\nalias.other.example.content_root: sites/other\n";
close $cf;

bind( $d, id => 'shop-list', domain => 'shop.example', operation => 'shop.products',
    modes => 'public, authenticated, scheduled', callers => 'staff' );
bind( $d, id => 'shop-order', domain => 'shop.example', operation => 'shop.add',
    modes => 'authenticated', callers => 'staff', params => 'product=product', fixed => 'basket_key=k' );
bind( $d, id => 'all-list', operation => 'shop.products', modes => 'public, authenticated', callers => 'staff' );

sub run_b {
    my ( $id,   %ctx ) = @_;
    my ( undef, $r )   = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding($id);
            Lazysite::Odoo::call( $b, {}, %ctx );
    } );
    return $r;
}

my %STAFF = ( mode => 'authenticated', actor => 'sam', groups => ['staff'] );

# reach => {} is "the manager request, whose own state says who is asking".
# This is that state for the cookie operator: no token, no scope.
sub as_operator {
    my ($code) = @_;
    require Lazysite::Manager::Common;
    no warnings 'once';
    local $Lazysite::Manager::Common::token_auth       = 0;
    local @Lazysite::Manager::Common::REQUEST_SCOPES   = ();
    local $Lazysite::Manager::Common::REQUEST_CONFINED = 0;
    return $code->();
}

subtest 'a request on a host runs only its domain\'s binding' => sub {
    ok( run_b( 'shop-list', mode => 'public', host => 'shop.example' )->{ok}, 'on its own domain: runs' );
    my $r = run_b( 'shop-list', mode => 'public', host => 'other.example' );
    is( $r->{kind}, 'wrong-domain', 'on another domain: refused' );
    like( $r->{error}, qr/belongs to the domain shop\.example/, 'saying whose it is' );
    is( run_b( 'shop-list', mode => 'public', host => 'primary.example' )->{kind}, 'wrong-domain',
        'on the primary site: refused' );
    ok( run_b( 'all-list', mode => 'public', host => 'other.example' )->{ok},
        'a binding with no domain runs anywhere' );
};

subtest 'a signed-in caller with no host runs it only if it reaches the domain' => sub {
    ok( run_b( 'shop-list', %STAFF, reach => { scopes => ['sites/shop'] } )->{ok},
        'a grant scoped to the domain: runs' );
    my $r = run_b( 'shop-list', %STAFF, reach => { scopes => ['sites/other'] } );
    is( $r->{kind}, 'wrong-domain', 'a grant scoped elsewhere: refused' );
    like( $r->{error}, qr/does not reach the domain shop\.example/, 'saying so' );
    is( run_b( 'shop-list', %STAFF, reach => { scopes => [] } )->{kind}, 'wrong-domain',
        'a grant naming no scope reaches no domain (SM975)' );
    ok( as_operator( sub { run_b( 'shop-list', %STAFF, reach => {} ) } )->{ok},
        'the unconfined operator reaches every domain' );
    is( run_b( 'shop-list', %STAFF, reach => {} )->{kind}, 'wrong-domain',
        'outside a manager request that state is fail-closed: refused' );
    ok( run_b( 'all-list', %STAFF, reach => { scopes => ['sites/other'] } )->{ok},
        'a binding with no domain is the instance\'s, for every caller' );
};

subtest 'the schedule runs it; a call that names neither is refused' => sub {
    ok( run_b( 'shop-list', mode => 'scheduled' )->{ok}, 'scheduled: no request, no host' );
    my $r = run_b( 'shop-list', %STAFF );
    is( $r->{kind}, 'wrong-domain', 'neither a host nor a reach: refused, never assumed' );
};

subtest 'the confirm is held to the same rule' => sub {
    my ( undef, $p ) = quiet( sub {
            my ($b) = Lazysite::Odoo::find_binding('shop-order');
            as_operator( sub { Lazysite::Odoo::call( $b, { product => 1 }, %STAFF, reach => {} ) } );
    } );
    ok( $p->{planned}, 'a plan, made by the operator' ) or diag explain $p;
    my ( undef, $c ) = quiet( sub {
            Lazysite::Odoo::confirm( $p->{plan}, %STAFF, reach => { scopes => ['sites/other'] } );
    } );
    is( $c->{kind}, 'wrong-domain', 'confirming it from a reach that misses the domain: refused' );
    ( undef, $c ) = quiet( sub { as_operator( sub { Lazysite::Odoo::confirm( $p->{plan}, %STAFF, reach => {} ) } ) } );
    ok( $c->{applied}, 'from one that reaches it: applied' ) or diag explain $c;
};

subtest 'the list offers only what the caller may run' => sub {
    my ( undef, $r ) = quiet( sub {
            Lazysite::Odoo::action_odoo_bindings( user => 'sam', groups => ['staff'], caps => {},
                reach => { scopes => ['sites/other'] } );
    } );
    is_deeply( [ sort map { $_->{id} } @{ $r->{bindings} } ], ['all-list'],
        'a grant scoped elsewhere sees only the instance\'s binding' );
};

subtest 'every refusal is a row' => sub {
    my @k = grep { ( $_->{kind} // '' ) eq 'wrong-domain' } @{ Lazysite::Odoo::read_calls() };
    ok( scalar @k >= 5, 'recorded in the call record' );
};

done_testing();
