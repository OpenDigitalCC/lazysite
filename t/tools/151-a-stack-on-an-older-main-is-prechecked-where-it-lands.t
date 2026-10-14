#!/usr/bin/perl
# SM1080: A STACK IS PRECHECKED ON THE INTEGRATION TREE, AFTER IT IS CHERRY-PICKED.
#
# The overnight run used to precheck each stack's OWN tree. A stack whose base
# predates a fix now on main failed on what main had already fixed (n568, n575
# and n584 on 2026-10-14, Odoo tests that n585 fixed) and was reported NOT READY
# for a stack that would have landed green. The precheck now runs after the
# stack's commits are on the integration tree, against the tree before them.
#
# The fixture: the old main holds OLD-BUG, which fails the stand-in precheck;
# main then removes it. A stack branched before that fails on its own tree and
# passes on the integration tree. A stack that carries the fault itself still
# fails there, is left out, and the tree is rebuilt without it.
# Driven in a scratch repository (t/lib/OvernightRig.pm); no real suite runs.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use OvernightRig qw(scratch stack overnight queue git spit slurp today);

sub fixed_main {
    my ($d) = @_;
    git( $d, 'rm', '-q', 'OLD-BUG' );
    git( $d, 'commit', '-q', '-m', 'main fixes OLD-BUG' );
    return;
}

subtest 'a stack on an older main, whose fault main has fixed, is READY' => sub {
    my $d  = scratch( 't/a.t' => 'true', 'OLD-BUG' => 'the fault' );
    my $wt = stack( $d, 'old1', 'main', 'S' => "s\n" );
    fixed_main($d);
    queue( $d, "$wt old1" );
    my ( $rc, $out, $res ) = overnight($d);
    my $sha = git( $d, 'rev-parse', '--short', 'old1' );
    unlike( $res, qr/NOT READY/, 'not NOT READY' ) or diag( $res, $out );
    like( $res, qr/^READY FOR REVIEW: old1 \Q$sha\E /m, 'READY FOR REVIEW' );
    like( $res, qr/^GREEN:/m,                           'on a green suite' );
    is( git( $d, 'log', '--format=%s', 'main..review/assess/integration' ), 'old1', 'the stack is on the integration tree' );
    ok( !-e "$d/inbox", 'and nothing is filed in the inbox' );
    my $calls = slurp("$d/calls");
    like( $calls, qr/^PRECHECK old1 against main fixes OLD-BUG$/m, 'it was prechecked against the tree before it, which holds the fix' );
};

subtest 'a stack that carries the fault is left out, and the tree is rebuilt without it' => sub {
    my $d   = scratch( 't/a.t' => 'true' );
    my $bad = stack( $d, 'bad', 'main', 'OLD-BUG' => "mine\n", 'BADFILE' => "x\n" );
    my $ok  = stack( $d, 'ok1', 'main', 'OK' => "ok\n" );
    queue( $d, "$bad bad", "$ok ok1" );
    my ( $rc, $out, $res ) = overnight($d);
    my $sha = git( $d, 'rev-parse', '--short', 'bad' );
    like( $res, qr/^NOT READY: bad \Q$sha\E - precheck failed on the integration tree after its commits /m,
        'the failing stack is NOT READY' )
        or diag( $res, $out );
    like( $res, qr/^LAND IN THIS ORDER:\n  1\. ok1 \S+ \(ok1\)$/m, 'and the other lands alone' );
    is( git( $d, 'diff', '--name-only', 'main', 'review/assess/integration' ), 'OK', 'the tree holds nothing of the failed stack' );
};

subtest 'a conflict is still reported, with the earlier stack' => sub {
    my $d  = scratch( 't/a.t' => 'true', 'OLD-BUG' => 'the fault' );
    my $c1 = stack( $d, 'c1', 'main', 'X' => "one\n" );
    my $c2 = stack( $d, 'c2', 'main', 'X' => "two\n" );
    fixed_main($d);
    queue( $d, "$c1 c1", "$c2 c2" );
    my ( $rc, $out, $res ) = overnight($d);
    like( $res, qr/^CONFLICT with c1: c2 left out - X$/m, 'CONFLICT with c1' ) or diag( $res, $out );
    like( $res, qr/^READY FOR REVIEW: c1 /m,              'the first stack is READY' );
};

done_testing();
