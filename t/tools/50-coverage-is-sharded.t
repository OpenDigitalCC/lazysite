#!/usr/bin/perl
# SM280: the coverage run is the gate, and it is now sharded.
#
# SM269 phase 0 attributed the eighty minutes with strace rather than
# estimation: coverage is 92% of gate wall-clock at a 12.4x instrumentation
# multiplier. Phases 1 and 2 improved the developer loop and moved the gate not
# at all, and SM269 recorded that plainly rather than claiming a win.
#
# Of the three candidate shapes, sharding is the only one that keeps the gate's
# MEANING intact - deferring coverage to a schedule and covering a rotating
# slice both trade coverage of this commit for speed.
#
# AND IT NEEDED NO MERGING MACHINERY. Devel::Cover already writes one directory
# per process under the shared db and `cover` merges them; that is the same
# mechanism that lets instrumented CGI subprocesses be counted at all. Parallel
# prove workers are more of the same writers.
#
# MEASURED on t/unit/mcp before the change was made:
#
#   serial   467s   52.2% statement / 27.2% branch
#   -j4      182s   52.2% statement / 27.2% branch
#
# The identical numbers are the half that matters. A faster run reporting
# DIFFERENT coverage would be a faster run measuring something else, which is
# the failure this project keeps finding in other clothes.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $COV  = "$root/tools/coverage.sh";
ok( -f $COV, 'coverage.sh is present' );

my $src = do { open my $fh, '<', $COV or die $!; local $/; <$fh> };

# The comments explain the change, so they contain every word the assertions
# below look for. Matching prose instead of code is how t/lint/55 first flagged
# its own subject, and it is worth not repeating in the same session.
my $code = join "\n", grep { !/^\s*#/ } split /\n/, $src;

subtest 'the suite runs in parallel under coverage' => sub {
    like( $src, qr/prove -j"\$JOBS" -r t\//,
        'prove is given a job count' )
        or diag( 'Serial coverage is 92% of an eighty-minute gate and no other '
            . 'lever moves it.' );
    like( $src, qr/JOBS=\$\{LAZYSITE_COVER_JOBS:-\d+\}/,
        'with a default and an override' );
};

subtest 'and the shared database is still the merge point' => sub {
    # Not N databases and a merge step. One db, many writers - the mechanism
    # that already counts the CGI subprocesses.
    my ($cmd) = $src =~ /(PERL5OPT=.*?prove -j.*?\|\| true)/s;
    ok( $cmd, 'the run is identifiable' ) or return;
    like( $cmd, qr/-db,\$DB/, 'every writer targets the one db' );
    unlike( $code, qr/cover\s.*-add\b/,
        'and no bespoke merging step was introduced' )
        or diag( 'Devel::Cover merges runs itself. A hand-rolled merge would '
            . 'be a second implementation of the thing that already works.' );
};

subtest 'the measurement is recorded where the change is' => sub {
    # A speed change with no numbers beside it is a claim. The next person to
    # wonder whether -j is safe should find the evidence rather than repeat it.
    like( $src, qr/MEASURED, not assumed/, 'the comment says it was measured' );
    like( $src, qr/467s/,                  'with the serial figure' );
    like( $src, qr/182s/,                  'and the parallel one' );
    like( $src, qr/52\.2/,                 'and the coverage that must not have moved' )
        or diag( 'The timing is the benefit; the identical coverage is the '
            . 'proof it is the same measurement.' );
};

subtest 'the job count is capped rather than nproc' => sub {
    # The run is inode-heavy - a directory per instrumented subprocess - and
    # release.sh already refuses to stage where inodes are short. More workers
    # past a point buys contention, not speed.
    unlike( $code, qr/nproc/, 'not derived from the core count' );
    like( $src, qr/inode/, 'and the reason is stated' );
};

done_testing();
