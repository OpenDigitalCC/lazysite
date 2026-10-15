#!/usr/bin/env perl
# SM1083 coverage in parts: `coverage.sh --groups` lists every group with its
# state - pass (and when), stale (and what it would measure), or nothing gated -
# and runs nothing.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use CoverageGroupsRig qw(rig parts digest spit);

my $d  = rig();
my $ad = digest( $d, 'auth' );
spit( "$d/store/auth/$ad.json", qq({ "inputs_digest": "$ad", "result": "pass", "captured": "2026-10-14T01:02:03Z" }\n) );

my ( $rc, $o ) = parts( $d, '--groups' );
is( $rc, 0, 'exit 0' ) or diag($o);
like( $o, qr/^coverage groups \(store \Q$d\E\/store\):\n/, 'headed with the store it read' );
like( $o, qr/^  processor\s+stale\s+[0-9a-f]{12}  1 gated file\(s\) to measure$/m, 'a stale group: its digest and what a run would measure' );
like( $o, qr/^  auth\s+pass\s+\Q${\ substr $ad, 0, 12}\E  captured 2026-10-14T01:02:03Z$/m, 'a matched group: its digest and when the pass was measured' );
like( $o, qr/^  data\s+nothing-gated\s+[0-9a-f]{12}  no file of this group is floor-checked$/m, 'a group with no floor-checked file' );
is( scalar( () = $o =~ /^  \S+\s+(?:stale|pass|nothing-gated)\s/mg ), 9, 'nine rows, one a group' );
ok( !-e "$d/calls", 'nothing ran' );

# A pass whose record is not a pass is stale.
spit( "$d/store/auth/$ad.json", qq({ "inputs_digest": "$ad", "result": "fail" }\n) );
( $rc, $o ) = parts( $d, '--groups' );
like( $o, qr/^  auth\s+stale/m, 'a recorded failure does not match' );
done_testing;
