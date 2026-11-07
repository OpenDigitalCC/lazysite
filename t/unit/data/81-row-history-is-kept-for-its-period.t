#!/usr/bin/perl
# SM1355 (ruling 170): ROW HISTORY IS KEPT FOR A PERIOD.
#
# 90 days by default; a table may set its own (`row_history_days`, a positive
# whole number of days, refused by name otherwise). A change older than its
# table's period is not undoable (`expired-change`) and is removed by the next
# write to the store - a deleted row's changes too - and never by a read.
#
# With the change reverted `row_history_days` is no descriptor key (the refusals
# pass and describe names no period), an old change is undone like a new one,
# and nothing is ever removed, so every subtest below fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_child site_tempdir);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Connect ();

my $mcp = "$FindBin::Bin/../../../lazysite-mcp.pl";
my $d   = site_tempdir();
make_path("$d/lazysite/auth");
{
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "mcp_enabled: true\nextensions:\n  - extensions/data.pl\n";
    close $cf;
}

my $stub = "$d/users-stub.pl";
{
    open my $sf, '>', $stub or die $!;
    print {$sf} "#!/usr/bin/perl\nuse strict; use warnings; use JSON::PP qw(encode_json);\n"
        . "print encode_json({ ok => 1, settings => { manage_data => 1, mcp => 1 } });\n";
    close $sf;
    chmod 0755, $stub;
}

sub call {
    my ( $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args || {} } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer owner:lzs_tok';
    my $resp = run_child( [ $^X, $mcp ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $r = ( defined $jb && length $jb ) ? eval { decode_json($jb) } : undef;
    return $r && $r->{result} ? $r->{result}{structuredContent}
        : { ok => 0, error => ( $r && $r->{error} ? $r->{error}{message} : 'no answer' ) };
}

# Make a recorded change look $days old, as the clock would after that long.
sub age {
    my ( $id, $days ) = @_;
    my $dbh = DBI->connect( 'dbi:SQLite:dbname=' . Lazysite::Data::Connect::store_path($d),
        '', '', { RaiseError => 1 } );
    my @t = gmtime( time() - $days * 86400 );
    my $at = sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, @t[ 3, 2, 1, 0 ];
    $dbh->do( 'UPDATE "_row_changes" SET "at" = ? WHERE "id" = ?', undef, $at, $id );
    $dbh->disconnect;
    return;
}

sub ids {
    my ( $table, $key ) = @_;
    my $h = call( 'list_row_changes', { table => $table, ( defined $key ? ( key => $key ) : () ), limit => 200 } );
    return [ map { $_->{id} } @{ $h->{changes} || [] } ];
}

my $MENU     = "key: slug\nfields:\n  slug:\n    type: text\n    required: true\n  name:\n    type: text\n";
my $SPECIALS = "row_history_days: 7\n$MENU";

subtest 'a table may set its own period, and a wrong one is refused by name' => sub {
    for my $bad ( '0', '-3', '1.5', 'week', '40000' ) {
        my $r = call( 'save_data_table', { table => 'specials', descriptor => "row_history_days: $bad\n$MENU" } );
        ok( !$r->{ok}, "row_history_days: $bad is refused" );
        is( $r->{rule}, 'row_history_days', '...by name' ) or diag explain $r;
    }
    for my $t ( [ menu => $MENU ], [ specials => $SPECIALS ] ) {
        ok( call( 'save_data_table', { table => $t->[0], descriptor => $t->[1] } )->{ok}, "$t->[0] declared" );
        ok( call( 'migrate_data_table', { table => $t->[0] } )->{ok}, '...and migrated' );
    }
    is( call( 'describe_data_table', { table => 'menu' } )->{row_history_days}, 90, 'the default is 90 days' );
    is( call( 'describe_data_table', { table => 'specials' } )->{row_history_days}, 7, 'a table sets its own' );
};

subtest 'a change older than the period cannot be undone, and the next write removes it' => sub {
    my $ins = call( 'save_data_row', { table => 'menu', row => { slug => 'soup', name => 'Soup' } } );
    my $upd = call( 'save_data_row', { table => 'menu', key => 'soup', row => { name => 'Tomato soup' } } );
    ok( $ins->{change} && $upd->{change}, 'two recorded changes' ) or diag explain [ $ins, $upd ];
    age( $_, 91 ) for $ins->{change}, $upd->{change};

    my $h = call( 'list_row_changes', { table => 'menu', key => 'soup' } );
    is( scalar @{ $h->{changes} || [] }, 2, 'a read removes nothing' ) or diag explain $h;
    ok( !$h->{changes}[0]{undoable}, '...and offers no Undo past the period' );
    my $u = call( 'undo_row_change', { table => 'menu', change => $upd->{change} } );
    is( $u->{kind}, 'expired-change', 'undoing it is refused as expired' ) or diag explain $u;
    my ($soup) = grep { $_->{slug} eq 'soup' } @{ call( 'read_data_rows', { table => 'menu' } )->{rows} || [] };
    is( $soup->{name}, 'Tomato soup', '...and the row is left as it is' );

    my $kept = call( 'save_data_row', { table => 'menu', row => { slug => 'tea', name => 'Tea' } } );
    age( $kept->{change}, 89 );
    ok( call( 'save_data_row', { table => 'menu', row => { slug => 'bread', name => 'Bread' } } )->{ok}, 'a write' );
    is_deeply( ids( 'menu', 'soup' ), [], 'removes the changes older than 90 days' );
    is_deeply( ids( 'menu', 'tea' ), [ $kept->{change} ], 'and keeps one of 89' );
    ok( call( 'list_row_changes', { table => 'menu', key => 'tea' } )->{changes}[0]{undoable}, '...undoable still' );
};

subtest 'a table\'s own period overrides the default' => sub {
    my $sp = call( 'save_data_row', { table => 'specials', row => { slug => 'pie', name => 'Pie' } } );
    my $mn = call( 'save_data_row', { table => 'menu', row => { slug => 'cake', name => 'Cake' } } );
    age( $_, 8 ) for $sp->{change}, $mn->{change};
    is( call( 'undo_row_change', { table => 'specials', change => $sp->{change} } )->{kind}, 'expired-change',
        'an 8-day change on a 7-day table is past Undo' );
    ok( call( 'undo_row_change', { table => 'menu', change => $mn->{change} } )->{ok},
        'an 8-day change on a default table is not' );
    ok( call( 'save_data_row', { table => 'menu', row => { slug => 'jam', name => 'Jam' } } )->{ok}, 'a write' );
    is_deeply( ids( 'specials', 'pie' ), [], 'removes the 7-day table\'s 8-day change' );
    ok( scalar @{ ids( 'menu', 'cake' ) }, 'and keeps the default table\'s' );
};

subtest 'a deleted row\'s history goes after the period too' => sub {
    my $ins = call( 'save_data_row', { table => 'menu', row => { slug => 'gone', name => 'Gone' } } );
    my $del = call( 'delete_data_row', { table => 'menu', key => 'gone' } );
    ok( $ins->{change} && $del->{change}, 'inserted and deleted, both recorded' ) or diag explain [ $ins, $del ];
    age( $_, 91 ) for $ins->{change}, $del->{change};
    is( scalar @{ ids( 'menu', 'gone' ) }, 2, 'still listed until a write' );
    ok( call( 'save_data_row', { table => 'specials', row => { slug => 'tart', name => 'Tart' } } )->{ok},
        'a write to another table' );
    is_deeply( ids( 'menu', 'gone' ), [], 'removes the deleted row\'s history' );
};

done_testing();
