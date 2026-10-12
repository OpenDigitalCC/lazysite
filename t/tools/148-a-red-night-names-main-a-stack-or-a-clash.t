#!/usr/bin/perl
# SM1062: A RED NIGHT NAMES ITS CAUSE - MAIN, A STACK, OR TWO STACKS TOGETHER.
#
# When the whole suite fails on the integration tip, each failing test file is
# run again on its own: on main, on each stack applied alone on main, and -
# when no single stack fails it - on each pair. The cause is "main itself",
# "stack X" or "stacks X+Y together (clash)"; only the stacks it names are NOT
# READY, and a stack not implicated is still READY FOR REVIEW. A red night
# files a report in the inbox.
#
# The fixture: t/main.t fails on main; t/one.t fails when x1's file is there;
# t/clash.t fails only when y1's file AND y2's file are both there, so each of
# y1 and y2 passes alone and the pair fails; z1 touches nothing a test reads.
# Driven in a scratch repository (t/lib/OvernightRig.pm); no real suite runs.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use OvernightRig qw(scratch stack overnight queue git spit slurp today);

my $d = scratch(
    't/main.t'  => 'exit 1',
    't/one.t'   => '[ ! -e ONE ]',
    't/clash.t' => '! { [ -e A ] && [ -e B ]; }',
);
my %wt;
$wt{x1} = stack( $d, 'x1', 'main', 'ONE' => "1\n" );
$wt{y1} = stack( $d, 'y1', 'main', 'A'   => "a\n" );
$wt{y2} = stack( $d, 'y2', 'main', 'B'   => "b\n" );
$wt{z1} = stack( $d, 'z1', 'main', 'Z'   => "z\n" );
queue( $d, map { "$wt{$_} $_" } qw(x1 y1 y2 z1) );
my ( $rc, $out, $res ) = overnight($d);
my %sha   = map { $_ => git( $d, 'rev-parse', '--short', $_ ) } qw(x1 y1 y2 z1);
my $integ = git( $d, 'rev-parse', '--short', 'review/assess/integration' );

like( $res, qr/^RED: the whole suite failed on review\/assess\/integration \Q$integ\E - 3 file\(s\)$/m, 'RED, three files' )
    or diag( $res, $out );
like( $res, qr/^FAIL t\/main\.t: main itself$/m, 'a file failing on main is main\'s' );
like( $res, qr/^FAIL t\/one\.t: stack x1$/m, 'a file one stack fails alone is that stack\'s' );
like( $res, qr/^FAIL t\/clash\.t: stacks y1\+y2 together \(clash\)$/m, 'a file only the pair fails is a clash' );

like( $res, qr/^NOT READY: x1 \Q$sha{x1}\E - t\/one\.t fails \(stack x1\)$/m, 'x1 is NOT READY with its file' );
like( $res, qr/^NOT READY: y1 \Q$sha{y1}\E - t\/clash\.t fails \(stacks y1\+y2 together \(clash\)\)$/m, 'y1 is NOT READY' );
like( $res, qr/^NOT READY: y2 \Q$sha{y2}\E - t\/clash\.t fails /m, 'so is y2' );
like( $res, qr/^READY FOR REVIEW: z1 \Q$sha{z1}\E \(precheck passed; not implicated in the red integration run\)$/m,
    'a stack not implicated is still READY, and says so' );
unlike( $res, qr/^(?:NOT READY|READY FOR REVIEW): \S+ .*main\.t/m, 'main\'s own failure is put on no stack' );
unlike( $res, qr/^LAND IN THIS ORDER/m, 'a red night gives no landing order' );

my $report = slurp( "$d/inbox/" . today() . '-overnight-integration-red.md' );
like( $report, qr/FAIL t\/clash\.t: stacks y1\+y2 together \(clash\)/, 'a red night files an inbox report with the verdict' );

my $calls = slurp("$d/calls");
my @whole = $calls =~ /^PROVE -lr\S* -j\d+ t\/ in (\S+)$/mg;
is( scalar @whole, 1, 'one whole suite; the attribution runs single files' );
like( $calls, qr/^PROVE -l t\/clash\.t in \Q$d\E\/tmp\/wt-integration$/m, 'in the integration worktree' );

done_testing();
