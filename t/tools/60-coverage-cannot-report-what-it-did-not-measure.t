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

    # A TEST THAT NEEDS THE REPO'S OWN lib/, written the way this suite writes
    # them: `use lib "$FindBin::Bin/../lib"` resolves to t/lib - the TEST
    # library - so the engine's lib/ arrives only because prove is run with
    # -l. coverage.sh ran `prove -r` without it for as long as it has existed,
    # and eleven files died at `use Lazysite::...` with "Can't locate", which
    # reads as a missing module and is nothing of the kind (SM478).
    # IN A SUBDIRECTORY, because that is where the real ones live and it is
    # the whole point. From t/unit, `$FindBin::Bin/../lib` resolves to t/lib -
    # the TEST library - and the engine's lib/ arrives only from -l. Put the
    # same file directly in t/ and `../lib` lands on the engine lib by
    # accident, the test passes with or without -l, and it proves nothing.
    # Which is exactly what the first version of this did: the sabotage that
    # removed -l could not fail it.
    make_path( "$d/lib/Mini", "$d/t/lib", "$d/t/unit" );
    open my $m, '>', "$d/lib/Mini/Thing.pm" or die $!;
    print {$m} "package Mini::Thing;\nsub hello {1}\n1;\n";
    close $m;
    open my $u, '>', "$d/t/unit/02-needs-lib.t" or die $!;
    print {$u} "use FindBin;\nuse lib \"\$FindBin::Bin/../lib\";\n"
        . "use Test::More;\nuse Mini::Thing;\n"
        . "ok( Mini::Thing::hello(), 'the engine lib was on \@INC' );\n"
        . "done_testing();\n";
    close $u;
    return $d;
}

sub run {
    my ( $d, @args ) = @_;
    my $args = join ' ', map { quotemeta } @args;

    # PERL5OPT IS CLEARED, because this file runs coverage.sh INSIDE a coverage
    # run. Inherited, the outer run's Devel::Cover follows every process the
    # miniature one starts, writes into the OUTER database, and the inner run
    # measures and reports something other than itself - so this file passed
    # standalone and failed in the suite, which is the least useful pair of
    # outcomes a test can have.
    #
    # A harness that tests a harness has to stand outside the one it is testing.
    local $ENV{PERL5OPT} = '';
    local $ENV{HARNESS_PERL_SWITCHES} = '';

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

subtest 'SM478: THE ENGINE LIB REACHES THE SUITE' => sub {
    # The whole of SM478 in one assertion. Without -l, t/02-needs-lib.t dies at
    # `use Mini::Thing` and the run is reported as a failing suite - which is
    # now visible, but the point is that it should not be failing at all.
    my $d = rig(1);
    my ( $rc, $out ) = run($d);
    is( $rc, 0, 'the suite passes' ) or diag($out);
    unlike( $out, qr/Can't locate/,
        'nothing failed to find a module that is right there' )
        or diag( 'coverage.sh must run prove the way the gate does. `-r`
            without `-l` leaves the engine lib off @INC, and Perl reports the
            resulting open() failure as "Can\'t locate" - which reads as a
            missing module and sends you looking for the wrong thing.' );
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
