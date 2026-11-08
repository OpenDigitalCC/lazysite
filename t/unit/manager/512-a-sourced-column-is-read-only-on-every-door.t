#!/usr/bin/perl
# SM1364: A COLUMN THE SOURCE FILLS IS READ-ONLY ON EVERY DOOR.
#
# A table that reads its rows from another system (`source:` in its
# descriptor) owns only its unmapped columns. Its mapped columns are the
# source's: a write to one is refused on the manager (a person's cookie), the
# control API (a token), MCP, and a CSV import, and the refusal names the
# source - "change it at the source" is the one remedy the next refresh will not
# undo. An unmapped column is written as on any table. All of it is one check,
# in Tables::_write_prep (and import_rows), which every door already passes
# through.
#
# The on-demand refresh is reachable on both doors (data-table-refresh,
# refresh_data_table) and refuses a table that names no source.
#
# With the change reverted every write below lands, `source` is no descriptor
# key, and the two refresh doors are unknown - each subtest fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use MIME::Base64 ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}

my $root = repo_root();
my $mapi = "$root/lazysite-manager-api.pl";
my $mcp  = "$root/lazysite-mcp.pl";
my $s    = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nmanager_groups: admins\n"
        . "extensions:\n  - extensions/data.pl\n" );
my $d = $s->docroot;

sub put {
    my ( $rel, $text ) = @_;
    open my $f, '>', "$d/$rel" or die "$rel: $!";
    print {$f} $text;
    close $f;
}
make_path("$d/lazysite/db/tables");
put( 'lazysite/db/tables/bookings.yaml', <<'YAML' );
title: Bookings
key: ref
fields:
  ref:
    type: text
    required: true
  guest:
    type: text
  note:
    type: text
source:
  connector: bookings
  schedule: bookings-refresh
  map:
    ref: ref
    guest: name
YAML
put( 'lazysite/db/tables/plain.yaml', "title: Plain\nkey: code\nfields:\n  code:\n    type: text\n    required: true\n" );

my @ALL = qw(ui api manage_data);
$s->add_user('boss');
$s->grant( 'boss', 'admins', [qw(ui manage_users manage_data)], \@ALL );
$s->add_user('agent');
$s->grant( 'agent', 'ops', [qw(api manage_data)], \@ALL );
my $tok = do {
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json( { action => 'token', username => 'agent' } ), stderr => 'inherit' )->{out};
    ( eval { decode_json($out) } || {} )->{token};
};
ok( $tok, 'the API client has a token' );

sub boss { my ( $action, %o ) = @_; return $s->call( 'boss', $action, %o ) }

sub api {
    my ( $qs, $body ) = @_;
    my $json = encode_json( $body // {} );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{QUERY_STRING}       = $qs;
    $ENV{CONTENT_LENGTH}     = length $json;
    $ENV{CONTENT_TYPE}       = 'application/json';
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . MIME::Base64::encode_base64( "agent:$tok", '' );
    my $out = run_child( [ $^X, $mapi ], stdin => $json, stderr => 'inherit' )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

my $stub = "$d/users-stub.pl";
put( 'users-stub.pl', <<'STUB' );
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json({ ok => 1, settings => { mcp => 1, manage_data => 1 } });
STUB
chmod 0755, $stub;

sub mcp {
    my ( $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args || {} } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE)};
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

for my $t (qw(bookings plain)) {
    my $m = boss( 'data-migrate', query => "action=data-migrate&table=$t", body => {} );
    ok( $m->{ok}, "$t migrated" ) or diag explain $m;
}

# A row as a refresh writes it: through the one path that may fill a mapped column.
require Lazysite::Data::Tables;
my $seed = Lazysite::Data::Tables::import_rows( $d, 'bookings', [qw(ref guest)], [ [ 'B1', 'Ada' ] ],
    apply => 1, actor => 'jobs', source_refresh => 1 );
ok( $seed->{ok} && $seed->{inserts} == 1, 'a refresh writes the mapped columns' ) or diag explain $seed;

sub guest {
    my $r = Lazysite::Data::Tables::read_rows( $d, 'bookings', as => 'operator', where => { ref => 'B1' } );
    return $r->{rows}[0]{guest};
}

my %door = (
    manager => sub { boss( 'data-row-save', query => 'action=data-row-save', body => $_[0] ) },
    api     => sub { api( 'action=data-row-save', $_[0] ) },
    mcp     => sub { mcp( 'save_data_row', $_[0] ) },
);

for my $name (qw(manager api mcp)) {
    subtest "the $name door refuses a mapped column, naming the source" => sub {
        my $r = $door{$name}->( { table => 'bookings', key => 'B1', row => { guest => 'Mallory' } } );
        ok( !$r->{ok}, 'an update of a mapped column is refused' ) or diag explain $r;
        like( $r->{error} // '', qr/column 'guest' is read from connector 'bookings'.*change it at the source/,
            '...naming the column and the source' );
        is( guest(), 'Ada', 'and nothing was written' );

        my $new = $door{$name}->( { table => 'bookings', row => { ref => 'B9', note => 'x' } } );
        ok( !$new->{ok}, 'a new row is refused - its key is the source\'s' );
        like( $new->{error} // '', qr/column 'ref' is read from connector 'bookings'/, '...by name' );
    };
    subtest "the $name door still writes an unmapped column" => sub {
        my $r = $door{$name}->( { table => 'bookings', key => 'B1', row => { note => "by $name" } } );
        ok( $r->{ok}, 'the site\'s own column is written' ) or diag explain $r;
        my $row = Lazysite::Data::Tables::read_rows( $d, 'bookings', as => 'operator', where => { ref => 'B1' } )->{rows}[0];
        is( $row->{note}, "by $name", '...and landed' );
    };
}

subtest 'a CSV import is a door too' => sub {
    my $r = Lazysite::Data::Tables::import_rows( $d, 'bookings', [qw(ref guest)], [ [ 'B1', 'Eve' ] ],
        apply => 1, actor => 'boss' );
    ok( !$r->{ok}, 'a mapped column in a CSV is refused' );
    like( $r->{error} // '', qr/read from connector 'bookings'/, '...naming the source' );
    my $ok = Lazysite::Data::Tables::import_rows( $d, 'bookings', [qw(ref note)], [ [ 'B1', 'csv' ] ],
        apply => 1, actor => 'boss' );
    ok( $ok->{ok}, 'the key addresses a row, and an unmapped column is written' ) or diag explain $ok;
    my $add = Lazysite::Data::Tables::import_rows( $d, 'bookings', [qw(ref note)], [ [ 'B7', 'csv' ] ],
        apply => 1, actor => 'boss' );
    ok( !$add->{ok}, 'and a new row is the source\'s to add' );
    is( guest(), 'Ada', 'nothing reached the mapped column' );
};

subtest 'the on-demand refresh is on both doors' => sub {
    my $a = api( 'action=data-table-refresh', { table => 'plain' } );
    ok( !$a->{ok}, 'data-table-refresh answers on the control API' );
    like( $a->{error} // '', qr/names no source/, '...refusing a table without one' );
    my $m = mcp( 'refresh_data_table', { table => 'plain' } );
    like( $m->{error} // '', qr/names no source/, 'refresh_data_table answers on MCP the same' );
    my $b = api( 'action=data-table-refresh', { table => 'bookings' } );
    like( $b->{error} // '', qr/connector 'bookings', which is not configured/,
        'and a sourced table whose connector is missing is told so' );
    my $desc = api( 'action=data-table&table=bookings' );
    is_deeply( $desc->{source}{read_only}, [qw(guest ref)], 'data-table names the read-only columns' );
    like( $desc->{source}{age_note} // '', qr/never refreshed/, 'and says the rows have no refresh yet' );
};

done_testing();
