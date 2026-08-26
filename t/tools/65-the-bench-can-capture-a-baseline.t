#!/usr/bin/perl
# SM601: `tools/bench.pl --baseline` was dead for eleven days and nothing said
# so.
#
# The baseline records a `loadavg` field - added 2026-08-15 because "a run on a
# loaded host and a genuinely slower engine look identical in the numbers" -
# and the function that produced it was never defined. So the mode died at the
# point of writing, every time. Nothing noticed, because re-capturing is the
# only thing that calls it and nothing re-captured until the 0.11.0 stable prep.
#
# WORSE THAN DEAD: `open '>'` truncates before the encode runs, so each failed
# attempt left a ZERO-BYTE baseline behind - a failed capture destroyed the
# reference it was meant to replace. Inside a git checkout that is recoverable.
# On a deploy host it is not.
#
# This does NOT run the benchmark, which takes minutes. It checks the two
# properties that rotted: the writer is whole, and a write that dies cannot
# take the baseline with it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $bench = repo_root() . '/tools/bench.pl';
plan skip_all => "no $bench" unless -f $bench;

my $src = do { open my $fh, '<', $bench or die $!; local $/; <$fh> };

# --- the writer is whole ----------------------------------------------------
# Every helper the baseline encode calls must exist. A field written into the
# encode whose function is missing kills the mode silently.
for my $fn ( $src =~ /^\s*\w+\s*=>\s*(_\w+)\(\)/gm ) {
    ok( $src =~ /^sub \Q$fn\E\b/m,
        "the baseline encode calls $fn() and it is defined" );
}

# --- a failed write cannot destroy the baseline -----------------------------
# The property, stated as the code must express it: the handle opened for
# writing is NOT the baseline path itself.
my ($write) = $src =~ /(open my \$b, '>', [^\n]+)/;
ok( $write, 'the baseline writer opens a handle' );
unlike( $write, qr/\$BASELINE\s*(?:or|;)/,
    'it does not open the baseline itself for writing - a die mid-encode '
        . 'would leave it truncated' );
like( $write, qr/\$tmp/, 'it writes to a temp path' );
like( $src, qr/rename \$tmp, \$BASELINE/,
    'and renames it into place, so the swap is atomic' );

# --- and the refusal still guards the value it protects ---------------------
# SM327: re-capturing over a regression must refuse. That check has to stay
# ahead of the write, or the baseline is gone before anyone is asked.
my $refuse_at = index( $src, 'REFUSING to re-capture' );
my $write_at  = index( $src, "open my \$b, '>'" );
ok( $refuse_at > 0 && $refuse_at < $write_at,
    'the regression refusal is reached before anything is written' );

done_testing();
