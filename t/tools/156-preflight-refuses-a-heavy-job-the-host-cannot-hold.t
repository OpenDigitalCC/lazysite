#!/usr/bin/env perl
# SM1083: tools/preflight.sh HEAVY refuses to START a heavy job unless memory,
# swap, stage disk, inodes and the heavy lock allow it. One line naming the
# failed condition, exit 3 = "not now" (a SKIP, never a failure). Thresholds
# are env-overridable; JOBS is 4 at >= 8 GB MemAvailable, else 2.
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
my $pf  = "$root/tools/preflight.sh";
my $tmp = tempdir( CLEANUP => 1 );
delete $ENV{LAZYSITE_HEAVY_HELD};
$ENV{LAZYSITE_HEAVY_LOCK} = "$tmp/heavy.lock";

sub meminfo {
    my ( $avail, $swt, $swf ) = @_;
    our $n; $n++; open my $f, ">", "$tmp/meminfo$n" or die;
    print {$f} "MemAvailable: $avail kB\nSwapTotal: $swt kB\nSwapFree: $swf kB\n";
    close $f;
    return "$tmp/meminfo$n";
}
sub pf {
    my (%env) = @_;
    my $mode = delete $env{MODE} // q(HEAVY);
    local @ENV{ keys %env } = values %env;
    my $o = run_cmd( q(bash), $pf, $mode, $tmp );
    return ( $? >> 8, $o );
}
my $good = meminfo( 16_000_000, 4_000_000, 4_000_000 );
my %ok = ( LAZYSITE_PF_MEMINFO => $good, LAZYSITE_PF_MIN_INODES => 1, LAZYSITE_PF_MIN_DISK_KB => 1 );

my ( $rc, $o ) = pf(%ok);
is( $rc, 0, 'a roomy host goes' ) or diag($o);

( $rc, $o ) = pf( %ok, LAZYSITE_PF_MEMINFO => meminfo( 1_000_000, 4_000_000, 4_000_000 ) );
is( $rc, 3, 'low MemAvailable is "not now" (3)' );
like( $o, qr/^preflight: not now - MemAvailable/, 'and names memory' );
is( scalar( () = $o =~ /\n/g ), 1, 'in one line' );

# Swap in use lags (pages a finished run pushed out stay there), so it refuses
# only when memory is ALSO short: under the memory threshold (5 GB) plus 2 GB.
( $rc, $o ) = pf( %ok, LAZYSITE_PF_MEMINFO => meminfo( 6_000_000, 4_000_000, 1_000_000 ) );
is( $rc, 3, 'swap in use over 1 GB with MemAvailable under 7 GB is "not now"' );
like( $o, qr/^preflight: not now - swap in use 2929 MB is over 1024 MB and MemAvailable 5859 MB is under 7168 MB$/m, 'naming both' );
( $rc, $o ) = pf( %ok, LAZYSITE_PF_MEMINFO => meminfo( 16_000_000, 4_000_000, 1_000_000 ) );
is( $rc, 0, 'the same swap with 16 GB available goes' );
like( $o, qr/^preflight: note - swap in use 2929 MB is over 1024 MB, but MemAvailable 15625 MB is ample; not refusing/m, 'with a note, not a refusal' );
( $rc, $o ) = pf( %ok, LAZYSITE_PF_MEMINFO => meminfo( 16_000_000, 4_000_000, 1_000_000 ), LAZYSITE_PF_SWAP_SLACK_KB => 20_000_000 );
is( $rc, 3, 'the slack is a threshold of its own' );

# SM1088: SUITE, for a gate that runs no coverage stage, has no swap rule - the
# 0.15.6 edge gate was refused on stale swap with 6,665 MB available.
( $rc, $o ) = pf( %ok, MODE => q(SUITE), LAZYSITE_PF_MEMINFO => meminfo( 6_000_000, 4_000_000, 1_000_000 ) );
is( $rc, 0, q(SUITE goes on the swap HEAVY refuses) );
like( $o, qr/^preflight: note - swap in use 2929 MB is over 1024 MB; not refusing \(no coverage stage/m, q(with a note saying why) );
( $rc, $o ) = pf( %ok, MODE => q(SUITE), LAZYSITE_PF_MEMINFO => meminfo( 1_000_000, 4_000_000, 4_000_000 ) );
is( $rc, 3, q(SUITE still refuses memory under the threshold) );

( $rc, $o ) = pf( %ok, LAZYSITE_PF_MIN_DISK_KB => 999_999_999_999 );
is( $rc, 3, 'too little stage disk is "not now"' );
like( $o, qr/free, under/, 'and names the disk' );

( $rc, $o ) = pf( %ok, LAZYSITE_PF_MIN_INODES => 999_999_999_999 );
is( $rc, 3, 'too few inodes is "not now"' );
like( $o, qr/free inodes/, 'and names inodes' );

open my $lk, '>>', "$tmp/heavy.lock" or die;
use Fcntl qw(:flock);
flock( $lk, LOCK_EX ) or die;
( $rc, $o ) = pf(%ok);
is( $rc, 3, 'a held heavy lock is "not now"' );
like( $o, qr/heavy lock/, 'and names the lock' );
{
    local $ENV{LAZYSITE_HEAVY_HELD} = 1;
    ( $rc, $o ) = pf(%ok);
    is( $rc, 0, 'a nested job (the lock already ours) is not refused by it' );
}
close $lk;

for my $c ( [ 16_000_000, 4 ], [ 7_000_000, 2 ] ) {
    local $ENV{LAZYSITE_PF_MEMINFO} = meminfo( $c->[0], 0, 0 );
    is( run_cmd( 'bash', $pf, 'JOBS' ), "$c->[1]\n", "JOBS is $c->[1] at MemAvailable $c->[0] kB" );
}
done_testing;
