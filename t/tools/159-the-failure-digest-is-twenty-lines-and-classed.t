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
done_testing;
