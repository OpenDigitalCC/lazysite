#!/usr/bin/perl
# SM1080: THE RESULTS SAY WHICH BASE A STACK WAS ON, AND HOW FAR BEHIND MAIN.
#
# A stack is cherry-picked onto the integration tree, so one based on an older
# main is, in effect, rebased in the run. The results file says so, so a reader
# sees why: "stack base is older than main by N commits". A stack on main's tip
# says it sits on main.
# Driven in a scratch repository (t/lib/OvernightRig.pm); no real suite runs.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use OvernightRig qw(scratch stack overnight queue git spit slurp today);

my $d    = scratch( 't/a.t' => 'true' );
my $old  = stack( $d, 'oldb', 'main', 'A' => "a\n" );
my $base = git( $d, 'rev-parse', '--short', 'main' );
for my $n ( 1 .. 3 ) {
    spit( "$d/m$n", "$n\n" );
    git( $d, 'add', "m$n" );
    git( $d, 'commit', '-q', '-m', "main $n" );
}
my $new = stack( $d, 'newb', 'main', 'B' => "b\n" );
my $tip = git( $d, 'rev-parse', '--short', 'main' );
queue( $d, "$old oldb", "$new newb" );
my ( $rc, $out, $res ) = overnight($d);

like( $res, qr/^BASE: oldb sits on \Q$base\E; stack base is older than main by 3 commits - /m,
    'a stack on an older main says where, and by how many commits' )
    or diag( $res, $out );
like( $res, qr/^BASE: newb sits on main \Q$tip\E$/m, 'a stack on main\'s tip says it sits on main' );
like( $res, qr/^BASE: oldb .*\n(?:.*\n)*?BASE: newb /m, 'in queue order' );
like( $res, qr/^GREEN:/m,                               'and both landed green' );

done_testing();
