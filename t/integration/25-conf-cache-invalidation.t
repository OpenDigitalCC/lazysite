#!/usr/bin/perl
# Issue 1 (site-agent report): a cached page render also depends on lazysite.conf
# (site_name, theme, nav, per-host lang/alias overrides), so a conf change that
# doesn't touch the .md must still invalidate the page cache. Before the fix the
# cache was keyed only on the .md mtime, so a persistent worker (or even a fresh
# CGI) served a page rendered under the OLD conf - the reported stale
# Content-Language / English chrome on a host whose conf now declares its
# language. This is mtime-based, so it holds under CGI and FastCGI alike.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite");
open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print $c "site_name: T\nlang: en\n";
close $c;
open my $i, '>', "$d/index.md" or die $!;
print $i "---\ntitle: Home\n---\n\nhi\n";
close $i;

# First render populates the cache (index.html) under lang: en.
my $out = run_processor( $d, '/' );
like( $out, qr/Content-Language:\s*en/i, 'first render: en' );
ok( -f "$d/index.html", 'the page cache was written' );

# A second render is served straight from that cache - still en.
$out = run_processor( $d, '/' );
like( $out, qr/Content-Language:\s*en/i, 'cache hit: still en' );

# Change ONLY the conf (the .md is untouched), and make the conf newer than the
# cached .html - exactly a "declare the host's language" edit.
open my $c2, '>', "$d/lazysite/lazysite.conf" or die $!;
print $c2 "site_name: T\nlang: de\n";
close $c2;
my $html_mtime = ( stat "$d/index.html" )[9];
utime $html_mtime + 5, $html_mtime + 5, "$d/lazysite/lazysite.conf";
# The .md stays older than the cache, so ONLY the conf change can invalidate it.
utime $html_mtime - 5, $html_mtime - 5, "$d/index.md";

# The next render must NOT serve the stale cache - it re-renders under lang: de.
$out = run_processor( $d, '/' );
like( $out, qr/Content-Language:\s*de/i,
    'a conf-only change invalidates the cache; re-render picks up lang: de' );
like( $out, qr/<html lang="de">/, 'the re-render reflects the new language in <html lang>' );

done_testing;
