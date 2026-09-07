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
use Errno               ();
use Time::HiRes         ();
use Lazysite::Util      qw(log_event cannot_read);
use Lazysite::Lifecycle qw(lifecycle_status);

our $VERSION = '0.1';

# The plugin script whose enabled state gates this runtime. One name, stated
# once - a second spelling of it somewhere else is how "disabled" drifts back
# into being a display state.
# SM759: the REGISTRY KEY, which is what the Plugin Manager writes into the
# conf's plugins: list and what every other enabled-check in the engine reads
# (`plugins/data.pl`, `plugins/briefs.pl`). This was 'daemon.pl' - a name the
# conf never holds - so should_run() was 0 on every site in the field: Enable
# wrote `plugins/daemon.pl`, the listing read it back as enabled, and the
# runtime read the same file, looked for a different word, and reported the
# plugin disabled. Every test fixture had written `- daemon.pl` by hand, so
# the fixture agreed with the reader and never met the writer. t/unit/daemon/09
# now enables through the real writer; t/lint/119 refuses a bare name.
our $PLUGIN = 'plugins/daemon.pl';

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
    open my $fh, '<', $f or return cannot_read( 'daemon pid', $f );
    my $pid = <$fh>;
    close $fh;
    return undef unless defined $pid;
    chomp $pid;
    return $pid =~ /\A\d+\z/ ? $pid + 0 : undef;
}

sub _alive {
    my ($pid) = @_;
    return 0 unless defined $pid && $pid > 0;
    return 1 if kill( 0, $pid );

    # SM760: EPERM means the process EXISTS and belongs to somebody else. The
    # first version read `kill 0` false as dead, so Status - run by the
    # request path as www-data - reported a runtime owned by the panel user
    # as "has not been started" while holding its pid and reading the run
    # records it had just written. That process is alive; it is not ours to
    # signal, which is a different fact and one the unix-user check names.
    return $!{EPERM} ? 1 : 0;
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
    open my $fh, '<', qq{/proc/$pid/stat} or return undef; # not a store: a pid that has gone is the ordinary case (t/lint/121)
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
# SM757: WHAT THE HOST HAS DONE, asked from the site. The manager has no root,
# so when a sysop presses Enable the one thing it can do is LOOK: is there a
# runtime conf naming this docroot, is its timer enabled, is the service up.
# Everything here is a read an unprivileged process may make - the conf is
# root-owned 0644 and `systemctl is-enabled` / `is-active` answer anyone. Where
# systemd is absent the answer is "unknown", said as such.
our $DAEMON_ETC = '/etc/lazysite/daemon';

sub _conf_user {
    my ($conf) = @_;
    open my $fh, '<', $conf or return cannot_read( 'host runtime conf', $conf );
    my ($u) = map { /^USER=(.*)$/ ? $1 : () } <$fh>;
    close $fh;
    return $u;
}

sub host_provisioning {
    my ($root) = @_;
    my %h = ( conf => undef, instance => undef, timer => 'unknown', service => 'unknown' );
    require Cwd;
    my $real = Cwd::realpath($root) // $root;
    if ( opendir my $dh, $DAEMON_ETC ) {
        for my $f ( sort grep { /\.conf\z/ } readdir $dh ) {
            open my $fh, '<', "$DAEMON_ETC/$f" or do { cannot_read( 'host runtime conf', "$DAEMON_ETC/$f" ); next };
            my ($doc) = map { /^DOCROOT=(.*)$/ ? $1 : () } <$fh>;
            close $fh;
            next unless defined $doc;
            my $d = Cwd::realpath($doc) // $doc;
            if ( $d eq $real ) { $h{conf} = "$DAEMON_ETC/$f"; ( $h{instance} = $f ) =~ s/\.conf\z//; last }
        }
        closedir $dh;
    }
    my ($systemctl) = grep { -x $_ } qw(/usr/bin/systemctl /bin/systemctl);
    if ( $systemctl && defined $h{instance} ) {
        my $inst = $h{instance};
        $h{timer} = system( $systemctl, 'is-enabled', '--quiet', "lazysited\@$inst.timer" ) == 0 ? 'enabled' : 'disabled';
        $h{service} = system( $systemctl, 'is-active', '--quiet', "lazysited\@$inst.service" ) == 0 ? 'active' : 'inactive';
    }
    return \%h;
}

# The job account, checked the way the scheduler will check it, plus what
# each job additionally needs - so Enable can say "and the sweep will be
# refused" before an hour passes and the run record says it.
sub job_account_checks {
    my ($root) = @_;
    require Lazysite::Daemon::Service::Scheduler;
    my @out;
    my ( $user, $why ) = Lazysite::Daemon::Service::Scheduler::resolve_job_user( docroot => $root );
    unless ( defined $user ) {
        push @out, { check => 'job_account', ok => 0, message => "no job will run: $why",
            remedy => 'set daemon_job_user in the plugin config to an account holding run_jobs (a purpose account, not a person\'s)' };
        return \@out;
    }
    push @out, { check => 'job_account', ok => 1, message => "jobs run as '$user', which holds run_jobs" };
    require Lazysite::Auth::Settings;
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = "$root/lazysite/auth";
    my $caps = Lazysite::Auth::Settings::caps_for($user) || {};
    my $jobs = Lazysite::Daemon::Service::Scheduler::jobs();
    for my $name ( sort keys %$jobs ) {
        my $needs = $jobs->{$name}{needs};
        next unless defined $needs;
        push @out, $caps->{$needs}
            ? { check => "job:$name", ok => 1, message => "$name may run ('$user' holds $needs)" }
            : { check => "job:$name", ok => 0, message => "$name will be refused: '$user' does not hold $needs",
            remedy => "grant $needs to the job account's group" };
    }
    return \@out;
}

sub status {
    my ( $docroot, %a ) = @_;
    my $root    = _docroot($docroot);
    my $enabled = should_run($root) ? 1 : 0;
    my $host    = host_provisioning($root);

    # SM760: DISABLE SAYS WHETHER THE PROCESS STOPPED. The field could not
    # confirm it - Status is refused while the plugin is off (a disabled
    # contract plugin executes nothing), so the only reading was to re-enable
    # and look. The on_disable hook runs this with `settle`, and it waits up
    # to that many seconds for the runtime to notice the gate ($GATE_EVERY)
    # and go, then reports "stopped" or "still stopping (pid N)". A wait
    # bounded by the gate interval, not a guess.
    if ( !$enabled && $a{settle} ) {
        my $deadline = time + $a{settle};
        while ( time < $deadline ) {
            my $alive = grep { _is_ours( _read_pid( $root, $_->{name} ), _read_state( $root, $_->{name} )->{start_ticks} ) } services();
            last unless $alive;
            sleep 1;
        }
    }

    my @svc;
    my $any_running = 0;
    my $any_died    = 0;
    my $any_pending = 0;    # a restart is due
        # SM766: the host timer is what starts the runtime after Enable (SM757);
        # while it is armed and nothing has run yet, the honest verdict is
        # `starting`, not `inconsistent` - the field read "inconsistent" on every
        # enable as a strong word for a normal, self-clearing wait.
    my $timer_armed = $enabled && $host->{conf} && ( $host->{timer} // '' ) eq 'enabled';
    my $any_waiting = 0;

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
            : ( !defined $pid && $timer_armed )   ? 'starting'
            :                                       'inconsistent';
        my $waiting = $verdict eq 'starting' && !defined $pid;
        $any_died    ||= ( $verdict eq 'failed' );
        $any_pending ||= ( $verdict eq 'starting' && !$waiting );
        $any_waiting ||= $waiting;

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
            ( $waiting
                ? ( message => "$s->{name} has not started yet; the host timer starts the runtime within five minutes",
                    remedy => 'wait for the timer; Status again in five minutes'
                    )
                : ()
            ),
            ( $verdict eq 'starting' && !$waiting
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
                    remedy => { _host_remedy($host) }->{remedy}
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
        ( !$any_died && !$any_pending && $any_waiting && !$any_running
            ? ( verdict => 'starting',
                message => 'the daemon is switched on and waiting for the host timer to start it',
                remedy => 'the plugin is enabled and the host runtime is provisioned; its timer starts it within five minutes'
                )
            : ()
        ),
        ( !$enabled
            ? ( message => $any_running
                ? 'the daemon plugin is disabled and the runtime is still stopping (pid '
                    . join( ', ', map { _read_pid( $root, $_->{name} ) // '?' } services() ) . ')'
                : 'the daemon plugin is disabled and the runtime is stopped' )
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
        ( $enabled && !$any_running && !$any_died && !$any_pending && !$any_waiting
            ? ( _host_remedy($host) )
            : ()
        ),
    );

    # SM757: the checks a sysop's Enable needs answered NOW, and one sentence
    # the Plugin Manager can show beside the toggle.
    my @checks = ( _host_checks( $host, $enabled, $any_running ), @{ $enabled ? job_account_checks($root) : [] } );
    # The host state is already the top-level remedy; "Also:" carries the first
    # failing JOB check, which no lifecycle field would otherwise mention.
    my ($first_bad) = grep { !$_->{ok} && $_->{check} =~ /^job/ } @checks;
    my $summary = $whole->{message}
        . ( $whole->{remedy} ? " - $whole->{remedy}"                              : '' )
        . ( !$enabled ? ' - enable it on the Plugin Manager to start the runtime' : '' )
        . ( $first_bad && $first_bad->{remedy}
        ? ". Also: $first_bad->{message} - $first_bad->{remedy}" : '' )
        . '.';
    $summary =~ s/\.\.\z/./;

    # SM759: what each job last did, from the run record - which the remote
    # surfaces cannot read, so Status is where a sysop or a partner sees it.
    require Lazysite::Daemon::Service::Scheduler;
    my $runs = Lazysite::Daemon::Service::Scheduler::run_record($root);

    return {
        ok     => 1,
        plugin => $PLUGIN,
        %{$whole},
        services => \@svc,
        host     => $host,
        checks   => \@checks,
        runs     => $runs,
        summary  => $summary,
    };
}

sub _host_remedy {
    my ($host) = @_;
    return ( remedy => 'the plugin is enabled and the host runtime is provisioned; '
            . 'its timer starts it within five minutes' )
        if $host->{conf} && $host->{timer} eq 'enabled';
    return ( remedy => "the plugin is enabled and the host runtime conf exists ($host->{conf}) but its "
            . "timer is not enabled - a host operator runs: systemctl enable --now lazysited\@$host->{instance}.timer" )
        if $host->{conf};
    return ( remedy => 'the plugin is enabled but this host has no runtime provisioned for this site: '
            . 'nothing will run until an operator provisions it - on Hestia the deploy '
            . '(lazysite-hestia-deploy.sh) does it on every deploy, or '
            . 'lazysite-hestia-domain add <user> <domain> --daemon' );
}

sub _host_checks {
    my ( $host, $enabled, $running ) = @_;
    my @c;
    push @c, $host->{conf}
        ? { check => 'host_conf', ok => 1, message => "the host runtime conf names this site ($host->{conf})" }
        : { check => 'host_conf', ok => 0, message => 'no host runtime conf names this site',
        remedy => 'an operator provisions it: the Hestia deploy does, or lazysite-hestia-domain add <user> <domain> --daemon' };
    if ( $host->{conf} ) {
        push @c, $host->{timer} eq 'enabled'
            ? { check => 'host_timer', ok => 1, message => "lazysited\@$host->{instance}.timer is enabled (starts the runtime within five minutes)" }
            : { check => 'host_timer', ok => ( $host->{timer} eq 'unknown' ? 1 : 0 ),
            message => "lazysited\@$host->{instance}.timer is $host->{timer}",
            ( $host->{timer} eq 'disabled' ? ( remedy => "systemctl enable --now lazysited\@$host->{instance}.timer" ) : () ) };
    }
    # SM760: THE RUNTIME MUST RUN AS THE UNIX USER THE REQUEST PATH WRITES AS.
    # The two share one write plane - the request path writes the auth stores
    # and the runtime reads them; the runtime writes its pid, state and run
    # records and Status reads those - and 0660 files owned by one are closed
    # to the other. The field's first real run refused every job for a
    # capability the account held, because www-data had rewritten
    # groups-settings.json and the runtime, as the panel user, could not open
    # it. This check compares the conf's USER= with the user Status itself
    # runs as, which IS the request path's user, so it needs no knowledge of
    # the host. The deploy writes USER= from the same rule.
    if ( $host->{conf} ) {
        my $want = _conf_user( $host->{conf} );
        my ($me) = getpwuid($>);
        $me //= $>;
        if ( defined $want && length $want ) {
            push @c, $want eq $me
                ? { check => 'runtime_user', ok => 1, message => "the runtime runs as '$want', the same unix user as the request path" }
                : { check => 'runtime_user', ok => 0,
                message => "the runtime runs as '$want' but the request path runs as '$me' - files one writes, the other cannot read",
                remedy => "set USER=$me in $host->{conf} and run: systemctl restart lazysited\@$host->{instance} (the deploy writes USER= from the request path's user)" };
        }
    }
    push @c, { check => 'runtime', ok => ( $running || !$enabled ) ? 1 : 0,
        message => $running ? 'the runtime is running' : $enabled ? 'the runtime is not running yet' : 'the plugin is disabled, so no runtime runs',
        ( $enabled && !$running ? ( _host_remedy($host) ) : () ) };
    return @c;
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
    open my $fh, '<', $f or return ( cannot_read( 'daemon state', $f ) // {} );
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
    open my $fh, '<:utf8', $f or return cannot_read( 'daemon.conf', $f );
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
