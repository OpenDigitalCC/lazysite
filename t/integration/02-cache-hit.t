#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site setup_auth_site run_processor);

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);

# --- first render writes the cache ---
{
    unlink "$docroot/index.html" if -f "$docroot/index.html";
    run_processor( $docroot, '/index' );
    ok( -f "$docroot/index.html", 'cache file written after render' );
}

# --- second render serves cache ---
{
    my $out = run_processor( $docroot, '/index' );
    like( $out, qr/Status: 200 OK/, 'cache hit still serves 200' );
}

# --- LAZYSITE_NOCACHE skips write ---
{
    unlink "$docroot/index.html" if -f "$docroot/index.html";
    run_processor( $docroot, '/index', LAZYSITE_NOCACHE => '1' );
    ok( !-f "$docroot/index.html",
        'LAZYSITE_NOCACHE env suppresses cache write' );
}

# --- protected (auth) page is not cached ---
{
    my $auth = tempdir( CLEANUP => 1 );
    setup_auth_site($auth);
    unlink "$auth/protected.html" if -f "$auth/protected.html";

    my $out = run_processor( $auth, '/protected',
        HTTP_X_REMOTE_USER   => 'alice',
        HTTP_X_REMOTE_GROUPS => 'members',
    );
    like( $out, qr/Status: 200/, 'auth-protected page served 200' );
    ok( !-f "$auth/protected.html",
        'auth-protected page NOT cached to disk' );
    like( $out, qr/Cache-Control:\s*no-store/i,
        'auth-protected page has no-store header' );
}

done_testing();
