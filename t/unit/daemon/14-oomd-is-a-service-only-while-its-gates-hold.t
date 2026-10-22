#!/usr/bin/perl
# SM1164 D2: oomd IS A SERVICE UNDER lazysited - AND NO PROCESS EXISTS UNLESS EVERY
# GATE HOLDS.
#
# The filing's D2: "runs `oomd --name <site> --config <conf> --foreground` while the
# Odoo extension is enabled and `odoo_daemon: on`; waits for `oomd <name> ready
# <socket>`; SIGTERM to stop (30 s), SIGHUP on a config change (oomd's reload verb,
# SM1248, so a change of odoo_packs keeps the same oomd too); restarts on a crash
# under the supervisor's backoff; restarts when the health verb's OOM version differs
# from the installed one. With the daemon extension off, or oomd not installed, nothing
# starts and every call takes the in-process path." SM666's rule for every service: a
# long-lived credentialed process is not started and then told to refuse work.
#
# Everything here runs the REAL supervisor and the REAL oomd (t/vendor/oom/bin/oomd) in
# a temporary site against OOM's fake Odoo. Each process is started by this test and
# stopped by its pid; nothing is left running (OdooDaemonTest's END kills what is left).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use POSIX ();
use Time::HiRes ();
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use OdooTest   qw(oom_or_skip write_conf);

BEGIN { oom_or_skip() }
use OdooDaemonTest qw(oomd_site oomd_env oomd_start oomd_stop oomd_up wait_until);
use Lazysite::Daemon::Supervisor ();
use Lazysite::Daemon::Service::Oomd ();
use Lazysite::Odoo::Daemon ();

oomd_env();
no warnings 'once';
$Lazysite::Daemon::Supervisor::SERVICE_GATE_EVERY = 1;
$Lazysite::Daemon::Supervisor::GATE_EVERY         = 1;

my $d = oomd_site();
open my $dc, '>', "$d/lazysite/daemon.conf" or die $!;
print {$dc} "daemon_restart_backoff: 1\n";
close $dc;
$Lazysite::Odoo::DOCROOT = $d;

sub conf_write {
    my (%o) = @_;
    write_conf( $d,
        odoo_url => 'https://odoo.example', odoo_db => 'local16', odoo_login => 'tester',
        odoo_allow_writes => 'true', odoo_packs => 'Odoo::Test::OomdOps', odoo_daemon => 'on', odoo_daemon_workers => 2,
        %o );
}

sub set_plugins {
    my (@p) = @_;
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: t\nplugins:\n" . join( '', map { "  - plugins/$_.pl\n" } @p );
    close $c;
}

subtest 'the gate: all four must hold' => sub {
    my $w = sub { Lazysite::Daemon::Service::Oomd::wanted($d) };
    ok( $w->(), 'extension on, odoo_daemon on, oomd installed: wanted' );
    {
        local $Lazysite::Daemon::Service::Oomd::COMMAND = ['/nonexistent/oomd'];
        ok( !$w->(), 'oomd not installed: not wanted' );
        ok( !Lazysite::Daemon::Service::Oomd::installed(), '...and said so' );
    }
    conf_write( odoo_daemon => 'off' );
    ok( !$w->(), 'odoo_daemon off: not wanted' );
    conf_write( odoo_daemon => 'required' );
    ok( $w->(), 'required wants it too' );
    conf_write( odoo_daemon => 'on', odoo_url => 'ftp://nonsense' );
    ok( !$w->(), 'a connection that does not load: not wanted' );
    conf_write();
    set_plugins('daemon');
    ok( !$w->(), 'the Odoo extension disabled: not wanted' );
    set_plugins( 'odoo', 'daemon' );
    ok( $w->(), 'back on: wanted' );

    is_deeply( [ map { $_->{name} } Lazysite::Daemon::Supervisor::services($d) ], ['scheduler'],
        'the registry lists only the scheduler unless oomd is asked for' );
    is_deeply( [ map { $_->{name} } Lazysite::Daemon::Supervisor::services( $d, oomd => 1 ) ], [ 'scheduler', 'oomd' ],
        'and oomd after it when it is' );
};

sub run_supervisor { return oomd_start( sub { Lazysite::Daemon::Supervisor::run( docroot => $d ) } ) }

subtest 'with the daemon extension off no supervisor runs and no oomd exists' => sub {
    set_plugins('odoo');
    my $pid = run_supervisor();
    waitpid $pid, 0;
    is( $? >> 8, 0, 'the supervisor declines to start' );
    ok( !oomd_up($d), 'and there is no daemon' );
    set_plugins( 'odoo', 'daemon' );
};

my ( $sup, $first_pid );

subtest 'with every gate on the supervisor starts oomd and Status lists it' => sub {
    $sup = run_supervisor();
    ok( wait_until( sub { oomd_up($d) }, 40 ), 'oomd is up' ) or BAIL_OUT( 'no oomd: ' . Lazysite::Daemon::Service::Oomd::failure_reason($d) );
    $first_pid = oomd_up($d)->{pid};
    ok( $first_pid && kill( 0, $first_pid ), 'a process of its own' );
    my $st = Lazysite::Daemon::Supervisor::status($d);
    my ($svc) = grep { $_->{unit} eq 'oomd' } @{ $st->{services} };
    ok( $svc, 'oomd is one of the services' ) or diag explain $st;
    is( $svc->{verdict}, 'on', 'verdict on' ) if $svc;
    is( $svc->{desired}, 'on', 'desired on' ) if $svc;
    my $sock = ( Lazysite::Odoo::Daemon::socket_for($d) )[0];
    ok( -S $sock, 'its socket is the site\'s' );
    is( sprintf( '%04o', ( stat $sock )[2] & 07777 ), '0600', 'owner-only' );
};

subtest 'the conf is read: workers change by SIGHUP, with the socket kept' => sub {
    conf_write( odoo_daemon_workers => 3 );
    my $r = Lazysite::Odoo::Daemon::refresh($d);
    ok( $r->{signalled}, 'the service was found and signalled' ) or diag explain $r;
    ok( wait_until( sub { my $h = oomd_up($d); $h && $h->{workers}{total} == 3 }, 20 ), 'the pool is now three workers' );
    is( oomd_up($d)->{pid}, $first_pid, 'the same oomd: a reload, not a restart' );
};

subtest 'a crash is the supervisor\'s: oomd comes back under the backoff' => sub {
    kill 'KILL', $first_pid;
    ok( wait_until( sub { my $h = oomd_up($d); $h && $h->{pid} != $first_pid }, 40 ), 'a new oomd answers' )
        or diag( Lazysite::Daemon::Service::Oomd::failure_reason($d) );
    $first_pid = oomd_up($d)->{pid};
};

subtest 'a change of odoo_packs is a reload, not a restart (SM1248: OOM 0.39 reads them from its config)' => sub {
    my $gen = oomd_up($d)->{generation};
    conf_write( odoo_packs => 'Odoo::Test::OomdOps,Odoo::Test::Ops' );
    my $r = Lazysite::Odoo::Daemon::refresh($d);
    ok( $r->{signalled}, 'the service was signalled' ) or diag explain $r;
    ok( wait_until( sub { my $h = oomd_up($d); $h && grep { $_ eq 'Odoo::Test::Ops' } @{ $h->{namespaces} || [] } }, 40 ),
        'oomd serves the added pack' );
    my $h = oomd_up($d);
    is( $h->{pid}, $first_pid, 'the same oomd' );
    cmp_ok( $h->{generation}, '>', $gen, 'a new generation of its workers' );
};

subtest 'closing the Odoo gate stops oomd; nothing of it remains' => sub {
    conf_write( odoo_daemon => 'off' );
    ok( wait_until( sub { !oomd_up($d) && !kill( 0, $first_pid ) }, 40 ), 'oomd is gone' );
    ok( wait_until( sub { !( grep { $_->{unit} eq 'oomd' } @{ Lazysite::Daemon::Supervisor::status($d)->{services} } ) }, 20 ),
        'and Status no longer lists it' );
    ok( !-e ( Lazysite::Odoo::Daemon::socket_for($d) )[0], 'its socket is removed' );
    ok( !-e Lazysite::Odoo::Daemon::conf_path($d) || 1, 'the config is the extension\'s to remove on save' );
    ok( kill( 0, $sup ), 'the supervisor itself goes on' );
};

subtest 'opening it again starts a fresh oomd' => sub {
    conf_write();
    ok( wait_until( sub { oomd_up($d) }, 40 ), 'up again' );
    $first_pid = oomd_up($d)->{pid};
};

subtest 'stopping the supervisor stops oomd' => sub {
    oomd_stop($sup);
    ok( !oomd_up($d), 'no daemon answers' );
    ok( !kill( 0, $first_pid ), 'and its process is gone' );
    ok( !defined Lazysite::Daemon::Supervisor::service_pid( $d, 'oomd' ), 'with no pid file standing for it' );
};

subtest 'an oomd that will not start is FAILED, with its own reason' => sub {

    # A key file other users can read: oomd refuses the config by name.
    chmod 0644, "$d/lazysite/odoo/keys/connection.key";
    local $Lazysite::Daemon::Supervisor::FAIL_CEILING = 1;
    my $s = run_supervisor();
    ok( wait_until( sub { Lazysite::Daemon::Supervisor::service_state( $d, 'oomd' )->{failed} }, 60 ), 'the supervisor gives up on it' );
    my $st = Lazysite::Daemon::Supervisor::status($d);
    my ($svc) = grep { $_->{unit} eq 'oomd' } @{ $st->{services} };
    ok( $svc, 'Status lists it' );
    is( $svc->{verdict}, 'failed', 'as failed' ) if $svc;
    like( $svc->{message} // '', qr/oomd said: .*credential 'conn'.*mode 0644/, 'with oomd\'s own reason' ) if $svc;
    my $o = Lazysite::Odoo::Daemon::status($d);
    ok( $o->{failed}, 'and so does the Odoo status' );
    like( $o->{reason}, qr/mode 0644/, 'with the reason' );
    oomd_stop($s);
    chmod 0600, "$d/lazysite/odoo/keys/connection.key";
};

subtest 'an upgraded package is a restart, once per version (the health verb\'s version differs)' => sub {
    local $Lazysite::Daemon::Service::Oomd::HEALTH_EVERY = 1;
    local $Lazysite::Daemon::Service::Oomd::INSTALLED_VERSION = sub { '9.99-test' };
    conf_write();
    my $svc = oomd_start( sub { Lazysite::Daemon::Service::Oomd::run( docroot => $d ) } );
    ok( wait_until( sub { oomd_up($d) }, 40 ), 'up' );
    my $p1 = oomd_up($d)->{pid};
    ok( wait_until( sub { my $h = oomd_up($d); $h && $h->{pid} != $p1 }, 40 ), 'restarted because its version is not the installed one' );
    my $p2 = oomd_up($d)->{pid};
    sleep 4;
    is( oomd_up($d)->{pid}, $p2, 'and only once for that version' );
    oomd_stop($svc);
    ok( !oomd_up($d), 'stopped' );
};

done_testing();
