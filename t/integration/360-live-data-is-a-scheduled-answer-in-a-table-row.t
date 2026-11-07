#!/usr/bin/perl
# SM1382 (ruling 132, B): THE LIVE-DATA CHAIN, END TO END, AS THE DOCS CLAIM IT.
#
#   schedule (interval, run_jobs account)
#     -> connector handler (the one way out over HTTP)
#     -> a remote source (a JSON server this test starts on 127.0.0.1)
#     -> the answer lands in a data-table row
#     -> a page binds db: and renders it, or mode=client and the browser reads
#        /cgi-bin/lazysite-data.pl
#
# This is the spike the "Live data" section of /docs/ai-briefing-building-sites
# is written from. EVERY LIMIT THAT SECTION STATES IS A SUBTEST HERE, so a change
# that moves one fails this file before the docs can go stale:
#
#   - the cadence floor: 300 s, and an interval rounds UP to a multiple of the
#     scheduler's own 300 s job - driven through the scheduler's clock (`now`),
#     not by waiting
#   - fixed fields: each poll sends the same request; a sweep over N items is N
#     entries, and the connector's rate cap counts them all
#   - the shape of the row: one new row per poll, the answer as JSON text
#   - freshness: no cache clear is needed; `ttl:` is the only bound, and
#     mode=live and snapshot do not differ
#   - the data endpoint refuses a parameter it does not read
#   - SM1384: a multi-step job protocol (submit, poll, read) cannot be expressed
#
# No network beyond the fixture on 127.0.0.1.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Find ();
use Time::HiRes ();
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

BEGIN {
    eval { require HTTP::Daemon; require LWP::UserAgent; require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'HTTP::Daemon/LWP/DBI/SQLite/YAML::PP not available';
}
use TestHelper qw(repo_root env_passthrough site_tempdir add_account grant_caps);
use Lazysite::Data::Tables               ();
use Lazysite::Manager::Connectors        ();
use Lazysite::Handlers                   ();
use Lazysite::Daemon::Service::Scheduler ();

my $root    = repo_root();
my $docroot = site_tempdir( extensions => 1 );
my $lz      = "$docroot/lazysite";
make_path( map { "$lz/$_" } qw(auth daemon logs cache forms db/tables layouts/t) );

sub spit  { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t // '' }

# --- the remote: a JSON source that counts, and logs what it was asked -------
#
# One process answering in turn, so the counter is one counter. `seq` is what
# lets a page say WHICH poll it is showing.
my $asked = "$docroot/../remote-asked.log";
my $srv   = HTTP::Daemon->new( LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1 ) or die "no daemon: $!";
my $base  = $srv->url;
my $pid   = fork;
die "fork: $!" unless defined $pid;
if ( !$pid ) {
    my $seq = 0;
    while ( my $conn = $srv->accept ) {
        while ( my $req = $conn->get_request ) {
            $seq++;
            my $uri = $req->uri;
            open my $lf, '>>', $asked or die $!;
            print {$lf} $uri->path_query, "\n";
            close $lf;
            my %q = $uri->query_form;
            my $body
                = $uri->path eq '/submit'
                ? { job => "job-$seq", status => 'queued' }    # SM1384: step one of three
                : { symbol => $q{symbol} // '', seq => $seq, price => "1.$seq" };
            my $res = HTTP::Response->new(200);
            $res->header( 'Content-Type' => 'application/json' );
            $res->content( encode_json($body) );
            $conn->send_response($res);
        }
        $conn->close;
    }
    exit 0;
}
END { kill 'TERM', $pid if $pid }

sub asked { return [ grep { length } split /\n/, slurp($asked) ] }

# --- the scratch site -------------------------------------------------------
spit( "$lz/lazysite.conf",
    "site_name: Live\nsite_url: http://localhost\nlayout: t\nextensions:\n  - extensions/data.pl\n" );
spit( "$lz/layouts/t/layout.tt",
    '<html><body>[% content %]'
        . '[% FOREACH r IN latest %]<p class="latest">[% r.answer %]</p>[% END %]'
        . '</body></html>' );
spit( "$docroot/404.md", "---\ntitle: NF\n---\nNot found\n" );

# The answer table. Its columns are the eight the connector writes; `public:
# true` because a visitor reads it.
spit( "$lz/db/tables/quotes.yaml",
    "public: true\nkey: id\nauto_key: true\nfields:\n"
        . join( '', map {"  $_->[0]: { type: $_->[1] }\n"}
            [ connector => 'text' ], [ call_id => 'text' ], [ mode => 'text' ], [ actor => 'text' ],
            [ at => 'integer' ], [ state => 'text' ], [ http => 'integer' ], [ answer => 'text' ] ) );
ok( Lazysite::Data::Tables::apply_schema( $docroot, 'quotes' )->{ok}, 'the answer table is applied' );

# The job account: run_jobs to carry a job at all, manage_connectors because
# that is what a connector handler's destination needs.
add_account( $docroot, 'jobs' );
grant_caps( $docroot, 'jobs', qw(run_jobs manage_connectors) );
spit( "$lz/daemon.conf", "daemon_tick_seconds: 60\ndaemon_job_user: jobs\n" );

$Lazysite::Manager::Connectors::DOCROOT = $docroot;
sub connector_ok {
    my ( $id, %over ) = @_;
    my $r = Lazysite::Manager::Connectors::action_connector_save( $id,
        { name => $id, url => "${base}quote", method => 'GET', modes => { scheduled => 1, authenticated => 0 },
            answer_table => 'quotes', %over } );
    ok( $r->{ok}, "connector '$id' saved" ) or diag $r->{error};
    return $r;
}
connector_ok('quote');    # the default rate cap: 60 an hour

spit( "$lz/forms/handlers.conf",
    "handlers:\n"
        . "  - id: quote\n    type: connector\n    name: Quote\n    connector: quote\n"
        . "  - id: capped\n    type: connector\n    name: Capped\n    connector: capped\n"
        . "  - id: submit\n    type: connector\n    name: Submit\n    connector: submit\n" );

sub schedule { spit( "$lz/forms/schedule.conf", "schedule:\n" . join '', @_ ) }
sub entry {
    my ( $id, $handler, $every, $payload ) = @_;
    return "  - id: $id\n    handler: $handler\n    every: $every\n    enabled: true\n"
        . "    payload: " . encode_json( $payload // {} ) . "\n";
}

# A clean clock for a subtest: neither the scheduler's record nor the
# schedule's says anything has run.
sub reset_clock { unlink "$lz/daemon/scheduler-runs.json", "$lz/daemon/schedule-runs.json"; return }
sub tick {
    my ($now) = @_;
    my $done = Lazysite::Daemon::Service::Scheduler::tick( docroot => $docroot, now => $now );
    my ($sr) = grep { $_->{job} eq 'schedule-run' } @$done;
    return $sr;
}
sub rows {
    my $r = Lazysite::Data::Tables::read_rows( $docroot, 'quotes', as => 'operator', order_by => 'id', order => 'asc', limit => 500 );
    return $r->{rows} || [];
}
# The answer as a page shows it is HTML-escaped JSON text ("seq&quot;:8), and as
# the store or the endpoint holds it, plain JSON text ("seq":8).
sub seq_of { my ($t) = @_; return ( defined $t && $t =~ /seq(?:&quot;|")\s*:\s*(\d+)/ ) ? $1 : undef }

my $T = time();

# --- 1. the chain holds ------------------------------------------------------
subtest 'the chain holds: schedule -> connector -> remote -> a table row' => sub {
    reset_clock();
    schedule( entry( 'abc', 'quote', 300, { symbol => 'ABC' } ) );
    my $t0 = [Time::HiRes::gettimeofday];
    my $sr = tick($T);
    my $ms = int( Time::HiRes::tv_interval($t0) * 1000 );
    is( $sr->{outcome}, 'ok', 'schedule-run ran as the job account' );
    my $rows = rows();
    is( scalar @$rows, 1, 'one poll, one row' );
    my $row = $rows->[0];
    is_deeply( [ sort grep { !/\A_/ && $_ ne 'id' && $_ ne 'created_by' && $_ ne 'created_at' && $_ ne 'updated_at' && $_ ne 'updated_by' } keys %$row ],
        [qw(actor answer at call_id connector http mode state)],
        'the row is the call record plus the answer: connector, call_id, mode, actor, at, state, http, answer' )
        or diag explain $row;
    is( $row->{connector}, 'quote',     'naming the connector' );
    is( $row->{mode},      'scheduled', 'in scheduled mode' );
    is( $row->{actor},     'jobs',      'as the job account' );
    is( $row->{state},     'answered',  'answered' );
    ok( !ref $row->{answer}, 'the answer is TEXT - the remote JSON encoded into one column' );
    my $a = decode_json( $row->{answer} );
    is( $a->{symbol}, 'ABC', 'and holds what the remote said' );
    is( $a->{seq},    1,     'from its first answer' );
    is_deeply( asked(), ['/quote?symbol=ABC'], 'the fixed payload went out as the GET query, and nothing else did' );
    diag("per-poll cost: one scheduler tick with one due entry took ${ms} ms (one HTTP call, one row, one call-record line)");
};

# --- 2. the cadence floor ----------------------------------------------------
subtest 'the floor is 300 s, and nothing below it can be scheduled' => sub {
    is( $Lazysite::Handlers::SCHEDULE_FLOOR, 300, 'the schedule floor is 300 s' );
    is( Lazysite::Daemon::Service::Scheduler::jobs()->{'schedule-run'}{every}, 300,
        'and the job that runs the schedule ticks every 300 s' );
    my $r = Lazysite::Handlers::action_schedule_save( { id => 'fast', handler => 'quote', every => 60 },
        unconstrained => 1 );
    ok( !$r->{ok}, 'an entry asking for 60 s is refused at save' );
    like( $r->{error}, qr/at least 300/, 'naming the floor' );
    $r = Lazysite::Handlers::action_schedule_save( { id => 'fast', handler => 'quote', every => 299 },
        unconstrained => 1 );
    ok( !$r->{ok}, 'and so is 299' );

    # Driven through the scheduler's clock, the entry above (every: 300).
    my $before = scalar @{ asked() };
    is( tick( $T + 60 ), undef, 'at +60 s the schedule job is not due at all' );
    is( tick( $T + 299 ), undef, 'nor at +299 s' );
    is( scalar @{ asked() }, $before, 'so nothing was asked' );
    is( tick( $T + 300 )->{outcome}, 'ok', 'at +300 s it runs' );
    is( scalar @{ asked() }, $before + 1, 'and the remote is asked again' );
    is( scalar @{ rows() }, 2, 'which is a SECOND row - a poll appends, it does not replace' );
    is( tick( $T + 360 ), undef, 'the next tick, +360 s, does nothing' );
    is( tick( $T + 600 )->{outcome}, 'ok', 'and +600 s is the third poll' );
    is( scalar @{ rows() }, 3, 'three polls, three rows: the minimum interval achieved is 300 s' );
};

subtest 'an interval rounds UP to a multiple of the 300 s job' => sub {
    reset_clock();
    my $t = $T + 10_000;
    schedule( entry( 'slow', 'quote', 450, { symbol => 'SLW' } ) );
    my $n = scalar @{ asked() };
    tick($t);
    is( scalar @{ asked() }, $n + 1, 'every: 450 runs at t' );
    tick( $t + 300 );
    is( scalar @{ asked() }, $n + 1, 'not at t+300 (450 has not elapsed)' );
    tick( $t + 450 );
    is( scalar @{ asked() }, $n + 1, 'nor at t+450 - the job that would run it last ran at t+300' );
    tick( $t + 600 );
    is( scalar @{ asked() }, $n + 2, 'but at t+600: a 450 s entry polls every 600 s' );
};

subtest 'an entry under the floor written by hand never runs, and is recorded as refused' => sub {
    reset_clock();
    my $t = $T + 20_000;
    schedule( entry( 'hand', 'quote', 60, { symbol => 'HND' } ) );
    my $n = scalar @{ asked() };
    tick($t);
    tick( $t + 300 );
    is( scalar @{ asked() }, $n, 'a hand-written every: 60 is never called' );
    my $runs = decode_json( slurp("$lz/daemon/schedule-runs.json") || '{}' );
    # SM1391 (ruling 148): the spike found this skipped in silence; it is a
    # recorded refusal now (t/unit/daemon/17 holds the once-only rule).
    is( $runs->{hand}{outcome}, 'refused', 'and the run record holds a refusal for it' );
    like( $runs->{hand}{refusal_reason}, qr/below the floor of 300/, 'naming the floor' );
};

# --- 3. fixed fields ---------------------------------------------------------
subtest 'fixed fields: a sweep is one entry per item, and the rate cap counts them all' => sub {
    reset_clock();
    my $t = $T + 30_000;
    connector_ok( 'capped', rate_per_hour => 3 );
    schedule( map { entry( "s$_", 'capped', 300, { symbol => "S$_" } ) } 1 .. 4 );
    my $n0 = scalar @{ asked() };
    my $r0 = scalar @{ rows() };
    tick($t);
    my $runs = decode_json( slurp("$lz/daemon/schedule-runs.json") || '{}' );
    is( scalar( grep { ( $runs->{"s$_"}{last_run} // 0 ) == $t } 1 .. 4 ), 4,
        'four entries naming one handler are all due, and all run, in one tick' );
    my @q = @{ asked() }[ $n0 .. $#{ asked() } ];
    is_deeply( \@q, [ map {"/quote?symbol=S$_"} 1 .. 3 ], 'each sent its own fixed symbol, three of them' );
    is( $runs->{s4}{outcome}, 'failed', 'and the fourth was stopped by the connector\'s rate cap of 3/hour' );
    like( $runs->{s4}{reason} // '', qr/rate cap/, 'named as the rate cap' );
    is( scalar @{ rows() }, $r0 + 3, 'three rows, not four' );

    my $bad = Lazysite::Handlers::action_schedule_save(
        { id => 'list', handler => 'quote', every => 300, payload => { symbols => [ 'A', 'B' ] } },
        unconstrained => 1 );
    ok( !$bad->{ok}, 'a payload cannot carry a list to sweep' );
    like( $bad->{error}, qr/fixed values only/, 'a scheduled call carries fixed values only' );
};

# --- 4. the page side --------------------------------------------------------
sub visit {
    my ($uri) = @_;
    local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $docroot, REDIRECT_URL => $uri,
        REQUEST_METHOD => 'GET', QUERY_STRING => '' );
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED)};
    return scalar qx($^X \Q$root/lazysite-processor.pl\E 2>/dev/null);
}
sub shown { my ($html) = @_; my ($p) = $html =~ m{<p class="latest">(.*?)</p>}s; return seq_of($p) }
sub newest_seq { my $r = rows(); return seq_of( $r->[-1]{answer} ) }

sub page {
    my ( $name, $front ) = @_;
    spit( "$docroot/$name.md", "---\ntitle: $name\n${front}tt_page_var:\n"
            . "  latest: db:quotes(order=-id,limit=1"
            . ( $name eq 'livemode' ? ',mode=live' : $name eq 'clientmode' ? ',mode=client' : '' )
            . ")\n---\n\nQuote.\n" );
    return;
}
page( 'fresh',    '' );
page( 'cached',   "ttl: 300\n" );
page( 'livemode', "ttl: 300\n" );
page( 'clientmode', '' );

# Everything the scratch site wrote is made old, so the only clock in play is
# the page cache's own.
File::Find::find( sub { utime( time - 5000, time - 5000, $_ ) if -f $_ }, $lz );
utime( time - 5000, time - 5000, map {"$docroot/$_.md"} qw(fresh cached livemode clientmode 404) );

sub render_of {
    my ($name) = @_;
    my $found;
    File::Find::find( sub { $found = $File::Find::name if $_ eq "$name.html" }, $docroot );
    return $found;
}

my $poll = $T + 40_000;
sub poll { reset_clock(); schedule( entry( 'abc', 'quote', 300, { symbol => 'ABC' } ) ); tick( $poll += 300 ); return }

subtest 'a page with no ttl: shows the newest row on the next request, no cache clear' => sub {
    my $html  = visit('/fresh');
    my $first = shown($html);
    is( $first, newest_seq(), 'the page shows the newest answer' ) or diag $html;
    poll();
    my $next = shown( visit('/fresh') );
    is( $next, newest_seq(), 'after a poll, the next request shows the new one' );
    isnt( $next, $first, 'which is a different answer' );
    ok( render_of('fresh'), 'though the render was written to the page cache' );
};

subtest 'ttl: is the only freshness bound, and mode=live does not change it' => sub {
    for my $name (qw(cached livemode)) {
        my $first = shown( visit("/$name") );
        is( $first, newest_seq(), "$name: renders the newest answer" );
        poll();
        my $within = shown( visit("/$name") );
        is( $within, $first, "$name: inside its ttl the cached render is served - the new row is not shown" );
        my $f = render_of($name);
        ok( $f, "$name: the render is in the cache" );
        utime( time - 301, time - 301, $f );
        my $after = shown( visit("/$name") );
        is( $after, newest_seq(), "$name: once the ttl has passed, the next request shows the new row" );
    }
};

# --- 5. the browser's side: the data endpoint --------------------------------
sub endpoint {
    my ($qs) = @_;
    local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $docroot, REQUEST_METHOD => 'GET', QUERY_STRING => $qs );
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE)};
    my $t0  = [Time::HiRes::gettimeofday];
    my $out = qx($^X \Q$root/lazysite-data.pl\E 2>/dev/null);
    my $ms  = int( Time::HiRes::tv_interval($t0) * 1000 );
    my ($status) = $out =~ /Status:\s*(\d+)/;
    my ($head, $body) = split /\r?\n\r?\n/, $out, 2;
    return ( $status // 0, ( eval { decode_json( $body // '' ) } || {} ), $head // '', $ms );
}

subtest 'mode=client: the endpoint answers the newest row, uncached, every time' => sub {
    # WHAT mode=client DOES TODAY, pinned because the Live data recipe says it:
    # the binding still reads its rows at render, exactly as snapshot does. What
    # makes a page client-side is a data-ls-db region, which the shipped helper
    # fills from the endpoint below. If this starts failing, mode=client has
    # begun to mean "no rows at render" - update the recipe with it.
    is( shown( visit('/clientmode') ), newest_seq(), 'a mode=client binding still renders its rows at render' );
    my ( $st, $r, $head, $ms ) = endpoint('table=quotes&order_by=id&order=desc&limit=1');
    is( $st, 200, 'a visitor reads the published table' ) or diag explain $r;
    is( seq_of( $r->{rows}[0]{answer} ), newest_seq(), 'and gets the newest answer' );
    ok( !ref $r->{rows}[0]{answer}, 'as JSON text the page\'s script parses' );
    like( $head, qr/Cache-Control: no-store/, 'with no-store, so nothing in front holds it' );
    poll();
    ( $st, $r ) = endpoint('table=quotes&order_by=id&order=desc&limit=1');
    is( seq_of( $r->{rows}[0]{answer} ), newest_seq(), 'and after a poll, the next read has the new one' );
    diag("per-read cost: one data-endpoint request took ${ms} ms on this host");

    ( $st, $r ) = endpoint('table=quotes&order_by=id&order=desc&limit=1&since=0');
    is( $st, 400, 'a parameter the endpoint does not read (since) is refused' );
    is( $r->{kind}, 'unknown-parameter', 'as unknown-parameter' );
    ( $st, $r ) = endpoint('table=quotes&order_by=id&order=desc&limit=1&_=1700000000');
    is( $st, 200, 'and the cache-buster _ is the one exception' );
};

# --- 6. SM1384: a job protocol is not a poll --------------------------------
subtest 'SM1384: a multi-step job protocol cannot be expressed' => sub {
    connector_ok( 'submit', url => "${base}submit" );
    reset_clock();
    my $t = $T + 90_000;
    schedule( entry( 'job', 'submit', 300, { task => 'report' } ) );
    my $n = scalar @{ asked() };
    tick($t);
    tick( $t + 300 );
    my @q = @{ asked() }[ $n .. $#{ asked() } ];
    is_deeply( \@q, [ '/submit?task=report', '/submit?task=report' ],
        'the second poll sends exactly what the first did - nothing from the first answer travels' );
    my @jobs = map { decode_json( $_->{answer} )->{job} } grep { $_->{connector} eq 'submit' } @{ rows() };
    is( scalar @jobs, 2, 'so each poll SUBMITS again' );
    isnt( $jobs[0], $jobs[1], 'and starts a new job, whose id lands in a row and is never asked about' );
};

done_testing();
