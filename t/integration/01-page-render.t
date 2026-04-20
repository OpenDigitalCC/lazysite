#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site setup_minimal_site run_processor);

# --- full pipeline render via subprocess ---
my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);

{
    my $out = run_processor( $docroot, '/index' );
    like( $out, qr/Status: 200 OK/,   '/index status 200' );
    like( $out, qr/<!DOCTYPE html>/i, 'DOCTYPE emitted' );
    like( $out, qr/Home page\./,      'body content rendered' );
}

# --- missing page → 404 ---
{
    my $out = run_processor( $docroot, '/nonexistent' );
    like( $out, qr/Status: 404/, 'missing page → 404' );
}

# --- api: true page → application/json content type ---
{
    my $out = run_processor( $docroot, '/api-test' );
    like( $out, qr{Content-type:\s*application/json}i,
        'api: true → application/json content-type' );
}

# --- raw: true page → text/plain content type ---
{
    my $out = run_processor( $docroot, '/raw-test' );
    like( $out, qr{Content-type:\s*text/plain}i,
        'raw: true → text/plain content-type' );
}

# --- fallback layout when no view.tt ---
{
    my $no_view = tempdir( CLEANUP => 1 );
    setup_minimal_site($no_view);  # no templates/view.tt
    my $out = run_processor( $no_view, '/index' );
    like( $out, qr/Status: 200 OK/,      'fallback render status 200' );
    like( $out, qr/built-in fallback/i,  'fallback layout used' );
}

# --- /lazysite/ path blocked ---
{
    my $out = run_processor( $docroot, '/lazysite/lazysite.conf' );
    like( $out, qr/Status: 403/, '/lazysite/* path → 403' );
}

# --- /lazysite-demo (not a system path) is accessible (may 404 here) ---
{
    my $out = run_processor( $docroot, '/lazysite-demo' );
    unlike( $out, qr/Status: 403/,
        '/lazysite-demo not blocked by /lazysite/ rule' );
}

# --- URI with trailing slash resolves to directory index ---
{
    my $out = run_processor( $docroot, '/' );
    like( $out, qr/Status: 200 OK/, '/ serves index' );
}

done_testing();
