#!/usr/bin/perl
# tools/patch-plan.pl - what a patch gate runs for a diff (SM1454 R1).
#
#   perl tools/patch-plan.pl BASE TARGET
#
# BASE and TARGET are git revisions of the tree this tool sits in: a stable patch
# is gated on the diff from the last release of its line, whose own gate passed.
# The first line says what to run:
#
#   patch<TAB>N files        the change is small and known: run every lint and the
#                            tests below. The lines after it are those tests, from
#                            tools/precheck-select.sh (the precheck's selection),
#                            slow tests included - there is no nightly run behind
#                            a release.
#   full<TAB>REASON          run the whole suite; REASON is one line for the gate's
#                            output and receipt.
#
# WHEN IT IS THE WHOLE SUITE. A change to what judges the others - the test
# harness (t/lib/), a lint's own library (anything under t/lint/ that is not a
# test), the release and gate tools and this selection, the build's control files -
# is not covered by tests chosen BY that machinery. A changed file that
# tools/precheck-areas.pl says nothing of (--uncovered) is one nobody mapped to
# tests. Either way the answer is the full suite, and the reason names the file.
#
# NOT COUNTED: release material (tools/release-material.pl --paths: the CHANGELOG,
# VERSION, the doc index, ...) - the gate writes it itself and every lint reads it -
# and download/, which a stable cut replaces. Documents (docs/, top-level *.md)
# need no test and count as covered; every lint reads them.
use strict;
use warnings;
use File::Basename qw(dirname);
use FindBin;

my $ROOT = dirname($FindBin::Bin);
chdir $ROOT or die "patch-plan: cannot enter $ROOT: $!\n";

my ( $base, $target ) = @ARGV;
die "usage: patch-plan.pl BASE TARGET\n" unless defined $target && length $target;

sub run_out {
    my @cmd = @_;
    open my $p, '-|', @cmd or die "patch-plan: cannot run $cmd[0]: $!\n";
    my @lines = <$p>;
    close $p or die "patch-plan: @cmd failed\n";
    chomp @lines;
    return grep { length } @lines;
}

my @material = run_out( $^X, 'tools/release-material.pl', '--paths' );
sub is_material {
    my ($f) = @_;
    return 1 if $f =~ m{^download/};
    for my $m (@material) {
        return 1 if $m =~ m{/$} ? index( $f, $m ) == 0 : $f eq $m;
    }
    return 0;
}

my @files = grep { !is_material($_) } run_out( 'git', 'diff', '--name-only', $base, $target );

# The first file that matches one of these decides, in file order.
my @FULL = (
    [ qr{^t/lib/}x, 'the test harness (t/lib/)' ],
    [ qr{^tools/ (?:release|gate-main|patch-plan|precheck[^/]*) \. (?:sh|pl) $}x, 'the release and precheck tools' ],
    [ qr{^t/lint/(?!.*\.t$)}x,                     "a lint's own library" ],
    [ qr{^(?:Makefile|cpanfile(?:\.snapshot)?)$}x, 'the build control files' ],
    [ qr{^(?:dist|debian)/}x,                      'the build control files' ],
);

for my $f (@files) {
    for my $rule (@FULL) {
        if ( $f =~ $rule->[0] ) {
            print "full\t$rule->[1] changed: $f\n";
            exit 0;
        }
    }
}

my @uncovered = @files ? run_out( $^X, 'tools/precheck-areas.pl', '--uncovered', @files ) : ();
if (@uncovered) {
    my $n     = @uncovered;
    my $names = join ', ', @uncovered[ 0 .. ( $n > 3 ? 2 : $n - 1 ) ];
    $names .= " (and " . ( $n - 3 ) . " more)" if $n > 3;
    print "full\tnot covered by the precheck's area map: $names\n";
    exit 0;
}

my @tests = @files ? run_out( 'bash', 'tools/precheck-select.sh', '--keep-slow', @files ) : ();
print "patch\t" . scalar(@files) . " files\n";
print "$_\n" for @tests;
exit 0;
