#!/usr/bin/perl
# RI-001 regression: the dev server (tools/lazysite-server.pl) must forward
# EVERY response header a CGI emits, including a header name that repeats.
# lazysite-auth.pl sends two Set-Cookie headers on login (the HttpOnly session
# cookie + the SM099 lzs_session display marker) and two on logout (both
# cleared). The old parser keyed headers by name in a hash, so the second
# Set-Cookie overwrote the first - dropping the real auth cookie on login, and
# (worse) dropping the cookie-clearing header on logout, leaving a live session.
#
# parse_cgi_headers now returns an ordered list of [name, value] pairs. The
# server is a modulino (require-safe: `return 1 if caller` before it binds), so
# this test drives the pure parser directly - no port, no subprocess, no flake.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $server = repo_root() . '/tools/lazysite-server.pl';
require $server;

can_ok( 'main', 'parse_cgi_headers' );

# --- Login: two Set-Cookie headers, both preserved, in order ---------------
{
    my $block = join "\r\n",
        'Status: 302 Found',
        'Content-type: text/html; charset=utf-8',
        'Set-Cookie: lazysite_auth=SIGNED; Path=/; HttpOnly; SameSite=Lax',
        'Set-Cookie: lzs_session=1; Path=/; SameSite=Lax',
        'Location: /';

    my ( $status, $ctype, $extra ) = main::parse_cgi_headers($block);

    is( $status, '302 Found', 'Status line parsed' );
    is( $ctype, 'text/html; charset=utf-8', 'Content-type parsed' );

    my @cookies = grep { lc $_->[0] eq 'set-cookie' } @{$extra};
    is( scalar @cookies, 2, 'both Set-Cookie headers preserved (not collapsed)' );
    like( $cookies[0][1], qr/^lazysite_auth=SIGNED/,
        'the real HttpOnly session cookie survives (RI-001 core)' );
    like( $cookies[1][1], qr/^lzs_session=1/,
        'the SM099 display marker is also present' );

    # Location must still be forwarded alongside the cookies.
    ok( ( grep { lc $_->[0] eq 'location' } @{$extra} ),
        'Location header preserved next to the repeated Set-Cookie' );
}

# --- Logout: both clearing headers preserved (the nastier half) ------------
{
    my $block = join "\r\n",
        'Status: 302 Found',
        'Content-type: text/html',
        'Set-Cookie: lazysite_auth=; Path=/; Max-Age=0',
        'Set-Cookie: lzs_session=; Path=/; Max-Age=0',
        'Location: /login';

    my ( undef, undef, $extra ) = main::parse_cgi_headers($block);
    my @cookies = grep { lc $_->[0] eq 'set-cookie' } @{$extra};
    is( scalar @cookies, 2,
        'logout keeps BOTH clearing headers (real cookie clear not dropped)' );
    ok( ( grep { $_->[1] =~ /^lazysite_auth=;/ } @cookies ),
        'the session-clearing Set-Cookie is emitted' );
}

# --- Single-header and body-split sanity -----------------------------------
{
    my ( $status, $ctype, $extra ) =
        main::parse_cgi_headers("Content-type: application/json\r\nX-Thing: 1");
    is( $status, '200 OK', 'default status when none given' );
    is( $ctype, 'application/json', 'content-type from a single header' );
    is( scalar @{$extra}, 1, 'one extra header collected' );
    is( $extra->[0][0], 'X-Thing', 'extra header name' );
}

done_testing();
