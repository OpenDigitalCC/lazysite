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
use Time::HiRes         ();
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

# A pid is reused. The 0.13.1 daemon review (D5 experiment 8) wrote the test's
# own pid into scheduler.pid and status() said `on`: `kill 0` proves a process
# exists, not that it is ours. The kernel's process start time (field 22 of
# /proc/PID/stat, in clock ticks since boot) is fixed for the life of a pid and
# differs for its next holder, so the supervisor records it at spawn and every
# liveness question asks for both. Where /proc is not readable the check falls
# back to the pid alone, which is what it was.
sub _start_ticks {
    my ($pid) = @_;
    open my $fh, '<', qq{/proc/$pid/stat} or return undef;
    my $line = <$fh>;
    close $fh;
    return undef unless defined $line;

    # comm may contain spaces and parentheses; everything after the last ')'
    # is the fixed-order field list, starting at field 3.
    my ($rest) = $line =~ /\)\s+(.*)\z/s;
    return undef unless defined $rest;
    my @f = split /\s+/, $rest;
    return $f[19];    # field 22 overall = index 19 after fields 1-2
}

sub _is_ours {
    my ( $pid, $started_ticks ) = @_;
    return 0 unless _alive($pid);
    return 1 unless defined $started_ticks;
    my $now_ticks = _start_ticks($pid);
    return 1 unless defined $now_ticks;    # no /proc: pid is all we have
    return $now_ticks eq $started_ticks ? 1 : 0;
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
    my $any_pending = 0;    # a restart is due

    for my $s ( services() ) {
        my $pid   = _read_pid( $root, $s->{name} );
        my $st    = _read_state( $root, $s->{name} );
        my $alive = _is_ours( $pid, $st->{start_ticks} );
        $any_running ||= $alive;

        # SM755. The verdict comes from what the supervisor RECORDED, not from
        # guessing at a pid. A recorded pid that is not alive used to read as
        # `failed`; it is `failed` only when the supervisor has given up
        # (past the ceiling), and `starting` while a restart is pending - the
        # contract's word for "not running, and something is about to do
        # something about it". Never started at all is `inconsistent`.
        my $verdict
            = !$enabled                           ? 'off'
            : $alive                              ? 'on'
            : $st->{failed}                       ? 'failed'
            : ( defined $pid && $st->{next_try} ) ? 'starting'
            :                                       'inconsistent';
        $any_died    ||= ( $verdict eq 'failed' );
        $any_pending ||= ( $verdict eq 'starting' );

        push @svc,
            lifecycle_status(
            unit       => $s->{name},
            kind       => 'service',
            desired_on => $enabled,
            running    => $alive,
            verdict    => $verdict,
            ( defined $pid || $st->{fails}
                ? ( detail => {
                        ( defined $pid ? ( pid => $pid ) : () ),
                        ( $st->{fails}
                            ? ( consecutive_failures => $st->{fails} )
                            : () ),
                } )
                : ()
            ),
            ( $verdict eq 'failed'
                ? ( message => "$s->{name} kept dying and the supervisor has "
                        . "stopped restarting it ($st->{fails} consecutive "
                        . 'failures)',
                    remedy => 'see the site log for why it dies; restart the '
                        . 'host service (systemctl restart lazysited@<domain>) '
                        . 'once the cause is fixed'
                    )
                : ()
            ),
            ( $verdict eq 'starting'
                ? ( message => "$s->{name} exited and a restart is due at "
                        . POSIX::strftime( '%H:%M:%S', localtime $st->{next_try} )
                        . " (failure $st->{fails})",
                    remedy => 'wait for the restart; if this repeats, see the '
                        . 'site log for why the service exits'
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
        ( !$any_died && $any_pending && !$any_running
            ? ( verdict => 'starting',
                message => 'a service exited and the supervisor is about to restart it',
                remedy  => 'wait; the per-service verdict below says when'
                )
            : ()
        ),
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
        ( $enabled && !$any_running && !$any_died && !$any_pending
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
#
# SM755 - THE REAP IS THE EXIT EVENT. The first version counted a failure only
# when it noticed a child gone BEFORE reaping it, and `kill 0` succeeds on a
# zombie - so the reap always won, the failure count never moved, the backoff
# never applied, the ceiling was unreachable, and a service that died at once
# was forked again every two seconds for ever while status() said `on`. That
# is the flapping-child-reported-healthy dishonesty property 3 above promises
# to avoid, built into the code that promised it. Now every exit is counted in
# ONE place, the reap loop, with the exit status in the log line; the backoff
# is applied to the next start; past the ceiling the service is FAILED, once,
# with a state file status() reads.
#
# A service that ran for a while before dying is not flapping. Its failure
# count starts again, so a rare crash over months cannot creep up to the
# ceiling and stop a healthy service from being restarted.
#
# THE GATE IS RE-READ WHILE RUNNING (F1.2 of the 0.13.1 daemon review). The
# unit and the README both say both switches must be on for anything to run;
# a sysop disabling the plugin in the manager must therefore stop the jobs,
# not merely prevent the next start. Checked every $GATE_EVERY seconds rather
# than every second, because it is a file read per instance and the host may
# have hundreds. Off means stop the children and exit 0 - the exit code the
# unit already treats as "disabled, do not restart".
our $GATE_EVERY   = 10;    # seconds between re-reads of the enabled gate
our $STEADY_AFTER = 60;    # a service alive this long has stopped flapping
our $FAIL_CEILING = 6;     # 2^6 * base; past this many exits a service is FAILED
our $LOCK_FH;              # the supervisor lock, held for its life (see _acquire_lock)

sub run {
    my (%opt) = @_;
    my $root = _docroot( $opt{docroot} );

    unless ( should_run($root) ) {
        log_event( 'INFO', 'daemon',
            'not starting: the daemon plugin is disabled' );
        return 0;
    }

    _ensure_state_dir($root);

    # ONE SUPERVISOR PER DOCROOT. The review's experiment 6 started a second
    # supervisor on a docroot whose first had been killed -9: it spawned a
    # second scheduler beside the orphaned first, overwrote the pid file, and
    # status() reported one healthy service while two ran the same jobs against
    # the same files. An advisory lock on a file in the state directory is held
    # for the supervisor's life; a second supervisor is refused with exit 3,
    # which Restart=on-failure will retry within its limit and then give up on,
    # and the log says which pid holds it.
    my $lock = _acquire_lock($root);
    unless ($lock) {
        log_event( 'ERROR', 'daemon',
            'not starting: another supervisor holds the lock for this docroot' );
        return 3;
    }

    log_event( 'INFO', 'daemon', 'supervisor starting',
        services => scalar( () = services() ) );

    # ADOPT BY STOPPING. A service left over from a supervisor that died without
    # stopping its children (kill -9, OOM) is still ours - same docroot, same
    # jobs - and starting a fresh one beside it is the duplication above. It is
    # stopped, deliberately and with a log line, before a fresh one is started
    # under this supervisor's care.
    for my $s ( services() ) {
        my $old = _read_pid( $root, $s->{name} );
        my $st  = _read_state( $root, $s->{name} );

        # Only with the start-time proof. A pid alone could be ANY process the
        # site user owns by now, and the one thing worse than a duplicate
        # scheduler is a supervisor that kills something else.
        next unless defined $st->{start_ticks}
            && _is_ours( $old, $st->{start_ticks} );
        log_event( 'WARN', 'daemon',
            'stopping an orphaned service from a previous supervisor',
            service => $s->{name}, pid => $old );
        kill 'TERM', $old;
        _wait_gone( $old, 10 ) or kill 'KILL', $old;
    }

    my %child;       # name => pid
    my %since;       # name => epoch the current child started
    my %fails;       # name => consecutive failures
    my %next_try;    # name => epoch before which we do not restart
    my %failed;      # name => 1 once past the ceiling (logged once)
    my $running = 1;

    local $SIG{TERM} = sub { $running = 0 };
    local $SIG{INT}  = sub { $running = 0 };

    my $backoff_base = _conf_number( $root, 'daemon_restart_backoff', 5 );
    my $gate_checked = time;

    while ($running) {

        # 1. Reap. An exit is counted here and only here.
        while ( ( my $gone = waitpid( -1, POSIX::WNOHANG() ) ) > 0 ) {
            my $status = $?;
            for my $name ( keys %child ) {
                next unless $child{$name} == $gone;
                delete $child{$name};

                my $ran = time - ( $since{$name} // time );
                $fails{$name} = 0 if $ran >= $STEADY_AFTER;
                $fails{$name}++;

                my $wait = $backoff_base * ( 2**( $fails{$name} - 1 ) );
                $next_try{$name} = time + $wait;
                log_event( 'WARN', 'daemon', 'service exited',
                    service              => $name,
                    exit                 => $status >> 8,
                    signal               => $status & 127,
                    ran_seconds          => $ran,
                    consecutive_failures => $fails{$name},
                    retry_in             => $wait );
                _write_state( $root, $name,
                    { fails => $fails{$name}, next_try => $next_try{$name} } );
            }
        }

        # 2. The gate, periodically.
        if ( time - $gate_checked >= $GATE_EVERY ) {
            $gate_checked = time;
            unless ( should_run($root) ) {
                log_event( 'INFO', 'daemon',
                    'stopping: the daemon plugin has been disabled' );
                last;
            }
        }

        # 3. Start what should be running and is not.
        for my $s ( services() ) {
            my $name = $s->{name};
            next if $child{$name};
            next if $failed{$name};

            if ( ( $fails{$name} // 0 ) > $FAIL_CEILING ) {
                # FAILED, and it stays failed. A service restarted forever is
                # reported as running by anything that only asks "is a process
                # there", which is the report an operator must not be given.
                $failed{$name} = 1;
                log_event( 'ERROR', 'daemon', 'service failed - not restarting',
                    service => $name, consecutive_failures => $fails{$name} );
                _write_state( $root, $name,
                    { fails => $fails{$name}, failed => 1 } );
                next;
            }

            next if time < ( $next_try{$name} // 0 );

            my $pid = _spawn( $s, $root );
            if ($pid) {
                $child{$name} = $pid;
                $since{$name} = time;
                delete $next_try{$name};
                _write_state( $root, $name,
                    { fails => $fails{$name} // 0,
                        started     => $since{$name},
                        start_ticks => _start_ticks($pid),
                    } );
                log_event( 'INFO', 'daemon', 'service started',
                    service => $name, pid => $pid,
                    ( $fails{$name} ? ( attempt => $fails{$name} + 1 ) : () ) );
            }
            else {
                # fork itself failed: counted like an exit, so the same backoff
                # governs a host that is out of processes.
                $fails{$name}++;
                $next_try{$name}
                    = time + $backoff_base * ( 2**( $fails{$name} - 1 ) );
                log_event( 'ERROR', 'daemon', 'could not start service',
                    service => $name, consecutive_failures => $fails{$name} );
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
        # The lock is the SUPERVISOR's. A child that inherited the open
        # descriptor would keep the lock alive after the supervisor died, and
        # the next supervisor would be refused by an orphan it should adopt.
        close $LOCK_FH if $LOCK_FH;

        # Child: become the service and never return. Its exit code is the
        # service's - run() returns one - so the supervisor's log line can say
        # how it ended. A die is exit 1, distinct from a clean 0.
        my $rc = eval { $s->{start}->( docroot => $root ) };
        unless ( defined $rc ) {
            # The message is fixed text. A service's death can carry a path or
            # a driver's vocabulary in $@, and SM739 earned the rule that a
            # caller-facing string says nothing about the host - the detail
            # goes to the log, where an operator can reach it.
            log_event( 'ERROR', 'daemon', 'service died',
                service => $s->{name}, detail => 'see the site log' );
            $rc = 1;
        }
        POSIX::_exit( $rc =~ /\A\d+\z/ ? $rc : 1 );
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

# What the supervisor knows about a service that a pid cannot say: how many
# times it has died in a row, when it will be tried again, whether it has been
# given up on. status() reads this so `starting` and `failed` are the
# supervisor's words, not a guess from a stale pid.
sub _state_file {
    my ( $root, $name ) = @_;
    return _state_dir($root) . "/$name.state.json";
}

sub _write_state {
    my ( $root, $name, $state ) = @_;
    my $f   = _state_file( $root, $name );
    my $tmp = "$f.tmp.$$";
    require JSON::PP;
    open my $fh, '>', $tmp or return;
    print {$fh} JSON::PP->new->canonical->encode($state);
    unless ( close $fh )       { unlink $tmp; return }
    unless ( rename $tmp, $f ) { unlink $tmp; return }
    return;
}

sub _read_state {
    my ( $root, $name ) = @_;
    my $f = _state_file( $root, $name );
    open my $fh, '<', $f or return {};
    my $raw = do { local $/; <$fh> };
    close $fh;
    require JSON::PP;
    my $d = eval { JSON::PP->new->decode($raw) };
    return ref $d eq 'HASH' ? $d : {};
}

# TERM every child, give them $STOP_DEADLINE seconds together, then KILL what is
# left. The first version waited without a deadline, so a job stuck in a
# subprocess held the supervisor's own shutdown until systemd's TimeoutStopSec
# killed the whole cgroup - with no log line of its own to say which service.
our $STOP_DEADLINE = 30;

sub _stop_children {
    my ( $child, $root ) = @_;
    for my $name ( keys %$child ) {
        kill 'TERM', $child->{$name};
    }
    my $until = time + $STOP_DEADLINE;
    for my $name ( keys %$child ) {
        my $pid  = $child->{$name};
        my $left = $until - time;
        unless ( _wait_gone( $pid, $left > 0 ? $left : 0 ) ) {
            log_event( 'WARN', 'daemon',
                'service did not stop within the deadline; killing it',
                service => $name, pid => $pid, deadline => $STOP_DEADLINE );
            kill 'KILL', $pid;
            waitpid( $pid, 0 );
        }
        unlink _pid_file( $root, $name );
        unlink _state_file( $root, $name );
    }
    return;
}

# Wait up to $seconds for $pid to be reaped (our child) or to vanish (not our
# child). Returns 1 when it is gone.
sub _wait_gone {
    my ( $pid, $seconds ) = @_;
    my $until = time + $seconds;
    while (1) {
        my $r = waitpid( $pid, POSIX::WNOHANG() );
        return 1 if $r == $pid || $r == -1 && !kill( 0, $pid );
        return 1 unless kill 0, $pid;
        return 0 if time >= $until;
        Time::HiRes::sleep(0.1);
    }
}

# --- the lock ---------------------------------------------------------------

sub _lock_file {
    my ($root) = @_;
    return _state_dir($root) . q{/supervisor.lock};
}

sub _acquire_lock {
    my ($root) = @_;
    require Fcntl;
    open my $fh, '>>', _lock_file($root) or return 0;
    unless ( flock( $fh, Fcntl::LOCK_EX() | Fcntl::LOCK_NB() ) ) {
        close $fh;
        return 0;
    }
    $LOCK_FH = $fh;
    return 1;
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
