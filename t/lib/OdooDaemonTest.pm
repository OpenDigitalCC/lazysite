package OdooDaemonTest;

# SM1164: the arrangement the tests of the resident OOM need - a configured
# site with the Odoo and daemon extensions on, the REAL oomd started from the
# vendored snapshot (t/vendor/oom/bin/oomd, SM1081: never the host's) against
# OOM's own fake Odoo (Odoo::Test::CliFake), and a way to stop exactly what the
# test started.
#
# THE ENVIRONMENT, STATED. bin/oomd begins `use lib "$FindBin::RealBin/../lib"`,
# which resolves to t/vendor/oom/lib; that is the only OOM it can load first. The
# daemon's workers also need OOM's test doubles (t/vendor/oom/t/lib), which are not
# beside bin/, so PERL5LIB is set here to the vendored lib, the vendored test lib
# and this repository's lib, and nothing else. Nothing is read from the host.
#
# ISOLATION. XDG_RUNTIME_DIR is a directory of the test's own, so the daemon's
# pid record is not in /tmp/oomd-<uid> where a daemon of the host would be.
use strict;
use warnings;
use File::Path qw(make_path);
use File::Temp ();
use POSIX      ();
use Time::HiRes ();
use OdooTest   qw(vendor_dir oom_lib oom_test_lib set_key write_conf);
use TestHelper ();

use Exporter 'import';
our @EXPORT_OK = qw(oomd_site oomd_env oomd_start oomd_stop oomd_up wait_until);

my @STARTED;    # pids this test started, killed at the end whatever happened

END {
    for my $pid (@STARTED) {
        next unless kill 0, $pid;
        kill 'TERM', $pid;
        for ( 1 .. 100 ) { last unless kill 0, $pid; Time::HiRes::sleep(0.1) }
        kill 'KILL', $pid if kill 0, $pid;
        waitpid $pid, 0;
    }
}

# A configured site: both extensions on, a connection, a key, odoo_daemon on.
# The packs namespace is OOM's own test operations (oomd.pid answers with the
# process that ran it, which is how a test tells the daemon from itself).
sub oomd_site {
    my (%over) = @_;
    my $d = TestHelper::site_tempdir( plugins => 1 );
    make_path("$d/lazysite");
    open my $fh, '>>', "$d/lazysite/lazysite.conf" or die "lazysite.conf: $!";
    print {$fh} "plugins:\n  - plugins/odoo.pl\n  - plugins/daemon.pl\n";
    close $fh;
    write_conf( $d,
        odoo_url          => 'https://odoo.example',
        odoo_db           => 'local16',
        odoo_login        => 'tester',
        odoo_allow_writes => 'true',
        odoo_packs        => 'Odoo::Test::OomdOps',
        odoo_daemon       => 'on',
        odoo_daemon_workers => 2,
        %over );
    set_key($d);
    return $d;
}

# The environment of the daemon and of the test: call once per file, before
# anything starts. Returns the directory that holds the fake Odoo's state.
sub oomd_env {
    my $t = File::Temp::tempdir( CLEANUP => 1 );
    make_path("$t/xdg");
    chmod 0700, "$t/xdg";
    $ENV{XDG_RUNTIME_DIR}        = "$t/xdg";
    $ENV{XDG_STATE_HOME}         = "$t/xdg";
    $ENV{XDG_CACHE_HOME}         = "$t/cache";
    $ENV{PERL5LIB}               = join ':', oom_lib(), oom_test_lib(), TestHelper::repo_root() . '/lib';
    $ENV{OOM_OPS_TEST_TRANSPORT} = 'Odoo::Test::CliFake';
    $ENV{OOM_OPS_TEST_STATE}     = "$t/state.json";
    require Lazysite::Daemon::Service::Oomd;
    no warnings "once";
    $Lazysite::Daemon::Service::Oomd::COMMAND = [ $^X, vendor_dir() . '/bin/oomd' ];
    return $t;
}

# Runs $code->() in a child (what the supervisor does with a service) and
# returns its pid. The test kills it with oomd_stop.
sub oomd_start {
    my ($code) = @_;
    my $pid = fork() // die "fork: $!";
    if ( $pid == 0 ) {
        my $rc = eval { $code->() };
        POSIX::_exit( defined $rc && $rc =~ /\A\d+\z/ ? $rc : 1 );
    }
    push @STARTED, $pid;
    return $pid;
}

# TERM and wait, by the pid we started. Returns the exit status or undef.
sub oomd_stop {
    my ( $pid, $wait ) = @_;
    return undef unless $pid && kill 0, $pid;
    kill 'TERM', $pid;
    my $until = Time::HiRes::time() + ( $wait // 40 );
    while ( Time::HiRes::time() < $until ) {
        my $k = waitpid( $pid, POSIX::WNOHANG() );
        return $? >> 8 if $k == $pid;
        Time::HiRes::sleep(0.1);
    }
    kill 'KILL', $pid;
    waitpid $pid, 0;
    return undef;
}

# Is a daemon answering on the site's socket? Its health, or undef.
sub oomd_up {
    my ($d) = @_;
    require Lazysite::Odoo::Daemon;
    my ($sock) = Lazysite::Odoo::Daemon::socket_for($d);
    require Odoo::Ops::Daemon::Path;
    return eval { Odoo::Ops::Daemon::Path->health( socket => $sock, timeout => 2 ) };
}

sub wait_until {
    my ( $code, $secs ) = @_;
    my $until = Time::HiRes::time() + ( $secs // 20 );
    while ( Time::HiRes::time() < $until ) {
        my $r = $code->();
        return $r if $r;
        Time::HiRes::sleep(0.2);
    }
    return 0;
}

1;
