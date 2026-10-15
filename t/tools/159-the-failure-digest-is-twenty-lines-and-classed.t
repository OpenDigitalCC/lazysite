#!/usr/bin/env perl
# SM1083: tools/failure-digest.pl LOG prints AT MOST 20 lines: each failing
# test file, its first failed assertion, its first diagnostic, and a class
# (ENV or TEST).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();
# SM1083: the gate exports LAZYSITE_STAGE_DIR (and may export other LAZYSITE_*
# settings) into the staged tree it tests; 157 read the gate's stage as "the
# default" on 0.15.5. The scripts under test see only what this file gives them.
delete @ENV{ grep { /^LAZYSITE_(?:STAGE_|PF_|HEAVY_|COVER_|NIGHTLY_)/ } keys %ENV };
my $tmp = tempdir( CLEANUP => 1 );
sub digest {
    my ($text) = @_;
    open my $f, '>', "$tmp/log" or die;
    print {$f} $text;
    close $f;
    return run_cmd( $^X, "$root/tools/failure-digest.pl", "$tmp/log" );
}
my $o = digest(<<'X');
t/unit/a.t .. 1/3
#   Failed test 'the thing is 4'
#   at t/unit/a.t line 9.
#          got: '3'
#     expected: '4'
t/unit/b.t .. 1/2
#   Failed test 'stage is made'
#   at t/unit/b.t line 5.
# release.sh: /tmp has only 431000 free inodes.
Test Summary Report
t/unit/a.t (Wstat: 256 Tests: 3 Failed: 1)
t/unit/b.t (Wstat: 256 Tests: 2 Failed: 1)
X
my @l = split /\n/, $o;
is( scalar @l, 2, 'one line per failing file' );
like( $l[0], qr{^t/unit/a\.t \| the thing is 4 \| got: '3' \| TEST$}, 'file, assertion, first diagnostic, class TEST' );
like( $l[1], qr{^t/unit/b\.t \| stage is made \| .*inodes.* \| ENV$}, 'an inode shortage is ENV' );

my $many = join '', map { "#   Failed test 'n$_'\n#   at t/x/f$_.t line 1.\n#   boom\n" } 1 .. 60;
@l = split /\n/, digest($many);
is( scalar @l, 20, 'sixty failures print 20 lines' );
like( $l[19], qr/and 41 more/, 'the last says how many are not shown' );

@l = split /\n/, digest("coverage: KILLED (memory/signal) - cover exit 143\n");
is( scalar @l, 1, 'no named file: one line' );
like( $l[0], qr/\| ENV \|.*KILLED/, 'killed is ENV' );
@l = split /\n/, digest("all fine\n");
like( $l[0], qr/\| TEST \|/, 'nothing recognised is TEST, told to read the log' );

# The coverage stage (0.15.5): cover's source listing quotes "inodes" in a
# comment, the tools group's file was not measured, and the floor line fails.
my $cov = <<'LOG';
coverage: group auth: MEASURING - digest 09d7f0879249 (3 gated file(s) to measure)
coverage: group auth: PASSED and recorded (3012s)
coverage: group tools: MEASURING - digest 46a377f9c048 (1 gated file(s) to measure)
70                                           # The first version let them start with 500,000 inodes free
  tools/lazysite-users.pl                stmt  61.2%  bran  40.1%  (floors 75%/62%)  BELOW
  tools/lazysite-bundle-apply.pl     NOT MEASURED - gate failure
COVERAGE BELOW FLOOR
coverage: group tools: FAILED (coverage.sh exit 1); no pass recorded for 46a377f9c048
coverage: GROUPS: 4 measured, 0 reused, 4 nothing gated; STOPPED at tools after 1800s
LOG
@l = split /\n/, digest($cov);
is( scalar @l, 3, 'the coverage stage: one line a file, then the group' );
is( $l[0], 'coverage: group tools below floor - tools/lazysite-users.pl measured 61.2% vs floor 75% (statements) | TEST', 'a file under its floor, with the figures' );
is( $l[1], "coverage: group tools below floor - tools/lazysite-bundle-apply.pl not measured by the group's tests | TEST", 'a file the group did not reach' );
is( $l[2], 'coverage: group tools: FAILED (coverage.sh exit 1); no pass recorded for 46a377f9c048 | TEST', 'and the group line' );
unlike( $o = digest($cov), qr/#/, 'no comment line is quoted' );
@l = split /\n/, digest("  lib/X.pm   stmt  70.0%  bran  30.0%  (floors 75%/62%)  BELOW-BRANCH\nCOVERAGE BELOW FLOOR\n");
like( $l[0], qr/^coverage: group \? below floor - lib\/X\.pm measured 30\.0% vs floor 62% \(branches\) \| TEST$/, 'a branch shortfall names the branch figures' );
@l = split /\n/, digest("coverage: group front: FAILED (coverage.sh exit 6); no pass recorded for abc\ncoverage: KILLED (memory/signal) - cover exit 137\n");
like( $l[0], qr/^coverage: group front: FAILED .* \| ENV$/, 'a group that failed on a kill is ENV' );
@l = split /\n/, digest( "coverage: group auth: MEASURING - digest a\n  x.pl   stmt  10.0%  bran  10.0%  (floors 75%/62%)  BELOW\ncoverage: group auth: PASSED and recorded (3s)\n"
        . "coverage: group tools: MEASURING - digest b\n  y.pl     NOT MEASURED - gate failure\nCOVERAGE BELOW FLOOR\n" );
is( scalar @l, 1, 'a group that went on to pass has nothing to report' );
like( $l[0], qr/^coverage: group tools below floor - y\.pl not measured/, 'only the group that failed is' );
@l = split /\n/, digest("12   # a comment that mentions inodes and nothing else\n");
like( $l[0], qr/\| TEST \| read the log tail/, 'a comment quoting an ENV word is not evidence' );
done_testing;
