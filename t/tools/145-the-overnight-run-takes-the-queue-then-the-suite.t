#!/usr/bin/perl
# SM1061: THE OVERNIGHT RUN TAKES THE QUEUE, ONE RUN AT A TIME.
#
# Stacks too heavy for the working day are queued (tools/overnight.sh --queue
# WORKTREE TIP [FLAG]) and run at 00:30. A second overnight run while one is
# going skips with a line in the results file rather than queueing.
#
# SM1062 changed what the run does with the queue: it is tested together as it
# will land (t/tools/146-149), not one handoff at a time. The queue interface
# and the runner lock are unchanged, and are what this file holds.
#
# Driven in a scratch repository (t/lib/OvernightRig.pm); no real suite runs.
use strict;
use warnings;
use Test::More;
use Fcntl qw(:flock);
use FindBin;
use lib "$FindBin::Bin/../lib";
use OvernightRig qw(scratch stack overnight queue git spit slurp today);

subtest 'a stack is queued, and a bad flag is refused' => sub {
    my $d  = scratch( 't/a.t' => 'true' );
    my $wt = stack( $d, 'feature', 'main', 'f' => "f\n" );
    my ( $rc, $out ) = overnight( $d, '--queue', $wt, 'feature', '--full' );
    is( $rc,                                 0, 'queued' ) or diag($out);
    is( slurp("$d/tmp/overnight/queue.txt"), "$wt feature --full\n", 'one line: WORKTREE TIP FLAG' );
    ( $rc, $out ) = overnight( $d, '--queue', $wt, 'feature', '--everything' );
    is( $rc, 2, 'an unknown flag is refused' );
    ( $rc, $out ) = overnight( $d, '--queue', "$d/no-such", 'feature' );
    is( $rc, 2, 'so is a worktree that is not there' );
};

subtest 'the run takes the queue' => sub {
    my $d  = scratch( 't/a.t' => 'true' );
    my $wt = stack( $d, 'feature', 'main', 'f' => "f\n" );
    overnight( $d, '--queue', $wt, 'feature', '--release' );
    my ( $rc, $out, $res ) = overnight($d);
    is( $rc, 0, 'exit 0' ) or diag($out);
    like( $res, qr/^READY FOR REVIEW: feature \S+ \(precheck passed; suite passed on /m, 'the verdict is in the results file' );
    is( slurp("$d/tmp/overnight/queue.txt"), '', 'the queue is taken' );
    like( slurp( "$d/tmp/overnight/queue-taken-" . today() . '.txt' ), qr/^\Q$wt\E feature --release$/m,
        'and recorded, flag and all' );
};

subtest 'a second overnight run skips, never queues' => sub {
    my $d  = scratch( 't/a.t' => 'true' );
    my $wt = stack( $d, 'feature', 'main', 'f' => "f\n" );
    overnight( $d, '--queue', $wt, 'feature' );
    open my $lk, '>>', "$d/tmp/overnight/.runner.lock" or die $!;
    flock( $lk, LOCK_EX ) or die $!;
    my ( $rc, $out, $res ) = overnight($d);
    close $lk;
    is( $rc,               0,  'exit 0' ) or diag($out);
    is( slurp("$d/calls"), '', 'nothing ran' );
    like( $res, qr/skipped/, 'the results file says it skipped' );
    is( slurp("$d/tmp/overnight/queue.txt"), "$wt feature\n", 'and the queue waits for the next night' );
};

done_testing();
