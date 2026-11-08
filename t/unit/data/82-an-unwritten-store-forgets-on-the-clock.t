#!/usr/bin/perl
# SM1355 (ruling 170): THE ROW HISTORY IS PRUNED EVEN WHEN NOBODY WRITES.
#
# The write path prunes after each recorded change, so a store nobody wrote to
# kept its expired changes - earlier values of people's rows - indefinitely. The
# daemon's row-history-prune job (daily, as the job account) makes the same call
# on a clock: every table the history names, each held to its own period, a
# table no longer declared to the default. Ruling 175: it needs only run_jobs -
# retention is never refusable by a missing grant - and each run is audited.
#
# With the job taken out of the scheduler's set, the tick runs nothing called
# row-history-prune and every expired change below is still there, so the first
# subtest fails; with its body not pruning, the same; with it needing
# manage_data again, it is refused to the run_jobs-only account here; without
# its audit row, the audit assertions fail.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_child site_tempdir add_account grant_caps);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Connect              ();
use Lazysite::Daemon::Service::Scheduler ();

my $mcp = "$FindBin::Bin/../../../lazysite-mcp.pl";

sub site {
    my $d = site_tempdir();
    make_path( "$d/lazysite/auth", "$d/lazysite/daemon", "$d/lazysite/logs" );
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "mcp_enabled: true\nextensions:\n  - extensions/data.pl\n";
    close $cf;
    open my $dc, '>', "$d/lazysite/daemon.conf" or die $!;
    print {$dc} "daemon_job_user: jobs\n";
    close $dc;
    add_account( $d, 'jobs' );
    grant_caps( $d, 'jobs', qw(run_jobs) );    # ruling 175: nothing beyond it
    my $stub = "$d/users-stub.pl";
    open my $sf, '>', $stub or die $!;
    print {$sf} "#!/usr/bin/perl\nuse strict; use warnings; use JSON::PP qw(encode_json);\n"
        . "print encode_json({ ok => 1, settings => { manage_data => 1, mcp => 1 } });\n";
    close $sf;
    chmod 0755, $stub;
    return $d;
}

sub call {
    my ( $d, $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args || {} } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = "$d/users-stub.pl";
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer owner:lzs_tok';
    my $resp = run_child( [ $^X, $mcp ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $r = ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
    return $r && $r->{result} ? $r->{result}{structuredContent}
        : { ok => 0, error => ( $r && $r->{error} ? $r->{error}{message} : 'no answer' ) };
}

sub dbh {
    my ($d) = @_;
    return DBI->connect( 'dbi:SQLite:dbname=' . Lazysite::Data::Connect::store_path($d),
        '', '', { RaiseError => 1 } );
}

# Make a recorded change look $days old, as the clock would after that long.
sub age {
    my ( $d, $id, $days ) = @_;
    my @t  = gmtime( time() - $days * 86400 );
    my $at = sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, @t[ 3, 2, 1, 0 ];
    my $h  = dbh($d);
    $h->do( 'UPDATE "_row_changes" SET "at" = ? WHERE "id" = ?', undef, $at, $id );
    $h->disconnect;
    return;
}

sub ids_left {
    my ($d) = @_;
    my $h = dbh($d);
    my $ids = $h->selectcol_arrayref('SELECT "id" FROM "_row_changes" ORDER BY "id"');
    $h->disconnect;
    return $ids;
}

sub the_job {
    my ($done) = @_;
    my ($j) = grep { $_->{job} eq 'row-history-prune' } @{ $done || [] };
    return $j || {};
}

my $MENU = "key: slug\nfields:\n  slug:\n    type: text\n    required: true\n  name:\n    type: text\n";

subtest 'an untouched store loses its expired changes when the job runs, and keeps the rest' => sub {
    my $d = site();
    ok( call( $d, 'save_data_table', { table => 'menu', descriptor => $MENU } )->{ok}, 'menu declared (90 days)' );
    ok( call( $d, 'save_data_table', { table => 'specials', descriptor => "row_history_days: 7\n$MENU" } )->{ok},
        'specials declared (7 days)' );
    ok( call( $d, 'migrate_data_table', { table => $_ } )->{ok}, "$_ migrated" ) for qw(menu specials);

    my %c;
    for my $w ( [ old => 'menu', 91 ], [ inside => 'menu', 89 ], [ sp_old => 'specials', 8 ],
        [ sp_new => 'specials', 6 ] )
    {
        my $r = call( $d, 'save_data_row', { table => $w->[1], row => { slug => $w->[0], name => $w->[0] } } );
        ok( $r->{change}, "$w->[0]: recorded" ) or diag explain $r;
        $c{ $w->[0] } = $r->{change};
    }
    # The writes above pruned as they went; age the changes only now, so nothing
    # but the job can remove them - the store is not written again.
    age( $d, $c{ $_->[0] }, $_->[1] ) for [ old => 91 ], [ inside => 89 ], [ sp_old => 8 ], [ sp_new => 6 ];

    # A table that is no longer declared is held to the default.
    {
        my $h = dbh($d);
        $h->do( q{INSERT INTO "_row_changes" ("at","tbl","row_key","op","actor","source") VALUES (?,?,?,?,?,?)},
            undef, '2020-01-01T00:00:00Z', 'dropped', 'x', 'delete', 'owner', 'mcp' );
        $c{dropped} = $h->last_insert_id( undef, undef, '_row_changes', 'id' );
        $h->disconnect;
    }
    is( scalar @{ ids_left($d) }, 5, 'five changes in the store before the tick' );

    my $j = the_job( Lazysite::Daemon::Service::Scheduler::tick( docroot => $d ) );
    is( $j->{outcome}, 'ok', 'the row-history-prune job ran' ) or diag explain $j;
    is( $j->{actor}, 'jobs', 'as the job account, which holds run_jobs and nothing else' );
    is_deeply( ids_left($d), [ sort { $a <=> $b } @c{qw(inside sp_new)} ],
        'gone: the 91-day menu change, the 8-day change on the 7-day table, the undeclared '
            . 'table\'s; kept: 89 days on menu, 6 days on specials' );

    open my $rf, '<', "$d/lazysite/daemon/scheduler-runs.json" or die $!;
    my $runs = decode_json( do { local $/; <$rf> } );
    is_deeply( $runs->{'row-history-prune'}{detail}, { tables => 3, removed => 3 },
        'the run record counts the tables and what went' );

    my @audit = audit_rows($d);
    is( scalar @audit, 1, 'the run is one audit row' ) or diag explain \@audit;
    like( $audit[0] // '', qr/\| jobs \| row-history-prune \| row-history \|  \| ok \| daemon \| tables=3 removed=3$/,
        '...naming the job account, the tables and the count' );

    # Daily: a second tick at once does not run it again.
    ok( !the_job( Lazysite::Daemon::Service::Scheduler::tick( docroot => $d ) )->{job},
        'not due again within the day' );
    is( scalar( () = audit_rows($d) ), 1, '...and writes no second row' );
};

subtest 'a site with no data store: nothing to prune, no store made, the run audited' => sub {
    my $d = site();
    my $j = the_job( Lazysite::Daemon::Service::Scheduler::tick( docroot => $d ) );
    is( $j->{outcome}, 'ok', 'the job ran' ) or diag explain $j;
    ok( !-e Lazysite::Data::Connect::store_path($d), 'and created no store' );
    my @audit = audit_rows($d);
    like( $audit[0] // '', qr/\| row-history-prune \| row-history \|  \| ok \| daemon \| tables=0 removed=0$/,
        'and the run is audited as removing nothing' );
};

sub audit_rows {
    my ($d) = @_;
    open my $in, '<', "$d/lazysite/logs/audit.log" or return ();
    my @r = grep {/\| row-history-prune \|/} <$in>;
    close $in;
    chomp @r;
    return @r;
}

done_testing();
