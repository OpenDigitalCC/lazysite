#!/usr/bin/perl
# SM1391 (ruling 148): a schedule entry whose interval is under the 300-second
# floor is recorded as refused, once.
#
# The save path refuses such an entry, so one exists only when it was written
# into schedule.conf by hand - and the scheduler passed over it in silence,
# which is what a job with nothing to do looks like (found at the SM1382
# spike). Now: the first tick that meets it records a refusal against the
# entry, naming the floor, and logs it; a later tick that finds the same
# refusal recorded writes nothing; and an entry raised to the floor runs.
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

my $root = site_tempdir();
make_path( map { "$root/lazysite/$_" } qw(auth daemon logs cache forms) );
sub spit  { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

add_account( $root, 'jobs' );
grant_caps( $root, 'jobs', qw(run_jobs manage_forms) );
spit( "$root/lazysite/daemon.conf", "daemon_tick_seconds: 60\ndaemon_job_user: jobs\n" );
spit( "$root/lazysite/forms/handlers.conf",
    "handlers:\n  - id: store\n    type: file\n    name: Store\n    path: lazysite/forms/timer\n" );
sub schedule { my ($every) = @_; spit( "$root/lazysite/forms/schedule.conf",
        "schedule:\n  - id: hand\n    handler: store\n    every: $every\n    enabled: true\n    payload: {\"k\":\"v\"}\n" ) }

my $runs_file = "$root/lazysite/daemon/schedule-runs.json";
# log_event writes to STDERR - the web server's or the daemon's error log - so
# the test's own STDERR is the log it reads back.
my $log = "$root/lazysite/logs/stderr.log";
open STDERR, '>>', $log or die "$log: $!";
sub tick { unlink "$root/lazysite/daemon/scheduler-runs.json"; return Lazysite::Daemon::Service::Scheduler::tick( docroot => $root, now => $_[0] ) }
sub runs { return JSON::PP::decode_json( slurp($runs_file) || '{}' ) }
sub refusal_lines { return scalar grep { /schedule entry refused/ && /entry=hand/ } split /\n/, slurp($log) }

my $T = 1_700_000_000;
schedule(60);

subtest 'the first tick records the refusal, naming the floor' => sub {
    my ($sr) = grep { $_->{job} eq 'schedule-run' } @{ tick($T) };
    is( $sr->{outcome}, 'ok', 'the job itself ran' );
    my $r = runs();
    is( $r->{hand}{outcome}, 'refused', 'the entry is recorded as refused' ) or diag explain $r;
    like( $r->{hand}{refusal_reason}, qr/every: 60 is below the floor of 300 seconds/, 'naming the floor' );
    like( $r->{hand}{refusal_reason}, qr/written by hand/, 'and how it got there' );
    is( $r->{hand}{refused_at}, $T, 'when' );
    ok( !$r->{hand}{last_run}, 'and it did not run' );
    ok( !-e "$root/lazysite/forms/timer/hand.jsonl", 'nothing was delivered' );
    is( refusal_lines(), 1, 'logged once' );
};

subtest 'the next tick writes nothing new' => sub {
    my $before = slurp($runs_file);
    tick( $T + 300 );
    is( slurp($runs_file), $before, 'the record is unchanged - refused_at stays at the first tick' );
    is( refusal_lines(), 1, 'and nothing more is logged' );
};

subtest 'raised to the floor, it runs' => sub {
    schedule(300);
    tick( $T + 600 );
    my $r = runs();
    is( $r->{hand}{outcome}, 'ok', 'recorded as run' ) or diag explain $r;
    is( $r->{hand}{last_run}, $T + 600, 'at this tick' );
    ok( -e "$root/lazysite/forms/timer/hand.jsonl", 'and delivered' );
};

done_testing();
