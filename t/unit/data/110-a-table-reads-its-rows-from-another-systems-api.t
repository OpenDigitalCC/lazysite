#!/usr/bin/perl
# SM1364: A TABLE READS ITS ROWS FROM ANOTHER SYSTEM'S API.
#
# A table's descriptor names a `source:` - a GET connector, the schedule entry
# that refreshes it and a map from each item's fields to its columns. The
# refresh is the existing chain (schedule -> connector handler -> connector ->
# the connector's answer_table), and because the answer table names a source the
# answer becomes the table's rows through import_rows instead of a call-record
# row. An on-demand refresh (Manager::Data::action_data_table_refresh, the
# data-table-refresh action and the refresh_data_table tool) is the same call.
#
# What must hold, against a remote on 127.0.0.1 this test starts:
#
# - a refresh fills the table, mapping nested fields, and a second refresh
#   updates the rows it sent again and keeps the site's own (unmapped) columns;
# - a refresh that fails - the remote down, or an answer that does not map -
#   changes nothing: the last good rows stay, the failure is recorded against
#   the entry, and the table's age (from schedule-runs.json) still counts from
#   the last good refresh;
# - the descriptor refuses a source it could not refresh by: an automatic key,
#   a map that does not fill the key, a column that is not declared.
#
# With the change reverted `source` is no descriptor key (the answer lands as a
# call-record row the table has no columns for), nothing is refreshed, and the
# subtests below fail.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);

BEGIN {
    eval { require HTTP::Daemon; require LWP::UserAgent; require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'HTTP::Daemon/LWP/DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Tables        ();
use Lazysite::Data::Descriptor    ();
use Lazysite::Manager::Connectors ();
use Lazysite::Manager::Data       ();
use Lazysite::Daemon::Jobs        ();

my $d = site_tempdir();
make_path( map {"$d/lazysite/$_"} qw(db/tables connectors forms daemon auth logs) );

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; return $t }

spit( "$d/lazysite/lazysite.conf", "extensions:\n  - extensions/data.pl\n" );

# --- the other system: what it answers is read from a file per request -------
my $mode = "$d/remote-mode";
spit( $mode, 'good' );
my $srv = HTTP::Daemon->new( LocalAddr => '127.0.0.1', LocalPort => 0, ReuseAddr => 1 ) or die "no daemon: $!";
my $base = $srv->url;
my $pid  = fork;
die "fork: $!" unless defined $pid;
if ( !$pid ) {
    while ( my $conn = $srv->accept ) {
        while ( my $req = $conn->get_request ) {
            my $m = slurp($mode) // 'good';
            $m =~ s/\s+\z//;
            if ( $m eq 'down' ) { $conn->send_error( 503, 'down for maintenance' ); next }
            my @items
                = $m eq 'bad'     ? ( { guest => { name => 'No Ref' }, seats => 1 } )
                : $m eq 'empty'   ? ()
                : $m eq 'changed' ? ( { ref => 'B1', guest => { name => 'Ada L' }, seats => 3 },
                                      { ref => 'B3', guest => { name => 'Cy' },    seats => 1 } )
                :                   ( { ref => 'B1', guest => { name => 'Ada' },   seats => 2 },
                                      { ref => 'B2', guest => { name => 'Bo' },    seats => 4 } );
            my $res = HTTP::Response->new(200);
            $res->header( 'Content-Type' => 'application/json' );
            $res->content( encode_json( { data => { items => \@items },
                        asked => { $req->uri->query_form } } ) );
            $conn->send_response($res);
        }
        $conn->close;
    }
    exit 0;
}
END { kill 'TERM', $pid if $pid }

# --- the site: a sourced table, its connector, handler and schedule entry -----
my $DESC = <<'YAML';
title: Bookings
key: ref
fields:
  ref:
    type: text
    required: true
  guest:
    type: text
  seats:
    type: integer
  note:
    type: text
source:
  connector: bookings
  schedule: bookings-refresh
  rows: data.items
  map:
    ref: ref
    guest: guest.name
    seats: seats
YAML
spit( "$d/lazysite/db/tables/bookings.yaml", $DESC );
my $m = Lazysite::Data::Tables::apply_schema( $d, 'bookings' );
ok( $m->{ok}, 'the sourced table is created' ) or diag explain $m;

$Lazysite::Manager::Connectors::DOCROOT = $d;
my $c = Lazysite::Manager::Connectors::action_connector_save( 'bookings',
    { url => "${base}bookings", method => 'GET', modes => { scheduled => 1, authenticated => 1 },
        answer_table => 'bookings', rate_per_hour => 0, timeout => 3 } );
ok( $c->{ok}, 'the GET connector is saved, its answers kept in the table' ) or diag explain $c;
spit( "$d/lazysite/forms/handlers.conf",
    "handlers:\n  - id: bookings-pull\n    type: connector\n    name: Pull\n    connector: bookings\n" );
spit( "$d/lazysite/forms/schedule.conf",
    "schedule:\n  - id: bookings-refresh\n    handler: bookings-pull\n    every: 300\n    enabled: true\n"
        . "    payload: {\"venue\":\"main\"}\n" );

my $now = 1_900_000_000;
sub tick {
    $now += 600;
    return Lazysite::Daemon::Jobs::schedule_run( docroot => $d, caps => { manage_connectors => 1 },
        actor => 'jobs', now => $now );
}
sub rows {
    my $r = Lazysite::Data::Tables::read_rows( $d, 'bookings', as => 'operator', order => 'ref' );
    return { map { $_->{ref} => $_ } @{ $r->{rows} || [] } };
}
sub run_rec { return Lazysite::Daemon::Jobs::schedule_run_record( $d, 'bookings-refresh' ) }

subtest 'the descriptor carries the source, and refuses one it could not refresh by' => sub {
    my $t = Lazysite::Data::Tables::load_table( $d, 'bookings' );
    is_deeply( $t->{source}{map}, { ref => 'ref', guest => 'guest.name', seats => 'seats' }, 'the map is kept' );
    is( $t->{source}{connector}, 'bookings', 'and the connector it reads from' );
    my $raw = YAML::PP->new->load_string($DESC);
    my %bad = (
        'an automatic key'          => sub { delete $_[0]{key}; delete $_[0]{fields}{ref}; delete $_[0]{source}{map}{ref} },
        'a map without the key'     => sub { delete $_[0]{source}{map}{ref} },
        'an undeclared column'      => sub { $_[0]{source}{map}{room} = 'room' },
        'no schedule entry'         => sub { delete $_[0]{source}{schedule} },
        'an unknown source setting' => sub { $_[0]{source}{every} = 300 },
    );
    for my $why ( sort keys %bad ) {
        my $copy = decode_json( encode_json($raw) );
        $bad{$why}->($copy);
        my $r = Lazysite::Data::Descriptor::load_descriptor( 'bookings', $copy );
        ok( !$r->{ok}, "refused: $why" );
        like( $r->{error} // '', qr/source:/, '...naming the source' );
    }
};

subtest 'a scheduled refresh fills the table from the remote' => sub {
    my $r = tick();
    is_deeply( $r->{detail}{ran}, ['bookings-refresh'], 'the entry ran' ) or diag explain $r;
    my $rows = rows();
    is_deeply( [ sort keys %$rows ], [qw(B1 B2)], 'one row per item the source sent' );
    is( $rows->{B1}{guest}, 'Ada', 'a nested field reaches its column' );
    is( $rows->{B2}{seats}, 4,     'and a plain one' );
    my $rec = run_rec();
    is( $rec->{outcome}, 'ok',  'the run is recorded' );
    is( $rec->{last_ok}, $now, 'with when it last delivered' );
};

subtest 'a second refresh updates what it sent and keeps the site\'s own column' => sub {
    my $u = Lazysite::Data::Tables::update_row( $d, 'bookings', 'B1', { note => 'window seat' },
        as => 'operator', actor => 'op' );
    ok( $u->{ok}, 'an unmapped column is the site\'s to write' ) or diag explain $u;
    spit( $mode, 'changed' );
    tick();
    my $rows = rows();
    is( $rows->{B1}{guest}, 'Ada L',       'a mapped column follows the source' );
    is( $rows->{B1}{seats}, 3,             '...each of them' );
    is( $rows->{B1}{note},  'window seat', 'the site\'s own column is kept' );
    ok( $rows->{B3},                       'a new item is a new row' );
};

# Ruling 189: the table mirrors the source - a row it stops sending goes, as a
# recorded delete Undo reverses - but an empty list, or a failed answer, removes
# nothing.
subtest 'a row the source drops is removed, and Undo brings it back' => sub {
    ok( !rows()->{B2}, 'the row the source no longer sends was removed' );
    $Lazysite::Manager::Data::DOCROOT   = $d;
    $Lazysite::Manager::Data::auth_user = 'op';
    my $h = Lazysite::Manager::Data::action_data_row_changes( 'bookings', key => 'B2' );
    my ($del) = grep { $_->{op} eq 'delete' } @{ $h->{changes} || [] };
    ok( $del, 'its removal is a recorded change' ) or return diag explain $h;
    is( $del->{source}, 'refresh:bookings', '...naming the refresh' );
    is( $del->{before}{guest}, 'Bo', '...with the row as it was' );
    my $u = Lazysite::Manager::Data::action_data_row_undo( 'bookings', $del->{id} );
    ok( $u->{ok}, 'Undo is accepted' ) or diag explain $u;
    is( rows()->{B2}{guest}, 'Bo', 'and the row is back' );

    my $before = rows();
    spit( $mode, 'empty' );
    my $r = tick();
    is_deeply( $r->{detail}{ran}, ['bookings-refresh'], 'an empty list is a delivered refresh' );
    is_deeply( rows(), $before, '...that removes nothing' );
    spit( $mode, 'changed' );
};

subtest 'a failed refresh leaves the last good rows and is recorded' => sub {
    my $before = rows();
    ok( $before->{B2}, 'B2 is a row the source does not send - a failed refresh must not remove it' );
    my $good   = run_rec()->{last_ok};

    spit( $mode, 'down' );
    my $r = tick();
    is_deeply( $r->{detail}{ran}, [], 'the entry did not deliver' );
    like( join( ' ', @{ $r->{detail}{failed} || [] } ), qr/bookings-refresh/, '...and is listed as failed' );
    is_deeply( rows(), $before, 'the remote being down changed nothing' );
    my $rec = run_rec();
    is( $rec->{outcome}, 'failed', 'the failure is recorded against the entry' );
    is( $rec->{last_ok}, $good,    'and the age still counts from the last good refresh' );

    spit( $mode, 'bad' );
    tick();
    is_deeply( rows(), $before, 'an answer that does not map changed nothing either' );
    $rec = run_rec();
    is( $rec->{outcome}, 'failed', 'recorded as failed' );
    like( $rec->{reason}, qr/item 1 has no 'ref'/, 'naming what was wrong with the answer' );

    $Lazysite::Manager::Data::DOCROOT   = $d;
    $Lazysite::Manager::Data::auth_user = 'op';
    my $st = Lazysite::Manager::Data::action_data_table('bookings')->{source};
    is( $st->{refreshed_at}, $good, 'the table says when its rows were last good' );
    ok( defined $st->{age_seconds}, '...and how old they are' );
    is( $st->{outcome}, 'failed', 'and that the last attempt failed' );
    is_deeply( $st->{read_only}, [qw(guest ref seats)], 'and which columns are the source\'s' );
};

subtest 'an on-demand refresh is the same call, and records its run' => sub {
    $Lazysite::Manager::Data::DOCROOT   = $d;
    $Lazysite::Manager::Data::auth_user = 'op';
    spit( $mode, 'good' );
    my $r = Lazysite::Manager::Data::action_data_table_refresh( 'bookings',
        caps => { manage_data => 1, manage_connectors => 1 }, groups => [] );
    ok( $r->{ok}, 'refreshed now' ) or diag explain $r;
    is( rows()->{B1}{guest}, 'Ada', 'the rows are the source\'s again' );
    is( run_rec()->{outcome}, 'ok', 'recorded against the schedule entry' );
    ok( $r->{source}{refreshed_at}, 'and the answer says when' );

    spit( $mode, 'down' );
    my $before = rows();
    my $f = Lazysite::Manager::Data::action_data_table_refresh( 'bookings',
        caps => { manage_data => 1, manage_connectors => 1 }, groups => [] );
    ok( !$f->{ok}, 'a failed on-demand refresh says so' );
    like( $f->{error}, qr/keeps its last good rows/, '...and that the rows are the last good copy' );
    is_deeply( rows(), $before, 'and changed nothing' );

    my $who = Lazysite::Manager::Data::action_data_table_refresh( 'bookings', caps => { manage_data => 1 }, groups => [] );
    ok( !$who->{ok}, 'an account the connector does not name may not cause the call' );
    like( $who->{error} // '', qr/callers|manage_connectors/, '...and is told what would let it' );
};

done_testing();
