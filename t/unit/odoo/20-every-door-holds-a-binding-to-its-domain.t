#!/usr/bin/perl
# SM747 E-Q1 (approved 2026-10-13), on the doors a request on a site comes
# through: the page endpoint, the `odoo:` page binding and a form. Each names
# the host it was asked on, and a domain's binding answers only there. The
# schedule names none and runs what the operator scheduled.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root load_processor setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready bind quiet odoo_site);

BEGIN { oom_or_skip() }
use Lazysite::Odoo     ();
use Lazysite::Handlers ();

my $root = repo_root();
my ( $d, $fake ) = shop_ready();
setup_minimal_site($d);
odoo_site($d);
make_path( "$d/sites/shop", "$d/sites/other" );
open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "alias_hosts: shop.example, other.example\n"
    . "alias.shop.example.content_root: sites/shop\nalias.other.example.content_root: sites/other\n";
close $cf;

bind( $d, id => 'shop-list', domain => 'shop.example', operation => 'shop.products',
    modes => 'public, scheduled' );
bind( $d, id => 'shop-signup', domain => 'shop.example', operation => 'shop.add', modes => 'public, scheduled',
    apply => 'immediate', params => 'product=product', fixed => 'basket_key=newsletter' );

load_processor($d);
require "$root/lazysite-odoo.pl";
$Lazysite::Odoo::TRANSPORT   = $fake;
$Lazysite::Handlers::DOCROOT = $d;

sub endpoint {
    my ($host) = @_;
    my $out = '';
    {
        local %ENV = ( PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET',
            QUERY_STRING => 'binding=shop-list', HTTP_HOST => $host, REMOTE_ADDR => '198.51.100.3' );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        quiet( sub { main::main() } );
    }
    my ( $head, $json ) = split /\r\n\r\n/, $out, 2;
    my ($st) = $head =~ /Status:\s*(\d+)/;
    return ( $st // 0, eval { decode_json( $json // '' ) } || {} );
}

subtest 'the page endpoint' => sub {
    my ( $st, $r ) = endpoint('shop.example');
    is( $st, 200, 'on its own domain: answered' ) or diag explain $r;
    ( $st, $r ) = endpoint('other.example');
    is( $st,        403,            'on another domain: forbidden' );
    is( $r->{kind}, 'wrong-domain', 'as wrong-domain' );
    ( $st, $r ) = endpoint('shop.example:8443');
    is( $st, 200, 'a port on the host is not a different domain' );
};

subtest 'the page binding' => sub {
    my $page = sub {
        my ($host) = @_;
        local $ENV{HTTP_HOST} = $host;
        my ( $log, %v ) = quiet( sub { main::resolve_tt_vars( { x => 'odoo:shop-list' } ) } );
        return ( $v{x}, $log );
    };
    my ($v) = $page->('shop.example');
    ok( ref $v eq 'HASH' && @{ $v->{rows} || [] }, 'renders on its own domain' );
    my ( $none, $log ) = $page->('other.example');
    is( $none, '', 'renders nothing on another' );
    like( $log, qr/kind=wrong-domain/, 'and the log says why' );
};

subtest 'a form, and the schedule' => sub {
    my $deliver = sub {
        my ( $host, %ctx ) = @_;
        local $ENV{HTTP_HOST} = $host;
        my ( undef, $r ) = quiet( sub {
                Lazysite::Handlers::deliver( 'shop-signup', { product => 1 }, source => 'form:x', %ctx );
        } );
        return $r;
    };
    my $qty = sub {
        my ($l) = grep { ( $_->{basket_key} // q() ) eq q(newsletter) } map { $fake->record( q(x.basket), $_ ) } @{ $fake->all_ids(q(x.basket)) };
        return $l ? $l->{qty} : 0;
    };
    my $before = $qty->();
    ok( $deliver->( 'shop.example', origin => 'form' )->{ok}, 'a form on its own domain: delivered' );
    my $r = $deliver->( 'other.example', origin => 'form' );
    ok( !$r->{ok}, 'a form posted on another domain: refused' );
    like( $r->{why}, qr/belongs to the domain shop\.example/, 'saying whose it is' );
    ok( $deliver->( 'other.example', origin => 'timer', actor => 'jobs' )->{ok},
        'the schedule has no host and runs it' );
    is( $qty->(), $before + 2, 'exactly the two that were allowed wrote' );
};

done_testing();
