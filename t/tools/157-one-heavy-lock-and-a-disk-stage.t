#!/usr/bin/env perl
# SM1083: ONE heavy lock (tools/heavy-lock.sh) so two heavy jobs never overlap,
# a waiting caller names the holder; the gate's stage defaults to a DISK path
# (created; retained stages older than 2 days removed) unless told otherwise.
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
delete $ENV{LAZYSITE_HEAVY_HELD};
$ENV{LAZYSITE_HEAVY_LOCK} = "$tmp/heavy.lock";
my $hl = "$root/tools/heavy-lock.sh";

# A holder: takes the lock, signals, waits on a fifo-less sleep.
my $pid = fork();
die unless defined $pid;
if ( !$pid ) {
    exec 'bash', '-c', ". $hl; heavy_lock $root holder-one wait; touch $tmp/held; sleep 30";
}
for ( 1 .. 100 ) { last if -e "$tmp/held"; select( undef, undef, undef, 0.1 ) }
ok( -e "$tmp/held", 'the first heavy job holds the lock' );

my $o = run_cmd( 'bash', '-c', ". $hl; heavy_lock $root second nowait; echo rc=\$?" );
like( $o, qr/held by: holder-one/, 'a second job is told who holds it' );
like( $o, qr/rc=3/,                'and with nowait gets 3 (skip)' );
$o = run_cmd( 'bash', '-c', "LAZYSITE_HEAVY_HELD=1; . $hl; heavy_lock $root nested wait; echo rc=\$?" );
like( $o, qr/^rc=0/, 'a nested job (HELD=1) does not lock again' );
kill 'TERM', $pid;
waitpid $pid, 0;
$o = run_cmd( 'bash', '-c', ". $hl; heavy_lock $root third nowait; echo rc=\$?" );
like( $o, qr/^rc=0/, 'the lock is free once the holder is gone' );

# The stage default.
my $sd  = "$root/tools/stage-default.sh";
my $def = "$tmp/stage";
{
    local $ENV{LAZYSITE_STAGE_DEFAULT} = $def;
    mkdir $def;
    mkdir "$def/old";
    mkdir "$def/new";
    utime( time - 3 * 86400, time - 3 * 86400, "$def/old" );
    is( run_cmd( 'bash', $sd ), "$def\n", 'the default stage base is the disk path' );
    ok( !-d "$def/old", 'a retained stage older than 2 days is removed' );
    ok( -d "$def/new",  'a newer one is kept' );
    local $ENV{LAZYSITE_STAGE_DIR} = "$tmp/mine";
    is( run_cmd( 'bash', $sd ), "$tmp/mine\n", 'LAZYSITE_STAGE_DIR wins' );
    ok( !-d "$tmp/mine", 'and is not created or pruned here' );
}
like( run_cmd( 'grep', '-n', 'var/tmp/lazysite-stage', $sd ), qr/var\/tmp/, 'the built-in default is under /var/tmp, not /tmp or /srv' );
done_testing;
