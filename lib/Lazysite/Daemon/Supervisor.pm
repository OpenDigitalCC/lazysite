package Lazysite::Daemon::Supervisor;

# SM666 phase 1: the supervisor.
#
# Its own job is small and boring on purpose - start, hold state, supervise
# services, report status, stop cleanly. It owns no protocol, and in phase 1 it
# owns no socket either.
#
# THE THREE PROPERTIES THIS FILE EXISTS TO HOLD:
#
# 1. DISABLED MEANS NO PROCESS. should_run() reads the daemon plugin's enabled
#    state and the entry point refuses to start when it is off. A CGI plugin
#    enforces "off" at dispatch because a request arrives to refuse; a daemon
#    has no dispatch, so the enforcement is that nothing is ever started.
#
# 2. ONE CHILD PER SERVICE. A service crashing must not take the others down,
#    and a wedged one must be restartable alone. SM142/SM139's per-site pool is
#    the local precedent. It also makes SM222's desired-versus-runtime split
#    fall out rather than need building: desired is what the configuration
#    says, runtime is whether the child is alive.
#
# 3. A FLAPPING CHILD IS FAILED, NOT RUNNING. Backoff doubles, and past the
#    ceiling the service reports `failed`. Reporting a service that dies every
#    two seconds as healthy would rebuild inside the daemon the exact
#    dishonesty SM222 was filed about.
#
# SM222 DEBT: PAID. The lifecycle verbs here were local, taken deliberately so
# phase 1 did not wait for the shared contract and written down as owed. The
# contract is Lazysite::Lifecycle now, and this is its first conforming
# consumer - so `up`/`down` are `on`/`off`, and the crash-loop verdict is the
# contract's `failed` rather than a word only this file understood.
#
# The distinction the debt note drew held: the VOCABULARY was temporary and has
# been replaced; the guarantee in property 1 was not, and is unchanged.
use strict;
use warnings;
use POSIX               ();
use Lazysite::Util      qw(log_event);
use Lazysite::Lifecycle qw(lifecycle_status);

our $VERSION = '0.1';

# The plugin script whose enabled state gates this runtime. One name, stated
# once - a second spelling of it somewhere else is how "disabled" drifts back
# into being a display state.
our $PLUGIN = 'daemon.pl';

# Injectable for tests, and for the entry point which knows its own root.
our $DOCROOT;

sub _docroot {
    my ($explicit) = @_;
    return $explicit if defined $explicit && length $explicit;
    return $DOCROOT  if defined $DOCROOT  && length $DOCROOT;
    return $ENV{LAZYSITE_DOCROOT} // $ENV{DOCUMENT_ROOT} // '';
}

# --- the gate ------------------------------------------------------------

# Does the runtime have permission to exist at all?
#
# Returns 1 when the daemon plugin is enabled, 0 otherwise. The caller must
# treat 0 as "do not start", never as "start and refuse work" - the second is
# what SM222 documents as today's behaviour for services and is precisely what
# a long-lived credentialed process must not do.
sub should_run {
    my ($docroot) = @_;
    my $root = _docroot($docroot);
    return 0 unless length $root;

    require Lazysite::Manager::Plugins;

    # `no warnings 'once'` because the module is REQUIRED at runtime, so its
    # `our $DOCROOT` is not visible when this file is compiled and Perl reads
    # the assignment as a possible typo. The variable is real - Plugins.pm
    # declares it and _lz() resolves the engine tree from it - and it is
    # localised rather than set so that nothing else in the process inherits
    # this docroot.
    no warnings 'once';
    local $Lazysite::Manager::Plugins::DOCROOT = $root;
    return Lazysite::Manager::Plugins::plugin_enabled($PLUGIN) ? 1 : 0;
}

# --- the service registry ------------------------------------------------

# Phase 1 has one service. The registry is a list rather than a discovery
# mechanism because a service is engine code - the same rule as a job. A
# service that could be declared by configuration would be a way to run code on
# a timer by editing a file.
#
# The service's entry point is a CODEREF, not a module name to be loaded from a
# string. perlcritic objects to `require "$name.pm"` and is right to: a
# stringy require is how a name from somewhere else becomes a file to execute.
# Here the set is closed anyway, so there is nothing to gain from dynamic
# loading - naming the package as a bareword says the same thing and cannot be
# fed a name from outside.
#
# It is still loaded LAZILY, inside the coderef, because Scheduler uses this
# module for conf_value: a top-level `use` in both directions is a circular
# dependency at compile time.
sub services {
    return (
        { name => 'scheduler',
            start => sub {
                require Lazysite::Daemon::Service::Scheduler;
                return Lazysite::Daemon::Service::Scheduler::run(@_);
            },
        },
    );
}

# --- state ---------------------------------------------------------------

sub _state_dir {
    my ($docroot) = @_;
    return _docroot($docroot) . '/lazysite/daemon';
}

sub _pid_file {
    my ( $docroot, $name ) = @_;
    return _state_dir($docroot) . "/$name.pid";
}

sub _ensure_state_dir {
    my ($docroot) = @_;
    my $dir = _state_dir($docroot);
    return $dir if -d $dir;
    require File::Path;
    File::Path::make_path($dir);
    return $dir;
}

sub _read_pid {
    my ( $docroot, $name ) = @_;
    my $f = _pid_file( $docroot, $name );
    open my $fh, '<', $f or return undef;
    my $pid = <$fh>;
    close $fh;
    return undef unless defined $pid;
    chomp $pid;
    return $pid =~ /\A\d+\z/ ? $pid + 0 : undef;
}

sub _alive {
    my ($pid) = @_;
    return 0 unless defined $pid && $pid > 0;
    return kill( 0, $pid ) ? 1 : 0;
}

# --- status --------------------------------------------------------------

# SM222's shape, and now SM222's CODE - the debt SM666 recorded is paid here.
#
# This was a local implementation of desired-versus-runtime, taken deliberately
# so phase 1 did not wait for the shared contract, and written down as owed. The
# contract now exists in Lazysite::Lifecycle and the daemon is its first
# conforming consumer, which is the exemplar-first shape ADR 0009 used for
# plugins.
#
# WHAT CHANGED, and it is not only vocabulary. The old `runtime` field mixed two
# questions: `died` and `not-started` are both "not running", but one is a
# failure and the other is a configuration that has not been acted on. The
# contract separates DESIRED from VERDICT, so the disagreement is the reported
# fact rather than something a reader infers from two words.
#
# `up`/`down` become `on`/`off` because the contract says so and one vocabulary
# is the point. `not-started` becomes `inconsistent` - switched on and not
# running, which is precisely what it always meant and now says.
sub status {
    my ($docroot) = @_;
    my $root      = _docroot($docroot);
    my $enabled   = should_run($root) ? 1 : 0;

    my @svc;
    my $any_running = 0;
    my $any_died    = 0;

    for my $s ( services() ) {
        my $pid   = _read_pid( $root, $s->{name} );
        my $alive = _alive($pid);
        $any_running ||= $alive;

        # A recorded pid that is not alive is a service that DIED, which the
        # contract calls `failed` - distinct from one that was never started,
        # because an operator's next move differs.
        my $verdict
            = !$enabled    ? 'off'
            : $alive       ? 'on'
            : defined $pid ? 'failed'
            :                'inconsistent';
        $any_died ||= ( $verdict eq 'failed' );

        push @svc,
            lifecycle_status(
            unit       => $s->{name},
            kind       => 'service',
            desired_on => $enabled,
            running    => $alive,
            verdict    => $verdict,
            ( defined $pid ? ( detail => { pid => $pid } ) : () ),
            ( $verdict eq 'failed'
                ? ( message =>
                        "$s->{name} was started and is no longer running",
                    remedy =>
                        'see the site log; the supervisor restarts a service '
                        . 'until it keeps failing, then reports it failed'
                    )
                : ()
            ),
            ( $verdict eq 'inconsistent'
                ? ( message => "$s->{name} has not been started",
                    remedy =>
                        'the plugin is enabled but the host service is not '
                        . 'running - a host operator instantiates it with '
                        . 'systemctl enable --now lazysited@<domain>'
                    )
                : ()
            ),
            );
    }

    # The runtime's own verdict, over its services. A supervisor with a dead
    # service is not healthy even if the supervisor itself is fine, which is
    # the reading an operator wants and the one a per-process check misses.
    my $whole = lifecycle_status(
        unit       => 'daemon',
        kind       => 'plugin',
        desired_on => $enabled,
        running    => $any_running,
        ( $any_died ? ( verdict => 'degraded' ) : () ),
        ( !$enabled
            ? ( message =>
                    'the daemon plugin is disabled, so no process is started' )
            : ()
        ),
        ( $any_died
            ? ( message => 'the runtime is up with a service that has failed',
                remedy => 'see the per-service verdicts below'
                )
            : ()
        ),

        # THE TOP-LEVEL REMEDY CARRIES THE COMMAND, because it is the line an
        # operator reads first - the Status button shows the unit before its
        # services, and a remedy that says "check the host service" when the
        # actual answer is one command is the SM750 defect at one remove.
        ( $enabled && !$any_running && !$any_died
            ? ( remedy =>
                    'the plugin is enabled but the host service is not '
                    . 'running - a host operator instantiates it with '
                    . 'systemctl enable --now lazysited@<domain>' )
            : ()
        ),
    );

    return {
        ok     => 1,
        plugin => $PLUGIN,
        %{$whole},
        services => \@svc,
    };
}

# --- run -----------------------------------------------------------------

# Start the supervisor loop. Returns an exit code.
#
# The FIRST thing it does is check the gate, and the check is not advisory: a
# disabled runtime exits 0 without creating a state directory, opening a file
# or spawning anything. "Started, then did nothing" would leave a process
# holding this instance's identity for no reason.
sub run {
    my (%opt) = @_;
    my $root = _docroot( $opt{docroot} );

    unless ( should_run($root) ) {
        log_event( 'INFO', 'daemon',
            'not starting: the daemon plugin is disabled' );
        return 0;
    }

    _ensure_state_dir($root);
    log_event( 'INFO', 'daemon', 'supervisor starting',
        services => scalar( () = services() ) );

    my %child;       # name => pid
    my %fails;       # name => consecutive failures
    my %next_try;    # name => epoch before which we do not restart
    my $running = 1;

    local $SIG{TERM} = sub { $running = 0 };
    local $SIG{INT}  = sub { $running = 0 };

    my $backoff_base = _conf_number( $root, 'daemon_restart_backoff', 5 );
    my $ceiling      = 6;    # 2^6 * base; past this a service is FAILED

    while ($running) {
        for my $s ( services() ) {
            my $name = $s->{name};
            next if $child{$name} && _alive( $child{$name} );

            # It was running and is not now.
            if ( $child{$name} ) {
                $fails{$name}++;
                delete $child{$name};
                log_event( 'WARN', 'daemon', 'service exited',
                    service => $name, consecutive_failures => $fails{$name} );
            }

            if ( ( $fails{$name} // 0 ) > $ceiling ) {
                # FAILED, and it stays failed. A service restarted forever is
                # reported as running by anything that only asks "is a process
                # there", which is the report an operator must not be given.
                next;
            }

            my $wait = $next_try{$name} // 0;
            next if time < $wait;

            my $pid = _spawn( $s, $root );
            if ($pid) {
                $child{$name}    = $pid;
                $next_try{$name} = 0;
                log_event( 'INFO', 'daemon', 'service started',
                    service => $name, pid => $pid );
            }
            else {
                $fails{$name}++;
                $next_try{$name}
                    = time + $backoff_base * ( 2**( $fails{$name} - 1 ) );
            }
        }

        # Reap, and notice a service that has gone.
        while ( ( my $gone = waitpid( -1, POSIX::WNOHANG() ) ) > 0 ) {
            for my $n ( keys %child ) {
                delete $child{$n} if $child{$n} == $gone;
            }
        }

        sleep 1;
    }

    _stop_children( \%child, $root );
    log_event( 'INFO', 'daemon', 'supervisor stopped' );
    return 0;
}

sub _spawn {
    my ( $s, $root ) = @_;
    my $pid = fork();
    return undef unless defined $pid;

    if ( $pid == 0 ) {
        # Child: become the service and never return.
        eval {
            $s->{start}->( docroot => $root );
            1;
        } or do {
            # The message is fixed text. A service's death can carry a path or
            # a driver's vocabulary in $@, and SM739 earned the rule that a
            # caller-facing string says nothing about the host - the detail
            # goes to the log, where an operator can reach it.
            log_event( 'ERROR', 'daemon', 'service died',
                service => $s->{name}, detail => 'see the site log' );
        };
        POSIX::_exit(0);
    }

    _write_pid( $root, $s->{name}, $pid );
    return $pid;
}

sub _write_pid {
    my ( $root, $name, $pid ) = @_;
    my $f = _pid_file( $root, $name );
    open my $fh, '>', $f or return;
    print {$fh} "$pid\n";
    close $fh;
    return;
}

sub _stop_children {
    my ( $child, $root ) = @_;
    for my $name ( keys %$child ) {
        kill 'TERM', $child->{$name};
    }
    for my $name ( keys %$child ) {
        waitpid( $child->{$name}, 0 );
        unlink _pid_file( $root, $name );
    }
    return;
}

# --- config --------------------------------------------------------------

# The daemon's own settings live in the plugin's config file. Read defensively:
# a missing or malformed value takes the default rather than stopping the
# runtime, because a typo in a tick interval must not be the reason nothing
# runs.
sub _conf_number {
    my ( $root, $key, $default ) = @_;
    my $v = conf_value( $root, $key );
    return $default unless defined $v && $v =~ /\A\d+\z/;
    return $v + 0;
}

sub conf_value {
    my ( $root, $key ) = @_;
    my $f = _docroot($root) . '/lazysite/daemon.conf';
    open my $fh, '<:utf8', $f or return undef;
    my $val;
    while ( my $line = <$fh> ) {
        chomp $line;
        next if $line =~ /\A\s*#/;
        if ( $line =~ /\A\s*\Q$key\E\s*:\s*(.*?)\s*\z/ ) { $val = $1; last }
    }
    close $fh;
    return $val;
}

1;
