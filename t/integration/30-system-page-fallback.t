#!/usr/bin/perl
# SM201: engine-required system pages (login/claim/402/403/404) are served with a
# three-tier fallback - per-domain content root, then the primary docroot root,
# then the protected engine default under lazysite/templates/system/. So a deleted
# or never-seeded content copy self-heals instead of 404ing (the field incident: a
# site agent deleted claim.md and /claim 404'd), and a content-rooted subdomain
# without its own copy still serves them.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_processor);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );

# A fresh install: copy starter/. This gives the protected engine defaults under
# lazysite/templates/system/ but NO root login.md/claim.md (they are moved there,
# not seeded to the root) - exactly the tier-3 baseline.
system( 'cp', '-r', "$root/starter/.", $docroot );
make_path("$docroot/lazysite/cache") unless -d "$docroot/lazysite/cache";
system( 'cp', "$docroot/lazysite.conf.example", "$docroot/lazysite/lazysite.conf" )
    if -f "$docroot/lazysite.conf.example" && !-f "$docroot/lazysite/lazysite.conf";
system( 'cp', "$docroot/nav.conf.example", "$docroot/lazysite/nav.conf" )
    if -f "$docroot/nav.conf.example" && !-f "$docroot/lazysite/nav.conf";

ok( -f "$docroot/lazysite/templates/system/claim.md",
    'the protected engine default claim.md is shipped under lazysite/templates/system/' );
ok( !-f "$docroot/claim.md",
    'a fresh install does NOT seed a root claim.md (it lives in the protected tree)' );

sub status_of { my ($r) = @_; my ($s) = $r =~ /Status:\s*(\d+)/; return $s // 0 }

# --- tier 3: no root copy -> the protected engine default serves (not 404) ------
{
    my $out = run_processor( $docroot, '/claim' );
    is( status_of($out), 200, '/claim serves from the engine default (tier 3), not 404' );
    like( $out, qr/password/i, 'the claim page (set-password form) rendered' );

    my $login = run_processor( $docroot, '/login' );
    is( status_of($login), 200, '/login also serves from the engine default' );
}

# --- tier 2/1: a root copy overrides the engine default -------------------------
{
    open my $fh, '>', "$docroot/claim.md" or die $!;
    print $fh "---\ntitle: Local claim\nauth: none\n---\n\nTIER-TWO-ROOT-CLAIM-MARKER\n";
    close $fh;
    unlink "$docroot/claim.html";    # no stale cache

    my $out = run_processor( $docroot, '/claim' );
    is( status_of($out), 200, '/claim still 200 with a root copy present' );
    like( $out, qr/TIER-TWO-ROOT-CLAIM-MARKER/,
        'the root copy overrides the engine default (tier 2 wins)' );
}

# --- self-heal: deleting the root copy falls back again, no 404 -----------------
{
    unlink "$docroot/claim.md";
    unlink "$docroot/claim.html";
    my $out = run_processor( $docroot, '/claim' );
    is( status_of($out), 200,
        'deleting the root claim.md self-heals to the engine default (no 404)' );
    unlike( $out, qr/TIER-TWO-ROOT-CLAIM-MARKER/, 'the deleted root copy is gone' );
}

# --- the fallback is BOUNDED: a non-system missing page still 404s --------------
{
    my $out = run_processor( $docroot, '/definitely-not-a-page' );
    is( status_of($out), 404,
        'a non-system missing page still 404s (fallback does not fire for it)' );
}

# --- content-rooted subdomain with no local copy: serves via the root/default ---
# The processor resolves under the domain content root first; a subdomain that has
# no claim.md of its own must NOT 404 - it falls back to the docroot root / engine
# default. Simulate a folder-root content root that lacks the page.
{
    make_path("$docroot/content/sub");
    open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
    print $cf "\ndomains:\n  - host: sub.example.test\n    content_root: content/sub\n";
    close $cf;
    my $out = run_processor( $docroot, '/claim', HTTP_HOST => 'sub.example.test' );
    is( status_of($out), 200,
        'a content-rooted subdomain without its own claim.md serves the fallback, not 404' );
}

done_testing();
