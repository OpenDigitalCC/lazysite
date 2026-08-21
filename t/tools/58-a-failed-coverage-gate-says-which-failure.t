#!/usr/bin/perl
# SM444: a coverage gate that dies must not report a floor breach.
#
# release.sh used to map EVERY non-zero exit from coverage.sh onto one
# sentence - "coverage below the declared floor". The 0.10.20 build failed
# that way and coverage was never the problem: coverage.sh had exited before
# reaching the floor comparison, so neither its per-file table nor its
# COVERAGE BELOW FLOOR marker was printed, and the message named a cause
# nobody had established. Cost: a 45-minute instrumented re-run, then a second
# full build, to discover all eight files were comfortably above their floors.
#
# A run that DIED and a run that MEASURED SOMETHING TOO LOW are different
# problems with different fixes. coverage.sh already distinguishes them. This
# asserts that release.sh does too, against both stand-ins.
#
# THE PIPE TRAP IS ASSERTED SEPARATELY IN t/tools/34, and this gate must not
# reintroduce it: capturing output through `if ! ( ... | tee f )` tests TEE's
# status, which succeeds whatever the child did. Here the output goes to a
# file and the status is read from the command itself.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my $release = "$root/tools/release.sh";
plan skip_all => 'release.sh missing' unless -f $release;

my $src = do { open my $fh, '<', $release or die $!; local $/; <$fh> };

# --- the source-level contract -------------------------------------------
like( $src, qr/COVERAGE BELOW FLOOR/,
    'the gate keys on the marker coverage.sh emits for a REAL floor breach' )
    or diag( 'Without this it cannot tell a died run from a measured one, '
        . 'and every failure is reported as a coverage shortfall.' );

like( $src, qr/WITHOUT reaching/,
    'and says plainly when the floor comparison was never reached' );

unlike( $src, qr/if\s*!\s*bash\s+"\$STAGE\/tools\/coverage\.sh"\s+--check/,
    'the bare `if ! coverage.sh` that asserted an unmeasured cause is gone' );

unlike( $src, qr/coverage\.sh"?\s+--check[^\n]*\|\s*tee/,
    'and the output is NOT captured through tee, whose status hides the child' );

# --- behaviour, against two stand-ins ------------------------------------
#
# Reproduce release.sh's branch verbatim rather than invoking the whole
# script: a real build clones, runs the suite and takes an hour. The branch
# is what changed and the branch is what is asserted.
sub verdict {
    my ( $child_body, $exit ) = @_;
    my $d = tempdir( 'lazysite-covgate-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    mkdir "$d/tools";
    open my $c, '>', "$d/tools/coverage.sh" or die $!;
    print {$c} "#!/bin/bash\n$child_body\nexit $exit\n";
    close $c;
    chmod 0755, "$d/tools/coverage.sh";

    open my $r, '>', "$d/run.sh" or die $!;
    print {$r} <<"RUN";
STAGE="$d"
COV_LOG="\$STAGE/coverage-check.txt"
bash "\$STAGE/tools/coverage.sh" --check > "\$COV_LOG" 2>&1
COV_STATUS=\$?
if [ "\$COV_STATUS" -ne 0 ]; then
    if grep -q 'COVERAGE BELOW FLOOR' "\$COV_LOG"; then
        echo "VERDICT: below-floor"
    else
        echo "VERDICT: did-not-finish (exit \$COV_STATUS)"
    fi
    exit 1
fi
echo "VERDICT: ok"
RUN
    close $r;
    my $out = qx(bash "$d/run.sh" 2>&1);
    return $out;
}

like( verdict( "echo '  f.pl stmt 10% bran 5% BELOW'\necho 'COVERAGE BELOW FLOOR' >&2", 1 ),
    qr/VERDICT: below-floor/,
    'a real floor breach is reported as a floor breach' );

like( verdict( "echo 'Running the suite under Devel::Cover, 4-way'", 137 ),
    qr/VERDICT: did-not-finish \(exit 137\)/,
    'a run KILLED before the comparison is NOT reported as a floor breach' )
    or diag( '137 is SIGKILL - an OOM-killed worker, the leading candidate '
        . 'for what actually happened to the 0.10.20 build.' );

like( verdict( "echo 'Devel::Cover not installed' >&2", 2 ),
    qr/VERDICT: did-not-finish \(exit 2\)/,
    'and neither is a run that could not start' );

like( verdict( "echo 'coverage: all measured production CGIs at or above'", 0 ),
    qr/VERDICT: ok/, 'a passing run still passes' );

done_testing();
