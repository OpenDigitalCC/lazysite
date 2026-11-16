#!/usr/bin/perl
# SM1449 R1: a gate on a tree with a recorded suite pass says when that pass was made -
# "suite: passed on this tree at <when>, reused" - and the receipt carries the time
# (suite_passed_at=), so the evidence for a release says what was reused and from when.
# The record itself is SM1454 R2 (t/tools/680); a damaged record is its refusal, and
# nothing recorded means the suite runs. Driven through the real release.sh (t/lib/ReleaseRig.pm).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use ReleaseRig qw(spit slurp git rig_repo rig_release rig_runs);

plan skip_all => 'setsid missing' unless grep { -x "$_/setsid" } split /:/, $ENV{PATH};

my $LOGDIR = tempdir( CLEANUP => 1 );
my $LOG    = "$LOGDIR/runs";
sub runs { return scalar grep { $_ eq 'suite' } @{ rig_runs($LOG) } }
sub gate { my ($d) = @_; rig_release( $d, { STUB_RUN_LOG => $LOG }, 'gate', '0.1.1', '--commit', git( $d, 'rev-parse', 'main' ) ) }

my $d = rig_repo();
my ( $rc, $out ) = gate($d);
is( $rc, 0, 'the first gate passes' ) or BAIL_OUT($out);
unlike( $out, qr/reused/, 'and reuses nothing' );
my $r1 = slurp("$d/tmp/release-gate/0.1.1/receipt");
unlike( $r1, qr/^suite_passed_at=/m, 'its receipt names no reused pass' );
my ($rec) = glob("$d/tmp/release-gate/suite-passes/*.json");
my ($when) = slurp($rec) =~ /"captured"\s*:\s*"([^"]+)"/;
ok( $when, 'the record says when it was made' );

( $rc, $out ) = gate($d);
is( $rc,    0, 'the second gate passes' ) or diag($out);
is( runs(), 1, 'without the suite' );
my @l = grep { /passed on this tree/ } split /\n/, $out;
is( scalar @l, 1, 'and says so in one line' );
like( $l[0], qr/^==> suite: passed on this tree \([0-9a-f]{12}\) at \Q$when\E, reused \(\d+ files, \d+ tests\)/, 'naming the tree, when it passed and that it was reused' );
like( slurp("$d/tmp/release-gate/0.1.1/receipt"), qr/^suite_passed_at=\Q$when\E$/m, 'the receipt carries when' );

spit( "$d/t/unit/01-more.t", "use Test::More; ok(1); done_testing;\n" );
ReleaseRig::commit( $d, 'a change' );
( $rc, $out ) = gate($d);
is( runs(), 2, 'a changed tree runs the suite' );
unlike( $out, qr/reused/, 'and says nothing was reused' );
unlike( slurp("$d/tmp/release-gate/0.1.1/receipt"), qr/^suite_passed_at=/m, 'the new receipt carries no reused time' );

done_testing;
