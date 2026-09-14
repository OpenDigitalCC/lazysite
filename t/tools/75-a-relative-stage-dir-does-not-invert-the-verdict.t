#!/usr/bin/perl
# N141-02: release.sh resolves --stage-dir to an absolute path before the gate
# cd's into it.
#
# A RELATIVE --stage-dir DID NOT FAIL. IT PRODUCED A WRONG VERDICT.
#
#     GATE_OUT="$STAGE/.gate-output.txt"
#     ( cd "$STAGE" && set -o pipefail && prove -lr t/ 2>&1 | tee "$GATE_OUT" )
#
# The cd is deliberate and documented. But with a relative $STAGE the path held
# in $GATE_OUT stops resolving the moment we are inside it, so `tee` dies with
# "No such file or directory", pipefail carries that out of the subshell, and
# the release is refused with "test suite failed; not releasing."
#
# Observed on the 0.13.16 cut: "All tests successful. Result: PASS" on one line
# and the refusal on the next. That is the worst shape a path bug can take - not
# an error, an inverted RESULT - and it cost a full gate run to diagnose.
#
# WHY THIS IS A SOURCE CHECK. Driving it for real means a complete release
# build: clone, compliance, the whole suite, bench, an hour of instrumented
# coverage. The behaviour under test is three lines of shell that run before any
# of that, so this asserts those three lines and says so rather than pretending
# to more. t/tools/47 covers release.sh's two-job shape by the same method.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $sh   = "$root/tools/release.sh";

open my $fh, '<', $sh or BAIL_OUT("no release.sh: $!");
my $src = do { local $/; <$fh> };
close $fh;

# --- the hazard is still there, so the fix is still needed -------------------
#
# If the gate stops cd'ing, or stops writing its log to a path built from
# $STAGE, this test is guarding a problem that no longer exists and should be
# reconsidered rather than kept out of habit.
like( $src, qr/GATE_OUT="\$STAGE\/\.gate-output\.txt"/,
    'the gate log is still a path built from $STAGE' )
    or diag( 'If this moved, re-read the reasoning above before trusting the '
        . 'rest of this file.' );
like( $src, qr/cd "\$STAGE" && set -o pipefail && prove/,
    "and the gate still cd's into \$STAGE, which is what breaks a relative one" );

# --- the resolution happens, and happens BEFORE the gate ---------------------
like( $src, qr/cd -P "\$STAGE_BASE" && pwd/,
    'a relative --stage-dir is resolved to an absolute path' )
    or diag( 'Without this, a relative --stage-dir makes tee fail inside the '
        . 'gate subshell and a PASSING suite is reported as a failure.' );

# ORDER IS MEASURED ON CODE, NOT ON PROSE. The fix's own comment quotes the
# gate line verbatim to explain the hazard, and the first draft of this check
# matched that comment instead of the gate - reporting the resolution as coming
# AFTER a "gate" that was really a sentence about the gate. A source check that
# reads documentation as code will believe whatever the documentation says.
( my $code = $src ) =~ s/^\s*#.*$//mg;

my ($resolve_at) = $code =~ /\A(.*?)cd -P "\$STAGE_BASE" && pwd/s;
my ($gate_at)    = $code =~ /\A(.*?)cd "\$STAGE" && set -o pipefail/s;
ok( defined $resolve_at && defined $gate_at
        && length($resolve_at) < length($gate_at),
    'and it is resolved BEFORE the gate runs, not after' )
    or diag( 'Order is the whole point: resolving after the gate has already '
        . 'been refused fixes nothing.' );

# --- and mkdir precedes it, or there is nothing to resolve -------------------
# From $code, like the two above: offsets from different strings are not
# comparable, and mixing them is how the first version of this check "compared"
# a position in the commented source with one in the stripped source.
my ($mkdir_at) = $code =~ /\A(.*?)mkdir -p "\$STAGE_BASE"/s;
ok( defined $mkdir_at && length($mkdir_at) < length($resolve_at),
    'the directory is created before it is resolved' )
    or diag( '`cd -P` into a directory that does not exist yet fails, and the '
        . 'stage base is routinely a path the operator has not made.' );

# --- an unresolvable path is refused, not carried forward --------------------
like( $src, qr/cannot be resolved; not releasing/,
    'a stage dir that cannot be resolved refuses the release' )
    or diag( 'Falling through with an unresolved path is how this defect '
        . 'behaved in the first place.' );

done_testing();
