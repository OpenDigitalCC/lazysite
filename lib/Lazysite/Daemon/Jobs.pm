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
# capability through the manager. stats_rollup runs the stats plugin's export,
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

our $VERSION = '0.1';

# --- stats-rollup -----------------------------------------------------------

# Where the stats plugin lives. The same candidates the manager API tries
# (_tool_path), because the layouts are the same: the repo, the Hestia domain
# root with plugins/ beside public_html, and the packaged /usr/share/lazysite.
#
# SM792: ONLY WHERE A DEPLOY PUTS IT. LAZYSITE_STATS_TOOL used to win here,
# first and unconditionally, so whatever owned the runtime's environment could
# name any script and the scheduler ran it. It was a test seam; the tests now
# put their stub where the real lookup finds it, beside the docroot.
sub _stats_tool {
    my ($root) = @_;
    for my $c (
        dirname($0) . '/../plugins/stats.pl',
        "$root/../plugins/stats.pl",
        '/usr/share/lazysite/plugins/stats.pl',
        )
    {
        return $c if defined $c && -f $c;
    }
    return undef;
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
        or return { ok => 0, error => 'the stats plugin was not found' };

    # List form, no shell; the actor goes in the environment as the manager
    # API sends it, so a plugin that reads it sees the same name the audit
    # row carries.
    local $ENV{LAZYSITE_ACTING_USER} = $ctx{actor};
    my $pid = open my $fh, '-|', $^X, $tool, '--export', '--index',
        '--docroot', $root;
    return { ok => 0, error => "cannot run the stats plugin: $!" } unless $pid;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $rc = $? >> 8;
    return { ok => 0, error => "the stats plugin exited $rc" } if $rc;

    require JSON::PP;
    my $idx = eval { JSON::PP->new->decode( $raw // '' ) };
    return { ok => 0, error => 'the stats plugin printed no JSON' }
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
    my $due = Lazysite::Handlers::due_entries( $schedule, $runs, $now );
    return { ok => 1, detail => { entries => scalar @$schedule, due => 0 } } unless @$due;

    my $handlers = Lazysite::Handlers::read_handlers();
    return { ok => 0, error => 'lazysite/forms/handlers.conf could not be read; see the log' }
        unless defined $handlers;

    my ( @ran, @failed, @refused );
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
        $runs->{ $e->{id} } = { last_run => $now, outcome => ( $r->{ok} ? 'ok' : 'failed' ),
            ( $r->{ok} ? () : ( reason => $r->{why} // 'failed' ) ) };
        if   ( $r->{ok} ) { push @ran,    $e->{id} }
        else              { push @failed, "$e->{id}: " . ( $r->{why} // 'failed' ) }
    }
    _write_schedule_runs( $root, $runs );

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

1;
