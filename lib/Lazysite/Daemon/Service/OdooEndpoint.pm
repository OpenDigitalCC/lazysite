package Lazysite::Daemon::Service::OdooEndpoint;

# SM1226: THE ODOO ENDPOINT'S WARM-FORK PARENT, AS A SERVICE UNDER lazysited.
#
# A thin parent over the program Lazysite::WarmFork is, as
# Lazysite::Daemon::Service::Oomd is over oomd:
#
#   * it runs while the daemon extension (the supervisor's own gate) AND the Odoo
#     extension are enabled, the site runs behind a pool (the only front end that
#     hands the parent a call) and the endpoint and a socket path are found. wanted()
#     is the one place that says so; with any missing NO PROCESS EXISTS and the
#     pool's front door runs the endpoint as a CGI, as before.
#   * the program starts in a FRESH perl (exec), never as a fork of the
#     supervisor, so what the parent holds is exactly what it loaded: code
#     (t/lint/272), never the supervisor's configuration reads;
#   * it waits for `lazysite-warm-fork ready <socket>`; SIGTERM is passed on and
#     waited for; a crash is the supervisor's (this exits non-zero, and the backoff
#     and `failed` ceiling apply as for the scheduler and oomd);
#   * RESTARTED ON UPGRADE: the program exits 75 when a file it loaded has changed
#     on disk (an upgrade of the engine), and this starts a new one at once, which
#     is not counted as a failure.
#
# THE RUN USER is whatever lazysited runs as (SM760): the request path's user, the
# user the pool's workers run as, who are the program's only clients through the
# 0700 run directory.
use strict;
use warnings;
use POSIX ();
use IO::Handle;
use IO::Select;
use Time::HiRes              ();
use File::Basename           ();
use File::Path               qw(make_path);
use Lazysite::Util           qw(log_event);
use Lazysite::Paths          ();
use Lazysite::WarmFork::Wire ();

our $VERSION = '0.1';

# A test replaces these.
our $SCRIPT;             # the endpoint; else found (script_for)
our $READY_WAIT = 30;    # seconds the program has to say it is ready
our $STOP_WAIT  = 10;
our @PROGRAM_ARGS;    # more arguments for the program (a test's --check-every, --settle)

# The endpoint the web server would run: the site's cgi-bin beside the docroot
# (every shipped layout), else the engine tree this module was loaded from (a
# source tree, the deb's /usr/share/lazysite). undef when neither has it.
sub script_for {
    my ($root) = @_;
    return $SCRIPT if defined $SCRIPT;
    my @c = ("$root/../cgi-bin/lazysite-odoo.pl");
    if ( my $me = $INC{'Lazysite/Daemon/Service/OdooEndpoint.pm'} ) {
        my $engine = File::Basename::dirname($me) . '/../../../..';
        push @c, "$engine/lazysite-odoo.pl";
    }
    for my $c (@c) {
        next unless -f $c && -r _;
        require Cwd;
        return Cwd::abs_path($c);
    }
    return undef;
}

# The gate. The site runs behind a pool (ruled 2026-10-20: the parent runs only
# where a front end uses it, and every front end that hands it a call does so
# through the pool - Lazysite::Paths::pool_conf_for), the Odoo extension is
# enabled, the endpoint is found, and the socket path fits. A plain-CGI site
# has no pool conf, so no parent. Reads only; asked every few seconds by the
# supervisor.
sub wanted {
    my ($root) = @_;
    return 0 unless defined Lazysite::Paths::pool_conf_for($root);
    require Lazysite::Manager::Plugins;
    no warnings 'once';
    local $Lazysite::Manager::Plugins::DOCROOT = $root;
    return 0 unless Lazysite::Manager::Plugins::plugin_enabled('plugins/odoo.pl');
    return 0 unless defined script_for($root);
    my ($sock) = Lazysite::WarmFork::Wire::socket_for( Lazysite::Paths::lazysite_dir($root) );
    return defined $sock ? 1 : 0;
}

sub _program {
    require Cwd;
    my $wf = Cwd::abs_path( $INC{'Lazysite/WarmFork/Wire.pm'} );
    $wf =~ s{/Wire\.pm\z}{.pm};
    ( my $lib = $wf ) =~ s{/Lazysite/WarmFork\.pm\z}{};
    return ( $lib, $wf );
}

sub _start {
    my ( $root, $script, $sock ) = @_;
    my ( $lib, $prog ) = _program();
    pipe( my $r, my $w ) or return;
    my $pid = fork();
    return unless defined $pid;
    if ( $pid == 0 ) {
        close $r;
        open STDOUT, '>&', $w;
        exec( $^X, '-I', $lib, $prog, '--docroot', $root, '--script', $script, '--socket', $sock, @PROGRAM_ARGS )
            or do { print STDERR "cannot run the warm-fork parent: $!\n"; POSIX::_exit(127) };
    }
    close $w;
    $r->blocking(0);
    return ( $pid, $r );
}

sub _wait_ready {
    my ( $pid, $r, $abort ) = @_;
    my $sel   = IO::Select->new($r);
    my $buf   = '';
    my $until = time + $READY_WAIT;
    while ( time < $until ) {
        return 0 if $abort->();
        if ( $sel->can_read(0.2) ) {
            my $n = sysread( $r, $buf, 4096, length $buf );
            return 0 if defined $n && $n == 0;
        }
        return 1 if $buf =~ /^lazysite-warm-fork ready \S+$/m;
        return 0 if waitpid( $pid, POSIX::WNOHANG() ) == $pid;
    }
    return 0;
}

sub _stop {
    my ($pid) = @_;
    kill 'TERM', $pid;
    my $until = Time::HiRes::time() + $STOP_WAIT;
    while ( Time::HiRes::time() < $until ) {
        return 1 if waitpid( $pid, POSIX::WNOHANG() ) == $pid;
        Time::HiRes::sleep(0.05);
    }
    kill 'KILL', $pid;
    waitpid( $pid, 0 );
    return 0;
}

sub run {
    my (%a)  = @_;
    my $root = $a{docroot};
    my $term = 0;
    local $SIG{TERM} = sub { $term = 1 };
    local $SIG{INT}  = sub { $term = 1 };
    local $SIG{HUP}  = 'IGNORE';    # the children read the config per request

    my $script = script_for($root);
    my ( $sock, $why ) = Lazysite::WarmFork::Wire::socket_for( Lazysite::Paths::lazysite_dir($root) );
    unless ( defined $script && defined $sock ) {
        log_event( 'ERROR', 'warm-fork', 'the Odoo endpoint cannot be warm-forked',
            reason => defined $script ? $why : 'lazysite-odoo.pl is not found' );
        return 1;
    }
    ( my $dir = $sock ) =~ s{/[^/]+\z}{};
    my $um = umask 077;
    make_path( $dir, { mode => 0700 } );
    umask $um;
    chmod 0700, $dir;

    while (1) {
        my ( $pid, $r ) = _start( $root, $script, $sock );
        unless ($pid) { log_event( 'ERROR', 'warm-fork', 'could not start the warm-fork parent' ); return 1 }
        unless ( _wait_ready( $pid, $r, sub { $term } ) ) {
            _stop($pid);
            return 0 if $term;
            log_event( 'ERROR', 'warm-fork', 'the warm-fork parent did not say it was ready' );
            return 1;
        }
        my $code;
        while ( !$term ) {
            my $buf;
            1 while sysread( $r, $buf, 4096 );
            if ( waitpid( $pid, POSIX::WNOHANG() ) == $pid ) { $code = $? >> 8; last }
            Time::HiRes::sleep(0.2);
        }
        if ($term) { _stop($pid); return 0 }
        if ( $code == 75 ) {
            log_event( 'INFO', 'warm-fork', 'the warm-fork parent restarted for a changed engine' );
            next;
        }
        log_event( 'WARN', 'warm-fork', 'the warm-fork parent exited', exit => $code );
        return 1;
    }
}

1;
