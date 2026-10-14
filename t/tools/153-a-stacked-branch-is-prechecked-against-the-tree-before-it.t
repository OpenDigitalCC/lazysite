#!/usr/bin/perl
# SM1080: EACH BRANCH OF A STACK IS PRECHECKED AGAINST THE TREE BEFORE ITS COMMITS.
#
# Branch by branch, lowest first, as tools/handoff.sh --stack does - but on the
# integration tree. A failure on an upper branch leaves the whole stack out (the
# lower branch is not offered without it) and rebuilds the tree as it was before
# the stack; the names say which branch failed and where the stack stopped.
# Driven in a scratch repository (t/lib/OvernightRig.pm); no real suite runs.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use OvernightRig qw(scratch stack overnight queue git spit slurp today);

my $d  = scratch( 't/a.t' => 'true' );
my $lo = stack( $d, 'lo', 'main', 'LO'      => "lo\n" );
my $hi = stack( $d, 'hi', 'lo',   'OLD-BUG' => "hi\n" );
my $z  = stack( $d, 'zz', 'main', 'ZZ'      => "z\n" );
queue( $d, "$hi hi", "$z zz" );
my ( $rc, $out, $res ) = overnight($d);
my %sha = map { $_ => git( $d, 'rev-parse', '--short', $_ ) } qw(lo hi);

like( $res, qr/^NOT READY: lo \Q$sha{lo}\E - the stack stops at hi$/m, 'the lower branch is NOT READY with its stack' ) or diag( $res, $out );
like( $res, qr/^NOT READY: hi \Q$sha{hi}\E - precheck failed on the integration tree after its commits /m, 'the failing branch is named' );
is( git( $d, 'diff', '--name-only', 'main', 'review/assess/integration' ), 'ZZ', 'the tree was rebuilt without the stack: only zz is in it' );
like( $res, qr/^LAND IN THIS ORDER:\n  1\. zz \S+ \(zz\)$/m, 'and the next stack lands alone' );
my $calls = slurp("$d/calls");
like( $calls, qr/^PRECHECK lo against base\nPRECHECK hi against lo\n/m, 'each branch was prechecked against the tree before its commits' );

done_testing();
