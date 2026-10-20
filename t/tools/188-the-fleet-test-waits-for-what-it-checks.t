#!/usr/bin/perl
# SM1208: t/tools/29-cli-fleet.t compares each site's installed version with
# the VERSION file. t/tools/52 rewrites VERSION to 99.0.0 for the length of its
# run, under TestHelper::preserve_tracked's lock. 29 read VERSION without that
# lock: under prove -j (the nightly) it read 99.0.0, built its manifests across
# the moment 52 put VERSION back, and installed 0.15.12 where it expected
# 99.0.0 (nightly 2026-10-20 08:33: 'got 0.15.12, expected 99.0.0').
#
# So: hold the VERSION lock here, start 29, and require that it makes no
# progress until the lock is let go - then that it passes. Nothing is loaded
# on the host beyond the one 29 run (about ten seconds).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root preserve_tracked);

my $root = repo_root();
my $t29  = "$root/t/tools/29-cli-fleet.t";
plan skip_all => "no $t29" unless -f $t29;

my ( $ofh, $out ) = tempfile( 'fleet-wait-XXXXXX', TMPDIR => 1, UNLINK => 1 );
close $ofh;

my $held = preserve_tracked("$root/VERSION");

my $pid = fork();
die "fork: $!" unless defined $pid;
if ( !$pid ) {
    open STDOUT, '>', $out or die $!;
    open STDERR, '>&', \*STDOUT or die $!;
    exec $^X, $t29;
    exit 127;
}

sleep 8;    # far longer than 29 needs to reach its first subtest
my $so_far = do { open my $fh, '<', $out or die $!; local $/; <$fh> };
is( waitpid( $pid, 1 ), 0, 'the fleet test is still waiting while VERSION is held' );
unlike( $so_far, qr/Subtest|^ok /m, 'and has checked nothing yet' )
    or diag($so_far);

undef $held;    # restore + unlock, as 52 does at its end
waitpid( $pid, 0 );
is( $? >> 8, 0, 'once VERSION is free the fleet test runs and passes' )
    or diag( do { open my $fh, '<', $out or die $!; local $/; <$fh> } );

done_testing();
