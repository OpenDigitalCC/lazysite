#!/usr/bin/perl
# SM389: registry hits were the one served path that recorded nothing at all.
#
# _serve_registry printed a 200 and never touched %ACCESS_REC, so a crawler
# fetching /sitemap.xml every few hours left no trace anywhere. That is exactly
# the traffic an operator wants to see - it is how you tell a search engine is
# still interested - and it was invisible.
#
# COUNTED, BUT NOT AS A PAGE VIEW. Its own channel and its own counters. Folding
# a sitemap fetch into `hits` would inflate the single figure an operator reads
# as "people", which is the SM329 mistake (an image counted as a page) repeated
# on a different path. Recording and counting are separate decisions and this
# makes both of them explicitly.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $plugin = "$root/plugins/stats.pl";
plan skip_all => "no $plugin" unless -f $plugin;

# --- the processor must record the hit at all -------------------------
{
    my $src = do { open my $fh, '<', "$root/lazysite-processor.pl" or die $!; local $/; <$fh> };
    my ($serve) = $src =~ /(sub _serve_registry \{.*?\n\})/s;
    ok( $serve, 'the registry server can be isolated' );
    like( $serve, qr/\$ACCESS_REC\{s\}\s*=\s*200/,
        'it records a served registry as a 200' );
    like( $serve, qr/\$ACCESS_REC\{ch\}\s*=\s*'registry'/,
        'on its own channel, so it is not counted as a page' );
}

# --- and the plugin must count it, separately -------------------------
my $d = tempdir( 'lazysite-reg-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
make_path( "$d/lazysite/logs", "$d/lazysite/stats", "$d/lazysite/cache" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_url: https://d.example.io\n";
close $cf;

my $now = time();
# SM600: THE DAY COMES FROM THE RECORDS, NOT FROM NOW.
#
# This fixture stamps its records 90 minutes back so the session is older than
# SESSION_GAP and the export closes it into a trail. It used to derive the day
# it asks for from `$now`, and for the 90 minutes after UTC midnight those are
# opposite sides of midnight: written under yesterday, asked for today. The
# same commit passed its release gate at 23:18 UTC and failed at 00:20.
#
# `$now` itself stays the real clock, deliberately: the export decides what is
# old enough to close by comparing against the real time, so back-dating $now
# stops sessions closing at all and no trail is written.
my $rec = $now - 5400;
my @gm  = gmtime($rec);
my $ymd = sprintf '%04d%02d%02d',   $gm[5] + 1900, $gm[4] + 1, $gm[3];
my $day = sprintf '%04d-%02d-%02d', $gm[5] + 1900, $gm[4] + 1, $gm[3];

open my $lf, '>', "$d/lazysite/logs/access-$ymd.jsonl" or die $!;
my $i = 0;
sub ev {
    my ( $path, $ch ) = @_;
    printf {$lf} qq({"t":%d,"p":"%s","s":200,"ch":"%s","v":"V1","ua":"Mozilla/5.0 Chrome/120"}\n),
        $rec + ( $i++ * 10 ), $path, $ch;
}
ev( '/',            'page' );
ev( '/about',       'page' );
ev( '/sitemap.xml', 'registry' );
ev( '/sitemap.xml', 'registry' );
ev( '/feed.rss',    'registry' );
close $lf;

my $out = `DOCUMENT_ROOT=\Q$d\E $^X \Q$plugin\E --export --day \Q$day\E 2>/dev/null`;
my $r   = eval { decode_json($out) } || {};
my $b   = $r->{day}                  || {};

ok( $r->{ok}, 'the day rollup answers' ) or diag($out);
is( $b->{registry_hits}, 3, 'every registry hit is counted' );
is_deeply(
    $b->{registry_by},
    { 'sitemap.xml' => 2, 'feed.rss' => 1 },
    'and counted per registry, so an operator can see WHICH is being fetched'
);

# The load-bearing half: it must not have inflated the page figures.
is( $b->{pageviews}, 2, 'the page count is the pages, not the pages plus the registries' );

done_testing();
