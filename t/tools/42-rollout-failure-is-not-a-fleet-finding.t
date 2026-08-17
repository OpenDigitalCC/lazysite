#!/usr/bin/perl
# SM344: a rollout that succeeded must not report that it failed.
#
# WHAT HAPPENED on the 0.10.12 edge rollout. Every site that could accept the
# release installed and verified ("VERIFY OK: installed code matches the
# manifest for 0.10.12"), and the release was independently confirmed serving
# from outside. The run exited 1, and the deploy watcher printed:
#
#   Deploy of 0.10.12 failed; skipping (bump again to retry)
#
# It exited 1 because the fleet-wide probe reported 22 exposed sites - sites on
# an OLDER line, in that state before the rollout began and in it afterwards.
#
# WHY THE ADVICE IS THE WORST PART. "Bump again to retry" is right for a
# transient install fault and wrong for everything else the status had come to
# cover. Following it burns a version number - which this project never reuses -
# to re-run a deploy that had already worked, against a condition no deploy can
# address.
#
# SM317 IS NOT BEING REVERTED. Making an exposure non-zero was correct: a fleet
# caller reading only $? must not miss one. The defect is that one bit carried
# two facts and the caller had to guess which. Two non-zero statuses, so it does
# not have to.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $script = repo_root() . '/installers/hestia/lazysite-hestia-update-all.sh';
ok( -f $script, 'the fleet updater is present' );

my $src = do { open my $fh, '<', $script or die $!; local $/; <$fh> };

# The exit block, taken from the end of the file so an `exit 1` elsewhere in the
# script (an argument error, a missing stage) is not mistaken for the verdict.
my ($tail) = $src =~ /(\n# SM344:.*)\z/s;
ok( $tail, 'the verdict block was found' ) or do { done_testing; exit };

subtest 'a failed install and a fleet finding get DIFFERENT statuses' => sub {
    # The whole fix. Same status for both is what let a working rollout be
    # reported as a failure.
    like( $tail, qr/\$\{#FAILED\[\@\]\}.*\|\|.*PROXY_FAILED.*\n.*\n.*\n.*\n\s*exit 1/s,
        'an install or proxy failure exits 1' );
    like( $tail, qr/REPAIR_RC.*\|\|.*ACL_PROBE_RC/s,
        'repairs and exposures are considered together' );
    like( $tail, qr/exit 2/, 'and exit with a DIFFERENT status' )
        or diag( 'One status for both is the defect: the caller cannot tell a '
            . 'rollout that failed from a fleet that has findings, and the '
            . 'watcher guessed wrong.' );

    my ($rollout)  = $tail =~ /(ROLLOUT FAILED.*?exit 1)/s;
    my ($findings) = $tail =~ /(ROLLOUT SUCCEEDED.*?exit 2)/s;
    ok( $rollout,  'the failure branch says a rollout failed' );
    ok( $findings, 'the findings branch says the rollout succeeded' );
};

subtest 'the status is explained in words, because the log is what is read' => sub {
    # An operator reads the log, not $?. The message is what stops them acting
    # on the wrong one.
    like( $tail, qr/A retry is meaningful/,
        'the failure case says a retry is worth making' );
    like( $tail, qr/re-running this deploy will not change them/,
        'and the findings case says a retry is not' )
        or diag( 'This is the sentence that replaces "bump again to retry", '
            . 'which was advice that could only waste a version number.' );
    like( $tail, qr/neither will cutting another version/,
        'and says explicitly that a version bump will not help either' );
};

subtest 'SM317 is preserved - an exposure is still non-zero' => sub {
    # The half that must NOT regress. SM317 made an exposure visible to a caller
    # that reads only the exit status; this must keep that while making the two
    # kinds distinguishable.
    # Scoped to the findings BRANCH. The first version matched
    # `ACL_PROBE_RC.*?exit 0` across the whole tail, which succeeds simply
    # because the file ends with `exit 0` - it could not have distinguished the
    # exposure path exiting 0 from the script's normal success path, and it
    # failed on correct code for that reason.
    my ($branch) = $tail =~ m{(if \[ "\$\{REPAIR_RC.*?\nfi\n)}s;
    ok( $branch, 'the findings branch was isolated' ) or return;
    unlike( $branch, qr/exit 0/,
        'an exposure never exits 0' );
    like( $tail, qr/SM317/,
        'and the reason it stays non-zero is recorded where it is enforced' )
        or diag( 'Without the note, the next person simplifying these branches '
            . 'has no way to know that zero is not an option here.' );
};

subtest 'a clean rollout on a clean fleet still exits 0' => sub {
    like( $tail, qr/\nexit 0\n?\z/,
        'the default path is success' );
};

done_testing();
