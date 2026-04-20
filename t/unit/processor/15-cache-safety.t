#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_processor);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/cache");
make_path("$docroot/lazysite/templates");

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "site_name: Test\nsite_url: http://localhost\n";
close $cf;

open my $vf, '>', "$docroot/lazysite/templates/view.tt" or die $!;
print $vf '<!DOCTYPE html><html><body>[% content %]</body></html>';
close $vf;

open my $idx, '>', "$docroot/index.md" or die $!;
print $idx "---\ntitle: Home\n---\nContent.\n";
close $idx;

open my $nf, '>', "$docroot/404.md" or die $!;
print $nf "---\ntitle: Not Found\n---\nNot found.\n";
close $nf;

# --- cache is written at docroot level for / ---
{
    unlink "$docroot/index.html" if -f "$docroot/index.html";
    run_processor( $docroot, '/' );
    ok(  -f "$docroot/index.html",          'cache file written at docroot' );
    ok( !-f "$docroot/lazysite/index.html", 'cache NOT written inside lazysite/' );
}

# --- LAZYSITE_NOCACHE prevents cache write ---
{
    unlink "$docroot/index.html" if -f "$docroot/index.html";
    run_processor( $docroot, '/', LAZYSITE_NOCACHE => '1' );
    ok( !-f "$docroot/index.html",
        'LAZYSITE_NOCACHE prevents cache write' );
}

# --- cache hit serves the cached content ---
{
    # Pre-populate cache with known content, then touch to make it newer
    # than the .md source.
    open my $fh, '>', "$docroot/index.html" or die $!;
    print $fh "CACHED SENTINEL CONTENT";
    close $fh;
    utime time + 2, time + 2, "$docroot/index.html";

    my $out = run_processor( $docroot, '/' );
    like( $out, qr/CACHED SENTINEL CONTENT/,
        'cache hit serves the cached HTML body' );
    like( $out, qr/Status: 200 OK/, 'status 200 on cache hit' );
}

# --- 404 for missing page ---
{
    my $out = run_processor( $docroot, '/nonexistent-xyz' );
    like( $out, qr/Status: 404/, '404 status for missing page' );
}

# --- lazysite/ URI is forbidden ---
{
    my $out = run_processor( $docroot, '/lazysite/lazysite.conf' );
    like( $out, qr/Status: 403/, 'system directory forbidden' );
}

done_testing();
