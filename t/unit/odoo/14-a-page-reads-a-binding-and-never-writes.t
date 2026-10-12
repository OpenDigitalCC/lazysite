#!/usr/bin/perl
# SM747 CU: a read operation's report handed to TT - `tt_page_var: x: odoo:ID`.
#
# Three refusals make it safe to put in a cached, shared render:
#   * a binding whose operation WRITES is never run by a render - a page view
#     must not plan or apply a change;
#   * a binding that works on a VISITOR'S KEY is never rendered - the render is
#     cached and would serve one visitor's basket to the next;
#   * every scalar in the report is ESCAPED, as a db: row is (SM786) - Odoo's
#     records are typed by people this site has never met.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(load_processor setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready bind quiet fake_shop odoo_site);

BEGIN { oom_or_skip() }
use Lazysite::Odoo ();

my ( $d, $fake ) = shop_ready( shop => { records => {
            'x.product' => [ { name => '<script>alert(1)</script>', price => 1 } ] } } );
setup_minimal_site($d);
odoo_site($d);    # setup_minimal_site rewrote lazysite.conf
bind( $d, id => 'list', operation => 'shop.products', modes => 'public' );
bind( $d, id => 'staff', operation => 'shop.products', modes => 'authenticated', callers => 'staff' );
bind( $d, id => 'add', operation => 'shop.add', modes => 'public', apply => 'immediate',
    params => 'product=product', fixed => 'basket_key=page' );
bind( $d, id => 'basket', operation => 'shop.basket', modes => 'public', visitor_param => 'basket_key' );

load_processor($d);
$Lazysite::Odoo::TRANSPORT = $fake;

sub var {
    my ($spec) = @_;
    my ( $log, %v ) = quiet( sub { main::resolve_tt_vars( { x => $spec } ) } );
    my $v = $v{x};
    return ( $v, $log );
}

subtest 'a public read renders its report' => sub {
    my ($v) = var('odoo:list');
    ok( ref $v eq 'HASH', 'the report is a hash for the template' ) or diag explain $v;
    my @names = map { $_->{name} } @{ $v->{rows} || [] };
    ok( scalar @names,                        'with rows' );
    ok( !( grep { /<script>/ } @names ),      'no raw markup survives' );
    ok( ( grep { /&lt;script&gt;/ } @names ), 'it is escaped, as a db: row is' );
};

subtest 'a render never writes' => sub {
    my $before = scalar @{ $fake->all_ids('x.basket') };
    my ( $v, $log ) = var('odoo:add');
    is( $v, '', 'renders empty' );
    like( $log, qr/a render never runs an operation that writes/, 'and says why in the log' );
    is( scalar @{ $fake->all_ids('x.basket') }, $before, 'and wrote nothing' );
    my @w = grep { $_->[1] eq 'execute_kw' && $_->[6] =~ /create|write/ } @{ $fake->calls };
    is( scalar @w, 0, 'not a single write reached Odoo' );
};

subtest 'a visitor\'s binding is not a page\'s' => sub {
    my ( $v, $log ) = var('odoo:basket');
    is( $v, '', 'renders empty' );
    like( $log, qr/works on a visitor's key/, 'and says to use the endpoint' );
};

subtest 'the binding\'s mode still decides' => sub {
    my ( $v, $log ) = var('odoo:staff');
    is( $v, '', 'an authenticated-only binding renders nothing into a public page' );
    like( $log, qr/kind=mode/, 'refused by the mode gate' );
};

subtest 'switched off, or no such binding' => sub {
    my ( $v, $log ) = var('odoo:nope');
    is( $v, '', 'an unknown binding renders empty' );
    like( $log, qr/names no usable binding/, 'logged' );
};

done_testing();
