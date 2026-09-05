#!/usr/bin/perl
# SM666, 0.13.1: the scheduler carries real work, and each job costs what the
# same work costs through the manager.
#
# 0.13.0 shipped a heartbeat and said so: the machinery was the point, and a
# second job would have proved none of it twice. This file is the second job,
# and the third, and what they must hold:
#
# - the set is still closed and still small, and every real job names a
#   capability that EXISTS and is the one the manager asks for the same work
#   (a job needing less than the manager would be the scheduled-work exemption)
# - a job account holding run_jobs but not the job's capability is refused
#   BY NAME of the missing capability, and the refusal does not consume the slot
# - the sessions sweep applies the reader's rule and no other: rows older than
#   the session lifetime go, fresh rows stay byte-for-byte, and the revocation
#   list ages out with it
# - the stats rollup runs the plugin the way the manager does - list form,
#   --export, the actor in the environment - and against the REAL plugin
#   closes yesterday without anyone reading the statistics (SM343)
# - a job that reports failure is recorded with its reason, distinct from one
#   that died
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use JSON::PP ();
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                           qw(grant_caps repo_root);
use Lazysite::Daemon::Service::Scheduler ();
use Lazysite::Auth::Settings             qw(@CAP_KEYS);

my $ROOT = repo_root();

sub site {

    # One level down, so the docroot's PARENT is ours too. The stats tool is
    # looked for at ../plugins/stats.pl beside the docroot (the Hestia
    # layout), and a bare tempdir's parent is /tmp - where another test's
    # leaked install can leave a plugins/ that makes 'not found' unreachable.
    my $t = tempdir( CLEANUP => 1 );
    mkdir "$t/site";
    my $d = "$t/site/public_html";
    mkdir $d;
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    mkdir "$d/lazysite/daemon";
    mkdir "$d/lazysite/logs";
    mkdir "$d/lazysite/cache";
    return $d;
}

sub set_job_user {
    my ( $root, $user ) = @_;
    open my $fh, '>', "$root/lazysite/daemon.conf" or die $!;
    print {$fh} "daemon_tick_seconds: 60\ndaemon_job_user: $user\n";
    close $fh;
    return;
}

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

sub by_job {
    my ($done) = @_;
    return { map { $_->{job} => $_ } @$done };
}

my %JOBS = %{ Lazysite::Daemon::Service::Scheduler::jobs() };

subtest 'the set: closed, small, and every need is a real capability' => sub {
    is_deeply( [ sort keys %JOBS ],
        [qw(daemon-heartbeat sessions-sweep stats-rollup)],
        'three jobs, named' );

    my %cap = map { $_ => 1 } @CAP_KEYS;
    for my $name ( sort keys %JOBS ) {
        my $needs = $JOBS{$name}{needs};
        next unless defined $needs;
        ok( $cap{$needs}, "$name needs '$needs', which is a capability that exists" );
    }
    ok( !defined $JOBS{'daemon-heartbeat'}{needs}, 'the heartbeat needs nothing' );
};

subtest 'each need is the capability the manager charges for the same work' => sub {
    # Read from the manager API's own gate table rather than restating it:
    # if the manager moves analyse_visitors to another capability, this test
    # is what says the scheduler must move with it.
    my $api = slurp("$ROOT/lazysite-manager-api.pl");
    my ($gate) = $api =~ /'analyse_visitors'\s*=>\s*'(\w+)'/;
    is( $JOBS{'stats-rollup'}{needs}, $gate,
        "stats-rollup needs what analyse_visitors is gated on ($gate)" );

    like( $api,
        qr/'sessions-list'.*?\n(?:.*\n){0,12}?.*?_user_caps\(\$auth_user\)->\{(\w+)\}/,
        'found the sessions gate' );
    my ($sgate) = $api =~ /'sessions-list'.*?\n(?:.*\n){0,12}?.*?_user_caps\(\$auth_user\)->\{(\w+)\}/;
    is( $JOBS{'sessions-sweep'}{needs}, $sgate,
        "sessions-sweep needs what sessions-list is gated on ($sgate)" );
};

subtest 'run_jobs alone runs the heartbeat and is refused the rest, by name' => sub {
    my $root = site();
    grant_caps( $root, 'jobs-thin', qw(run_jobs) );
    set_job_user( $root, 'jobs-thin' );

    my $r = by_job( Lazysite::Daemon::Service::Scheduler::tick( docroot => $root ) );
    is( $r->{'daemon-heartbeat'}{outcome}, 'ok',      'heartbeat: ok' );
    is( $r->{'stats-rollup'}{outcome},     'refused', 'stats-rollup: refused' );
    like( $r->{'stats-rollup'}{reason}, qr/analytics/,
        'and the refusal names the capability that is missing' );
    is( $r->{'sessions-sweep'}{outcome}, 'refused', 'sessions-sweep: refused' );
    like( $r->{'sessions-sweep'}{reason}, qr/manage_users/, 'by name' );

    # Grant it, tick again with no time passing: the refusal did not consume
    # the slot (the 0.13.0 rule, now holding for a per-job refusal too).
    grant_caps( $root, 'jobs-thin', qw(run_jobs manage_users) );
    my $r2 = by_job( Lazysite::Daemon::Service::Scheduler::tick( docroot => $root ) );
    is( $r2->{'sessions-sweep'}{outcome}, 'ok',
        'granted, the sweep runs on the next tick without waiting an interval' );
    is( $r2->{'sessions-sweep'}{actor}, 'jobs-thin', 'as the job account' );
};

subtest 'sessions-sweep: the reader\'s rule, applied on a clock' => sub {
    my $root = site();
    grant_caps( $root, 'jobs-users', qw(run_jobs manage_users) );
    set_job_user( $root, 'jobs-users' );

    # Default session lifetime is what Lazysite::Auth::Session reads from an
    # absent lazysite.conf; ask it rather than assume 24h.
    require Lazysite::Auth::Session;
    my $life = Lazysite::Auth::Session::session_lifetime("$root/lazysite");
    ok( $life > 0, "session lifetime resolves ($life s)" );

    my $now   = time;
    my $fresh = JSON::PP::encode_json(
        { sid => 'a' x 16, user => 'ann', t => $now - 60, ip => '203.0.113.5', ua => 'x' } ) . "\n";
    my @stale = map {
        JSON::PP::encode_json(
            { sid => $_ x 16, user => 'bob', t => $now - $life - 100, ip => '203.0.113.6', ua => 'y' } ) . "\n"
    } qw(b c);
    open my $fh, '>:raw', "$root/lazysite/auth/sessions.jsonl" or die $!;
    print {$fh} $stale[0], $fresh, $stale[1];
    close $fh;

    open my $rv, '>:raw', "$root/lazysite/auth/revoked.json" or die $!;
    print {$rv} JSON::PP::encode_json( {
            sids       => { 'd' x 16 => $now - $life - 5, 'e' x 16 => $now - 5 },
            not_before => { old      => $now - $life - 5 },
    } );
    close $rv;

    my $r = by_job( Lazysite::Daemon::Service::Scheduler::tick( docroot => $root ) );
    is( $r->{'sessions-sweep'}{outcome}, 'ok', 'the sweep ran' ) or diag explain $r;

    is( slurp("$root/lazysite/auth/sessions.jsonl"), $fresh,
        'the registry now holds exactly the fresh row, byte for byte' );

    my $rev = JSON::PP::decode_json( slurp("$root/lazysite/auth/revoked.json") );
    is_deeply( [ sort keys %{ $rev->{sids} } ], [ 'e' x 16 ],
        'the expired revocation is gone, the live one kept' );
    is_deeply( $rev->{not_before}, {}, 'and the expired not_before' );

    # The record says what was done, in numbers.
    my $runs = JSON::PP::decode_json( slurp("$root/lazysite/daemon/scheduler-runs.json") );
    is_deeply( $runs->{'sessions-sweep'}{detail},
        { removed => 2, kept => 1, revocations_pruned => 2 },
        'the run record carries the counts' );
    is( $runs->{'sessions-sweep'}{actor}, 'jobs-users', 'and names the actor' );

    # A second sweep with nothing to do must not touch the files.
    my $mt1 = ( stat "$root/lazysite/auth/revoked.json" )[9];
    utime $mt1 - 10, $mt1 - 10, "$root/lazysite/auth/revoked.json",
        "$root/lazysite/auth/sessions.jsonl";
    delete $runs->{'sessions-sweep'};
    open my $w, '>', "$root/lazysite/daemon/scheduler-runs.json" or die $!;
    print {$w} JSON::PP::encode_json($runs);
    close $w;
    Lazysite::Daemon::Service::Scheduler::tick( docroot => $root );
    is( ( stat "$root/lazysite/auth/revoked.json" )[9], $mt1 - 10,
        'nothing to prune: revoked.json is not rewritten' );
    is( ( stat "$root/lazysite/auth/sessions.jsonl" )[9], $mt1 - 10,
        'nothing to remove: the registry is not rewritten' );
};

subtest 'stats-rollup: runs the plugin the way the manager does' => sub {
    my $root = site();
    grant_caps( $root, 'jobs-stats', qw(run_jobs analytics) );
    set_job_user( $root, 'jobs-stats' );

    # A stub in the plugin's place records how it was called and answers as
    # the real one does. What the job passes is the contract with the plugin.
    my $stub = "$root/stub-stats.pl";
    open my $fh, '>', $stub or die $!;
    print {$fh} <<'STUB';
use strict; use warnings;
open my $o, '>', "$ENV{STUB_RECORD}" or die $!;
print {$o} join("\n", @ARGV), "\n--\n", ($ENV{LAZYSITE_ACTING_USER} // ''), "\n";
close $o;
print '{"ok":true,"days":[{"date":"2026-09-01"},{"date":"2026-09-02"}]}';
STUB
    close $fh;

    local $ENV{LAZYSITE_STATS_TOOL} = $stub;
    local $ENV{STUB_RECORD}         = "$root/stub-record.txt";
    my $r = by_job( Lazysite::Daemon::Service::Scheduler::tick( docroot => $root ) );
    is( $r->{'stats-rollup'}{outcome}, 'ok', 'the rollup ran' ) or diag explain $r;

    my $rec = slurp("$root/stub-record.txt") // '';
    my ( $argv, $actor ) = split /\n--\n/, $rec;
    is_deeply( [ split /\n/, $argv ], [ '--export', '--index', '--docroot', $root ],
        'called with --export --index --docroot ROOT, as arguments not a shell string' );
    chomp $actor;
    is( $actor, 'jobs-stats',
        'LAZYSITE_ACTING_USER carries the job account, as the manager API sends it' );

    my $runs = JSON::PP::decode_json( slurp("$root/lazysite/daemon/scheduler-runs.json") );
    is_deeply( $runs->{'stats-rollup'}{detail}, { days_indexed => 2 },
        'the record says how many days the index holds' );
};

subtest 'stats-rollup: against the real plugin, yesterday closes unread' => sub {
    # SM343's finding was that a day file was complete only if nobody read the
    # statistics that day. Here nobody reads anything: one hit yesterday, one
    # tick, and the day file exists.
    my $root = site();
    grant_caps( $root, 'jobs-stats', qw(run_jobs analytics) );
    set_job_user( $root, 'jobs-stats' );

    my $yday = time - 86400;
    my @ymd  = ( gmtime $yday )[ 5, 4, 3 ];
    my $file = sprintf 'access-%04d%02d%02d.jsonl', $ymd[0] + 1900, $ymd[1] + 1, $ymd[2];
    my $day  = sprintf '%04d-%02d-%02d',            $ymd[0] + 1900, $ymd[1] + 1, $ymd[2];
    open my $fh, '>', "$root/lazysite/logs/$file" or die $!;
    print {$fh} JSON::PP::encode_json(
        { t => $yday, ip => '203.0.113.9', m => 'GET', p => 'https://gh.072103.xyz/', s => 200, ua => 'Mozilla/5.0', r => '' } ),
        "\n";
    close $fh;

    local $ENV{LAZYSITE_STATS_TOOL} = "$ROOT/plugins/stats.pl";
    my $r = by_job( Lazysite::Daemon::Service::Scheduler::tick( docroot => $root ) );
    is( $r->{'stats-rollup'}{outcome}, 'ok', 'the real plugin ran under the job' )
        or diag explain $r;
    ok( -f "$root/lazysite/stats/daily/$day.json",
        "yesterday's durable day file exists without anyone opening the Stats page" );
    ok( -f "$root/lazysite/stats/index.json", 'and the index' );
};

subtest 'a job that reports failure is recorded with its reason' => sub {
    my $root = site();
    grant_caps( $root, 'jobs-stats', qw(run_jobs analytics) );
    set_job_user( $root, 'jobs-stats' );

    my $stub = "$root/exit3.pl";
    open my $fh, '>', $stub or die $!;
    print {$fh} "exit 3;\n";
    close $fh;

    local $ENV{LAZYSITE_STATS_TOOL} = $stub;
    my $r = by_job( Lazysite::Daemon::Service::Scheduler::tick( docroot => $root ) );
    is( $r->{'stats-rollup'}{outcome}, 'error', 'a plugin that exits non-zero is an error' );
    like( $r->{'stats-rollup'}{reason}, qr/exited 3/, 'with the exit status in the reason' );

    my $runs = JSON::PP::decode_json( slurp("$root/lazysite/daemon/scheduler-runs.json") );
    like( $runs->{'stats-rollup'}{reason}, qr/exited 3/, 'kept verbatim in the record' );
    ok( $runs->{'stats-rollup'}{last_run},
        'and unlike a refusal, a failed RUN holds its slot - retrying a failing '
            . 'job every tick would hammer it' );

    # No plugin at all: the failure names that, rather than "exited 2" or a
    # shell error.
    local $ENV{LAZYSITE_STATS_TOOL} = "$root/does-not-exist.pl";
    delete $runs->{'stats-rollup'};
    open my $w, '>', "$root/lazysite/daemon/scheduler-runs.json" or die $!;
    print {$w} JSON::PP::encode_json($runs);
    close $w;
    local $0 = "$root/nowhere/lazysited.pl";    # so the sibling lookup misses too
    my $r2 = by_job( Lazysite::Daemon::Service::Scheduler::tick( docroot => $root ) );
    is( $r2->{'stats-rollup'}{outcome}, 'error', 'no plugin: error' );
    like( $r2->{'stats-rollup'}{reason}, qr/not found/, 'saying it was not found' );
};

subtest 'the runs record is written atomically' => sub {
    # A truncate-in-place write leaves a torn file on a crash, and a torn
    # record reads as empty - every job runs again at once. Temp and rename
    # means the file on disk is always a complete one.
    my $src = slurp("$ROOT/lib/Lazysite/Daemon/Service/Scheduler.pm");
    my ($write) = $src =~ /(sub _write_runs \{.*?\n\})/s;
    ok( $write, 'found _write_runs' ) or return;
    like( $write, qr/\.tmp\.\$\$/,             'writes to a temp file' );
    like( $write, qr/rename \$tmp, \$f/,       'and renames it into place' );
    like( $write, qr/unless \( close \$fh \)/, 'with the close checked' );
};

done_testing();
