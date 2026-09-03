package Lazysite::Daemon::Service::Scheduler;

# SM666 phase 1: the scheduler, and the first service against the contract.
#
# It is first BECAUSE it needs no socket. That lets it prove the supervisor,
# the service contract, the lifecycle reporting and - the part worth the most -
# the job identity and audit path, with zero network surface to get wrong at
# the same time.
#
# THE TWO RULES IT EXISTS TO ENFORCE:
#
# A JOB IS ENGINE CODE, NOT CONFIGURATION. %JOBS below is the whole set. No
# site, app, theme or config file can add one. This is a rule rather than a
# phase-1 convenience: the moment a schedule becomes a configuration surface,
# "write a schedule" becomes "execute code on a timer", reachable by anyone who
# can write configuration. What IS configurable is which identity a job runs as
# and how often the tick fires.
#
# A JOB RUNS AS A USER, NEVER AS system. `system:*` is how the CLI acts and the
# CLI is unconstrained, so a job running that way would bypass the capability
# model entirely - which is what the model exists to prevent. Two gates apply:
# the identity must hold `run_jobs` (it may carry a job at all), and the job's
# action faces the ordinary capability gate unchanged (no scheduled-work
# exemption, no widening).
#
# FAILURE IS CLOSED IN EVERY DIRECTION. A missing user, a user without
# run_jobs, or a user lacking what the job's action needs means THE JOB DOES
# NOT RUN. It never falls back to system, to the primary site's owner, or to
# whoever configured it. It records a refusal naming what was missing.
use strict;
use warnings;
use Lazysite::Util               qw(log_event);
use Lazysite::Daemon::Supervisor ();

our $VERSION = '0.1';

# --- the job set -----------------------------------------------------------
#
# Closed, by rule. Each entry declares what it needs, so the gate can be
# applied without the job being consulted about its own authorisation.
#
# `every`  - seconds between runs.
# `needs`  - the capability the job's action requires, beyond run_jobs.
# `run`    - a coderef taking (%ctx). It performs the work; it does NOT decide
#            whether it is allowed to, which is checked before it is called.
#
# Phase 1 ships ONE job, deliberately. The point of the phase is the machinery
# - the identity, the gate, the record - and a second job proves none of it
# twice. The maintenance work SM340 named (retention sweeps, token expiry,
# stats rollups) arrives once this has run somewhere real.
our %JOBS = (
    'daemon-heartbeat' => {
        every => 300,
        needs => undef,    # reads nothing and writes nothing but its own record
        run   => sub {
            my (%ctx) = @_;
            return { ok => 1, detail => 'alive' };
        },
    },
);

sub jobs { return \%JOBS }

# --- identity --------------------------------------------------------------

# Resolve the account a job runs as, and refuse rather than improvise.
#
# Returns ( $user, undef ) when the identity is usable, or ( undef, $reason )
# when it is not. The reason is for the record: an operator reading "job did
# not run" needs to know which of the three ways it failed.
sub resolve_job_user {
    my (%a) = @_;
    my $root = $a{docroot};

    my $user = Lazysite::Daemon::Supervisor::conf_value( $root,
        'daemon_job_user' );

    return ( undef, 'no daemon_job_user is configured, so no job runs' )
        unless defined $user && length $user;

    # Never system. Stated as an explicit refusal rather than left to the
    # capability check, because `system:*` would not be found in the user store
    # at all and "unknown account" is the wrong reason to report for it.
    return ( undef, "a job may not run as '$user' - system identities are "
            . 'unconstrained by the capability model' )
        if $user =~ /\Asystem:/;

    require Lazysite::Auth::Settings;
    local $Lazysite::Auth::Settings::AUTH_DIR = "$root/lazysite/auth";

    my $caps = Lazysite::Auth::Settings::caps_for($user);
    return ( undef, "the configured job account '$user' does not exist or "
            . 'holds no capabilities' )
        unless ref $caps eq 'HASH';

    return ( undef, "the job account '$user' does not hold run_jobs" )
        unless $caps->{run_jobs};

    return ( $user, undef );
}

# The second gate: the job's own action. Unchanged from what any other actor
# faces - that is the point of it.
sub _may_run_job {
    my ( $caps, $job ) = @_;
    my $needs = $job->{needs};
    return ( 1, undef ) unless defined $needs;
    return ( 1, undef ) if $caps->{$needs};
    return ( 0, "the job account does not hold $needs" );
}

# --- the tick --------------------------------------------------------------

sub _state_file {
    my ($root) = @_;
    return "$root/lazysite/daemon/scheduler-runs.json";
}

sub _read_runs {
    my ($root) = @_;
    my $f = _state_file($root);
    open my $fh, '<:utf8', $f or return {};
    my $raw = do { local $/; <$fh> };
    close $fh;
    require JSON::PP;
    my $d = eval { JSON::PP->new->decode($raw) };
    return ref $d eq 'HASH' ? $d : {};
}

sub _write_runs {
    my ( $root, $runs ) = @_;
    my $f = _state_file($root);
    require JSON::PP;
    open my $fh, '>:utf8', $f or return 0;
    print {$fh} JSON::PP->new->canonical->pretty->encode($runs);
    close $fh;
    return 1;
}

# A REFUSAL IS NOT A RUN, and getting this wrong is easy.
#
# The first version recorded `last_run` on a refusal, which meant a job refused
# because no account was configured had consumed its schedule slot: an operator
# who fixed the configuration then waited a full interval for anything to
# happen, with nothing saying why. The refusal is a statement about the
# CONFIGURATION, not about the work, and the work has not been done.
#
# So `last_run` moves only when the job actually ran (or ran and errored -
# retrying a failing job every tick would hammer it). A refusal records itself
# separately, and logs only when the reason CHANGES: a misconfigured daemon
# would otherwise write the same WARN every tick forever, which trains an
# operator to ignore the log that is trying to tell them something.
sub _record_refusal {
    my ( $runs, $name, $now, $reason, $actor ) = @_;
    my $prev = $runs->{$name}{refusal_reason} // '';

    $runs->{$name}{outcome}        = 'refused';
    $runs->{$name}{refused_at}     = $now;
    $runs->{$name}{refusal_reason} = $reason;
    $runs->{$name}{actor}          = $actor if defined $actor;

    return if $prev eq $reason;    # already said, and nothing has changed
    log_event( 'WARN', 'scheduler', 'job refused',
        job => $name, reason => $reason,
        ( defined $actor ? ( actor => $actor ) : () ) );
    return;
}

# One pass. Separated from the loop so a test can run exactly one, which is the
# difference between testing the scheduler and waiting for it.
sub tick {
    my (%a)  = @_;
    my $root = $a{docroot};
    my $now  = $a{now} // time;

    my $runs = _read_runs($root);
    my @done;

    my ( $user, $why ) = resolve_job_user( docroot => $root );

    require Lazysite::Auth::Settings;
    local $Lazysite::Auth::Settings::AUTH_DIR = "$root/lazysite/auth";
    my $caps = defined $user
        ? Lazysite::Auth::Settings::caps_for($user)
        : {};

    for my $name ( sort keys %JOBS ) {
        my $job  = $JOBS{$name};
        my $last = $runs->{$name}{last_run} // 0;
        next if $now - $last < $job->{every};

        # Refused for identity reasons: recorded, not silently skipped. A job
        # that never runs and says nothing is indistinguishable from a job
        # that has nothing to do.
        unless ( defined $user ) {
            _record_refusal( $runs, $name, $now, $why, undef );
            push @done, { job => $name, outcome => 'refused', reason => $why };
            next;
        }

        my ( $ok, $deny ) = _may_run_job( $caps, $job );
        unless ($ok) {
            _record_refusal( $runs, $name, $now, $deny, $user );
            push @done, { job => $name, outcome => 'refused', reason => $deny };
            next;
        }

        my $res = eval { $job->{run}->( docroot => $root, actor => $user ) };
        if ( !$res ) {
            my $detail = 'the job died; see the site log';
            $runs->{$name} = { last_run => $now, outcome => 'error',
                reason => $detail, actor => $user };
            log_event( 'ERROR', 'scheduler', 'job died',
                job => $name, actor => $user );
            push @done, { job => $name, outcome => 'error' };
            next;
        }

        $runs->{$name} = { last_run => $now, outcome => 'ok', actor => $user };

        # The audit row names the REAL user. Not 'scheduler', not 'system' -
        # so a row written at 03:00 answers the same question as one written by
        # a person at noon: who was this, and what were they allowed to do.
        log_event( 'INFO', 'scheduler', 'job ran',
            job => $name, actor => $user );
        push @done, { job => $name, outcome => 'ok', actor => $user };
    }

    _write_runs( $root, $runs );
    return \@done;
}

# --- the service ------------------------------------------------------------

sub run {
    my (%a)  = @_;
    my $root = $a{docroot};
    my $tick = Lazysite::Daemon::Supervisor::conf_value( $root,
        'daemon_tick_seconds' );
    $tick = 60 unless defined $tick && $tick =~ /\A\d+\z/ && $tick > 0;

    my $running = 1;
    local $SIG{TERM} = sub { $running = 0 };

    log_event( 'INFO', 'scheduler', 'service started', tick => $tick );
    while ($running) {
        eval { tick( docroot => $root ); 1 }
            or log_event( 'ERROR', 'scheduler', 'tick failed' );
        my $slept = 0;
        while ( $running && $slept < $tick ) { sleep 1; $slept++ }
    }
    log_event( 'INFO', 'scheduler', 'service stopped' );
    return 0;
}

1;
