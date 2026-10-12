#!/usr/bin/perl
# SM1061: EVERY CODE AREA HAS A PRECHECK ROW, AND THE WHOLE SUITE ONE RUNNER.
#
# The handoff no longer runs the whole suite; the precheck runs the tests of
# each area a change touches, from the one map in tools/precheck-areas.pl. An
# area with no row would be covered only by the tests that happen to name the
# changed file - the gap t/unit/processor/101 fell through on 2026-10-12. So:
#
#   1. every top-level code area has its own row: each lazysite-*.pl front end,
#      lazysite-processor/, each directory under lib/Lazysite/, lib/Lazysite/
#      itself (its single modules), plugins/ and tools/;
#   2. every selector in the map selects at least one test, so a renamed test
#      directory cannot leave a row that quietly runs nothing;
#   3. the whole plain suite is run only by tools/suite.sh, which takes the
#      host-wide lock - not by the handoff or a make tier on its own.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
{
    local @ARGV = ();
    local $0    = "$root/tools/precheck-areas.pl";
    require "$root/tools/precheck-areas.pl";    ## no critic (RequireBarewordIncludes)
}
my @rows = main::rows();
my %row  = map { $_->[0] => $_ } @rows;

subtest 'every top-level code area has its own row' => sub {
    my @areas = (
        ( map { s{^\Q$root\E/}{}r } glob("$root/lazysite-*.pl") ),
        'lazysite-processor/',
        ( map { s{^\Q$root\E/}{}r . '/' } grep { -d } glob("$root/lib/Lazysite/*") ),
        'lib/Lazysite/', 'plugins/', 'tools/',
    );
    cmp_ok( scalar @areas, '>', 15, 'found the code areas to check' );
    my @missing = grep { !$row{$_} } @areas;
    is_deeply( \@missing, [], 'each has a row in tools/precheck-areas.pl' )
        or diag('Add a row naming the test directories that cover it (SM1061).');
};

subtest 'every selector selects a test' => sub {
    my @empty;
    for my $r (@rows) {
        for my $sel ( @{$r}[ 1 .. $#$r ] ) {
            push @empty, "$r->[0]: $sel" unless main::select_tests($sel);
        }
    }
    is_deeply( \@empty, [], 'no row runs nothing' );
};

subtest 'the whole suite has one runner' => sub {
    my $code = sub {
        open my $f, '<', "$root/$_[0]" or die "$_[0]: $!";
        return grep { !/^\s*#/ } <$f>;
    };
    for my $f (qw(tools/handoff.sh Makefile tools/precheck.sh scripts/pre-review.sh tools/overnight.sh tools/integration.pl)) {
        my @direct = grep { /\bprove\b[^\n]*\s-\S*r\b[^\n]*\bt\/(?:\s|\|\||$)/ } $code->($f);
        is_deeply( \@direct, [], "$f runs no whole suite of its own" );
    }
    like( join( '', $code->('tools/suite.sh') ), qr/flock/, 'tools/suite.sh takes the lock' );
    like( join( '', $code->('tools/suite.sh') ), qr/--git-common-dir/, '...in the common git dir' );
};

done_testing();
