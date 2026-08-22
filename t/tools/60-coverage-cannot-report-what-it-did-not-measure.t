#!/usr/bin/perl
# A coverage report about a suite that did not finish is not a measurement.
#
# WHAT THIS COST. tools/coverage.sh ran `prove ... >/dev/null 2>&1 || true` -
# the suite's output thrown away and its exit code swallowed - so a run that
# died partway produced a report indistinguishable from a healthy one, only
# with lower numbers. A 2-job run reported 38.6% for a file whose recorded
# baseline is 82.1%, the obvious reading was "job count changes the
# measurement", and that was about to be written into dist/config/coverage-floor
# as a new baseline. The floors would have been ratcheted DOWN, which that file
# forbids in as many words, on the strength of a run that never happened.
#
# The giveaway was the clock, not the numbers: 465 seconds against 270 for the
# same suite UNINSTRUMENTED. Devel::Cover does not cost 1.7x.
#
# SM444 is already the filing about a failed coverage gate blaming coverage.
# This is the same mistake one layer further in: reporting a coverage verdict
# about something that was never measured.
#
# DRIVEN AGAINST A MINIATURE TREE, because the real thing takes over an hour
# and this is not a question about the real suite - it is a question about what
# the harness does when a suite fails.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# coverage.sh derives its ROOT from its own location, so a copy in a temp tree
# operates entirely inside that tree.
sub rig {
    my ($passing) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/tools", "$d/t", "$d/dist/config" );

    open my $in, '<', "$root/tools/coverage.sh" or die $!;
    my $sh = do { local $/; <$in> };
    close $in;
    open my $out, '>', "$d/tools/coverage.sh" or die $!;
    print {$out} $sh;
    close $out;
    chmod 0755, "$d/tools/coverage.sh";

    open my $fl, '>', "$d/dist/config/coverage-floor" or die $!;
    print {$fl} "floor=75\nbranch_floor=62\n";
    close $fl;

    open my $t, '>', "$d/t/01-tiny.t" or die $!;
    print {$t} "use Test::More;\nok( "
        . ( $passing ? 1 : 0 )
        . ", 'the miniature suite' );\ndone_testing();\n";
    close $t;
    return $d;
}

sub run {
    my ( $d, @args ) = @_;
    my $args = join ' ', map { quotemeta } @args;
    my $out = qx(cd \Q$d\E && sh tools/coverage.sh $args 2>&1);
    return ( $? >> 8, $out );
}

subtest 'a passing suite still reports' => sub {
    my $d = rig(1);
    my ( $rc, $out ) = run($d);
    is( $rc, 0, 'it succeeds' ) or diag($out);
    like( $out, qr/exit=0/, 'and says the suite passed' )
        or diag( 'The suite result has to be VISIBLE even when it is good, or '
            . 'nobody learns to look for it when it is not.' );
};

subtest 'A FAILING SUITE IS SAID, NOT SWALLOWED' => sub {
    my $d = rig(0);
    my ( $rc, $out ) = run($d);
    like( $out, qr/THE SUITE DID NOT PASS/, 'the report says so, loudly' )
        or diag( 'This is the line whose absence turned a run that never '
            . 'happened into a proposed new baseline.' );
    like( $out, qr/did not finish/, 'and warns what the numbers describe' );
};

subtest 'AND --check REFUSES TO GIVE A VERDICT' => sub {
    my $d = rig(0);
    my ( $rc, $out ) = run( $d, '--check' );
    is( $rc, 3, 'it exits 3 - not 0, and not the coverage-failure code' )
        or diag( 'Exiting 0 would pass a release gate on an unmeasured suite. '
            . 'Exiting 1 would blame coverage for something that is not '
            . 'coverage, which is SM444 one layer further in.' );
    like( $out, qr/NOT CHECKING FLOORS/, 'saying it did not check' );
    unlike( $out, qr/below the declared floor/,
        'and never blames coverage for it' );
};

subtest 'set -e does not eat the failure' => sub {
    # coverage.sh runs under `set -e`, so a failing prove followed by a bare
    # `$?` on the next line would kill the script before it could explain
    # itself - the run vanishing instead of reporting, which is a louder
    # version of the same fault.
    my $d = rig(0);
    my ( $rc, $out ) = run($d);
    ok( length $out > 40, 'the script produced output after the failure' )
        or diag( 'If this is empty, set -e aborted the run at the prove line.' );
    like( $out, qr/suite under instrumentation/,
        'including the line that comes after the suite' );
};

done_testing();
