#!/usr/bin/perl
# SM1062: A STACK THAT DOES NOT APPLY, OR FAILS ITS PRECHECK, IS LEFT OUT.
#
# The overnight integration run cherry-picks the queued stacks onto main in
# queue order. A stack that does not apply on top of the ones before it is
# reported "CONFLICT with <earlier stack>: files" (or with main, when no earlier
# stack touched those files), is NOT READY, and the rest continue; a conflict
# files a report in the inbox. A stack whose precheck fails (each branch against
# the one below it, as tools/handoff.sh runs it) is NOT READY and never enters
# the integration tree. When nothing is left to integrate, the plain nightly
# suite runs on main instead.
#
# Driven in a scratch repository (t/lib/OvernightRig.pm); no real suite runs.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use OvernightRig qw(scratch stack overnight queue git spit slurp today);

my $day = today();

subtest 'a conflict with an earlier stack is left out; the rest continue' => sub {
    my $d  = scratch( 't/a.t' => 'true' );
    my $c1 = stack( $d, 'c1', 'main', 'X' => "one\n" );
    my $c2 = stack( $d, 'c2', 'main', 'X' => "two\n" );
    my $c3 = stack( $d, 'c3', 'main', 'Y' => "y\n" );
    queue( $d, "$c1 c1", "$c2 c2", "$c3 c3" );
    my ( $rc, $out, $res ) = overnight($d);
    my $c2sha = git( $d, 'rev-parse', '--short', 'c2' );
    like( $res, qr/^CONFLICT with c1: c2 left out - X$/m, 'the conflict names the earlier stack and the file' )
        or diag( $res, $out );
    like( $res, qr/^NOT READY: c2 \Q$c2sha\E - CONFLICT with c1: X$/m, 'and the stack is NOT READY' );
    like( $res, qr/^GREEN:/m, 'the rest went on to a green suite' );
    like( $res, qr/^LAND IN THIS ORDER:\n  1\. c1 \S+ \(c1\)\n  2\. c3 \S+ \(c3\)$/m, 'without the conflicting stack' );
    is( git( $d, 'show', 'review/assess/integration:X' ), 'one', 'the integration tree has the earlier stack\'s file' );
    my $report = slurp("$d/inbox/$day-overnight-integration-green.md");
    like( $report, qr/CONFLICT with c1: c2 left out - X/, 'a conflict files an inbox report, even on a green night' );
};

subtest 'a conflict with main says so' => sub {
    my $d  = scratch( 't/a.t' => 'true', 'Z' => 'base' );
    my $m1 = stack( $d, 'm1', 'main', 'Z' => "m1\n" );
    spit( "$d/Z", "main moved\n" );
    git( $d, 'commit', '-q', '-am', 'main moves Z' );
    queue( $d, "$m1 m1" );
    my ( $rc, $out, $res ) = overnight($d);
    like( $res, qr/^CONFLICT with main: m1 left out - Z$/m, 'CONFLICT with main' ) or diag( $res, $out );
    like( $res, qr/^NOTHING INTEGRATED/m, 'nothing was left to integrate' );
    like( slurp("$d/calls"), qr/^PROVE -lr\S* -j\d+ t\/ in \Q$d\E\/tmp\/wt-nightly$/m,
        'so the plain nightly suite ran on main' );
};

subtest 'a stack failing its precheck is left out' => sub {
    my $d  = scratch( 't/a.t' => '[ ! -e PRECHECK-FAILS ]' );
    my $q1 = stack( $d, 'q1', 'main', 'PRECHECK-FAILS' => "x\n" );
    git( $d, 'worktree', 'remove', $q1 );
    my $q2 = stack( $d, 'q2', 'q1',   'q2file' => "q2\n" );
    my $r1 = stack( $d, 'r1', 'main', 'R'      => "r\n" );
    queue( $d, "$q2 q2", "$r1 r1" );
    my ( $rc, $out, $res ) = overnight($d);
    my %sha = map { $_ => git( $d, 'rev-parse', '--short', $_ ) } qw(q1 q2);
    like( $res, qr/^NOT READY: q1 \Q$sha{q1}\E - precheck failed on the integration tree after its commits /m, 'the failing branch is NOT READY' )
        or diag( $res, $out );
    like( $res, qr/^NOT READY: q2 \Q$sha{q2}\E - the stack stops at q1$/m, 'and so is the rest of its stack' );
    like( $res, qr/^GREEN:/m, 'the other stack went on to a green suite' );
    like( $res, qr/^LAND IN THIS ORDER:\n  1\. r1 \S+ \(r1\)$/m, 'alone' );
    is( git( $d, 'log', '--format=%s', 'main..review/assess/integration' ), 'r1',
        'the failing stack never entered the integration tree' );
    ok( !-e "$d/inbox", 'a precheck failure alone files nothing in the inbox' );
};

done_testing();
