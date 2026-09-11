#!/usr/bin/perl
# SM842: THE TIMER CALLS HANDLERS.
#
# One engine job, schedule-run, calls every due entry of the site's schedule
# through the handler it names - the same Lazysite::Handlers::deliver a form
# calls. What it must hold:
#
# - the job account runs an entry only when it holds the capability of that
#   entry's handler's DESTINATION - the same cap_for_type that gated creating
#   the handler - and an entry it may not run is REFUSED by name, not skipped
# - a refusal does not consume the entry's slot: fixing the grant takes effect
#   on the next tick, not a whole interval later (the scheduler's own rule)
# - a delivery that fails does consume it, so a remote that is down is not
#   hammered every tick
# - a delivered entry carries its fixed payload and nothing else
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use JSON::PP ();
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                           qw(grant_caps add_account site_tempdir);
use Lazysite::Daemon::Service::Scheduler ();

sub site {
    my $d = site_tempdir();
    make_path( map { "$d/lazysite/$_" } qw(auth daemon logs cache forms) );
    return $d;
}

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

sub by_job { return { map { $_->{job} => $_ } @{ $_[0] } } }

my $root = site();
add_account( $root, 'jobs' );
grant_caps( $root, 'jobs', qw(run_jobs) );
spit( "$root/lazysite/daemon.conf", "daemon_tick_seconds: 60\ndaemon_job_user: jobs\n" );
spit( "$root/lazysite/forms/handlers.conf",
    "handlers:\n  - id: store\n    type: file\n    name: Store\n    path: lazysite/forms/timer\n" );
spit( "$root/lazysite/forms/schedule.conf",
    "schedule:\n  - id: nightly\n    handler: store\n    every: 3600\n    enabled: true\n"
        . "    payload: {\"kind\":\"ping\"}\n" );

my $store = "$root/lazysite/forms/timer/nightly.jsonl";

subtest 'an entry the job account may not run is refused by name, and keeps its slot' => sub {
    my $done = by_job( Lazysite::Daemon::Service::Scheduler::tick( docroot => $root ) );
    is( $done->{'schedule-run'}{outcome}, 'ok', 'the job itself ran' );
    my $runs = JSON::PP::decode_json( slurp("$root/lazysite/daemon/schedule-runs.json") );
    is( $runs->{nightly}{outcome}, 'refused', 'the entry was refused' );
    like( $runs->{nightly}{refusal_reason}, qr/does not hold manage_forms/,
        'naming the destination capability the account lacks' );
    ok( !$runs->{nightly}{last_run}, 'and the refusal did not consume the slot' );
    ok( !-e $store,                  'nothing was delivered' );
};

subtest 'granted, it runs on the next tick, with its payload' => sub {
    grant_caps( $root, 'jobs', qw(run_jobs manage_forms) );
    # The scheduler's own record says the job ran a moment ago; clear it so the
    # job is due again now rather than in five minutes.
    unlink "$root/lazysite/daemon/scheduler-runs.json";
    Lazysite::Daemon::Service::Scheduler::tick( docroot => $root );
    ok( -e $store, 'the entry delivered through its handler' );
    my $rec = JSON::PP::decode_json( ( split /\n/, slurp($store) )[0] );
    is( $rec->{kind},    'ping',          'carrying its fixed payload' );
    is( $rec->{_source}, 'timer:nightly', 'and saying where it came from' );
    my $runs = JSON::PP::decode_json( slurp("$root/lazysite/daemon/schedule-runs.json") );
    is( $runs->{nightly}{outcome}, 'ok', 'recorded as run' );
    ok( $runs->{nightly}{last_run}, 'with when' );
    like( slurp("$root/lazysite/logs/audit.log") // '',
        qr/\| jobs \| deliver \| timer:nightly -> store \|  \| ok \| timer/,
        'and audited as the job account' );

    unlink "$root/lazysite/daemon/scheduler-runs.json";
    Lazysite::Daemon::Service::Scheduler::tick( docroot => $root );
    my @lines = grep { /\S/ } split /\n/, slurp($store);
    is( scalar @lines, 1, 'the next tick inside the interval does not run it again' );
};

subtest 'a failed delivery consumes the slot' => sub {
    spit( "$root/lazysite/forms/schedule.conf",
        "schedule:\n  - id: broken\n    handler: gone\n    every: 3600\n" );
    unlink "$root/lazysite/daemon/scheduler-runs.json";
    Lazysite::Daemon::Service::Scheduler::tick( docroot => $root );
    my $runs = JSON::PP::decode_json( slurp("$root/lazysite/daemon/schedule-runs.json") );
    is( $runs->{broken}{outcome}, 'refused', 'an entry naming no handler is refused' );
    like( $runs->{broken}{refusal_reason}, qr/no handler 'gone'/, 'by name' );

    spit( "$root/lazysite/forms/handlers.conf",
        "handlers:\n  - id: gone\n    type: file\n    name: G\n    enabled: false\n" );
    unlink "$root/lazysite/daemon/scheduler-runs.json";
    Lazysite::Daemon::Service::Scheduler::tick( docroot => $root );
    $runs = JSON::PP::decode_json( slurp("$root/lazysite/daemon/schedule-runs.json") );
    is( $runs->{broken}{outcome}, 'failed', 'a handler that does not deliver is a failed run' );
    like( $runs->{broken}{reason}, qr/switched off/, 'with its reason' );
    ok( $runs->{broken}{last_run}, 'and it consumed the slot, so it is not retried every tick' );
};

done_testing();
