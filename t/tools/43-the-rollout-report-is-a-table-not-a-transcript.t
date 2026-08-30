#!/usr/bin/perl
# The fleet rollout reports a table, not a transcript.
#
# WHAT THE OPERATOR SAW. "install/deploy is now very noisy, reporting an ever
# longer collection of information." A rollout printed each candidate up to four
# times - a discovery list, again with its channel, again in an out-of-scope
# block, again in an excluded block - and then streamed the entire install
# transcript for every site, followed by repair and probe output for every site.
# On a fleet of any size the two lines that matter are indistinguishable from
# the several thousand that do not.
#
# WHAT IT REPORTS NOW: one table of every candidate carrying its version, its
# channel and whether this release is for it; then only warnings and failures
# while it runs; then a summary table of what actually happened. --verbose
# restores the transcript.
#
# THE ONE THING NEVER SUPPRESSED is the detail of a failure. A summary that says
# "failed" without saying why moves the operator's work to a second run, so a
# site whose deploy exits non-zero prints everything that was captured.
#
# These are OUTCOME tests: the reporting helpers are extracted from the script
# and RUN, because the defect this change fixed in its own first draft (a
# wrapper that clobbered the caller's errexit and killed the script on the
# failure path) was invisible in the source and obvious the moment it ran.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);
use File::Temp qw(tempdir);

my $script = repo_root() . '/installers/hestia/lazysite-hestia-update-all.sh';
plan skip_all => "no $script" unless -f $script;

my $src = do { open my $fh, '<', $script or die $!; local $/; <$fh> };

# Extract the helper block and drive it, the way the script does.
my $dir = tempdir( CLEANUP => 1 );
my ($fns) = $src =~ /(^TBL_FMT=.*?^run_quiet\(\) \{.*?^\}$)/ms;
ok( $fns, 'the reporting helpers were located' )
    or do { done_testing; exit };

my sub run_bash {
    my ($body) = @_;
    open my $fh, '>', "$dir/t.sh" or die $!;
    print {$fh} "set -u\nVERBOSE=0\n$fns\n$body\n";
    close $fh;
    my $out = qx{bash $dir/t.sh 2>&1};
    return ( $out, $? >> 8 );
}

subtest 'a candidate appears once, with everything known about it' => sub {
    my ( $out, $rc ) = run_bash(
        qq{table_head\ntable_row a.example alice 0.11.7 edge "in scope"\n} );
    is( $rc, 0, 'the table renders' );
    like( $out, qr/DOMAIN\s+USER\s+VERSION\s+CHANNEL\s+SCOPE/,
        'the header names version, channel and scope' )
        or diag( 'These are the four facts the operator asked for in one '
            . 'place: what was found, what it runs, what it is set to, and '
            . 'whether this release is for it.' );
    like( $out, qr/a\.example\s+alice\s+0\.11\.7\s+edge\s+in scope/,
        'and a row carries all four' );
};

subtest 'a clean site says nothing at all' => sub {
    my ( $out, $rc ) = run_bash(
        q{set +e; run_quiet site.example bash -c 'echo installing; echo "VERIFY OK"; exit 0'; echo "rc=$?"} );
    like( $out, qr/rc=0/, 'the status is reported to the caller' );
    unlike( $out, qr/installing/,
        'the transcript of a clean run is not printed' )
        or diag( 'This is the whole point: a fleet of clean sites should '
            . 'produce a table and nothing else.' );
};

subtest 'a warning is surfaced, and says which site it came from' => sub {
    my ( $out, undef ) = run_bash(
        q{set +e; run_quiet a.example bash -c 'echo ok; echo "WARN: perms drifted"; exit 0'} );
    like( $out, qr/\[a\.example\]\s*WARN: perms drifted/,
        'the warning is printed and attributed' )
        or diag( 'A filtered line with no site attached is not actionable on '
            . 'a fleet - the operator cannot tell which site to look at.' );
    unlike( $out, qr/^\s*ok$/m, 'the ordinary line around it is not' );
};

subtest 'a FAILURE keeps its whole output, and its status' => sub {
    my ( $out, $rc ) = run_bash(
        q{set +e; run_quiet bad.example bash -c 'echo step-one; echo step-two; exit 7'; echo "rc=$?"} );
    like( $out, qr/step-one/, 'the detail of a failure is kept' );
    like( $out, qr/step-two/, 'all of it' )
        or diag( 'A summary that says "failed" without saying why just moves '
            . 'the operator\'s work into a second run.' );
    like( $out, qr/FAILED \(status 7\)/, 'and it is labelled as a failure' );
    like( $out, qr/rc=7/, 'and the status reaches the caller unchanged' )
        or diag( 'Every call site branches on this status. The wrapper has to '
            . 'be invisible to that logic.' );
    is( $rc, 0, 'and the script it was called from SURVIVES the failure' )
        or diag( 'The first draft ended run_quiet with a bare `set -e`, which '
            . 'turned errexit on even when the caller had turned it off - so '
            . 'returning non-zero killed the script at the call site. That is '
            . 'the exact bug this wrapper exists to stop.' );
};

subtest 'the script itself is wired to the helpers' => sub {
    like( $src, qr/^\s*run_quiet "\$d" bash "\$DEPLOY"/m,
        'the per-site deploy goes through the quiet wrapper' );
    like( $src, qr/--verbose\|-v\)\s*VERBOSE=1/,
        '--verbose restores the transcript' );
    like( $src, qr/==> SUMMARY/,
        'there is a closing summary' );

    # The errexit repair: `cmd; rc=$?` does not survive errexit, so the deploy
    # loop must guard explicitly. Without this the first failing site aborts
    # the rollout and FAILED never fills.
    like( $src, qr/set \+e\n\s*run_quiet "\$d" bash "\$DEPLOY".*?\n\s*rc=\$\?\n\s*set -e/s,
        'the deploy call is guarded so a failing site cannot abort the rollout' )
        or diag( 'The scope loop leaves errexit ON. A bare `cmd; rc=$?` exits '
            . 'before the assignment runs, so FAILED could never fill and the '
            . '"ROLLOUT FAILED" verdict could never print.' );
};

done_testing();
