#!/usr/bin/perl
# SM1088: an edge or beta gate is not refused on stale swap.
#
# The 0.15.6 edge gate (2026-10-16) was SKIPPED: "swap in use 2521 MB is over
# 1024 MB and MemAvailable 6665 MB is under 7168 MB". The swap rule guards the
# coverage stage, and an edge gate runs none. gate-main.sh now starts the
# guard in SUITE mode unless coverage will run (stable, certified, or
# LAZYSITE_COVER_FORCE=1).
#
# HOW IT IS TOLD APART WITHOUT RUNNING A GATE. Stale swap, and a stage disk
# requirement no host meets: the HEAVY guard refuses on the swap (it is checked
# first), the SUITE guard passes the swap and refuses on the disk. Either way
# the gate stops at the guard, exit 3, before it stages anything.
use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $tmp  = File::Temp->newdir;
open my $f, '>', "$tmp/meminfo" or die $!;
print {$f} "MemAvailable: 6815744 kB\nSwapTotal: 8388604 kB\nSwapFree: 5806876 kB\n";
close $f;

sub gate {
    my (@args) = @_;
    local $ENV{LAZYSITE_PF_MEMINFO}     = "$tmp/meminfo";
    local $ENV{LAZYSITE_PF_MIN_DISK_KB} = 999_999_999_999;
    local $ENV{LAZYSITE_STAGE_DIR}      = "$tmp/stage";
    my $cmd = join ' ', map {"\Q$_\E"} 'bash', "$root/tools/gate-main.sh",
        '--version', '9.9.9', '--stage-dir', "$tmp/stage", @args;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

my ( $rc, $out ) = gate();
is( $rc, 3, 'the edge gate stops at the guard' ) or diag $out;
unlike( $out, qr/swap in use \d+ MB is over 1024 MB and MemAvailable/, 'not on the swap' );
like( $out, qr/stage base .* MB free, under/, 'on the disk, past the swap' );

( $rc, $out ) = gate('--final');
is( $rc, 3, 'the stable gate stops at the guard' ) or diag $out;
like( $out, qr/swap in use \d+ MB is over 1024 MB and MemAvailable 6656 MB is under 7168 MB/,
    'on the swap: coverage runs for stable' );

{
    local $ENV{LAZYSITE_COVER_FORCE} = 1;
    ( $rc, $out ) = gate();
    like( $out, qr/swap in use \d+ MB is over 1024 MB and MemAvailable/,
        'an edge gate with coverage forced keeps the swap rule' );
}

done_testing();
