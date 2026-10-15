#!/usr/bin/perl
# SM1081: EACH COMMIT OF A STACK IS CHERRY-PICKED EXACTLY ONCE.
#
# On 2026-10-15 the overnight run picked n566's one commit three times - once
# per branch of the stack n566 < n567 < n568 - and the third copy collided, so
# the stack was reported "CONFLICT with main" though main touched none of its
# files. Each branch's pick took main..<branch>, which holds the lower
# branches' commits too; `git cherry` did not mark the first copy as applied
# because the pick had auto-merged (main had moved the context, CHANGELOG.md)
# and so carried a new patch-id. Now each branch picks only the tip of the
# branch below it (or the stack's base on main) to its own tip.
#
# The fixture: a 3-branch stack on an older main; each branch appends to a
# shared file whose context main has since moved, so a pick auto-merges and its
# patch-id changes - exactly the 2026-10-15 shape.
# Driven in a scratch repository (t/lib/OvernightRig.pm); no real suite runs.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use OvernightRig qw(scratch stack overnight queue git spit slurp today);

my $old = "head\np1\np2\np3\np4\np5\np6\nctx\nold line\n";   # p6 is in the pick's context
my $d = scratch( "t/a.t" => "true", "LOG" => substr( $old, 0, -1 ) ); # scratch adds the final newline
my $b1 = stack( $d, 'b1', 'main', 'LOG' => "${old}b1\n",         'F1' => "1\n" );
my $b2 = stack( $d, 'b2', 'b1',   'LOG' => "${old}b1\nb2\n",     'F2' => "2\n" );
my $b3 = stack( $d, 'b3', 'b2',   'LOG' => "${old}b1\nb2\nb3\n", 'F3' => "3\n" );
( my $moved = $old ) =~ s/p6/p6 moved on main/; # 2 lines above the pick: in its context, not adjacent
spit( "$d/LOG", $moved );
git( $d, 'commit', '-q', '-am', 'main moves the context' );
my $base = git( $d, 'rev-parse', '--short', 'b1~1' );
queue( $d, "$b3 b3" );
my ( $rc, $out, $res ) = overnight($d);

unlike( $res, qr/CONFLICT/,  'no CONFLICT is reported' ) or diag( $res, $out );
unlike( $res, qr/NOT READY/, 'nothing is NOT READY' );
like( $res, qr/^GREEN:/m, 'the stack lands green' );
is( git( $d, 'log', '--reverse', '--format=%s', 'main..review/assess/integration' ), "b1\nb2\nb3",
    'each commit is on the integration tree exactly once, in order' );
like( $res, qr/^BASE: b3 sits on \Q$base\E; stack base is older than main by 1 commits/m, 'the base line says the stack is behind main' );
is( git( $d, 'show', 'review/assess/integration:LOG' ), "${moved}b1\nb2\nb3", 'main\'s move and all three lines are in the file' );
like( slurp("$d/calls"), qr/^PRECHECK b1 against main moves the context\nPRECHECK b2 against b1\nPRECHECK b3 against b2\n/m,
    'each branch was prechecked once, against the tree before its own commits' );
like( $res, qr/^READY FOR REVIEW: b1 .*\nREADY FOR REVIEW: b2 .*\nREADY FOR REVIEW: b3 /m, 'every branch is READY' );

done_testing();
