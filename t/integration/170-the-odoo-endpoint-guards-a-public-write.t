#!/usr/bin/perl
# SM747 CU / Q1: THE PAGE ENDPOINT, ADVERSARIALLY.
#
# lazysite-odoo.pl is how a page's own JavaScript runs an Odoo binding, and on a
# public basket binding it is an anonymous write path into an ERP. Every attack
# here is one a stranger can make with a browser or a script:
#
#   * CSRF - another site makes a visitor's browser post: the visitor cookie is
#     SameSite=Strict, so it arrives without it, and the token is bound to it;
#   * a missing, stale or another visitor's token;
#   * a forged visitor cookie;
#   * a write sent as a GET;
#   * an oversized or malformed body;
#   * flooding (the cap answers 429);
#   * the extension switched off - nothing answers, not even the cookie.
#
# Driven IN-PROCESS - the script is loaded and its main() called per request
# with the request's environment - because the transport is OOM's fake Odoo,
# injected into the engine the way OOM's own tests inject it, and a child
# process would not have it. Nothing reaches a network.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Auth::Session ();

my $root = repo_root();
require "$root/lazysite-odoo.pl";

my ( $d, $fake ) = shop_ready();
bind( $d, id => 'add', operation => 'shop.add', modes => 'public', apply => 'immediate',
    params => 'product=product, qty=qty', visitor_param => 'basket_key', rate_per_visitor_hour => 5 );
bind( $d, id => 'basket', operation => 'shop.basket', modes => 'public', visitor_param => 'basket_key' );
bind( $d, id => 'list', operation => 'shop.products', modes => 'public', params => 'n=limit' );
bind( $d, id => 'staff-add', operation => 'shop.add', modes => 'authenticated', callers => 'staff',
    params => 'product=product', fixed => 'basket_key=counter' );

make_path("$d/lazysite/auth");
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print {$sf} 'a' x 64;
close $sf;
open my $gf, '>', "$d/lazysite/auth/groups" or die $!;
print {$gf} "staff: sam\n";
close $gf;
open my $uf, '>', "$d/lazysite/auth/users" or die $!;
print {$uf} "sam:x\n";
close $uf;

sub session_cookie {
    my ($user) = @_;
    require Digest::SHA;
    my $payload = "$user:" . time . ':';
    return 'lazysite_auth=' . $payload . ':' . Digest::SHA::hmac_sha256_hex( $payload, 'a' x 64 );
}

# One request through the endpoint. Returns ( status, body, headers ).
sub hit {
    my (%o)  = @_;
    my $body = defined $o{json} ? encode_json( $o{json} ) : ( $o{body} // '' );
    my $out  = '';
    {
        local %ENV = (
            PATH           => $ENV{PATH},
            DOCUMENT_ROOT  => $d,
            REQUEST_METHOD => $o{method} // 'GET',
            QUERY_STRING   => $o{qs}     // '',
            CONTENT_LENGTH => $o{length} // length $body,
            REMOTE_ADDR    => '203.0.113.5',
            ( defined $o{cookie} ? ( HTTP_COOKIE       => $o{cookie} ) : () ),
            ( defined $o{csrf}   ? ( HTTP_X_CSRF_TOKEN => $o{csrf} )   : () ),
        );
        local *STDIN;
        open STDIN, '<', \$body or die $!;
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        quiet( sub { main::main() } );
    }
    my ( $head, $json ) = split /\r\n\r\n/, $out, 2;
    my ($st) = $head =~ /Status:\s*(\d+)/;
    return ( $st // 0, ( eval { decode_json( $json // '' ) } || {} ), $head );
}

sub visitor {
    my ( $st, $r, $head ) = hit( qs => 'csrf=1' );
    my ($cookie) = $head =~ /Set-Cookie: (lzs_odoo_visitor=[^;]+)/;
    return ( $cookie, $r->{visitor_token}, $head );
}

sub lines_for {
    my ($cookie) = @_;
    my ( $st, $r ) = hit( qs => 'binding=basket', cookie => $cookie );
    return $r->{report}{rows} // [];
}

my ( $alice, $alice_t, $head ) = visitor();
my ( $bob, $bob_t ) = visitor();

subtest 'a visitor gets a cookie a page cannot read and a token bound to it' => sub {
    ok( $alice, 'a visitor cookie was set' );
    like( $head,    qr/HttpOnly/,                'HttpOnly' );
    like( $head,    qr/SameSite=Strict/,         'SameSite=Strict' );
    like( $head,    qr/Cache-Control: no-store/, 'and nothing caches the answer' );
    like( $alice_t, qr/\A[0-9a-f]{64}\z/,        'a visitor token' );
    my ( undef, $again, $h2 ) = hit( qs => 'csrf=1', cookie => $alice );
    unlike( $h2, qr/Set-Cookie/, 'a visitor who has one is not given another' );
    is( $again->{visitor_token}, $alice_t, 'and gets the same token' );
};

subtest 'the visitor adds to their basket' => sub {
    my ( $st, $r ) = hit( method => 'POST', cookie => $alice,
        json => { binding => 'add', params => { product => 1, qty => 2 }, visitor_token => $alice_t } );
    is( $st, 200, 'answered' ) or diag explain $r;
    ok( $r->{applied}, 'applied in the request (Q1)' );
    is( scalar @{ lines_for($alice) }, 1, 'and it is in their basket' );
    is( scalar @{ lines_for($bob) },   0, 'and in nobody else\'s' );
};

subtest 'CSRF' => sub {
    my ( $st, $r ) = hit( method => 'POST', cookie => $alice,
        json => { binding => 'add', params => { product => 2 } } );
    is( $st,        403,    'no token: 403' );
    is( $r->{kind}, 'csrf', 'as csrf' );

    ( $st, $r ) = hit( method => 'POST', cookie => $alice,
        json => { binding => 'add', params => { product => 2 }, visitor_token => $bob_t } );
    is( $st, 403, 'another visitor\'s token: 403' );

    # What a cross-site POST looks like: the SameSite=Strict cookie stays
    # behind, and a token lifted from anywhere names no basket without it.
    ( $st, $r ) = hit( method => 'POST',
        json => { binding => 'add', params => { product => 2 }, visitor_token => $alice_t } );
    is( $st, 403, 'a token with no cookie: 403' );
    like( $r->{error}, qr/no visitor key/, 'said as a missing visitor key' );

    my $forged = 'lzs_odoo_visitor=' . ( 'f' x 64 ) . '.' . ( '0' x 64 );
    ( $st, $r ) = hit( method => 'POST', cookie => $forged,
        json => { binding => 'add', params => { product => 2 }, visitor_token => $alice_t } );
    is( $st,                           403, 'a forged cookie is no visitor' );
    is( scalar @{ lines_for($alice) }, 1,   'Alice\'s basket unchanged by any of it' );
};

subtest 'a visitor cannot name another visitor\'s basket' => sub {
    my ( $st, $r ) = hit( method => 'POST', cookie => $bob,
        json => { binding => 'add', params => { product => 2, basket_key => 'x' }, visitor_token => $bob_t } );
    is( $st, 400, 'refused' );
    like( $r->{error}, qr/does not take: basket_key/, 'the key is not a request field' );
    ( $st, $r ) = hit( qs => 'binding=basket&basket_key=x', cookie => $bob );
    is( $st, 400, 'nor on a read' );
};

subtest 'shape and method' => sub {
    my ( $st, $r ) = hit( qs => 'binding=add&product=1', cookie => $alice );
    is( $st, 405, 'a write sent as a GET is refused' );
    ( $st, $r ) = hit( method => 'POST', cookie => $alice, body => 'not json' );
    is( $st, 400, 'a body that is not JSON' );
    ( $st, $r ) = hit( method => 'POST', cookie => $alice, body => '{}', length => 70000 );
    is( $st, 413, 'a body over 64 KB' );
    ( $st, $r ) = hit( qs => 'binding=nope' );
    is( $st, 404, 'an unknown binding' );
    ( $st, $r ) = hit( qs => 'binding=list&n=1' );
    is( $st,                            200, 'a public read needs no token' );
    is( scalar @{ $r->{report}{rows} }, 1,   'and answers' );
    unlike( encode_json($r), qr/site-connection|odoo\.example|shopdb/, 'naming no connection detail' );
};

subtest 'flooding is capped' => sub {
    my $st;
    for ( 1 .. 6 ) {
        ($st) = hit( method => 'POST', cookie => $bob,
            json => { binding => 'add', params => { product => 1 }, visitor_token => $bob_t } );
    }
    is( $st, 429, 'the sixth add in an hour from one visitor: 429' );
};

subtest 'a signed-in account plans and confirms with its own token' => sub {
    my $sam = session_cookie('sam');
    my ( undef, $t ) = hit( qs => 'csrf=1', cookie => $sam );
    ok( $t->{token}, 'a session token for a signed-in account' );
    my ( $st, $r ) = hit( method => 'POST', cookie => $sam, csrf => $t->{token},
        json => { binding => 'staff-add', params => { product => 2 } } );
    is( $st, 200, 'planned' ) or diag explain $r;
    ok( $r->{planned}, 'a plan, not a write' );
    ( $st, $r ) = hit( method => 'POST', cookie => $sam, json => { plan => $r->{plan}, confirm => JSON::PP::true } );
    is( $st, 403, 'a confirm without the token is refused' );
    my $plan = ( hit( method => 'POST', cookie => $sam, csrf => $t->{token},
            json => { binding => 'staff-add', params => { product => 2 } } ) )[1]{plan};
    ( $st, $r ) = hit( method => 'POST', cookie => $sam, csrf => $t->{token},
        json => { plan => $plan, confirm => JSON::PP::true } );
    is( $st, 200, 'with it, applied' ) or diag explain $r;
    ( $st, $r ) = hit( method => 'POST', cookie => $sam, csrf => $t->{token},
        json => { plan => $plan, confirm => JSON::PP::true } );
    is( $st,        409,       'a replayed confirm: 409' );
    is( $r->{kind}, 'applied', 'as already applied' );

    ( $st, $r ) = hit( method => 'POST', cookie => $alice,
        json => { binding => 'staff-add', params => { product => 2 }, visitor_token => $alice_t } );
    is( $st,        403,    'a visitor cannot run the staff binding' );
    is( $r->{kind}, 'mode', 'the mode gate refuses it' );
};

subtest 'switched off, nothing answers' => sub {
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n";
    close $cf;
    my ( $st, $r, $h ) = hit( qs => 'csrf=1' );
    is( $st, 403, 'forbidden' );
    unlike( $h, qr/Set-Cookie/, 'and no visitor cookie is minted' );
};

done_testing();
