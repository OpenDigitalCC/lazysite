#!/usr/bin/perl
# SM070: lazysite-dav.pl gate chain and authentication.
use strict;
use warnings;
use Test::More;
use MIME::Base64 qw(encode_base64);
use Fcntl qw(O_RDWR O_CREAT);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_dav_site run_dav dav_users_tool);

# --- site gate: webdav disabled => 404, nothing advertised ------------
{
    my $s = setup_dav_site( conf => "site_name: t\n" );    # no webdav_enabled
    my $r = run_dav( $s->{docroot}, 'OPTIONS', '/', HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 404, 'disabled site returns 404 (endpoint hidden)' );
}

# --- transport gate: plaintext refused, loopback excepted -------------
{
    my $s = setup_dav_site();
    # Non-loopback, no HTTPS => 403, and no auth challenge over plaintext.
    my $r = run_dav( $s->{docroot}, 'OPTIONS', '/',
        REMOTE_ADDR => '203.0.113.5', HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 403, 'plaintext from non-loopback is refused' );
    ok( !exists $r->{headers}{'www-authenticate'}, 'no Basic challenge over plaintext' );

    # Loopback is allowed without HTTPS.
    my $r2 = run_dav( $s->{docroot}, 'OPTIONS', '/',
        REMOTE_ADDR => '127.0.0.1', HTTP_AUTHORIZATION => $s->{auth} );
    is( $r2->{code}, 200, 'loopback allowed without HTTPS' );
    is( $r2->{headers}{dav}, '1, 2', 'OPTIONS advertises DAV class 1 and 2' );
    like( $r2->{headers}{allow} // '', qr/\bLOCK\b/, 'Allow header lists LOCK' );

    # HTTPS from anywhere is allowed.
    my $r3 = run_dav( $s->{docroot}, 'OPTIONS', '/',
        REMOTE_ADDR => '203.0.113.5', HTTPS => 'on', HTTP_AUTHORIZATION => $s->{auth} );
    is( $r3->{code}, 200, 'HTTPS allowed from non-loopback' );

    # dav_allow_insecure opens plaintext deliberately.
    my $s2 = setup_dav_site( conf => "webdav_enabled: true\ndav_allow_insecure: true\n" );
    my $r4 = run_dav( $s2->{docroot}, 'OPTIONS', '/',
        REMOTE_ADDR => '203.0.113.5', HTTP_AUTHORIZATION => $s2->{auth} );
    is( $r4->{code}, 200, 'dav_allow_insecure permits plaintext' );
}

# --- authentication ----------------------------------------------------
{
    my $s = setup_dav_site();

    my $none = run_dav( $s->{docroot}, 'GET', '/content/x.md' );
    is( $none->{code}, 401, 'missing credentials => 401' );
    like( $none->{headers}{'www-authenticate'} // '', qr/Basic realm="lazysite-dav"/,
        'challenge carries the realm' );

    my $garbled = run_dav( $s->{docroot}, 'GET', '/content/x.md',
        HTTP_AUTHORIZATION => 'Basic !!!not-base64' );
    is( $garbled->{code}, 401, 'garbled Authorization => 401' );

    my $bad = run_dav( $s->{docroot}, 'GET', '/content/x.md',
        HTTP_AUTHORIZATION => 'Basic ' . encode_base64( 'deploy:wrong', '' ) );
    is( $bad->{code}, 401, 'wrong password => 401' );
}

# --- mechanism gate: valid creds but webdav off => 403 ----------------
{
    my $s = setup_dav_site( webdav => 'off' );
    my $r = run_dav( $s->{docroot}, 'GET', '/content/x.md', HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 403, 'webdav-disabled account => 403' );
}

# --- rate limit: DB seeded at the cap => 429 --------------------------
{
    my $s = setup_dav_site();
    # Seed the failed-attempt DB for this IP at the limit.
    my $ip = '198.51.100.7';
    require DB_File;
    my %db;
    my $window = int( time() / 300 );
    tie %db, 'DB_File', "$s->{docroot}/lazysite/auth/.dav-rate.db", O_CREAT | O_RDWR, 0o600;
    $db{"$ip:$window"} = 5;
    untie %db;

    my $r = run_dav( $s->{docroot}, 'GET', '/content/x.md',
        REMOTE_ADDR => $ip, HTTPS => 'on',
        HTTP_AUTHORIZATION => 'Basic ' . encode_base64( 'deploy:wrong', '' ) );
    is( $r->{code}, 429, 'rate-limited IP => 429' );
}

# --- proxy auth headers are ignored -----------------------------------
{
    my $s = setup_dav_site();
    # Present a spoofed upstream-auth context but NO valid Basic creds.
    my $r = run_dav( $s->{docroot}, 'GET', '/content/x.md',
        HTTP_X_REMOTE_USER    => 'deploy',
        LAZYSITE_AUTH_TRUSTED => '1' );
    is( $r->{code}, 401, 'X-Remote-User / LAZYSITE_AUTH_TRUSTED do not authenticate' );
}

done_testing();
