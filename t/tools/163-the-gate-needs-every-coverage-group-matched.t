#!/usr/bin/env perl
# SM1083 coverage in parts: THE GATE NEEDS EVERY GROUP MATCHED. A group that
# cannot be measured to a pass stops the driver with the group named, leaves no
# record for it and prints neither the pass line nor the skip line - so
# release.sh, which reads those markers, does not release. release.sh itself
# asks for the groups' combined digest when the tree has the map.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper        qw(repo_root run_cmd);
use CoverageGroupsRig qw(rig parts digest slurp spit);

my $root = repo_root();

subtest 'a group that fails stops the run, by name' => sub {
    my $d = rig();
    local $ENV{STUB_FAIL} = 'auth';
    my ( $rc, $o ) = parts( $d, '--check' );
    is( $rc, 1, 'exit 1, coverage.sh\'s own code' );
    like( $o, qr/^coverage: group auth: FAILED \(coverage.sh exit 1\); no pass recorded for [0-9a-f]{12}$/m, 'the group is named, with its digest' );
    like( $o, qr/^coverage: GROUPS: \d+ measured, 0 reused, \d+ nothing gated; STOPPED at auth$/m, 'and the summary says where it stopped' );
    unlike( $o, qr/SKIPPED|at or above their floors/, 'no pass line and no skip line for release.sh to read' );
    ok( !-f "$d/dist/config/coverage-last.json", 'no combined record' );
    ok( !glob("$d/store/auth/*.json"),           'nothing recorded for auth' );
    my $ad = digest( $d, 'auth' );
    ( $rc, $o ) = parts( $d, '--check' );
    is( $rc, 1, 'and the next run fails the same way: a failure never licenses a skip' );
};

subtest 'a group with gated files and no tests is a gate failure, not a quiet pass' => sub {
    my $d = rig();
    unlink "$d/t/unit/auth/01-b.t";
    my ( $rc, $o ) = parts( $d, '--check' );
    is( $rc, 1, 'exit 1' );
    like( $o, qr/^coverage: group auth: NO TESTS SELECTED for its files/m, 'said plainly' );
    ok( !glob("$d/store/auth/*.json"), 'and nothing recorded' );
};

subtest 'a group map that gives no groups is not a pass' => sub {
    my $d = rig();
    spit( "$d/tools/coverage-groups.pl", "die 'broken';\n" );
    my ( $rc, $o ) = parts( $d, '--check' );
    is( $rc, 4, 'exit 4' );
    like( $o, qr/^coverage: the group map .* gave NO GROUPS - not a pass:/m, 'said, with the map\'s own error' );
    unlike( $o, qr/SKIPPED|at or above their floors/, 'no pass line, no skip line' );
};

subtest 'release.sh asks for the combined digest when the tree has the map' => sub {
    my $src = slurp("$root/tools/release.sh");
    like( $src, qr/COV_DIGEST_TOOL=coverage-groups\.pl\n\s+COV_DIGEST_ARGS="--digest all"/, 'the gate digest is the groups\' combined one' );
    like( $src, qr/export LAZYSITE_COVER_STORE="\$COV_STORE"/, 'and the store the gate keeps is the one the groups use' );
    my $cs = slurp("$root/tools/coverage.sh");
    like( $cs, qr/exec bash "\$ROOT\/tools\/coverage-parts\.sh" "\$\@"/, 'coverage.sh hands --check over to the parts driver' );
};
done_testing;
