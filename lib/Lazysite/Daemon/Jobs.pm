package Lazysite::Daemon::Jobs;

# SM666 phase 1, the payoff: the work the scheduler carries.
#
# Each job here is ENGINE CODE the scheduler's closed set names - this module
# holds the bodies, Scheduler.pm's %JOBS holds the set, the schedule and what
# each needs. Nothing in this file decides whether it may run; that is checked
# before it is called, against the job account's capabilities, and a body
# that re-checked would be a second gate that could drift from the first.
#
# WHAT A JOB MAY DO is bounded by what the engine already does for the same
# capability through the manager. stats_rollup runs the stats extension's export,
# which is what the Stats page and analyse_visitors run and what `analytics`
# grants; sessions_sweep applies the session reader's own expiry rule to the
# registry, under `manage_users`, which is the grant that lists and revokes
# sessions. A job invents no new power - it moves existing work off the back
# of a visitor's page view and onto a clock.
#
# THE CONTRACT WITH THE SCHEDULER: a body takes (%ctx) with `docroot` and
# `actor`, returns a hashref { ok => 1, detail => ... } for a run that
# completed, { ok => 0, error => ... } for one that did not, and dies for one
# that broke. `detail` is what the runs record shows an operator, so it says
# what was done in numbers, not adjectives.
use strict;
use warnings;
use File::Basename  qw(dirname);
use Lazysite::Util  ();
use Lazysite::Paths ();
use Lazysite::Extensions ();

our $VERSION = '0.1';

# --- stats-rollup -----------------------------------------------------------

# Where the stats extension lives. The same candidates the manager API tries
# (_tool_path), because the layouts are the same: the repo, the Hestia domain
# root with extensions/ beside public_html, and the packaged /usr/share/lazysite.
#
# SM792: ONLY WHERE A DEPLOY PUTS IT. LAZYSITE_STATS_TOOL used to win here,
# first and unconditionally, so whatever owned the runtime's environment could
# name any script and the scheduler ran it. It was a test seam; the tests now
# put their stub where the real lookup finds it, beside the docroot.
sub _stats_tool {
    my ($root) = @_;
    return Lazysite::Extensions::locate( 'stats.pl', dirname($0) . '/..', "$root/.." );
}

# Close the day without anyone looking (SM343).
#
# The stats export ingests the access log, mirrors the day buckets to the
# durable store, writes a closed day once more after it closes, flushes and
# expires visitor trails, and trims the export cache. Every one of those
# happened only when somebody opened the Stats page or called
# analyse_visitors, so a day file was complete only if nobody had read the
# statistics on that day - SM343's finding - and a site nobody looked at
# accumulated a month of raw log waiting for a reader. On a clock, the
# rollup is complete because it is scheduled, and the reader's page view
# costs a read.
#
# --index rather than the window view: the export does the same work either
# way, and the index is the smallest thing it can print afterwards.
sub stats_rollup {
    my (%ctx) = @_;
    my $root  = $ctx{docroot};
    my $tool  = _stats_tool($root)
        or return { ok => 0, error => 'the stats extension was not found' };

    # List form, no shell; the actor goes in the environment as the manager
    # API sends it, so an extension that reads it sees the same name the audit
    # row carries.
    local $ENV{LAZYSITE_ACTING_USER} = $ctx{actor};
    my $pid = open my $fh, '-|', $^X, $tool, '--export', '--index',
        '--docroot', $root;
    return { ok => 0, error => "cannot run the stats extension: $!" } unless $pid;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $rc = $? >> 8;
    return { ok => 0, error => "the stats extension exited $rc" } if $rc;

    require JSON::PP;
    my $idx = eval { JSON::PP->new->decode( $raw // '' ) };
    return { ok => 0, error => 'the stats extension printed no JSON' }
        unless ref $idx eq 'HASH';

    # "No stats index yet." is not a failure: the export ran and found no
    # traffic to roll up, which is what a new site looks like.
    my $days = ref $idx->{days} eq 'ARRAY' ? scalar @{ $idx->{days} } : 0;
    return { ok => 1, detail => { days_indexed => $days } };
}

# --- sessions-sweep ---------------------------------------------------------

# Expire the session registry on a clock rather than on a login. The rule
# and the reasons are in Lazysite::Manager::Sessions::sweep_expired; this is
# the daemon's call to it, with the module pointed at this site the way the
# manager API points it at the request's.
# SM579: the connector call record, kept honest on the clock.
sub connectors_sweep {
    my (%ctx) = @_;
    require Lazysite::Manager::Connectors;
    my $r = Lazysite::Manager::Connectors::sweep( $ctx{docroot} );
    return $r unless $r->{ok};
    return { ok => 1, kept => $r->{kept}, expired => $r->{expired}, unanswered => $r->{unanswered} };
}

# --- row-history-prune -------------------------------------------------------

# SM1355 (ruling 170): the row history is kept for its table's period (90 days
# by default). The write path prunes after each recorded change, so a store
# nobody writes to kept its expired changes - earlier values of people's rows -
# for as long as nobody wrote. This is the clock making the same call the write
# path makes: RowHistory::prune with RowHistory::period_for, every table the
# history names. A site with no data store has nothing to prune, and the job
# does not create one.
#
# Ruling 175: IT NEEDS ONLY run_jobs. Retention is never refusable by a missing
# grant, and the job reads and changes no current row: it removes only history
# past its period. EACH RUN IS AUDITED - one row, `row-history-prune`, naming
# the tables the history held and how many changes went (or why it failed), so
# a removal nobody asked for is still answerable to who and when.
sub row_history_prune {
    my (%ctx) = @_;
    my $root = $ctx{docroot};
    require Lazysite::Data::Connect;
    require Lazysite::Data::RowHistory;
    my $r = _row_history_prune($root);
    _audit_prune( $root, $ctx{actor}, $r );
    return $r;
}

sub _row_history_prune {
    my ($root) = @_;
    return { ok => 1, detail => { tables => 0, removed => 0, store => 'none' } }
        unless -e Lazysite::Data::Connect::store_path($root);
    my $dbh = Lazysite::Data::Connect::write_handle($root)
        or return { ok => 0, error => 'the data store could not be opened for writing; see the log' };
    my %stat;
    my $n = Lazysite::Data::RowHistory::prune( $dbh, Lazysite::Data::RowHistory::period_for($root), \%stat );
    $dbh->disconnect;
    return { ok => 0, error => 'the row history could not be pruned; see the log' } unless defined $n;
    return { ok => 1, detail => { tables => $stat{tables} // 0, removed => $n } };
}

sub _audit_prune {
    my ( $root, $actor, $r ) = @_;
    my $d = ref $r->{detail} eq 'HASH' ? $r->{detail} : {};
    eval {
        require Lazysite::Audit;
        no warnings 'once';
        local $Lazysite::Audit::LAZYSITE_DIR = Lazysite::Paths::lazysite_dir($root);
        Lazysite::Audit::audit_log( $actor // '', 'row-history-prune', 'row-history', '',
            ( $r->{ok} ? 'ok' : 'failed' ), 'daemon',
            $r->{ok}
            ? 'tables=' . ( $d->{tables} // 0 ) . ' removed=' . ( $d->{removed} // 0 )
            : ( $r->{error} // 'failed' ) );
        1;
    };
    return;
}

# SM842: THE SCHEDULE. Call every entry whose interval has elapsed, through the
# handler it names.
#
# ONE ENGINE JOB, not a job per entry. %JOBS stays the closed literal the
# daemon's security review re-verified: an entry says which handler, how often
# and with what fixed fields, and nothing a site writes can add a job, change
# the job's own interval, or reach the scheduler's identity gate.
#
# THE DESTINATION DECIDES, HERE AS AT SAVE. An entry runs only when the job
# account holds the capability its handler's type needs - asked through
# Lazysite::Handlers::cap_for_type, the same function that gated creating the
# handler. An entry the account may not run is REFUSED, not skipped: the
# refusal is recorded against the entry with its reason and logged when the
# reason changes, and it does not consume the entry's slot, so fixing the grant
# takes effect on the next tick rather than a whole interval later.
#
# A DELIVERY THAT FAILS DOES consume the slot: retrying a remote that is down
# every tick would hammer it. The failure is recorded with its reason, and the
# handler's own audit line says the same.
#
# The outcome names each entry and what happened to it, because a scheduled
# call is the one nobody watches - "3 ran" tells an operator nothing about
# which one has been failing since Tuesday.
sub schedule_run {
    my (%ctx) = @_;
    my $root  = $ctx{docroot};
    my $now   = $ctx{now} // time;
    require Lazysite::Handlers;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $root;

    my $schedule = Lazysite::Handlers::read_schedule();
    return { ok => 0, error => 'lazysite/forms/schedule.conf could not be read; see the log' }
        unless defined $schedule;
    return { ok => 1, detail => { entries => 0 } } unless @$schedule;

    my $runs = _read_schedule_runs($root);
    return { ok => 0, error => 'the schedule run record could not be read; see the log' }
        unless defined $runs;

    # SM1391 (ruling 148): AN ENTRY UNDER THE FLOOR IS REFUSED, ONCE. due_entries
    # passed over a hand-written `every: 60` in silence, and silence is what a
    # job with nothing to do looks like (found at the SM1382 spike). The
    # refusal is recorded against the entry the first time the job meets it,
    # naming the floor, and logged then; a later tick that finds the same
    # refusal already recorded writes nothing, so the record is not rewritten
    # every five minutes for an entry nobody has touched. `lazysite check`
    # names such an entry from the file (report_schedule_floor).
    my ( @floor_refused, @floor_ids );
    for my $e ( @{ Lazysite::Handlers::below_floor_entries($schedule) } ) {
        my $why = "every: " . ( $e->{every} // '' ) . " is below the floor of "
            . "$Lazysite::Handlers::SCHEDULE_FLOOR seconds, so this entry never runs - "
            . 'the save path refuses it; it was written by hand';
        my $prev = ( ref $runs->{ $e->{id} } eq 'HASH' ? $runs->{ $e->{id} }{refusal_reason} : '' ) // '';
        next if $prev eq $why;
        $runs->{ $e->{id} } = { %{ $runs->{ $e->{id} } || {} },
            outcome => 'refused', refused_at => $now, refusal_reason => $why };
        Lazysite::Util::log_event( 'WARN', 'scheduler', 'schedule entry refused',
            entry => $e->{id}, reason => $why );
        push @floor_refused, "$e->{id}: $why";
        push @floor_ids,     $e->{id};
    }

    my $due = Lazysite::Handlers::due_entries( $schedule, $runs, $now );
    unless (@$due) {
        _merge_schedule_runs( $root, $runs, @floor_ids ) if @floor_ids;
        return { ok => 1, detail => { entries => scalar @$schedule, due => 0,
                ( @floor_refused ? ( refused => \@floor_refused ) : () ) } };
    }

    my $handlers = Lazysite::Handlers::read_handlers();
    return { ok => 0, error => 'lazysite/forms/handlers.conf could not be read; see the log' }
        unless defined $handlers;

    my ( @ran, @failed, @refused ) = ( (), (), @floor_refused );
    for my $e (@$due) {
        my $h   = Lazysite::Handlers::find_handler( $handlers, $e->{handler} // '' );
        my $cap = $h ? Lazysite::Handlers::cap_for_type( $h->{type} ) : undef;
        my $why
            = !$h ? "no handler '" . ( $e->{handler} // '' ) . "'"
            : !$cap ? "handler '$h->{id}' is a '$h->{type}' handler, which no longer delivers"
            : !( $ctx{caps} || {} )->{$cap} ? "the job account '$ctx{actor}' does not hold $cap"
            :                                 '';
        if ( length $why ) {
            my $prev = ( ref $runs->{ $e->{id} } eq 'HASH' ? $runs->{ $e->{id} }{refusal_reason} : '' ) // '';
            $runs->{ $e->{id} } = { %{ $runs->{ $e->{id} } || {} },
                outcome => 'refused', refused_at => $now, refusal_reason => $why };
            Lazysite::Util::log_event( 'WARN', 'scheduler', 'schedule entry refused',
                entry => $e->{id}, reason => $why ) unless $prev eq $why;
            push @refused, "$e->{id}: $why";
            next;
        }
        my $r = Lazysite::Handlers::deliver( $h->{id}, { %{ $e->{payload} || {} } },
            origin => 'timer',     source   => "timer:$e->{id}", store => $e->{id},
            actor  => $ctx{actor}, handlers => $handlers );
        $runs->{ $e->{id} } = _run_outcome( $runs->{ $e->{id} }, $now, $r->{ok}, $r->{why} );
        if   ( $r->{ok} ) { push @ran,    $e->{id} }
        else              { push @failed, "$e->{id}: " . ( $r->{why} // 'failed' ) }
    }
    _merge_schedule_runs( $root, $runs, @floor_ids, map { $_->{id} } @$due );

    # NOT ok => 0 when an entry fails. The job DID what it was for; a remote
    # that is down is a fact about that entry, recorded here and in the audit
    # trail, and failing the whole job would put the scheduler into a retry
    # loop over somebody else's outage.
    return { ok => 1, detail => { due => scalar @$due, ran => \@ran, failed => \@failed,
            refused => \@refused } };
}

# When each schedule entry last ran - the job's own record, beside the
# scheduler's, so due-ness survives a restart. SM766: a record that exists and
# cannot be opened is not an empty record; treating it as one would run every
# entry at once on every tick.
sub _schedule_runs_file { return Lazysite::Paths::lazysite_dir( $_[0] ) . "/daemon/schedule-runs.json" }

# One entry's record after a run. SM1364: `last_ok` is when it last delivered,
# carried across a failure - a sourced table's rows are as old as its last good
# refresh, and a record that kept only the latest outcome would forget that the
# moment a refresh failed.
sub _run_outcome {
    my ( $prev, $now, $ok, $why ) = @_;
    my $last_ok = $ok ? $now : ( ref $prev eq 'HASH' ? $prev->{last_ok} : undef );
    return { last_run => $now, outcome => ( $ok ? 'ok' : 'failed' ),
        ( $ok              ? ()                      : ( reason => $why // 'failed' ) ),
        ( defined $last_ok ? ( last_ok => $last_ok ) : () ) };
}

# SM1364: one entry's run record, for the surfaces that say how old a sourced
# table is. undef when the record cannot be read (logged by the reader), {} when
# the entry has never run.
sub schedule_run_record {
    my ( $root, $id ) = @_;
    my $runs = _read_schedule_runs($root);
    return undef unless defined $runs;
    return ref $runs->{$id} eq 'HASH' ? { %{ $runs->{$id} } } : {};
}

# SM1364: an on-demand refresh is the schedule entry's run, recorded as one, so
# the table's age says when it was last refreshed by either. Returns 1, or 0
# when the record could not be read or written - the refresh stands either way.
sub record_schedule_run {
    my ( $root, $id, $ok, $why, $now ) = @_;
    return _locked_runs_update( $root,
        sub { $_[0]{$id} = _run_outcome( $_[0]{$id}, $now // time, $ok, $why ) } );
}

# SM1364 (ruling 191): TWO WRITERS, ONE LOCK. The daemon's schedule run and an
# on-demand refresh (the manager, MCP) both write schedule-runs.json. The daemon
# reads the record before its deliveries, which call remotes and take seconds;
# holding a lock across them would stall every on-demand refresh behind the
# slowest remote. So each writer takes the lock only for a read-modify-write of
# the entries it changed: the daemon merges its entries into the record as it
# stands when it writes, and leaves an entry the manager refreshed meanwhile
# alone. A lock file that cannot be opened (a folder this user may not write)
# is logged and the write is tried without it, as before the lock existed: the
# daemon must keep recording, and a manager that cannot write the folder fails
# at the write and says so (Manager::Data's age_note).
sub _locked_runs_update {
    my ( $root, $edit ) = @_;
    my $f = _schedule_runs_file($root);
    require File::Path;
    File::Path::make_path( dirname($f) ) unless -d dirname($f);
    require Fcntl;
    my $lk;
    if ( open $lk, '>>', "$f.lock" ) {
        flock( $lk, Fcntl::LOCK_EX() ) or undef $lk;
    }
    else {
        undef $lk;
    }
    Lazysite::Util::log_event( 'WARN', 'scheduler', 'schedule run record written without its lock',
        lock => 'daemon/schedule-runs.json.lock', error => "$!" )
        unless $lk;
    my $runs = _read_schedule_runs($root);
    my $ok   = 0;
    if ( defined $runs ) {
        $edit->($runs);
        $ok = _write_schedule_runs( $root, $runs );
    }
    close $lk if $lk;
    return $ok;
}

# The daemon's write: its own entries, merged into the record as it stands now.
sub _merge_schedule_runs {
    my ( $root, $runs, @ids ) = @_;
    my %seen;
    @ids = grep { !$seen{$_}++ } @ids;
    return _locked_runs_update( $root,
        sub { for my $id (@ids) { $_[0]{$id} = $runs->{$id} if exists $runs->{$id} } } );
}

sub _read_schedule_runs {
    my ($root) = @_;
    my $f = _schedule_runs_file($root);
    open my $fh, '<:utf8', $f or return $!{ENOENT} ? {} : Lazysite::Util::cannot_read( 'schedule run record', $f );
    my $raw = do { local $/; <$fh> };
    close $fh;
    require JSON::PP;
    my $d = eval { JSON::PP->new->decode( $raw // '' ) };
    return {} unless ref $d eq 'HASH';    # torn or hand-edited: every entry is due, once
    delete $d->{$_} for grep { ref $d->{$_} ne 'HASH' } keys %$d;
    return $d;
}

sub _write_schedule_runs {
    my ( $root, $runs ) = @_;
    my $f   = _schedule_runs_file($root);
    my $tmp = "$f.tmp.$$";
    require File::Path;
    File::Path::make_path( dirname($f) ) unless -d dirname($f);
    require JSON::PP;
    open my $fh, '>:utf8', $tmp or return 0;
    print {$fh} JSON::PP->new->canonical->pretty->encode($runs);
    unless ( close $fh )       { unlink $tmp; return 0 }
    unless ( rename $tmp, $f ) { unlink $tmp; return 0 }
    return 1;
}

# SM1020: the notification outbox. The body is Lazysite::Outbox::run, which
# resolves, caps, sends once each and audits; this is the daemon's call to it.
sub notify_outbox {
    my (%ctx) = @_;
    require Lazysite::Outbox;
    return Lazysite::Outbox::run( docroot => $ctx{docroot}, actor => $ctx{actor}, now => $ctx{now} );
}

sub sessions_sweep {
    my (%ctx) = @_;
    require Lazysite::Manager::Sessions;

    # `no warnings 'once'` for the same reason Supervisor gives: the module is
    # required at runtime, so its globals are not visible at compile time
    # and Perl reads the assignment as a possible typo. Localised, so nothing
    # else in the process inherits this site.
    no warnings 'once';
    local $Lazysite::Manager::Sessions::LAZYSITE_DIR = "$ctx{docroot}/lazysite";
    local $Lazysite::Manager::Sessions::auth_user    = $ctx{actor};
    my $r = Lazysite::Manager::Sessions::sweep_expired();
    return $r unless $r->{ok};
    return {
        ok     => 1,
        detail => {
            removed            => $r->{removed},
            kept               => $r->{kept},
            revocations_pruned => $r->{revocations_pruned},
        },
    };
}

# --- schedule-exceptions ------------------------------------------------------

# SM1356 (ruling 164): remove the schedule exceptions whose dates have passed,
# each recorded in the audit trail with the exception it removed. The rule and
# its condition (no removal with the trail off) are in
# Lazysite::Data::Schedule::sweep_passed; this is the clock calling it, under
# manage_data, the grant that deletes a row.
sub schedule_exceptions {
    my (%ctx) = @_;
    require Lazysite::Data::Schedule;
    my $r = Lazysite::Data::Schedule::sweep_passed( $ctx{docroot}, actor => $ctx{actor}, now => $ctx{now} );
    return $r unless $r->{ok};
    return {
        ok     => 1,
        detail => {
            removed => $r->{removed},
            kept    => $r->{kept},
            tables  => $r->{tables},
            ( $r->{reason} ? ( reason => $r->{reason} ) : () ),
        },
    };
}

1;
