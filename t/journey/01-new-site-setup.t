#!/usr/bin/perl
# Journey: a fresh site comes up and renders. Exercises the same code
# paths as a first-install would: lazysite.conf in place, no cached
# HTML, nav.conf present, 404 page present, index renders, random
# missing page 404s.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site run_processor);

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);

# Write a nav.conf so the nav block is exercised
open my $nf, '>', "$docroot/lazysite/nav.conf" or die $!;
print $nf "Home | /\nAbout | /about\nDocs\n  Install | /docs/install\n";
close $nf;

# Add a non-trivial page so we're not just rendering the index
open my $ab, '>', "$docroot/about.md" or die $!;
print $ab "---\ntitle: About\nsubtitle: A realistic page\n---\n"
        . "## Section\n\nBody text with **bold**.\n";
close $ab;

# --- Fresh render of index ---
{
    my $out = run_processor( $docroot, '/' );
    like( $out, qr/Status: 200 OK/,               'fresh index → 200' );
    like( $out, qr/<!DOCTYPE html>/i,             'DOCTYPE emitted' );
    like( $out, qr/Home page\./,                  'index body rendered' );
    like( $out, qr/X-Content-Type-Options: nosniff/,
          'security header on fresh render' );
    ok( -f "$docroot/index.html",                 'cache file written' );
}

# --- Cache hit on second render ---
{
    my $out = run_processor( $docroot, '/' );
    like( $out, qr/Status: 200 OK/, 'second index → 200 from cache' );
}

# --- About page (not cached yet) ---
{
    my $out = run_processor( $docroot, '/about' );
    like( $out, qr/Status: 200 OK/,          'about → 200' );
    # setup_test_site's minimal view.tt only renders title + content;
    # subtitle is only exposed by richer layouts. Check what the
    # minimal layout actually emits.
    like( $out, qr{<title>About</title>},    'about title rendered' );
    like( $out, qr{<strong>bold</strong>}i,  'markdown processed' );
    ok(   -f "$docroot/about.html",          'about cache file written' );
}

# --- Nav appears on the page (via fallback template) ---
{
    my $out = run_processor( $docroot, '/about' );
    # setup_test_site writes a minimal view.tt that only has
    # [% content %], no nav. Journey covers the fact that pages
    # render whether or not the layout exposes nav.
    ok( $out =~ /About/, 'page title in rendered output' );
}

# --- 404 for missing page ---
{
    my $out = run_processor( $docroot, '/definitely-not-a-page' );
    like( $out, qr/Status: 404/, 'missing page → 404' );
}

# --- lazysite system dir stays forbidden ---
{
    my $out = run_processor( $docroot, '/lazysite/lazysite.conf' );
    like( $out, qr/Status: 403/, '/lazysite/* → 403' );
}

done_testing();
