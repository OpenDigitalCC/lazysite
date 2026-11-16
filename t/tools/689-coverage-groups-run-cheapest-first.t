#!/usr/bin/perl
# SM1449 R3: coverage groups run cheapest first, by the recorded time of the group's
# last pass; a group never timed runs after the timed ones, in map order. A measured
# group's wall time is stamped into its pass record, so the next run has it.
# A stub coverage.sh (t/lib/CoverageGroupsRig.pm) records the order; nothing is instrumented.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use CoverageGroupsRig qw(rig parts groups spit slurp);

sub order { my ($d) = @_; return join ' ', map { /^RAN (\S+)/ ? $1 : () } split /\n/, slurp("$d/calls") }
sub names { my ($d) = @_; return join ' ', map { ( split /\t/ )[0] } split /\n/, groups( $d, '--state', "$d/store" ) }
sub rec   { my ( $d, $g, $s ) = @_; spit( "$d/store/$g/old-digest.json", qq({ "result": "pass", "captured": "earlier", "seconds": $s }\n) ) }

subtest 'no recorded time: the map order, as before' => sub {
    my $d = rig();
    like( names($d), qr/^processor manager auth /, 'processor first, auth after it' );
    my ( $rc, $o ) = parts( $d, '--check' );
    is( $rc,        0,                'the run passes' ) or diag($o);
    is( order($d),  'processor auth', 'processor was measured before auth' );
};

subtest 'a timed group runs before an untimed one, whatever the map says' => sub {
    my $d = rig();
    rec( $d, 'auth', 50 );
    like( names($d), qr/^auth processor /, 'auth (timed) leads the state' );
    my ( $rc, $o ) = parts( $d, '--check' );
    is( $rc,       0,              'the run passes' ) or diag($o);
    is( order($d), 'auth processor', 'auth was measured first' );
};

subtest 'two timed groups: the shorter first' => sub {
    my $d = rig();
    rec( $d, 'processor', 500 );
    rec( $d, 'auth',      900 );
    my ( $rc, $o ) = parts( $d, '--check' );
    is( order($d), 'processor auth', 'processor (500 s) before auth (900 s)' );
    $d = rig();
    rec( $d, 'processor', 900 );
    rec( $d, 'auth',      500 );
    ( $rc, $o ) = parts( $d, '--check' );
    is( order($d), 'auth processor', 'auth (500 s) before processor (900 s)' );
};

subtest 'a measured group has its time stamped into its record' => sub {
    my $d = rig();
    my ( $rc, $o ) = parts( $d, '--check' );
    my $pd = ( groups( $d, '--digest', 'processor' ) =~ /^([0-9a-f]{64})/ )[0];
    my $r  = slurp("$d/store/processor/$pd.json");
    like( $r, qr/"seconds"\s*:\s*\d+/, 'the pass record carries seconds' );
    like( $r, qr/"result"\s*:\s*"pass"/, 'and is still a pass' );
    is_deeply( [ glob "$d/store/processor/*.[0-9]*" ], [], 'no half-written file is left beside it' );
    ( $rc, $o ) = parts( $d, '--check' );
    like( $o, qr/^coverage: SKIPPED - every group matched a recorded pass$/m, 'a stamped record is still a reused pass' );
};

subtest 'the order changes no digest' => sub {
    my $d = rig();
    my $before = groups( $d, '--digest', 'all' );
    rec( $d, 'auth', 1 );
    is( groups( $d, '--digest', 'all' ), $before, 'the combined digest is the map\'s, not the order\'s' );
};

done_testing;
