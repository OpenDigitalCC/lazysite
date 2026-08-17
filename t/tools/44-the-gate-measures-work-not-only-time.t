#!/usr/bin/perl
# SM342: the perf gate ran where no site runs, and only measured the clock.
#
# Every figure this project holds is a DURATION taken on a development host with
# a local uncontended disk. Real sites are on shared hosting. Measured across
# both: the same statistics export costs ~630 ms here and ~3.0 s of engine time
# on the instrument, and the gap is mostly contended storage.
#
# So a change that adds file reads or writes - an entirely normal thing for this
# engine to do - is nearly free here and expensive in the field, and a gate on
# elapsed time cannot see it coming. That is the wrong direction to be blind in.
#
# WHAT TRANSFERS IS WORK. "It re-read every retained log on every call" is the
# same statement on any disk, and it is exactly what SM340 turned out to be: the
# export cache was never loaded, so every call re-ingested everything. A count
# would have read the same on this machine as on the instrument and would have
# moved the moment the defect appeared. Nobody noticed for months because the
# only instrument was a stopwatch on the fastest disk in the project.
#
# AND IT IS COMPARATIVE, NOT PASS/FAIL - the release manager's instruction, and
# the right shape. A duration is reported with its ratio to the baseline so a
# human can see drift or confirm an optimisation landed; it never fails a build.
# A count is exact and host-independent, so an increase does.
#
# The warm counter is the sharp one. A second call with nothing new in the log
# has nothing to read, so it must be ZERO. A zero that becomes non-zero is SM340
# returning.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $bench = "$root/tools/bench.pl";
my $base  = "$root/dist/config/bench-baseline.json";
ok( -f $bench, 'the bench tool is present' );
ok( -f $base,  'and its baseline' );

my $src      = do { open my $fh, '<', $bench or die $!; local $/; <$fh> };
my $baseline = decode_json( do { open my $fh, '<', $base or die $!; local $/; <$fh> } );

subtest 'work is measured, and separately from time' => sub {
    like( $src, qr/work_cold_log_bytes/, 'a cold ingest is counted' );
    like( $src, qr/work_warm_log_bytes/, 'and a warm one' )
        or diag( 'The warm count is the SM340 detector: a call with nothing '
            . 'new to read must read nothing.' );

    for my $k ( qw(work_cold_log_bytes work_cold_log_files
        work_warm_log_bytes work_warm_log_files work_warm_days_written) )
    {
        ok( exists $baseline->{ops}{$k}, "$k has a baseline figure" )
            or diag( 'An op with no baseline is not compared to anything, '
                . 'which is coverage in name only.' );
    }
};

subtest 'a warm call reads nothing, and the baseline says so' => sub {
    # The property, not merely the counter. If this baseline is ever non-zero,
    # the thing it is guarding has already happened.
    is( $baseline->{ops}{work_warm_log_bytes}, 0,
        'the baseline for a warm read is ZERO bytes' )
        or diag( 'A warm call has nothing new in the log. Any bytes at all '
            . 'mean the offsets are not being honoured - which is SM340, and '
            . 'it cost every call a full re-ingest on every site.' );
    is( $baseline->{ops}{work_warm_log_files}, 0,
        'and zero files' );

    cmp_ok( $baseline->{ops}{work_cold_log_bytes}, '>', 0,
        'while a cold ingest reads the whole retained log' )
        or diag( 'If the cold figure is zero the fixture has no logs and both '
            . 'counters are measuring an empty site - which would pass '
            . 'forever and mean nothing.' );
};

subtest 'a timing is reported, never failed on' => sub {
    # SM327 established that a 2x tolerance permits unbounded accretion, and
    # SM342 that the number is about this machine anyway. Reporting the ratio
    # makes drift visible without pretending a millisecond figure from here
    # predicts anything about a contended disk.
    like( $src, qr/SLOWER than baseline \(reported, not failed\)/,
        'a slow op is reported as such' );
    like( $src, qr/FASTER \/ LESS WORK than baseline/,
        'and an improvement is reported too - the comparison runs both ways' )
        or diag( 'A gate that only speaks when something got worse cannot '
            . 'confirm that an optimisation landed.' );

    # The failure path must be the count, and only the count.
    my ($fail_block) = $src =~ /(if \(\@fail\) \{.*?exit 1;\n    \})/s;
    ok( $fail_block, 'the failure branch was found' ) or return;
    like( $fail_block, qr/WORK REGRESSION/,
        'and it is about work' );
    unlike( $fail_block, qr/\bms\b/,
        'not about milliseconds' )
        or diag( 'Failing a build on a duration measured on the wrong kind of '
            . 'disk is what this filing is about.' );
};

subtest 'an unbaselined op is named, not skipped' => sub {
    # Carried over from SM340: an op with no baseline used to `next` silently,
    # so adding one LOOKED like coverage while being compared to nothing.
    like( $src, qr/NOT CHECKED \(no baseline figure\)/,
        'the check names what it did not check' );
};

done_testing();
