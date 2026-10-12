#!/usr/bin/perl
# SM1062: AN EMPTY QUEUE STILL CHECKS MAIN, AND NO QUEUED BRANCH STAYS CHECKED OUT.
#
# With nothing queued the overnight run is the plain nightly - tools/suite.sh
# --nightly on main - so main is checked every night. With a queue, every
# queued worktree, and any worktree holding a branch of a queued stack, is
# detached at main before the integration tree is built, so vcs-review (which
# does not offer a checked-out branch) can offer them in the morning; one with
# uncommitted changes is left alone and its stack is NOT READY. A whole-suite
# run already holding the suite lock is a skip, never a wait: the stacks go
# back on the queue for the next night.
#
# Driven in a scratch repository (t/lib/OvernightRig.pm); no real suite runs.
use strict;
use warnings;
use Test::More;
use Fcntl qw(:flock);
use FindBin;
use lib "$FindBin::Bin/../lib";
use OvernightRig qw(scratch stack overnight queue git spit slurp today);

subtest 'an empty queue runs the plain nightly on main' => sub {
    my $d = scratch( 't/a.t' => 'true' );
    my ( $rc, $out, $res ) = overnight($d);
    is( $rc, 0, 'exit 0' ) or diag($out);
    like( $res, qr/no queued stacks/,      'the results say the queue was empty' );
    like( $res, qr/nightly suite: exit 0/, 'and give the nightly suite\'s result' );
    like( slurp("$d/calls"), qr/\APROVE -lr -j\d+ t\/ in \Q$d\E\/tmp\/wt-nightly\n\z/,
        'one whole suite, on main in tmp/wt-nightly' );
    ok( !defined eval { git( $d, 'rev-parse', '--verify', '-q', 'review/assess/integration' ) },
        'and no integration branch' );
};

subtest 'every queued worktree is released; a dirty one is left and NOT READY' => sub {
    my $d  = scratch( 't/a.t' => 'true' );
    my $w0 = stack( $d, 'w0', 'main', 'w0f' => "0\n" );
    my $w1 = stack( $d, 'w1', 'w0',   'w1f' => "1\n" );
    my $v1 = stack( $d, 'v1', 'main', 'v1f' => "v\n" );
    spit( "$v1/v1f", "edited, not committed\n" );
    queue( $d, "$w1 w1", "$v1 v1" );
    my ( $rc, $out, $res ) = overnight($d);
    my $main = git( $d, 'rev-parse', 'main' );
    for my $wt ( $w0, $w1 ) {
        is( git( $wt, 'branch', '--show-current' ), '', "$wt holds no branch" ) or diag( $res, $out );
        is( git( $wt, 'rev-parse', 'HEAD' ), $main, '...detached at main' );
    }
    my $list = git( $d, 'worktree', 'list', '--porcelain' );
    unlike( $list, qr{^branch refs/heads/w[01]$}m, 'neither branch of the stack is checked out anywhere' );
    like( $res, qr/^READY FOR REVIEW: w0 .*\nREADY FOR REVIEW: w1 /m, 'and the stack is READY' );
    like( $res, qr/^NOT READY: v1 \S+ - uncommitted changes in \Q$v1\E; v1 is left checked out there$/m,
        'a worktree with uncommitted changes is NOT READY' );
    is( git( $v1, 'branch', '--show-current' ), 'v1', 'and left as it was' );
    is( slurp("$v1/v1f"), "edited, not committed\n",  'with its edit intact' );
    unlike( git( $d, 'log', '--format=%s', 'main..review/assess/integration' ), qr/v1/, 'and kept out of the tree' );
};

subtest 'a held suite lock is a skip: the stacks wait for the next night' => sub {
    my $d  = scratch( 't/a.t' => 'true' );
    my $s1 = stack( $d, 's1', 'main', 'f' => "f\n" );
    queue( $d, "$s1 s1 --full" );
    open my $lk, '>>', "$d/.git/lazysite-suite.lock" or die $!;
    flock( $lk, LOCK_EX ) or die $!;
    my ( $rc, $out, $res ) = overnight($d);
    close $lk;
    is( $rc, 0, 'exit 0' ) or diag($out);
    like( $res, qr/^NO VERDICT: another whole-suite run held the suite lock; s1 went back on the queue/m,
        'no verdict, and why' );
    is( slurp("$d/tmp/overnight/queue.txt"), "$s1 s1 --full\n", 'the queued line is back on the queue' );
    unlike( $res, qr/^(?:NOT )?READY/m, 'nothing is called READY or NOT READY' );
    is( slurp("$d/calls") =~ /^PROVE/m ? 'ran' : 'none', 'none', 'and no suite ran' );
};

done_testing();
