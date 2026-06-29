#!/usr/bin/perl
# The manager admin bar is per-viewer, so it must NOT be written to the shared
# page cache. It is injected per-request at output time. Therefore: the cached
# .html is bar-free; a manager sees the bar on both a cache MISS and a cache HIT;
# an anonymous visitor never sees it - regardless of who warmed the cache first.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/layouts/default");
open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
# manager_groups unset -> any authenticated user is a manager (simplest case);
# auth_proxy_trusted lets the test present an identity via X-Remote-User.
print $c "site_name: T\nlayout: default\nmanager: enabled\nauth_proxy_trusted: true\n";
close $c;
open my $l, '>', "$d/lazysite/layouts/default/layout.tt" or die $!;
print $l '<!DOCTYPE html><html><head><title>[% page_title %]</title></head>'
       . '<body><main>[% content %]</main></body></html>';
close $l;
open my $nf, '>', "$d/404.md" or die $!;
print $nf "---\ntitle: NF\n---\nNF.\n";
close $nf;
open my $idx, '>', "$d/index.md" or die $!;
print $idx "---\ntitle: Home\n---\nHi.\n";
close $idx;

my $BAR = qr{id="ls-admin-bar"};

# 1) Manager warms the cache (cache miss) - sees the bar.
my $mgr1 = run_processor( $d, '/',
    HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => '' );
like( $mgr1, $BAR, 'manager sees the admin bar on a cache miss' );

# 2) The cached file on disk must be bar-free.
my $cached = do { local ( @ARGV, $/ ) = ("$d/index.html"); <> };
unlike( $cached, $BAR, 'cached .html does NOT contain the admin bar' );

# 3) Anonymous visitor on the warm cache - no bar (the bug: it used to show
#    whatever the cache-warmer baked in).
my $anon = run_processor( $d, '/',
    HTTP_X_REMOTE_USER => undef, HTTP_X_REMOTE_GROUPS => undef );
unlike( $anon, $BAR, 'anonymous visitor never sees the bar, even from a warm cache' );

# 4) Manager again, now a cache HIT - bar still injected per-request.
my $mgr2 = run_processor( $d, '/',
    HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => '' );
like( $mgr2, $BAR, 'manager sees the bar on a cache hit too' );

done_testing;
