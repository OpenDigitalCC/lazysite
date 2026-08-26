#!/usr/bin/perl
# SM393: the ordered trail is recorded, and it expires.
#
# THIS TESTS A REVERSAL. The day bucket's own comment said of the sequence
# aggregates that they "reconstruct a flow without retaining anybody's path" -
# and now a path is retained. The reversal is deliberate (order cannot be
# recomputed from a rollup once the event ring rolls) but it means the deletion
# is not a later refinement: a retention that arrives after the recording is a
# retention nobody has. So expiry is asserted here, in the same file, against
# the same run that does the recording.
#
# WHAT IS ASSERTED
#   the sequence is ORDERED, and is the order the pages were actually visited
#   entry and exit are the first and last of that sequence
#   depth counts DISTINCT pages, so a reload is not another page
#   each step carries the gap to the NEXT step, and the last step carries none
#   each step carries the class AS IT WAS AT THE TIME
#   the per-visitor step cap holds, so one crawl cannot fill the file
#   the file states its own retention, and a day past it is DELETED
#   a second export does not write the same visit twice
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $PLUGIN = repo_root() . '/plugins/stats.pl';
plan skip_all => "no $PLUGIN" unless -f $PLUGIN;

my $d = tempdir( 'lazysite-trail-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
# NOTE the trails directory is deliberately NOT created here. The engine has
# to make its own, and an earlier version of this test that pre-created it
# passed against a flush whose mkdir did not work at all.
make_path( "$d/lazysite/logs", "$d/lazysite/stats", "$d/lazysite/cache" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_url: https://d.example.io\nfirst_party_analytics: on\n";
close $cf;

# THE FIXTURE MUST NOT STRADDLE A UTC MIDNIGHT, and it did.
#
# Events are timestamped up to 5400 seconds (90 minutes) in the past, while the
# log file and the expected trail file were both named from `gmtime` at the
# moment of the call. Run this between 00:00 and 01:30 UTC and the events fall
# on YESTERDAY while the assertions look for TODAY's file - so the test fails
# for ninety minutes a day and passes for the other twenty-two and a half
# hours.
#
# It cost a full coverage measurement to find. The run started at 00:51, this
# file BAIL_OUTed, and prove stops the whole suite on a bail - so eighty-four
# later files never ran and every one of their coverage numbers was missing
# from the report. Nothing about it looked like a clock problem.
#
# Anchored instead: if the current UTC time-of-day is inside the danger window,
# the whole fixture moves back into the previous day, where 90 minutes of
# events cannot cross anything. Every date below derives from $now, so they
# cannot disagree with each other again.
my $now = time();
{
    my @g   = gmtime($now);
    my $sod = $g[2] * 3600 + $g[1] * 60 + $g[0];
    $now -= ( $sod + 60 ) if $sod < 5400 + 600;    # the oldest event, plus slack
}
my $ymd = do { my @t = gmtime($now); sprintf '%04d%02d%02d', $t[5] + 1900, $t[4] + 1, $t[3] };

# SELF-CHECK, because the whole failure was two dates that were computed
# separately and silently disagreed. If this ever fails, the fixture is
# straddling again and nothing below it means anything.
{
    my $a = do { my @t = gmtime($now); sprintf '%04d%02d%02d', $t[5] + 1900, $t[4] + 1, $t[3] };
    my $b = do { my @t = gmtime( $now - 5400 ); sprintf '%04d%02d%02d', $t[5] + 1900, $t[4] + 1, $t[3] };
    is( $a, $b, 'the fixture does not straddle a UTC midnight' );
}
open my $lf, '>', "$d/lazysite/logs/access-$ymd.jsonl" or die $!;

# Every event is aged well past SESSION_GAP so the visits are CLOSED by the
# export - an open session has no trail yet, which is correct and is why a
# fixture of fresh events would record nothing and prove nothing.
sub ev {
    my ( $ago, $path, $tok, $ua ) = @_;
    printf {$lf} qq({"t":%d,"p":"%s","s":200,"ch":"page","v":"%s","ua":"%s"}\n),
        $now - $ago, $path, $tok, $ua;
}
my $HUMAN = 'Mozilla/5.0 Chrome/120';

# A person reading: four pages, deliberately uneven gaps, and /pricing twice so
# depth (distinct) and length (steps) cannot be the same number by accident.
ev( 5400, '/',             'READER', $HUMAN );
ev( 5360, '/pricing',      'READER', $HUMAN );
ev( 5300, '/case-studies', 'READER', $HUMAN );
ev( 5250, '/pricing',      'READER', $HUMAN );

# A person who reads a great many pages, to exercise the cap. It has to be a
# person: a crawler never opens a session at all, so a bot UA here would cap
# nothing and the assertion would pass on an empty set.
ev( 5200 - $_, "/deep/$_", 'GRAZER', $HUMAN ) for 0 .. 59;

# And a real crawler, which must leave NO trail. Trails are the most
# person-adjacent thing the store holds; a search engine is not a person and
# has no business in the file.
ev( 5100 - $_, "/bot/$_", 'CRAWLER', 'Mozilla/5.0 (compatible; Googlebot/2.1)' )
    for 0 .. 3;
close $lf;

my $cmd = qq{DOCUMENT_ROOT=\Q$d\E $^X \Q$PLUGIN\E --export --window 30};
my $out = `$cmd 2>/dev/null`;
ok( length $out, 'the export ran' );

# FROM $now, NOT FROM A FRESH gmtime. The two used to be computed
# independently and were the pair that disagreed.
my $file = "$d/lazysite/stats/trails/"
    . do { my @t = gmtime($now); sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3] }
    . '.json';
ok( -f $file, 'a trail file was written for today' )
    or BAIL_OUT('no trail file - nothing below can be judged');

my $doc = decode_json( do { open my $fh, '<', $file or die $!; local $/; <$fh> } );
ok( $doc->{retention_days} >= 1, 'the file states its own retention' );

my ($reader) = grep { @{ $_->{steps} } == 4 } @{ $doc->{trails} };
ok( $reader, 'the four-step visit was recorded' ) or BAIL_OUT('no reader trail');

is_deeply(
    [ map { $_->{p} } @{ $reader->{steps} } ],
    [ '/', '/pricing', '/case-studies', '/pricing' ],
    'the sequence is the order the pages were visited'
);
is( $reader->{entry}, '/',        'entry is the first page' );
is( $reader->{exit},  '/pricing', 'exit is the last page' );
is( $reader->{depth}, 3,          'depth counts distinct pages, not steps' );

is_deeply(
    [ map { $_->{gap} } @{ $reader->{steps} }[ 0 .. 2 ] ],
    [ 40, 60, 50 ],
    'each step carries the gap to the next, which is the dwell on that page'
);
ok( !exists $reader->{steps}[3]{gap},
    'the last step carries no gap - there is no page after it to leave for' );

is( scalar( grep { ( $_->{c} // '' ) ne '' } @{ $reader->{steps} } ),
    4, 'every step carries the class it had at the time' );

my ($long) = grep { @{ $_->{steps} } > 4 } @{ $doc->{trails} };
ok( $long, 'the long visit was recorded' ) or diag('no long trail');
cmp_ok( scalar @{ $long->{steps} }, '<=', 40,
    'the per-visitor step cap holds, so one reader cannot fill the file' );

is( scalar( grep { $_->{entry} =~ m{^/bot/} } @{ $doc->{trails} } ),
    0, 'a crawler leaves no trail' );

# Now a second export, which has NOTHING new to record - the visits are already
# closed and the log already read. It has to do two things anyway.
#
# A day that is unambiguously past any retention this can be configured to.
my $STALE = "$d/lazysite/stats/trails/2020-01-01.json";
open my $sf, '>', $STALE or die $!;
print {$sf} '{"date":"2020-01-01","retention_days":30,"trails":[]}';
close $sf;

my $before = scalar @{ $doc->{trails} };
`$cmd 2>/dev/null`;

ok( !-f $STALE,
    'a day past retention is deleted even by an export with nothing to write' );

# Trail files are APPENDED to, so an append that runs again is a duplicate
# rather than a no-op.
my $again = decode_json( do { open my $fh, '<', $file or die $!; local $/; <$fh> } );
is( scalar @{ $again->{trails} }, $before,
    'a second export does not write the same visit again' );

done_testing();
