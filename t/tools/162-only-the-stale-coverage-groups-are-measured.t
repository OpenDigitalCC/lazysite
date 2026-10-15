#!/usr/bin/env perl
# SM1083 coverage in parts: the driver (coverage.sh hands --check over to
# coverage-parts.sh) measures ONLY the groups whose digest has no recorded
# pass, each with its own tests, files, floor lines and DB; reuses the rest;
# records each pass under the group and digest; and runs everything with
# --all. A stub coverage.sh records what it was asked; nothing is instrumented.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use CoverageGroupsRig qw(rig parts digest spit slurp);

my $d  = rig();
my $ad = digest( $d, 'auth' );
spit( "$d/store/auth/$ad.json", qq({ "inputs_digest": "$ad", "result": "pass", "captured": "earlier" }\n) );

my ( $rc, $o ) = parts( $d, '--check' );
is( $rc, 0, 'exit 0' ) or diag($o);
like( $o, qr/^coverage: group auth: REUSED - digest \Q${\ substr $ad, 0, 12}\E matched a recorded pass \(captured earlier\)/m,
    'auth is reused, with its digest and when it passed' );
like( $o, qr/^coverage: group processor: MEASURING/m, 'processor is measured' );
like( $o, qr/^coverage: group data: nothing gated/m, 'a group with nothing floor-checked is said, not run' );
my $calls = slurp("$d/calls");
is( scalar( () = $calls =~ /^RAN /mg ), 1, 'coverage.sh ran once' );
like( $calls, qr/^RAN processor tests=t\/unit\/processor\/01-a\.t, files=lazysite-processor\.pl, floor=3 db=cover_db-processor$/m,
    'for the processor group: its tests, its files, its floor lines, its own DB' );
my $pd = digest( $d, 'processor' );
ok( -f "$d/store/processor/$pd.json", 'and its pass is recorded under the group and digest' );
like( $o, qr/^coverage: GROUPS: 1 measured, 1 reused, \d+ nothing gated$/m, 'the summary counts' );
unlike( $o, qr/^coverage: SKIPPED/m, 'a run that measured is not a skip' );
like( $o, qr/^coverage: all measured production CGIs and their parts at or above their floors/m, 'and ends with the pass line release.sh reads' );
like( slurp("$d/dist/config/coverage-last.json"), qr/"processor": \{ "digest": "$pd", "state": "pass" \}/, 'the combined record names each group and its digest' );

( $rc, $o ) = parts( $d, '--check' );
is( $rc,                                           0, 'a second run exits 0' );
is( scalar( () = slurp("$d/calls") =~ /^RAN /mg ), 1, 'and runs nothing' );
like( $o, qr/^coverage: SKIPPED - every group matched a recorded pass$/m, 'saying every group matched (the marker release.sh reads as reused)' );

spit( "$d/lazysite-auth.pl", "print 3;\n" );
( $rc, $o ) = parts( $d, '--check' );
is( scalar( () = slurp("$d/calls") =~ /^RAN auth /mg ), 1, 'a changed auth file re-measures auth' );
is( scalar( () = slurp("$d/calls") =~ /^RAN processor /mg ), 1, 'and not processor' );

( $rc, $o ) = parts( $d, '--check', '--all' );
is( $rc,                                           0, '--all exits 0' );
is( scalar( () = slurp("$d/calls") =~ /^RAN /mg ), 4, 'and measures every gated group again, matched or not' );

( $rc, $o ) = parts( $d, '--check', '--group', 'processor' );
is( scalar( () = slurp("$d/calls") =~ /^RAN processor /mg ), 2, '--group on a matched group reuses it, as the driver would' );
like( $o, qr/^coverage: group processor: REUSED/m, 'and says so' );
( $rc, $o ) = parts( $d, '--check', '--group', 'processor', '--all' );
is( scalar( () = slurp("$d/calls") =~ /^RAN processor /mg ), 3, '--group --all runs that group alone' );
is( scalar( () = slurp("$d/calls") =~ /^RAN auth /mg ), 2, 'and no other' );
done_testing;
