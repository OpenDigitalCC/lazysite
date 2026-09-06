#!/usr/bin/perl
# SM755, from the 0.13.1 daemon review, dimension 5 (reliability) experiments
# 6, 8 and 10, each of which found the service doing the wrong thing:
#
#   6. kill -9 the supervisor: its scheduler ran on as an orphan, a second
#      supervisor started a second scheduler beside it, and status() showed one
#      healthy service while two ran the same jobs on the same files.
#   8. write any live pid into scheduler.pid: status() said `on`. `kill 0`
#      proves a process exists, not that it is ours.
#  10. corrupt the run record: every job ran at once, in silence.
#
# Now: a supervisor holds a lock for the docroot and a second is refused with
# exit 3; a supervisor that finds an orphan it can PROVE is its predecessor's
# (pid and kernel start time both match) stops it before starting afresh; a
# reused pid is not `on`; a torn record is logged; and an idle tick does not
# rewrite the record.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use POSIX    ();
use JSON::PP ();
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                           qw(grant_caps add_account);
use Lazysite::Daemon::Supervisor         ();
use Lazysite::Daemon::Service::Scheduler ();

sub site {
    my $t = tempdir( CLEANUP => 1 );
    mkdir "$t/site";
    my $d = "$t/site/public_html";
    mkdir $d;
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: t\nplugins:\n  - plugins/daemon.pl\n";
    close $c;
    open my $dc, '>', "$d/lazysite/daemon.conf" or die $!;
    print {$dc} "daemon_restart_backoff: 1\ndaemon_tick_seconds: 60\n";
    close $dc;
    return ( $t, $d );
}

my $LIVES = {
    name  => 'lives',
    start => sub {
        my $go = 1;
        local $SIG{TERM} = sub { $go = 0 };
        while ($go) { sleep 1 }
        return 0;
    },
};

sub start_supervisor {
    my ( $t, $d, $tag ) = @_;
    my $log = "$t/supervisor-$tag.log";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ( $pid == 0 ) {
        no warnings 'redefine';
        *Lazysite::Daemon::Supervisor::services = sub { return ($LIVES) };
        open STDERR, '>', $log or die $!;
        exit Lazysite::Daemon::Supervisor::run( docroot => $d );
    }
    return ( $pid, $log );
}

sub slurp { open my $fh, '<', $_[0] or return ''; local $/; my $s = <$fh>; close $fh; return $s }

sub child_pid {
    my ($d) = @_;
    my $p = slurp("$d/lazysite/daemon/lives.pid");
    chomp $p;
    return $p;
}

subtest 'a second supervisor on the same docroot is refused' => sub {
    my ( $t,  $d )  = site();
    my ( $p1, $l1 ) = start_supervisor( $t, $d, 'first' );
    sleep 2;
    my $child1 = child_pid($d);
    ok( $child1 && kill( 0, $child1 ), 'the first supervisor has its service running' );

    my ( $p2, $l2 ) = start_supervisor( $t, $d, 'second' );

    # Bounded: against the pre-fix code the second supervisor never exits, and a
    # test that hangs is a test that reports nothing.
    my $exited = 0;
    for ( 1 .. 50 ) {
        if ( waitpid( $p2, POSIX::WNOHANG() ) > 0 ) { $exited = 1; last }
        select( undef, undef, undef, 0.2 );
    }
    ok( $exited, 'the second exits within 10 s' ) or kill 'KILL', $p2;
    is( $? >> 8, 3, 'with exit 3' ) if $exited;
    like( slurp($l2), qr/another supervisor holds the lock/, 'and says why' );
    is( child_pid($d), $child1, 'the first\'s service is untouched and still the one on record' );

    kill 'TERM', $p1;
    waitpid $p1, 0;
    ok( !kill( 0, $child1 ), 'clean stop still stops the service' );
};

subtest 'an orphan the new supervisor can prove is its predecessor\'s is stopped, not duplicated' => sub {
    my ( $t,  $d )  = site();
    my ( $p1, $l1 ) = start_supervisor( $t, $d, 'first' );
    sleep 2;
    my $orphan = child_pid($d);
    kill 'KILL', $p1;
    waitpid $p1, 0;
    sleep 1;
    ok( kill( 0, $orphan ), 'after kill -9 of the supervisor the service is an orphan, still running' );

    my ( $p2, $l2 ) = start_supervisor( $t, $d, 'second' );
    sleep 3;
    ok( !kill( 0, $orphan ), 'the second supervisor stopped the orphan' );
    like( slurp($l2), qr/stopping an orphaned service/, 'and logged that it did' );
    my $fresh = child_pid($d);
    ok( $fresh && $fresh != $orphan && kill( 0, $fresh ), 'and runs one fresh service of its own' );

    kill 'TERM', $p2;
    waitpid $p2, 0;
    ok( !kill( 0, $fresh ), 'which stops with it' );
};

subtest 'a reused pid is not a running service' => sub {
    my ( $t, $d ) = site();
    mkdir "$d/lazysite/daemon";

    # Experiment 8's exact move: our own pid in the pid file. With no state
    # (no start-time proof) the fallback is the pid alone, as before...
    open my $fh, '>', "$d/lazysite/daemon/scheduler.pid" or die $!;
    print {$fh} "$$\n";
    close $fh;
    my $st = Lazysite::Daemon::Supervisor::status($d);
    is( $st->{services}[0]{verdict}, 'on',
        'with no recorded start time the pid alone still counts (nothing better exists)' );

    # ...but a supervisor always records one, and then the pid must match it.
    open my $sf, '>', "$d/lazysite/daemon/scheduler.state.json" or die $!;
    print {$sf} JSON::PP::encode_json( { fails => 0, started => time, start_ticks => '1' } );
    close $sf;
    $st = Lazysite::Daemon::Supervisor::status($d);
    isnt( $st->{services}[0]{verdict}, 'on',
        'a live pid whose start time is not the recorded one is NOT on' );
    is( $st->{services}[0]{verdict}, 'inconsistent',
        'it reads as not started, which is what a stale record means' );
};

subtest 'a torn run record is logged, and an idle tick leaves the record alone' => sub {
    my ( $t, $d ) = site();
    mkdir "$d/lazysite/daemon";
    add_account( $d, 'jobs' );
    grant_caps( $d, 'jobs', qw(run_jobs analytics manage_users) );
    open my $c, '>', "$d/lazysite/daemon.conf" or die $!;
    print {$c} "daemon_job_user: jobs\n";
    close $c;

    my $log = "$t/tick.log";
    my $rec = "$d/lazysite/daemon/scheduler-runs.json";

    # first tick: everything runs (or is refused) and the record is written
    {
        open my $save, '>&', \*STDERR or die $!;
        open STDERR,   '>',  $log     or die $!;
        Lazysite::Daemon::Service::Scheduler::tick( docroot => $d );
        open STDERR, '>&', $save or die $!;
    }
    ok( -f $rec, 'the record exists after a tick with work' );
    my $mt = ( stat $rec )[9];
    utime $mt - 100, $mt - 100, $rec;

    # second tick, nothing due
    my $done = Lazysite::Daemon::Service::Scheduler::tick( docroot => $d );
    is( scalar @$done,    0,         'nothing due on the second tick' );
    is( ( stat $rec )[9], $mt - 100, 'and the record was not rewritten' );

    # corrupt it
    open my $g, '>', $rec or die $!;
    print {$g} "\x00\xffnot json";
    close $g;
    {
        open my $save, '>&', \*STDERR or die $!;
        open STDERR,   '>>', $log     or die $!;
        $done = Lazysite::Daemon::Service::Scheduler::tick( docroot => $d );
        open STDERR, '>&', $save or die $!;
    }
    ok( scalar @$done >= 1, 'a torn record makes jobs due again (the safe direction)' );
    like( slurp($log), qr/run record is unreadable/, 'and the WARN says so, once' );
    is( scalar( () = slurp($log) =~ /run record is unreadable/g ), 1, 'exactly once' );
};

done_testing();
