#!/usr/bin/perl
# SM755, from the 0.13.1 daemon review (D1 F1.1): the supervisor's restart path.
#
# The plugin's description promises "a service that keeps dying is reported as
# FAILED rather than restarted forever". At 53df9a44 the opposite was measured:
# a service that exited at once was forked again every ~2 s indefinitely, the
# failure count never moved (the reap loop forgot the child before the failure
# branch saw it), the backoff never applied, and status() said `on` while the
# zombie existed. No test ran Supervisor::run with the plugin enabled, which is
# how that shipped.
#
# This file runs the supervisor for real - forked, plugin enabled, with the
# service registry overridden - and holds:
#   - every exit is counted, with its exit status, and the backoff grows
#   - past the ceiling the service is FAILED once, and status() says `failed`
#     with the count, not `on`
#   - while a restart is pending status() says `starting`, not `failed`
#   - a healthy service is started once and stays started
#   - SIGTERM stops the children and removes the pid and state files
#   - disabling the plugin while the daemon runs STOPS it (F1.2): both switches
#     must be on, after start as well as before
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use POSIX ();
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Daemon::Supervisor ();

sub site {
    my $t = tempdir( CLEANUP => 1 );
    mkdir "$t/site";
    my $d = "$t/site/public_html";
    mkdir $d;
    mkdir "$d/lazysite";
    set_enabled( $d, 1 );
    open my $c, '>', "$d/lazysite/daemon.conf" or die $!;
    print {$c} "daemon_restart_backoff: 1\n";
    close $c;
    return ( $t, $d );
}

sub set_enabled {
    my ( $d, $on ) = @_;
    my $tmp = "$d/lazysite/lazysite.conf.tmp";
    open my $c, '>', $tmp or die $!;
    print {$c} "site_name: t\n";
    print {$c} "plugins:\n  - plugins/daemon.pl\n" if $on;
    close $c;
    rename $tmp, "$d/lazysite/lazysite.conf" or die $!;
    return;
}

# Run the supervisor in a child with stderr to a log; return (pid, log path).
sub start_supervisor {
    my ( $t, $d ) = @_;
    my $log = "$t/supervisor.log";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ( $pid == 0 ) {
        open STDERR, '>', $log or die $!;
        exit Lazysite::Daemon::Supervisor::run( docroot => $d );
    }
    return ( $pid, $log );
}

sub count_lines {
    my ( $log, $re ) = @_;
    open my $fh, '<', $log or return 0;
    my $n = grep { /$re/ } <$fh>;
    close $fh;
    return $n;
}

sub with_service {
    my ( $svc, $code ) = @_;
    no warnings 'redefine';
    local *Lazysite::Daemon::Supervisor::services = sub { return ($svc) };
    return $code->();
}

subtest 'a service that dies at once: counted, backed off, FAILED, and status says so' => sub {
    my ( $t, $d ) = site();
    local $Lazysite::Daemon::Supervisor::FAIL_CEILING = 2; # fails 1, 2 retried; 3rd exit = failed

    with_service(
        { name => 'dies', start => sub { POSIX::_exit(3) } },
        sub {
            my ( $pid, $log ) = start_supervisor( $t, $d );

            # backoff base 1: exits at ~0, ~1, ~3 s; FAILED on the loop after the third.
            sleep 8;
            my $st = Lazysite::Daemon::Supervisor::status($d);
            kill 'TERM', $pid;
            waitpid $pid, 0;

            my $started = count_lines( $log, qr/service started/ );
            my $exited  = count_lines( $log, qr/service exited/ );
            my $failed  = count_lines( $log, qr/service failed - not restarting/ );

            is( $exited, 3, 'three exits, three WARN lines - every exit counted' )
                or diag( do { local ( @ARGV, $/ ) = $log; <> } );
            is( $started, 3, 'three starts, not one every two seconds for eight seconds' );
            is( $failed,  1, 'FAILED logged exactly once' );
            like( ( grep { /service exited/ } do { open my $fh, '<', $log; <$fh> } )[0],
                qr/exit=3/, 'the WARN carries the exit status' );
            like( ( grep { /service exited/ } do { open my $fh, '<', $log; <$fh> } )[1],
                qr/retry_in=2/, 'and the second exit doubles the wait' );

            is( $st->{services}[0]{verdict}, 'failed',
                'status: the service is failed - not on, not starting' );
            like( $st->{services}[0]{message}, qr/3 consecutive failures/,
                'with the count in the message' );
            is( $st->{verdict}, 'degraded', 'and the runtime is degraded' );
            like( $st->{remedy}, qr/per-service/, 'pointing at the service verdicts' );
        }
    );
};

subtest 'between exit and retry, status says starting' => sub {
    my ( $t, $d ) = site();
    open my $c, '>', "$d/lazysite/daemon.conf" or die $!;
    print {$c} "daemon_restart_backoff: 30\n"; # one exit, then a long wait we can observe
    close $c;

    with_service(
        { name => 'once', start => sub { POSIX::_exit(0) } },
        sub {
            my ( $pid, $log ) = start_supervisor( $t, $d );
            sleep 3;
            my $st = Lazysite::Daemon::Supervisor::status($d);
            kill 'TERM', $pid;
            waitpid $pid, 0;

            is( $st->{services}[0]{verdict}, 'starting',
                'a restart is pending: starting, which is the contract\'s word for it' );
            like( $st->{services}[0]{message}, qr/restart is due at \d\d:\d\d:\d\d/,
                'and the message says when' );
            ok( !$st->{services}[0]{healthy}, 'not healthy' );
            like( $st->{services}[0]{remedy}, qr/wait/, 'remedy: wait' );
            is( $st->{verdict}, 'starting',
                'and the runtime as a whole says starting, not "enable the unit"' );
            unlike( $st->{remedy} // '', qr/systemctl enable/,
                'the top-level remedy is not the provisioning command' );
        }
    );
};

subtest 'a healthy service is started once and TERM stops everything cleanly' => sub {
    my ( $t, $d ) = site();
    with_service(
        { name => 'lives',
            start => sub {
                my $go = 1;
                local $SIG{TERM} = sub { $go = 0 };
                while ($go) { sleep 1 }
                return 0;
            },
        },
        sub {
            my ( $pid, $log ) = start_supervisor( $t, $d );
            sleep 3;
            my $st    = Lazysite::Daemon::Supervisor::status($d);
            my $child = do {
                open my $fh, '<', "$d/lazysite/daemon/lives.pid" or die $!;
                my $p = <$fh>;
                chomp $p;
                $p;
            };
            is( $st->{services}[0]{verdict}, 'on', 'running: on' );
            is( $st->{verdict},              'on', 'and the runtime is on' );
            ok( kill( 0, $child ), 'the service child is alive' );

            kill 'TERM', $pid;
            waitpid $pid, 0;
            is( count_lines( $log, qr/service started/ ), 1, 'started exactly once' );
            ok( !kill( 0, $child ),                 'the child is gone after TERM' );
            ok( !-e "$d/lazysite/daemon/lives.pid", 'the pid file is removed' );
            ok( !-e "$d/lazysite/daemon/lives.state.json", 'and the state file' );
            is( Lazysite::Daemon::Supervisor::status($d)->{services}[0]{verdict},
                'inconsistent', 'status after a clean stop: enabled, not running' );
        }
    );
};

subtest 'disabling the plugin while it runs stops it - both switches, after start too' => sub {
    my ( $t, $d ) = site();
    local $Lazysite::Daemon::Supervisor::GATE_EVERY = 1;
    with_service(
        { name => 'lives',
            start => sub {
                my $go = 1;
                local $SIG{TERM} = sub { $go = 0 };
                while ($go) { sleep 1 }
                return 0;
            },
        },
        sub {
            my ( $pid, $log ) = start_supervisor( $t, $d );
            sleep 2;
            set_enabled( $d, 0 );
            my $t0 = time;
            my $rc;
            for ( 1 .. 10 ) {
                last if waitpid( $pid, POSIX::WNOHANG() ) > 0;
                sleep 1;
            }
            ok( !kill( 0, $pid ), 'the supervisor exited on its own within 10 s of the plugin being disabled' )
                or kill 'TERM', $pid;
            is( $? >> 8, 0, 'with exit 0, which the unit treats as "disabled, do not restart"' );
            ok( count_lines( $log, qr/plugin has been disabled/ ), 'and said why' );
            ok( !-e "$d/lazysite/daemon/lives.pid", 'its child is stopped and the pid file removed' );
            is( Lazysite::Daemon::Supervisor::status($d)->{verdict}, 'off', 'status: off' );
        }
    );
};

done_testing();
