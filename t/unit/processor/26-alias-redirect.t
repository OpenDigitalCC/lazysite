#!/usr/bin/perl
# SM134: page alias redirects - the processor issues a 301 to the canonical page
# when a requested path is a known alias and nothing else matched. A genuine miss
# still 404s; a real page is served, not redirected.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site run_processor);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);

# A real content page, and an alias map that points two old URLs at it.
open my $p, '>', "$docroot/pricing.md" or die $!;
print $p "---\ntitle: Pricing\naliases:\n  - /old-pricing\n  - /plans\n---\n\nPrices.\n";
close $p;

make_path("$docroot/lazysite");
open my $m, '>', "$docroot/lazysite/aliases.json" or die $!;
print $m '{"/old-pricing":"/pricing","/plans":"/pricing"}';
close $m;

# --- an alias 301s to the canonical page ---
my $out = run_processor( $docroot, '/old-pricing' );
like( $out, qr{Status:\s*301}i,         'a known alias returns 301' );
like( $out, qr{Location:\s*/pricing\b}, 'the redirect points at the canonical URL' );

my $out2 = run_processor( $docroot, '/plans' );
like( $out2, qr{Location:\s*/pricing\b}, 'a second alias also redirects to the canonical' );

# --- trailing slash on the request still matches ---
my $out3 = run_processor( $docroot, '/plans/' );
like( $out3, qr{Status:\s*301}i, 'a trailing slash on the alias still redirects' );

# --- a genuine miss (not an alias) still 404s, not 301 ---
my $miss = run_processor( $docroot, '/genuinely-missing' );
like( $miss, qr{Status:\s*404}i, 'an unknown path still 404s' );
unlike( $miss, qr{Status:\s*301}i, 'an unknown path is not redirected' );

# --- the canonical page itself is served, never redirected ---
my $real = run_processor( $docroot, '/pricing' );
unlike( $real, qr{Status:\s*301}i, 'the canonical page is served, not redirected' );

# === SM134 follow-ups: aliases_temp -> 302; old map entries stay 301 =========
# Build the map through the writer (Lazysite::Aliases), as a save would - a page
# declaring both kinds - then confirm the processor honours the per-entry type.
use lib "$FindBin::Bin/../../../lib";
require Lazysite::Aliases;

open my $mx, '>', "$docroot/moving.md" or die $!;
my $mixed = "---\ntitle: Moving\naliases:\n  - /old-home\naliases_temp:\n  - /interim\n---\n\nHi.\n";
print $mx $mixed;
close $mx;
Lazysite::Aliases::index_page( $docroot, 'moving.md', $mixed );

# --- an aliases_temp entry 302s ---
my $tmp = run_processor( $docroot, '/interim' );
like( $tmp, qr{Status:\s*302 Found}i,  'a temporary alias returns 302 Found' );
like( $tmp, qr{Location:\s*/moving\b}, 'the 302 still points at the canonical URL' );

# --- mixed 301/302 on one page: the permanent sibling stays 301 ---
my $perm = run_processor( $docroot, '/old-home' );
like( $perm, qr{Status:\s*301 Moved Permanently}i, 'the same page\'s aliases: entry stays 301' );
like( $perm, qr{Location:\s*/moving\b}, 'the 301 points at the canonical URL' );

# --- backward compat: the hand-written old-format (string) entries above are
# still 301 with the new reader ---
my $legacy = run_processor( $docroot, '/old-pricing' );
like( $legacy, qr{Status:\s*301 Moved Permanently}i,
    'an old-format (plain string) map entry still redirects 301' );

# --- defence in depth: an unknown code in a hand-edited map falls back to 301 ---
{
    open my $mf, '<', "$docroot/lazysite/aliases.json" or die $!;
    my $raw = do { local $/; <$mf> };
    close $mf;
    $raw =~ s/\}$/,"\/odd":{"target":"\/pricing","code":307}}/;
    open my $wf, '>', "$docroot/lazysite/aliases.json" or die $!;
    print $wf $raw;
    close $wf;
    my $odd = run_processor( $docroot, '/odd' );
    like( $odd, qr{Status:\s*301}i, 'an unknown redirect code reads as 301' );
}

# --- SEC-2026-07 (Low/Info): a hostile alias target (author-controlled) must
# not reflect into the redirect body as XSS, nor inject headers via CR/LF. ---
{
    open my $wf, '>', "$docroot/lazysite/aliases.json" or die $!;
    print $wf '{"/x":"/pricing\"><script>alert(1)</script>"}';
    close $wf;
    my $evil = run_processor( $docroot, '/x' );
    my ($body) = $evil =~ /\r?\n\r?\n(.*)/s;
    $body //= '';
    unlike( $body, qr{<script>alert\(1\)}, 'alias target not reflected as raw <script> in the body' );
    like( $body, qr{&lt;script&gt;alert\(1\)}, 'alias target HTML-escaped in the body' );
}

done_testing();
