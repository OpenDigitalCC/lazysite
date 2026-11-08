#!/usr/bin/perl
# SM1364 (ruling 191): THE SCHEDULE'S RUN RECORD HAS TWO WRITERS AND ONE LOCK.
#
# The daemon's schedule run and an on-demand refresh both write
# lazysite/daemon/schedule-runs.json. What must hold:
#
# - a write waits for the lock the other writer holds (schedule-runs.json.lock);
# - the daemon merges its own entries into the record as it stands when it
#   writes, so an entry the manager recorded while the daemon was delivering is
#   kept rather than overwritten with the daemon's stale copy;
# - a folder the writer may not write is a failed write it can report (the
#   manager's age_note), never a crash.
#
# With the change reverted there is no lock, the daemon writes back the whole
# record it read before delivering, and the first two subtests fail.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Fcntl      qw(:flock);
use JSON::PP   qw(encode_json decode_json);
use Time::HiRes ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);

BEGIN {
    eval { require HTTP::Daemon; require LWP::UserAgent; 1 }
        or plan skip_all => 'HTTP::Daemon/LWP not available';
}
use Lazysite::Daemon::Jobs        ();
use Lazysite::Manager::Connectors ();

my $d = site_tempdir();
make_path( map {"$d/lazysite/$_"} qw(connectors forms daemon auth logs) );
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub runs {
    open my $fh, '<', "$d/lazysite/daemon/schedule-runs.json" or return {};
    local $/;
    return decode_json(<$fh>);
}
my $lockf = "$d/lazysite/daemon/schedule-runs.json.lock";

subtest 'a writer waits for the lock the other holds' => sub {
    my $ready = "$d/held";
    my $pid   = fork // die "fork: $!";
    if ( !$pid ) {
        open my $lk, '>>', $lockf or exit 1;
        flock $lk, LOCK_EX or exit 1;
        spit( $ready, '1' );
        select undef, undef, undef, 2;
        exit 0;
    }
    my $t = Time::HiRes::time();
    select undef, undef, undef, 0.05 until -e $ready || Time::HiRes::time() - $t > 5;
    my $t0 = Time::HiRes::time();
    ok( Lazysite::Daemon::Jobs::record_schedule_run( $d, 'manual', 1, undef, 100 ), 'the write lands' );
    my $waited = Time::HiRes::time() - $t0;
    waitpid $pid, 0;
    cmp_ok( $waited, '>', 1.2, 'after the other writer let go of the lock' );
    is( runs()->{manual}{last_ok}, 100, 'and is in the record' );
};

# The remote, while the daemon is delivering to it, plays the other writer: it
# records an on-demand refresh of another entry, as the manager would.
my $srv = HTTP::Daemon->new( LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1 ) or die "no daemon: $!";
my $base = $srv->url;
my $pid  = fork // die "fork: $!";
if ( !$pid ) {
    while ( my $conn = $srv->accept ) {
        while ( my $req = $conn->get_request ) {
            Lazysite::Daemon::Jobs::record_schedule_run( $d, 'manual', 1, undef, 4242 );
            my $res = HTTP::Response->new(200);
            $res->header( 'Content-Type' => 'application/json' );
            $res->content('{"ok":true}');
            $conn->send_response($res);
        }
        $conn->close;
    }
    exit 0;
}
END { kill 'TERM', $pid if $pid }

subtest 'the daemon keeps an entry recorded while it delivered' => sub {
    $Lazysite::Manager::Connectors::DOCROOT = $d;
    my $c = Lazysite::Manager::Connectors::action_connector_save( 'pinger',
        { url => "${base}ping", method => 'GET', modes => { scheduled => 1 }, rate_per_hour => 0, timeout => 3 } );
    ok( $c->{ok}, 'a connector' ) or diag explain $c;
    spit( "$d/lazysite/forms/handlers.conf",
        "handlers:\n  - id: ping\n    type: connector\n    name: Ping\n    connector: pinger\n" );
    spit( "$d/lazysite/forms/schedule.conf",
        "schedule:\n  - id: pinging\n    handler: ping\n    every: 300\n    enabled: true\n" );
    my $r = Lazysite::Daemon::Jobs::schedule_run( docroot => $d, caps => { manage_connectors => 1 },
        actor => 'jobs', now => 2_000_000_000 );
    is_deeply( $r->{detail}{ran}, ['pinging'], 'the daemon delivered its entry' ) or diag explain $r;
    my $runs = runs();
    is( $runs->{pinging}{last_ok}, 2_000_000_000, 'its own entry is recorded' );
    is( $runs->{manual}{last_ok}, 4242, 'and the entry written during its delivery is kept' );
};

subtest 'a folder this writer may not write is a failed write, not a crash' => sub {
    plan skip_all => 'running as root: permissions do not refuse' if $> == 0;
    chmod 0555, "$d/lazysite/daemon";
    my $ok = eval { Lazysite::Daemon::Jobs::record_schedule_run( $d, 'manual', 1, undef, 7 ) };
    chmod 0755, "$d/lazysite/daemon";
    ok( !$@, 'no die' ) or diag $@;
    ok( !$ok, 'the write reports that it did not land' );
};

done_testing();
