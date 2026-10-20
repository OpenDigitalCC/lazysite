#!/usr/bin/perl
# SM1203: the installed app's service worker re-fetches each offline page behind
# every view of it (SM1197) and the engine records that fetch on its own channel,
# `app` (lazysite-processor/access-log.pm, from the X-Lazysite-App: keep header).
#
# COUNTED, BUT NOT AS A VISIT. The same decision SM389 made for a registry fetch:
# its own counters beside the page figures, never inside them. In the browser's
# own User-Agent, the fetch classified `unattributed`, which is where any human
# is, so each such page counted twice. Recording and counting are separate
# decisions; this holds the second.
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

my $d = tempdir( 'lazysite-app-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
make_path( "$d/lazysite/logs", "$d/lazysite/stats", "$d/lazysite/cache" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_url: https://d.example.io\n";
close $cf;

# The day comes from the records, 90 minutes back and clear of UTC midnight
# (the same care as t/unit/plugins/16: a fixture that straddles midnight asks
# for the wrong day).
my $now   = time();
my $spill = ( $now - 5400 + 600 ) % 86400;
$now -= $spill + 1 if $spill < 600;
my $rec = $now - 5400;
my @gm  = gmtime($rec);
my $ymd = sprintf '%04d%02d%02d',   $gm[5] + 1900, $gm[4] + 1, $gm[3];
my $day = sprintf '%04d-%02d-%02d', $gm[5] + 1900, $gm[4] + 1, $gm[3];

open my $lf, '>', "$d/lazysite/logs/access-$ymd.jsonl" or die $!;
my $i = 0;
sub ev {
    my ( $path, $ch, $v ) = @_;
    printf {$lf} qq({"t":%d,"p":"%s","s":200,"ch":"%s","v":"%s","ua":"Mozilla/5.0 Chrome/120"}\n),
        $rec + ( $i++ * 10 ), $path, $ch, $v;
}
ev( '/portal/', 'page', 'V1' );    # the person's view
ev( '/portal/', 'app',  'V1' );    # the worker's keeping fetch behind it
ev( '/portal/', 'app',  'V1' );
ev( '/about',   'app',  'V1' );
ev( '/about',   'page', 'V2' );
close $lf;

my $out = `DOCUMENT_ROOT=\Q$d\E $^X \Q$plugin\E --export --day \Q$day\E 2>/dev/null`;
my $r   = eval { decode_json($out) } || {};
my $b   = $r->{day}                  || {};

ok( $r->{ok}, 'the day rollup answers' ) or diag($out);
is( $b->{app_hits}, 3, 'every keeping fetch is counted' );
is_deeply( $b->{app_by}, { '/portal/' => 2, '/about' => 1 }, 'per page, so an operator can see which are being kept' );
is( $b->{pageviews}, 2, 'the page count is the two views, not the views plus the fetches' );
is( $b->{visitors},  2, 'and the visitors are the two people' ) if exists $b->{visitors};

done_testing();
