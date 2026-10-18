package Lazysite::Daemon::Service::Oomd;

# SM1164 D2: oomd, THE RESIDENT OOM, AS A SERVICE UNDER lazysited.
#
# Lazysite::Daemon::Service::Scheduler is the model (a closed service, started
# by the supervisor, reporting through Lazysite::Lifecycle); this one differs in
# that it supervises a PROGRAM, not code of ours, so it is a thin parent over
# `oomd --name <site> --config <conf> --foreground`:
#
#   * it runs while the daemon extension AND the Odoo extension are enabled,
#     `odoo_daemon` is `on` or `required`, and oomd is installed. `wanted()` is
#     the one place that says so, and the supervisor asks it; with any of the
#     four missing NO PROCESS EXISTS and every call takes the in-process path.
#     (A long-lived credentialed process must not be started and then told to
#     refuse work: SM222/SM666.)
#   * it waits for `oomd <name> ready <socket>` before the supervisor sees it
#     healthy; SIGTERM stops oomd (it finishes the requests in hand, deadline
#     30 s, removes its socket); SIGHUP is passed on (reload the config and the
#     packs, keeping the socket);
#   * a crash is the supervisor's: this process exits and the supervisor's
#     backoff and `failed` ceiling apply as they do for the scheduler;
#   * it restarts oomd when the health verb's OOM version is not the installed
#     one (an upgrade of the package), once per installed version, and when
#     the packs oomd reads from its environment (odoo_packs) have changed.
#
# THE RUN USER. Nothing here chooses one: lazysited runs as the unix user the
# request path writes as (SM760), so oomd's socket, pid record, log and cache
# - all owner-only - belong to the user the CGI connects as. On a plain-CGI site
# that is www-data, shared with every other plain-CGI site; oomd closes a peer of
# another uid but cannot keep two sites of one uid apart (OOM's answer to Q1).
# Sites that must be apart run on the pool, each as its own user.
use strict;
use warnings;
use POSIX ();
use IO::Handle;
use IO::Select;
use Time::HiRes     ();
use File::Path      qw(make_path);
use Lazysite::Util  qw(log_event);
use Lazysite::Paths ();

our $VERSION = '0.1';

# The program. Production is the deb's /usr/bin/oomd; a test points this at the
# vendored front door (t/vendor/oom/bin/oomd, run by the test's own perl) and
# never at the host (SM1081, t/lint/262).
our $COMMAND = ['/usr/bin/oomd'];

# A test replaces these.
our $HEALTH_EVERY = 60;    # seconds between asking the health verb
our $READY_WAIT   = 30;    # seconds oomd has to say it is ready
our $STOP_WAIT    = 30;    # oomd's own shutdown deadline
our $INSTALLED_VERSION;    # coderef: the installed OOM version (a test's)

sub installed {
    my @c = @{$COMMAND};
    return 0 unless @c && defined $c[0] && -x $c[0];
    return 0 if @c > 1 && !-r $c[-1];
    return 1;
}

# The gate. All of: the Odoo extension enabled, a connection that loads,
# `odoo_daemon` on or required, oomd installed. (The daemon extension itself is
# the supervisor's own gate, should_run.) Reads only; cheap enough to ask every
# few seconds.
sub wanted {
    my ($root) = @_;
    return 0 unless installed();
    require Lazysite::Odoo;
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT = $root;
    return 0 unless Lazysite::Odoo::_extension_enabled();
    my ($c) = Lazysite::Odoo::connection();
    return 0 unless $c && $c->{daemon} ne 'off';
    return 1;
}

# The last line oomd said on stderr: why it would not start or why it stopped.
# This is what Status shows beside `failed`.
sub failure_reason {
    my ($root) = @_;
    require Lazysite::Odoo::Daemon;
    my $f = Lazysite::Odoo::Daemon::err_file($root);
    open my $fh, '<', $f or return 'oomd left no reason (see the site log)';
    my $last;
    while ( my $l = <$fh> ) { chomp $l; $last = $l if $l =~ /\S/ }
    close $fh;
    return defined $last ? $last : 'oomd left no reason (see the site log)';
}

sub installed_version {
    return $INSTALLED_VERSION->() if $INSTALLED_VERSION;
    # Odoo::Ops::Version holds only $VERSION. It is read afresh: a package
    # upgraded under a running service must be seen.
    local $@;
    delete $INC{'Odoo/Ops/Version.pm'};
    no warnings 'redefine';
    return eval { require Odoo::Ops::Version; $Odoo::Ops::Version::VERSION };
}

# What oomd reads from its environment rather than its config. A change is a
# restart, not a SIGHUP.
sub _env_signature {
    my ($root) = @_;
    require Lazysite::Odoo;
    no warnings 'once';
    local $Lazysite::Odoo::DOCROOT = $root;
    my ($c) = Lazysite::Odoo::connection();
    return $c ? join( ',', @{ $c->{packs} || [] } ) : '';
}

sub _start {
    my ( $root, $name, $conf, $sig ) = @_;
    require Lazysite::Odoo::Daemon;
    my ($sock) = Lazysite::Odoo::Daemon::socket_for($root);
    ( my $dir = $sock ) =~ s{/[^/]+\z}{};
    my $um = umask 077;
    make_path( $dir, { mode => 0700 } );
    umask $um;
    chmod 0700, $dir;

    pipe( my $r, my $w ) or return;
    my $err = Lazysite::Odoo::Daemon::err_file($root);
    my $pid = fork();
    return unless defined $pid;
    if ( $pid == 0 ) {
        close $r;
        open STDOUT, '>&', $w;
        $um = umask 077;
        open STDERR, '>', $err;
        umask $um;
        $ENV{ODOO_OPS_NAMESPACES} = $sig;
        exec( @{$COMMAND}, '--name', $name, '--config', $conf, '--foreground' )
            or do { print STDERR "cannot run $COMMAND->[0]: $!\n"; POSIX::_exit(127) };
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
            return 0 if defined $n && $n == 0;    # closed: oomd is gone
        }
        return 1 if $buf =~ /^oomd \S+ ready \S+$/m;
        return 0 if waitpid( $pid, POSIX::WNOHANG() ) == $pid;
    }
    return 0;
}

sub _stop {
    my ($pid) = @_;
    kill 'TERM', $pid;
    my $until = Time::HiRes::time() + $STOP_WAIT + 5;
    while ( Time::HiRes::time() < $until ) {
        return 1 if waitpid( $pid, POSIX::WNOHANG() ) == $pid || !kill( 0, $pid );
        Time::HiRes::sleep(0.1);
    }
    kill 'KILL', $pid;
    waitpid( $pid, 0 );
    return 0;
}

# An oomd of this socket left by a supervisor that died without stopping its
# children still answers on it, and a second daemon with the name is refused.
# It is the socket we would use, in a directory only we can enter, so it is
# ours: told to stop, and waited for.
sub _clear_stale {
    my ( $root, $sock ) = @_;
    my $h = eval {
        require Odoo::Ops::Daemon::Path;
        Odoo::Ops::Daemon::Path->health( socket => $sock, timeout => 3 );
    };
    return unless ref $h eq 'HASH' && $h->{pid} && $h->{pid} =~ /\A\d+\z/;
    log_event( 'WARN', 'oomd', 'stopping an oomd left by an earlier supervisor', pid => $h->{pid} );
    kill 'TERM', $h->{pid};
    for ( 1 .. 100 ) { last unless kill( 0, $h->{pid} ); Time::HiRes::sleep(0.1) }
    return;
}

sub run {
    my (%a) = @_;
    my $root = $a{docroot};
    my ( $term, $hup ) = ( 0, 0 );

    # Before anything else: a SIGHUP that arrives while oomd is starting is a
    # request to reload, not to die.
    local $SIG{TERM} = sub { $term = 1 };
    local $SIG{INT}  = sub { $term = 1 };
    local $SIG{HUP}  = sub { $hup  = 1 };

    require Lazysite::Odoo::Daemon;
    my $dir = Lazysite::Odoo::Daemon::run_dir($root);
    my $um  = umask 077;
    make_path( $dir, { mode => 0700 } );
    make_path( Lazysite::Odoo::Daemon::runs_dir($root) );
    umask $um;

    # The conf is written from the config as it is NOW: a service that started
    # on a conf from before a key was set would refuse that key's label.
    my $w = Lazysite::Odoo::Daemon::write_conf($root);
    unless ( $w->{ok} && !$w->{removed} ) {
        log_event( 'ERROR', 'oomd', 'no oomd config', reason => $w->{error} // 'odoo_daemon is off' );
        _note_error( $root, $w->{error} // 'odoo_daemon is off' );
        return 1;
    }
    my $name = Lazysite::Odoo::Daemon::name($root);
    my ($sock) = Lazysite::Odoo::Daemon::socket_for($root);
    _clear_stale( $root, $sock );

    my $sig = _env_signature($root);
    my ( $pid, $r ) = _start( $root, $name, $w->{path}, $sig );
    unless ($pid) { log_event( 'ERROR', 'oomd', 'could not start oomd' ); return 1 }
    unless ( _wait_ready( $pid, $r, sub { $term } ) ) {
        if ($term) { _stop($pid); return 0 }
        _stop($pid);
        log_event( 'ERROR', 'oomd', 'oomd did not say it was ready', reason => failure_reason($root) );
        return 1;
    }
    log_event( 'INFO', 'oomd', 'oomd ready', name => $name );

    my %restarted_for;
    my $next_health = time + $HEALTH_EVERY;
    while ( !$term ) {
        my $buf;
        1 while sysread( $r, $buf, 4096 ); # the pipe is drained and never read: a full one would stop oomd
        if ( waitpid( $pid, POSIX::WNOHANG() ) == $pid ) {
            log_event( 'WARN', 'oomd', 'oomd exited', reason => failure_reason($root) );
            return 1;
        }
        my $restart = 0;
        if ($hup) {
            $hup = 0;
            my $now = _env_signature($root);
            if ( $now ne $sig ) { $restart = 1 }
            else {
                kill 'HUP', $pid;
                log_event( 'INFO', 'oomd', 'oomd told to reload' );
            }
        }
        if ( !$restart && time >= $next_health ) {
            $next_health = time + $HEALTH_EVERY;
            my $h = eval {
                require Odoo::Ops::Daemon::Path;
                Odoo::Ops::Daemon::Path->health( socket => $sock, timeout => 5 );
            };
            my $have = installed_version();
            if ( ref $h eq 'HASH' && defined $have && defined $h->{version} && $h->{version} ne $have
                && !$restarted_for{$have}++ )
            {
                log_event( 'INFO', 'oomd', 'oomd restarted for a new OOM version', running => $h->{version}, installed => $have );
                $restart = 1;
            }
        }
        if ($restart) {
            _stop($pid);
            Lazysite::Odoo::Daemon::write_conf($root);
            $sig = _env_signature($root);
            ( $pid, $r ) = _start( $root, $name, $w->{path}, $sig );
            return 1 unless $pid;
            unless ( _wait_ready( $pid, $r, sub { $term } ) ) {
                _stop($pid);
                return $term ? 0 : 1;
            }
        }
        Time::HiRes::sleep(0.2);
    }
    _stop($pid);
    log_event( 'INFO', 'oomd', 'oomd stopped' );
    return 0;
}

sub _note_error {
    my ( $root, $msg ) = @_;
    require Lazysite::Odoo::Daemon;
    my $um = umask 077;
    if ( open my $fh, '>', Lazysite::Odoo::Daemon::err_file($root) ) { print {$fh} "$msg\n"; close $fh }
    umask $um;
    return;
}

1;
