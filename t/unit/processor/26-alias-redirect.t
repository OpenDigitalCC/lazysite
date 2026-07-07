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
like( $out, qr{Status:\s*301}i,          'a known alias returns 301' );
like( $out, qr{Location:\s*/pricing\b},  'the redirect points at the canonical URL' );

my $out2 = run_processor( $docroot, '/plans' );
like( $out2, qr{Location:\s*/pricing\b}, 'a second alias also redirects to the canonical' );

# --- trailing slash on the request still matches ---
my $out3 = run_processor( $docroot, '/plans/' );
like( $out3, qr{Status:\s*301}i, 'a trailing slash on the alias still redirects' );

# --- a genuine miss (not an alias) still 404s, not 301 ---
my $miss = run_processor( $docroot, '/genuinely-missing' );
like(   $miss, qr{Status:\s*404}i, 'an unknown path still 404s' );
unlike( $miss, qr{Status:\s*301}i, 'an unknown path is not redirected' );

# --- the canonical page itself is served, never redirected ---
my $real = run_processor( $docroot, '/pricing' );
unlike( $real, qr{Status:\s*301}i, 'the canonical page is served, not redirected' );

done_testing();
