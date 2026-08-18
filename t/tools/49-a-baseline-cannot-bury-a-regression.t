#!/usr/bin/perl
# SM327: re-capturing the baseline would have hidden a real regression.
#
# Every operation was 9-26% slower than the 2026-07-02 baseline on the same
# host, same Perl, same iteration count. The tolerance was 2x, so the gate
# reported everything within tolerance on every release including four cut in
# one fortnight.
#
# AND RE-CAPTURING WAS THE QUEUED TASK. The compliance gate warns the baseline
# is stale at a stable cut, and the obvious remedy - run --baseline - would have
# raised it to the current, slower numbers. A warning clears, the gate goes
# green, and the regression becomes the new definition of correct.
#
# That is a control reporting success because the bar moved, which is the shape
# this project spent a fortnight removing from other people's code. It must not
# arrive in the perf gate to clear a housekeeping warning.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $BENCH = "$root/tools/bench.pl";
ok( -f $BENCH, 'bench.pl is present' );

my $src = do { open my $fh, '<', $BENCH or die $!; local $/; <$fh> };

subtest 'the tolerance is deliberate, and stated' => sub {
    my ($tol) = $src =~ /my \$TOLERANCE = ([\d.]+);/;
    ok( defined $tol, 'a tolerance is set' ) or return;
    cmp_ok( $tol, '<', 2.0,
        'tighter than the 2x that passed a 26% drift on every release' );
    cmp_ok( $tol, '>=', 1.15,
        'and not so tight it sits near the ~1.5% noise floor - a flaky gate '
            . 'gets ignored, which is worse than a wide one' );

    like( $src, qr/arrives as ACCRETION/,
        'and the reasoning is written where the number is' )
        or diag( 'A tolerance that is merely tighter is a number somebody will '
            . 'widen again the first time it is inconvenient.' );
};

subtest 'a re-capture that buries a regression is refused' => sub {
    # THE FILING. The check is on the source rather than by running a full
    # benchmark, because the benchmark takes minutes and what is being asserted
    # is the guard's existence and its shape.
    like( $src, qr/REFUSING to re-capture over a regression/,
        'the refusal exists' )
        or diag( 'Without it, the remedy for a stale-baseline warning is the '
            . 'thing that hides the regression.' );

    my ($guard) = $src =~ /(if \( -f \$BASELINE && !grep.*?\n    \})/s;
    ok( $guard, 'and is guarded, not unconditional' ) or return;
    like( $guard, qr/accept-regression/,
        'with an explicit override' );
    like( $guard, qr/ratio >= \( \$old->\{tolerance\}/,
        'comparing each op against the OLD baseline and its tolerance' )
        or diag( 'Comparing against the new numbers would compare them with '
            . 'themselves.' );
    like( $guard, qr/\$op =~ \/\^work_\//,
        'and skipping work counters, which are counts rather than timings' );
};

subtest 'the refusal names what drifted, not just that something did' => sub {
    like( $src, qr/%s %\.2fx \(%\.1f -> %\.1f ms\)/,
        'each op is reported with its ratio and both figures' )
        or diag( '"Something regressed" sends somebody to re-run the whole '
            . 'benchmark to find out what.' );
    like( $src, qr/new definition of correct/,
        'and the message says what writing it would mean' );
};

subtest 'the override is a statement, not a difficulty' => sub {
    # The flag is not meant to be hard to type. It is meant to make somebody
    # say that these numbers are RIGHT rather than merely current, which is
    # what a baseline claims.
    like( $src, qr/somebody has to state that\s*\n?\s*#\s*these numbers are RIGHT/s,
        'the reason for the flag is recorded next to it' );
};

done_testing();
