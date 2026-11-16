#!/usr/bin/perl
# SM1454 R6 (c): A FAULT IN A RECORD FAILS THE GATE IN SECONDS, NOT AFTER THE SUITE.
#
# 0.17.1's second gate ran the full suite for 33 minutes and then failed on t/lint/26,
# a lint over the CHANGELOG and the filings that reads nothing the suite produced.
# The release-material lints (release-material.pl --lints: t/lint/09 and 26 among
# them) used to run in the BUILD only; the gate ran them last, inside the suite. They
# now run in the gate too, on the stage with the release material in it, right after
# the compliance check and BEFORE the suite stage; a failure there is the gate's
# failure, with no suite run, no receipt and no record of a pass.
#
# Driven through the REAL release.sh in a scratch repository (t/lib/ReleaseRig.pm), whose
# release-material checks are stubs that fail when told to (STUB_LINT_FAIL) and whose
# suite logs each run.
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
sub suite_runs { return scalar grep { $_ eq 'suite' } @{ rig_runs($LOG) } }
sub gate { my ( $d, $env, @a ) = @_; unlink $LOG; return rig_release( $d, { STUB_RUN_LOG => $LOG, %{ $env // {} } }, 'gate', '0.1.1', '--commit', git( $d, 'rev-parse', 'main' ), @a ) }

subtest 'a failing release-material check fails the gate before the suite starts' => sub {
    for my $channel ( [ 'edge' ], [ 'stable', '--final' ] ) {
        my ( $name, @flag ) = @$channel;
        my $d = rig_repo();
        my ( $rc, $out ) = gate( $d, { STUB_LINT_FAIL => 1 }, @flag );
        is( $rc, 1, "$name: the gate fails" ) or diag($out);
        like( $out, qr/^==> the release-material checks on [0-9a-f]+ \(\d+ files\)$/m, "$name: it ran the checks, in the gate" );
        like( $out, qr/release\.sh: a check on the release material failed \(log: /, "$name: and says one failed" );
        is( suite_runs(), 0, "$name: the suite never started" );
        unlike( $out, qr/==> Running/, "$name: no suite stage was announced" );
        ok( !-e "$d/tmp/release-gate/0.1.1/receipt", "$name: no receipt was written" );
        is( scalar( () = glob "$d/tmp/release-gate/suite-passes/*.json" ), 0, "$name: and no pass was recorded" );
    }
};

subtest 'a passing check is followed by the suite, in that order' => sub {
    my $d = rig_repo();
    my ( $rc, $out ) = gate($d);
    is( $rc, 0, 'the gate passes' ) or return diag($out);
    my @lines = split /\n/, $out;
    my ($checks) = grep { $lines[$_] =~ /^==> the release-material checks on / } 0 .. $#lines;
    my ($suite)  = grep { $lines[$_] =~ /^==> Running full test suite/ } 0 .. $#lines;
    ok( defined $checks && defined $suite && $checks < $suite, 'the checks come before the suite' ) or diag($out);
    is( suite_runs(), 1, 'and the suite ran' );
    like( $lines[ $checks + 1 ] // '', qr/^Files=\d+/, 'with prove\'s summary of the checks' );

    # A tree whose suite already passed is not run again (R2), but its records are still checked.
    ( $rc, $out ) = gate( $d, { STUB_LINT_FAIL => 1 } );
    is( $rc, 1, 'a recorded pass does not excuse a record fault' );
    is( suite_runs(), 0, 'and the suite did not run either' );
};

subtest 'a failing compliance check fails it before the suite too' => sub {
    my $d = rig_repo( base => { 'tools/lazysite-compliance.pl' => "print qq{FAIL obligations register: behind\\n}; exit 1;\n" } );
    my ( $rc, $out ) = gate( $d, {}, '--final' );
    is( $rc, 1, 'the gate fails' ) or diag($out);
    like( $out, qr/compliance records are not current for this cut; not releasing\./, 'saying the records are behind' );
    is( suite_runs(), 0, 'with no suite run' );
};

done_testing();
