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
use File::Basename qw(dirname);

our $VERSION = '0.1';

# --- stats-rollup -----------------------------------------------------------

# Where the stats plugin lives. The same candidates the manager API tries
# (_tool_path), because the layouts are the same: the repo, the Hestia domain
# root with plugins/ beside public_html, and the packaged /usr/share/lazysite.
# LAZYSITE_STATS_TOOL wins, as it does there, so a test can point at a stub.
sub _stats_tool {
    my ($root) = @_;
    for my $c (
        $ENV{LAZYSITE_STATS_TOOL},
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
