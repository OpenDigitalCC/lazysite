#!/usr/bin/perl
# SM1087: a stack whose branch name has a slash is prechecked, not failed.
#
# The integration run named each precheck log after the queued tip. A house
# branch name has a slash (claude/n599-...), so the log path named a directory
# that did not exist, the shell could not open it, and the stack was reported
# "NOT READY: precheck failed" without a precheck having run (2026-10-16).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use OvernightRig qw(scratch stack overnight queue slurp);

my $d = scratch( "t/a.t" => "true" );
stack( $d, 'claude/s1', 'main', 'F1' => "1\n" );
queue( $d, "$d/tmp/wt-claude/s1 claude/s1" );
my ( $rc, $out, $res ) = overnight($d);

unlike( $res, qr/NOT READY/, 'nothing is NOT READY' ) or diag( $res, $out );
like( $res, qr/^READY FOR REVIEW: claude\/s1 /m, 'the slashed branch is READY' );
like( slurp("$d/calls"), qr/^PRECHECK claude\/s1 /m, 'and its precheck ran' );

done_testing();
