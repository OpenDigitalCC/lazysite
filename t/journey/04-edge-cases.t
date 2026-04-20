#!/usr/bin/perl
# Journey: boundary conditions that cross multiple subsystems.
# Each case documents behaviour that's nuanced or surprising so
# future refactors don't silently change it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site run_processor);

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);

# --- Unicode content round-trips ---
{
    open my $fh, '>:utf8', "$docroot/greek.md" or die $!;
    print $fh "---\ntitle: \x{0391}\x{03B2}\n---\n"
            . "Content: \x{4E2D}\x{6587} and emoji \x{1F600}\n";
    close $fh;
    my $out = run_processor( $docroot, '/greek' );
    like( $out, qr/Status: 200 OK/, 'utf-8 page → 200' );
    utf8::decode($out);
    like( $out, qr/\x{4E2D}\x{6587}/, 'CJK round-trips' );
    like( $out, qr/\x{1F600}/,        'emoji round-trips' );
}

# --- Empty front matter (bare `---\n---\n`) ---
{
    open my $fh, '>', "$docroot/bare.md" or die $!;
    print $fh "---\n---\nJust body\n";
    close $fh;
    my $out = run_processor( $docroot, '/bare' );
    like( $out, qr/Status: 200 OK/,  'empty front matter → 200' );
    like( $out, qr/Just body/,        'body still rendered' );
}

# --- URL with encoded characters in query string ---
# FINDING (encoding bug, to fix separately): the processor
# URL-decodes the query value to raw bytes, then passes those bytes
# to Template Toolkit configured with ENCODING => 'utf8'. Each byte
# is treated as a Latin-1 character and re-encoded as UTF-8 on
# output, producing mojibake. For %E2%9C%93 (U+2713 check mark) the
# output is C3 A2 C2 9C C2 93 instead of the expected E2 9C 93.
# The plain-ASCII portion round-trips correctly; the bug only
# surfaces for non-ASCII query values.
#
# Asserting what the code does today, as a TODO, so the fix can
# invert this check when it lands.
{
    open my $fh, '>', "$docroot/q.md" or die $!;
    print $fh "---\ntitle: Q\nquery_params:\n  - q\n---\n"
            . "Got: [% query.q %]\n";
    close $fh;
    my $out = run_processor(
        $docroot, '/q',
        QUERY_STRING => 'q=hello%20world%20%E2%9C%93'
    );
    like( $out, qr/Status: 200 OK/, 'encoded query → 200' );
    like( $out, qr/hello world/,     'ASCII portion of query decoded' );
    TODO: {
        local $TODO = 'query-string UTF-8 decoding (Latin-1 round-trip bug)';
        like( $out, qr/hello world \xE2\x9C\x93/,
              'percent-encoded UTF-8 in query emerges as UTF-8 on page' );
    }
}

# --- Path traversal via request URI → 404, not file read ---
{
    my $out = run_processor( $docroot, '/../../../etc/passwd' );
    unlike( $out, qr/root:/, 'no passwd content served' );
    # Could be 404 or 403 depending on sanitise_uri path; both are fine
    like( $out, qr/Status:\s*(?:404|403)/, 'traversal blocked with error status' );
}

# --- Null byte in URI rejected ---
{
    my $out = run_processor( $docroot, "/page\0null" );
    like( $out, qr/Status:\s*(?:404|403)/, 'null byte in URI rejected' );
}

# --- Same-page concurrent-looking renders don't collide ---
# Write a page, render it twice back-to-back, both must succeed.
# Exercises the atomic tempfile+rename cache write.
{
    open my $fh, '>', "$docroot/concurrent.md" or die $!;
    print $fh "---\ntitle: C\n---\nConcurrent render test\n";
    close $fh;
    unlink "$docroot/concurrent.html" if -f "$docroot/concurrent.html";

    # `run_processor` uses qx() which in list context returns lines
    # as an array; force scalar context so each @outs element is the
    # whole response.
    my @outs = map { scalar run_processor( $docroot, '/concurrent' ) } 1..3;
    like( $_, qr/Status: 200 OK/, 'concurrent-like render → 200' ) for @outs;
    ok( -f "$docroot/concurrent.html", 'cache file present' );
    open my $cf, '<', "$docroot/concurrent.html" or die $!;
    my $cached = do { local $/; <$cf> };
    close $cf;
    unlike( $cached, qr/\.tmp\./, 'no tempfile leakage in cache' );
    like( $cached, qr/Concurrent render test/, 'cache has real content' );
}

# --- 0-byte .md file should not crash; should render empty-ish page ---
{
    open my $fh, '>', "$docroot/zero.md" or die $!;
    close $fh;
    my $out = run_processor( $docroot, '/zero' );
    # Accepting 200 (empty page) or 404 (if processor refuses empty) -
    # both are defensible, pin whichever is current.
    like( $out, qr/Status:\s*(?:200|404)/, '0-byte .md does not crash' );
}

# --- `ttl:` caching respected ---
{
    open my $fh, '>', "$docroot/ttl.md" or die $!;
    print $fh "---\ntitle: TTL\nttl: 60\n---\nBody\n";
    close $fh;
    my $out = run_processor( $docroot, '/ttl' );
    like( $out, qr/Cache-Control:\s*public,\s*max-age=60/,
          'ttl sets public max-age' );
}

done_testing();
