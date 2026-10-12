#!/usr/bin/perl
# SM949: THE PRE-CHECK RUNS FIRST, AND ONLY THE SLOW PARTS ARE NARROWED.
#
# Most handoff re-runs in 0.15.2 were a lint, tidy or a file that did not
# compile - knowable in seconds, found after the six-minute suite. tools/precheck.sh
# runs the lints and the tests naming a changed file in about ten seconds, and
# handoff.sh stops on it. (Since SM1061 it also runs each touched area's tests;
# t/tools/144 covers that.)
#
# What it narrows, and why each is safe:
#   - the two perlcritic lints check only changed files WHEN TOLD TO
#     (LAZYSITE_LINT_FILES); unset, as in the suite, handoff and gate, they check
#     every file as before;
#   - the three changelog lints run only when CHANGELOG.md changed;
#   - tests measured over 20 s are left to the whole suite, which still runs
#     them (nightly and for a release, SM1061).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
sub slurp { open my $f, '<', $_[0] or die "$_[0]: $!"; local $/; my $t = <$f>; close $f; $t }
my $h = slurp("$root/tools/handoff.sh");
my $p = slurp("$root/tools/precheck.sh");

# SM1061: the whole suite is no longer the handoff's - it runs only with --full,
# through tools/suite.sh - so the pre-check is what a default handoff tests with.
subtest 'handoff runs the pre-check before any suite, and stops on it' => sub {
    my $pre   = index( $h, 'bash tools/precheck.sh' );
    my $suite = index( $h, 'bash tools/suite.sh' );
    ok( $pre > 0 && $suite > $pre, 'the pre-check comes before the --full suite' );
    unlike( $h, qr/^[^#\n]*\bprove -lr/m, 'and the handoff runs no prove -lr of its own' );
    like( $h, qr/precheck failed.*?exit 1/s, 'and a failure ends the handoff there' );
};

subtest 'the perlcritic lints narrow only when asked' => sub {
    for my $l (qw(t/lint/02-perlcritic.t t/lint/05-perlcritic-security.t)) {
        my $s = slurp("$root/$l");
        like( $s, qr/if \( defined \$ENV\{LAZYSITE_LINT_FILES\} \)/, "$l narrows on LAZYSITE_LINT_FILES" );
    }
    local $ENV{LAZYSITE_LINT_FILES} = 'no/such/file.pl';
    my $out = `$^X -I\Q$root/lib\E -I\Q$root/t/lib\E \Q$root/t/lint/02-perlcritic.t\E 2>&1`;
    like( $out, qr/skip.*no changed production scripts/i, 'told about no production file, it checks none' );
};

subtest 'the slow parts are left to the full suite, by name' => sub {
    like( $p, qr{t/tools/60-coverage-cannot-report-what-it-did-not-measure\.t}, 'the 150 s coverage test' );
    like( $p, qr{grep -qx CHANGELOG\.md}, 'the changelog lints only when the changelog changed' );
    like( $p, qr/LAZYSITE_LINT_FILES=.*grep -v '\^t\/'/, 'and test files are kept out of the production-file list' );
};

done_testing();
