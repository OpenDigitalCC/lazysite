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
use Lazysite::Util               qw(log_event cannot_read);
use Lazysite::Daemon::Supervisor ();
use Lazysite::Daemon::Jobs       ();

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
# 0.13.0 shipped ONE job, deliberately: the heartbeat proved the identity, the
# gate and the record with nothing else to go wrong. 0.13.1 adds the work
# SM666 named as the reason a scheduler exists at all - the maintenance that
# ran on the back of a visitor's page view, or did not run. The bodies live
# in Lazysite::Daemon::Jobs; this table is the set, the schedule and the gate.
#
# `needs` IS THE CAPABILITY THE SAME WORK COSTS THROUGH THE MANAGER. The
# stats export is what analyse_visitors runs, and analyse_visitors is gated
# on analytics; the session registry is listed and revoked under
# manage_users. A job that needed less than the manager asks for the same
# work would be the scheduled-work exemption this module exists to refuse.
our %JOBS = (
    'daemon-heartbeat' => {
        every => 300,
        needs => undef,    # reads nothing and writes nothing but its own record
        run   => sub {
            my (%ctx) = @_;
            return { ok => 1, detail => 'alive' };
        },
    },

    # Close the day, flush and expire the trails, trim the export cache - on a
    # clock, so a day file is complete whether or not anyone read the
    # statistics that day (SM343), and so the visitor who happens to arrive
    # first does not pay for the ingest (SM340). Hourly: the export is
    # incremental against its cache, and the first run after midnight UTC is
    # the one that closes the day.
    'stats-rollup' => {
        every => 3600,
        needs => 'analytics',
        run   => \&Lazysite::Daemon::Jobs::stats_rollup,
    },

    # Expire the session registry and the revocation list without waiting for
    # a login to do it. A row older than the session lifetime describes a
    # cookie that can no longer verify, and carries an IP and a user agent.
    'sessions-sweep' => {
        every => 3600,
        needs => 'manage_users',
        run   => \&Lazysite::Daemon::Jobs::sessions_sweep,
    },

    # SM579: expire the connector call record past its keep and count what
    # never answered, so the run record says how many stuck calls there are.
    # Scheduled INVOCATION of a connector (mode 1) is phase 2; this is the
    # timer keeping the record honest.
    'connectors-sweep' => {
        every => 3600,
        needs => 'manage_connectors',
        run   => \&Lazysite::Daemon::Jobs::connectors_sweep,
    },

    # SM579 phase 2, mode 1: call every connector whose declared interval has
    # elapsed. ONE job, and this table stays a closed literal - a connector
    # says how OFTEN it wants calling; it cannot add a job, change this
    # schedule, or reach the identity gate. The tick is 300s because that is
    # the floor a connector's schedule_every may declare; a connector asking
    # for less would be told it runs every minute while it did not.
    'connectors-call' => {
        every => 300,
        needs => 'manage_connectors',
        run   => \&Lazysite::Daemon::Jobs::connectors_call_due,
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

    # An account that is not in the user store is a typo or a deleted user,
    # and the remedy for either is not "grant run_jobs". The first version
    # asked caps_for and tested for a non-hash, which caps_for never returns
    # (every capability key, 0 or 1) - so the branch was dead and a mistyped
    # name was refused as "does not hold run_jobs": true, and the wrong reason
    # to give someone who needs to fix a spelling. The 0.13.1 daemon review
    # found it (D1 F1.3); account_names() is the reader both the audit trail
    # and the manager use to ask the same question.
    return ( undef, "the configured job account '$user' does not exist - "
            . 'daemon_job_user must name an account in the user store' )
        unless Lazysite::Auth::Settings::account_names()->{$user};

    # SM760: the stores must be READABLE before their answer means anything.
    # An unreadable groups-settings.json read as "holds nothing", so every
    # job was refused as "does not hold run_jobs" while the Groups page and
    # the pre-flight checks - run by the request path, which could read it -
    # said the account held it. The refusal names the file, the error and
    # the unix user, which is the fact an operator needs.
    my ($who) = getpwuid($>);
    $who //= $>;
    for my $store ( [ 'groups-settings.json', "$root/lazysite/auth/groups-settings.json" ], [ 'groups', "$root/lazysite/auth/groups" ] ) {
        my ( $what, $f ) = @$store;

        # SM770: ask by OPENING. `-e` said "nothing here" for a store inside a
        # directory this process may not search - which is the fault this check
        # exists to catch, reported as its own absence.
        my $fh;
        next if open( $fh, '<', $f ) && close $fh;
        next if $!{ENOENT};    # not there at all: nothing to be unable to read
        return ( undef, "the runtime (unix user '$who') cannot read lazysite/auth/$what: $! - "
                . 'the runtime must run as the unix user the request path writes as; '
                . 'the deploy sets USER= in /etc/lazysite/daemon/<domain>.conf' );
    }

    my $caps = Lazysite::Auth::Settings::caps_for($user);

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

# A record that exists and does not parse is reported, not swallowed. It reads
# as empty - every job due at once - which is the safe direction (better a
# rollup twice than never), but the review's experiment 10 found that happened
# in silence, and a file somebody corrupted is a fact an operator should be
# told once.
# SM759: the run record, for Status. The field could not read
# lazysite/daemon/ on any grant it held (the system tree is closed to the
# remote surfaces by design), so the only way to learn what a job did was to
# ask somebody with the filesystem. Status carries it: per job, the outcome,
# when, as whom, and the refusal reason if there was one.
sub run_record {
    my ($root) = @_;
    return _read_runs($root);
}

sub _read_runs {
    my ($root) = @_;
    my $f = _state_file($root);
    open my $fh, '<:utf8', $f or return ( cannot_read( 'run record', $f ) // {} );
    my $raw = do { local $/; <$fh> };
    close $fh;
    require JSON::PP;
    my $d = eval { JSON::PP->new->decode($raw) };
    if ( ref $d eq 'HASH' ) {

        # SM787: THE FAIL-OPEN PROMISE HELD FOR ONE SHAPE OF CORRUPTION OUT OF
        # TWO. The comment above says a corrupted record "reads as empty -
        # every job due at once - which is the safe direction", and that was
        # true only for a TOTAL parse failure. A record that is valid JSON with
        # a top-level object and a scalar job value - {"stats-rollup":"boom"} -
        # passed this guard and then died in tick, dereferencing a string as a
        # hash. run() catches, logs, sleeps and retries, and _write_runs only
        # runs when a job completed, so nothing ever repaired the file: every
        # tick died the same way, forever, and no remote surface can read the
        # system tree to say why.
        #
        # Dropping the bad entry collapses it into the behaviour that was
        # already designed and documented - that job is due now, logged once -
        # instead of a permanent stop of all maintenance.
        my @bad = grep { ref $d->{$_} ne 'HASH' } sort keys %$d;
        if (@bad) {
            delete $d->{$_} for @bad;
            log_event( 'WARN', 'scheduler',
                'the run record has entries that are not job records; they are '
                    . 'treated as never having run',
                file    => 'lazysite/daemon/scheduler-runs.json',
                entries => join( ',', @bad ) );
        }
        return $d;
    }
    log_event( 'WARN', 'scheduler',
        'the run record is unreadable and is treated as empty - every job '
            . 'is due now', file => 'lazysite/daemon/scheduler-runs.json' );
    return {};
}

# Temp and rename, with the close checked. The first version truncated the
# file in place, which on a crash or a full disk leaves a torn record - and a
# torn record reads as an empty one, so every job would run again at once.
# The engine writes its JSON this way everywhere else; the daemon does too.
sub _write_runs {
    my ( $root, $runs ) = @_;
    my $f   = _state_file($root);
    my $tmp = "$f.tmp.$$";
    require JSON::PP;
    open my $fh, '>:utf8', $tmp or return 0;
    print {$fh} JSON::PP->new->canonical->pretty->encode($runs);
    unless ( close $fh )       { unlink $tmp; return 0 }
    unless ( rename $tmp, $f ) { unlink $tmp; return 0 }
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
        my $job = $JOBS{$name};
        # SM787: defensive beside the reader's own filter, and cheap. The
        # two together mean a malformed record costs a re-run, never a tick.
        my $last = ( ref $runs->{$name} eq 'HASH' ? $runs->{$name}{last_run} : 0 ) // 0;
        # A last_run in the FUTURE keeps `$now - $last` negative for as long as
        # it says, so the job is silently skipped and nothing reports it. The
        # record is same-uid-writable, so that is reachable; and an occasional
        # harmless re-run is a better failure than a job that never runs and
        # says nothing.
        $last = 0 if $last !~ /\A\d+(?:\.\d+)?\z/ || $last > $now;
        next      if $now - $last < $job->{every};

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

        # A body that returns ok => 0 completed and is reporting that the work
        # could not be done - the stats plugin missing, a file that would not
        # write. Distinct from dying, and carrying its own reason, which the
        # record keeps verbatim: an operator reading it should not have to
        # find the log line to learn which.
        if ( ref $res eq 'HASH' && !$res->{ok} ) {
            my $why = $res->{error} // 'the job reported failure without a reason';
            $runs->{$name} = { last_run => $now, outcome => 'error',
                reason => $why, actor => $user };
            log_event( 'ERROR', 'scheduler', 'job failed',
                job => $name, actor => $user, reason => $why );
            push @done, { job => $name, outcome => 'error', reason => $why };
            next;
        }

        # `detail` is what the job did, in numbers where it has them - the
        # record is the only place an operator can see that a rollup closed a
        # day or a sweep removed nothing.
        $runs->{$name} = { last_run => $now, outcome => 'ok', actor => $user,
            ( ref $res eq 'HASH' && defined $res->{detail}
                ? ( detail => $res->{detail} )
                : () ) };

        # The audit row names the REAL user. Not 'scheduler', not 'system' -
        # so a row written at 03:00 answers the same question as one written by
        # a person at noon: who was this, and what were they allowed to do.
        log_event( 'INFO', 'scheduler', 'job ran',
            job => $name, actor => $user );
        push @done, { job => $name, outcome => 'ok', actor => $user };
    }

    # Nothing due means nothing changed, and a rewrite that changes nothing is
    # a rename per tick per site for no reader (review D4: 300 renames a minute
    # across a 300-site host at the default tick, all of them no-ops).
    _write_runs( $root, $runs ) if @done;
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
