#!/usr/bin/perl
# SM1454 R2: A TREE IS NEVER RUN TWICE.
#
# The 0.17.0 gate spent 2096 s in the suite, on a tree that differed from a gated one
# by a line. The suite stage now records a pass keyed by the TREE id of the gated
# commit (the release manager lands by rebase, so the commit changes and the tree does
# not), the version, the channel and the suite mode, under
# tmp/release-gate/suite-passes/. A gate on a recorded tree says so in one line,
# skips the suite and names the record in the receipt; only a PASS writes one; a
# damaged record is a refusal naming the file, never a pass (ruling 206).
#
# Driven through the REAL release.sh in a scratch repository (t/lib/ReleaseRig.pm);
# the suite is a stub test that logs each run to STUB_RUN_LOG.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_cmd);
use ReleaseRig qw(spit slurp git commit rig_repo rig_release rig_runs);

plan skip_all => 'setsid missing' unless grep { -x "$_/setsid" } split /:/, $ENV{PATH};

my $LOGDIR = tempdir( CLEANUP => 1 );
my $LOG    = "$LOGDIR/runs";
sub runs { return scalar grep { $_ eq 'suite' } @{ rig_runs($LOG) } }
sub gate { my ( $d, $env, @a ) = @_; rig_release( $d, { STUB_RUN_LOG => $LOG, %{ $env // {} } }, 'gate', '0.1.1', '--commit', git( $d, 'rev-parse', 'main' ), @a ) }
sub records { my ($d) = @_; return sort glob("$d/tmp/release-gate/suite-passes/*.json") }
sub receipt { slurp("$_[0]/tmp/release-gate/0.1.1/receipt") }

subtest 'a passing suite is recorded, and the same tree is not run again' => sub {
    unlink $LOG;
    my $d = rig_repo();
    my ( $rc, $out ) = gate($d);
    is( $rc,    0, 'the first gate passes' ) or return diag($out);
    is( runs(), 1, 'the suite ran once' );
    my @rec = records($d);
    is( scalar @rec, 1, 'and left one record' ) or return;
    like( slurp( $rec[0] ), qr/"result"\s*:\s*"pass"/, 'a pass' );
    like( receipt($d), qr/^suite_from=this gate$/m, 'the receipt says the suite ran in this gate' );

    ( $rc, $out ) = gate($d);
    is( $rc,    0, 'the second gate of the same tree passes' ) or return diag($out);
    is( runs(), 1, 'WITHOUT running the suite again' );
    my @lines = grep { /passed on this tree/ } split /\n/, $out;
    is( scalar @lines, 1, 'and says so in one line' );
    like( $lines[0], qr/not run again; record \Q$rec[0]\E$/, 'which names the record' );
    my $r = receipt($d);
    like( $r, qr/^suite_from=recorded pass \Q$rec[0]\E$/m, 'the receipt names the record' );
    like( $r, qr/^files=\d+$/m, 'and carries the counts the record kept' );
    like( slurp("$d/tmp/release-gate/0.1.1/suite.txt"), qr/skipped - recorded pass/, 'the suite log says it was skipped' );

    {
        local $ENV{LAZYSITE_SUITE_FRESH} = 1;
        ( $rc, $out ) = gate($d);
        is( $rc,    0, 'LAZYSITE_SUITE_FRESH=1: the gate passes' ) or diag($out);
        is( runs(), 2, 'and ran the suite again, whatever the record says' );
        like( receipt($d), qr/^suite_from=this gate$/m, 'the receipt says so' );
    }

    # The tree, not the commit: the same tree on another commit is the same pass.
    git( $d, 'commit', '-q', '--amend', '-m', 'SM2, reworded' );
    ( $rc, $out ) = gate($d);
    is( $rc,    0, 'the same tree on a rewritten commit passes' ) or diag($out);
    is( runs(), 2, 'and is not run again' );

    # A different tree is a different key.
    spit( "$d/t/unit/01-more.t", "use Test::More; ok(1); done_testing;\n" );
    commit( $d, 'a change' );
    ( $rc, $out ) = gate($d);
    is( $rc,                   0, 'a changed tree passes' ) or diag($out);
    is( runs(),                3, 'by running the suite' );
    is( scalar( () = records($d) ), 2, 'and has its own record' );
};

subtest 'the version and the channel are part of the key' => sub {
    unlink $LOG;
    my $d = rig_repo();
    my ( $rc, $out ) = gate($d);
    is( $rc, 0, 'an edge gate passes' ) or return diag($out);
    ( $rc, $out ) = gate( $d, undef, '--beta' );
    is( $rc,    0, 'a beta gate of the same tree passes' ) or diag($out);
    is( runs(), 2, 'and runs the suite: the material it tests is a beta\'s' );
    ( $rc, $out ) = rig_release( $d, { STUB_RUN_LOG => $LOG, STUB_WANT_VERSION => '0.1.2' }, 'gate', '0.1.2', '--commit', git( $d, 'rev-parse', 'main' ) );
    is( $rc, 0, 'another version of the same tree passes' ) or diag($out);
    is( runs(), 3, 'and runs the suite: VERSION and the CHANGELOG section are the version\'s' );
};

subtest 'a failed suite records nothing' => sub {
    unlink $LOG;
    my $d = rig_repo();
    my ( $rc, $out ) = gate( $d, { STUB_SUITE_FAIL => 1 } );
    isnt( $rc, 0, 'a failing suite fails the gate' );
    like( $out, qr/test suite failed; not releasing/, 'saying so' );
    is( runs(), 1, 'the suite ran' );
    is_deeply( [ records($d) ], [], 'and no record was kept' );
    ok( !-e "$d/tmp/release-gate/0.1.1/receipt", 'nor a receipt' );
    ( $rc, $out ) = gate($d);
    is( $rc,                   0, 'the next gate of that tree passes' ) or diag($out);
    is( runs(),                2, 'by running the suite, not by a record' );
    is( scalar( () = records($d) ), 1, 'and now there is one' );
    is_deeply( [ glob("$d/tmp/release-gate/suite-passes/*.[0-9]*") ], [], 'no half-written file is left beside it' );
};

subtest 'a stopped suite records nothing' => sub {
    unlink $LOG;
    my $d = rig_repo( base => { 't/unit/01-killed.t' => "kill 'KILL', \$\$ if \$ENV{STUB_SUITE_KILL}; print qq{1..1\\nok 1\\n};\n" } );
    my ( $rc, $out ) = gate( $d, { STUB_SUITE_KILL => 1 } );
    isnt( $rc, 0, 'a test killed mid-suite fails the gate' );
    is_deeply( [ records($d) ], [], 'and no record was kept' );
};

subtest 'a damaged record is a refusal that names the file, never a pass' => sub {
    unlink $LOG;
    my $d = rig_repo();
    my ( $rc, $out ) = gate($d);
    is( $rc, 0, 'a gate passes' ) or return diag($out);
    my ($rec) = records($d);
    my $good = slurp($rec);
    is( runs(), 1, 'the suite ran once' );

    for my $case (
        [ 'garbage'            => "this is not json\n" ],
        [ 'empty'              => '' ],
        [ 'a truncated record' => substr( $good, 0, int( length($good) / 2 ) ) ],
        [ 'not a pass'         => $good =~ s/"result"\s*:\s*"pass"/"result" : "fail"/r ],
        [ 'another tree'       => $good =~ s/("tree"\s*:\s*")[0-9a-f]+/${1}0000/r ],
        [ 'no counts'          => $good =~ s/"tests"\s*:\s*\d+,?//r ],
        )
    {
        my ( $name, $text ) = @$case;
        spit( $rec, $text );
        unlink "$d/tmp/release-gate/0.1.1/receipt";
        ( $rc, $out ) = gate($d);
        is( $rc, 1, "$name: the gate refuses" );
        like( $out, qr/the suite record \Q$rec\E is unreadable or malformed/, "$name: naming the file" );
        like( $out, qr/LAZYSITE_SUITE_FRESH=1/, "$name: and the way out" );
        is( runs(), 1, "$name: the suite did not run, and nothing passed" );
        ok( !-e "$d/tmp/release-gate/0.1.1/receipt", "$name: no receipt" );
    }

    local $ENV{LAZYSITE_SUITE_FRESH} = 1;
    ( $rc, $out ) = gate($d);
    is( $rc,    0, 'LAZYSITE_SUITE_FRESH=1 repairs it' ) or diag($out);
    is( runs(), 2, 'by running the suite' );
    like( slurp($rec), qr/"result"\s*:\s*"pass"/, 'and the record is a good one again' );
};

# The hook the lab runner (SM1454 R3) plugs into: LAZYSITE_SUITE_RUNNER STAGE_DIR JOBS OUTFILE.
subtest 'LAZYSITE_SUITE_RUNNER runs the full suite in place of the local prove, and its verdict counts' => sub {
    unlink $LOG;
    my $d      = rig_repo();
    my $runner = "$LOGDIR/runner.sh";
    spit( $runner, <<'SH' );
#!/bin/bash
echo "ARGS $# stage=$([ -f "$1/VERSION" ] && echo has-version) jobs=$2 out=$3" >> "$STUB_RUNNER_LOG"
echo "runner output" > "$3"
echo "Files=3, Tests=7, 1 wallclock secs" >> "$3"
exit "${STUB_RUNNER_RC:-0}"
SH
    chmod 0755, $runner;
    my %env = ( LAZYSITE_SUITE_RUNNER => $runner, STUB_RUNNER_LOG => "$LOGDIR/runner.log" );

    my ( $rc, $out ) = gate( $d, { %env, STUB_RUNNER_RC => 3 } );
    isnt( $rc, 0, 'a runner that exits non-zero fails the gate' );
    like( $out, qr/test suite failed \(the runner exited 3\); not releasing/, 'saying so' );
    is_deeply( [ records($d) ], [], 'and no record was kept' );
    is( runs(), 0, 'the local suite did not run in its place' );

    ( $rc, $out ) = gate( $d, \%env );
    is( $rc,    0, 'a runner that exits 0 passes it' ) or return diag($out);
    is( runs(), 0, 'with no local suite run' );
    like( slurp("$LOGDIR/runner.log"), qr/^ARGS 3 stage=has-version jobs=4 out=\S+\.gate-output\.txt$/m,
        'the runner got the staged tree, the job count and an output file' );
    my $r = receipt($d);
    like( $r, qr/^files=3$/m, 'the gate read the files from OUTFILE' );
    like( $r, qr/^tests=7$/m, 'and the tests' );
    like( slurp("$d/tmp/release-gate/0.1.1/suite.txt"), qr/runner output/, 'and kept its output' );
    is( scalar( () = records($d) ), 1, 'a pass from the runner is recorded as any other' );
};

done_testing();
