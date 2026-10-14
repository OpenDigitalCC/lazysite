#!/usr/bin/perl
# SM1062: THE OVERNIGHT RUN TESTS WHAT IS ABOUT TO LAND, IN THE ORDER IT LANDS.
#
# The release manager ruled on 2026-10-12: "maybe the suite runs on its own
# branch, not main, then the review process checks that in to main". The queued
# stacks are cherry-picked onto main in queue order in tmp/wt-integration (kept
# as review/assess/integration, which vcs-review never offers), ONE whole suite
# runs on that tip, and a green night says "LAND IN THIS ORDER:" and READY FOR
# REVIEW for every branch, as tools/handoff.sh prints it. vcs-review lands by
# cherry-pick, so landing in that order makes main that tree; a commit already
# on main (a stack landed in part) is skipped, as vcs-review skips it.
#
# Driven in a scratch repository (t/lib/OvernightRig.pm) with the real
# overnight.sh, integration.pl and suite.sh, a stand-in precheck and a stand-in
# prove. No real suite runs.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use OvernightRig qw(scratch stack overnight queue git spit slurp today);

subtest 'a green night lands the stacks in queue order' => sub {
    my $d    = scratch( 't/a.t' => '[ ! -e BROKEN ]' );
    my $wt_t = stack( $d, 't1', 'main', 'g' => "g\n" );
    stack( $d, 's1', 'main', 'f1' => "f1\n" );
    my $wt_s = stack( $d, 's2', 's1', 'f2' => "f2\n" );
    queue( $d, "$wt_t t1", "$wt_s s2" );
    my ( $rc, $out, $res ) = overnight($d);
    is( $rc, 0, 'exit 0' ) or diag($out);

    my $integ = git( $d, 'rev-parse', '--short', 'review/assess/integration' );
    my %sha   = map { $_ => git( $d, 'rev-parse', '--short', $_ ) } qw(t1 s1 s2);
    like( $res, qr/^GREEN: the whole suite passed on review\/assess\/integration \Q$integ\E$/m, 'GREEN, naming the tip' )
        or diag($res);
    like( $res, qr/^LAND IN THIS ORDER:\n  1\. t1 \Q$sha{t1}\E \(t1\)\n  2\. s2 \Q$sha{s2}\E \(s1 s2\)$/m,
        'the stacks in queue order, each with its branches' );
    my $what = "(precheck passed; suite passed on review/assess/integration $integ)";
    like( $res, qr/^\QREADY FOR REVIEW: t1 $sha{t1} $what\E\n\QREADY FOR REVIEW: s1 $sha{s1} $what\E\n\QREADY FOR REVIEW: s2 $sha{s2} $what\E$/m,
        'a READY FOR REVIEW line per branch, in the format handoff.sh prints' );

    is( git( $d, 'log', '--reverse', '--format=%s', 'main..review/assess/integration' ), "t1\ns1\ns2",
        'the integration branch is main plus each stack, cherry-picked in queue order' );
    is( git( $d, 'diff', '--name-only', 'main', 'review/assess/integration' ), "f1\nf2\ng", 'and holds all of them' );
    my $calls = slurp("$d/calls");
    like( $calls, qr/^PRECHECK t1 against base\nPRECHECK s1 against t1\nPRECHECK s2 against s1\n/m,
        'each branch was prechecked on the integration tree, against the tree before its commits' );
    my @suite = $calls =~ /^PROVE -lr\S* -j\d+ t\/ in (\S+)$/mg;
    is_deeply( \@suite, ["$d/tmp/wt-integration"], 'ONE whole suite, in tmp/wt-integration' );
    is( git( "$d/tmp/wt-integration", 'rev-parse', 'HEAD' ), git( $d, 'rev-parse', 'review/assess/integration' ),
        'on the integration tip' );
    is( git( "$d/tmp/wt-integration", 'branch', '--show-current' ), '', 'with the worktree detached' );
    ok( !-e "$d/inbox", 'a green night files nothing in the inbox' );
    is( slurp("$d/tmp/overnight/queue.txt"), '', 'the queue is taken' );
    unlike( $calls, qr/wt-nightly/, 'and the plain nightly did not run as well' );
};

subtest 'a stack landed in part: what is on main is skipped' => sub {
    my $d  = scratch( 't/a.t' => 'true' );
    my $wt = stack( $d, 'p1', 'main', 'pa' => "pa\n" );
    spit( "$wt/pb", "pb\n" );
    git( $wt, 'add',    'pb' );
    git( $wt, 'commit', '-q', '-m', 'p1 second' );
    git( $d, 'cherry-pick', '-x', git( $d, 'rev-parse', 'p1~1' ) ); # landed: -x makes a new SHA, the same patch
    isnt( git( $d, 'rev-parse', 'main' ), git( $d, 'rev-parse', 'p1~1' ), 'the fixture: main holds a copy, not the commit' );
    queue( $d, "$wt p1" );
    my ( $rc, $out, $res ) = overnight($d);
    like( $res, qr/^GREEN:/m, 'green' ) or diag( $res, $out );
    is( git( $d, 'log', '--format=%s', 'main..review/assess/integration' ), 'p1 second',
        'only the commit not yet on main was applied' );
    like( $res, qr/^READY FOR REVIEW: p1 /m, 'and the stack is READY' );
};

done_testing();
