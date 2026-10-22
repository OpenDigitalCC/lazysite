#!/usr/bin/perl
# SM982 (ruled 2026-10-11, "Table ACLs bind it + row filter"): a table's read and
# write rules bind a holder of manage_data (the operator is unaffected), and a
# table may name the rows its visitor surfaces show.
#
# Reported from a members' area on 0.15.3: a member holding manage_data changed
# rows in `categories` and `people`, whose write rules did not list them, and
# read a private table its read rule excluded, through the control API; and a
# table published for page bindings served every row - including rows a
# moderator had marked hidden or spam - to an anonymous request at the data
# endpoint. Every Manager::Data row action answered `as => 'operator'` for any
# manage_data holder, and nothing asked a table's write list at all.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use TestHelper             qw(repo_root env_passthrough run_child);
use ManagerSession         qw(new_site);
use Lazysite::Data::Tables qw(apply_schema insert_row read_rows);
use Lazysite::Auth::Acl    ();

my $root = repo_root();
my $s    = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\nplugins:\n  - plugins/data.pl\n" );
my $d = $s->docroot;
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

make_path("$d/lazysite/db/tables");
spit( "$d/lazysite/db/tables/categories.yaml",
    "title: Categories\npublic: true\nkey: slug\nfields:\n  slug:\n    type: text\n  name:\n    type: text\n" );
spit( "$d/lazysite/db/tables/people.yaml",
    "title: People\nkey: slug\nfields:\n  slug:\n    type: text\n  name:\n    type: text\n" );
spit( "$d/lazysite/db/tables/feedback.yaml",
    "title: Feedback\npublic: true\nkey: slug\nwhere: status = ok\nfields:\n  slug:\n    type: text\n"
        . "  msg:\n    type: text\n  status:\n    type: enum\n    values: [ok, hidden, spam]\n" );
spit( "$d/lazysite/db/tables/comments.yaml",
    "title: Comments\npublic: true\nkey: slug\nwhere: \"status != spam\"\nfields:\n  slug:\n    type: text\n"
        . "  msg:\n    type: text\n  status:\n    type: text\n" );
apply_schema( $d, $_ ) for qw(categories people feedback comments);
insert_row( $d, 'categories', { slug => 'c1', name => 'ORIGINAL' } );
insert_row( $d, 'people',     { slug => 'p1', name => 'PRIVATE-PERSON' } );
insert_row( $d, 'feedback',   { slug => 'f1', msg => 'SHOWN-OK',   status => 'ok' } );
insert_row( $d, 'feedback',   { slug => 'f2', msg => 'HIDDEN-ROW', status => 'hidden' } );
insert_row( $d, 'feedback',   { slug => 'f3', msg => 'SPAM-ROW',   status => 'spam' } );
insert_row( $d, 'comments',   { slug => 'k1', msg => 'PLAIN-COMMENT' } );
insert_row( $d, 'comments',   { slug => 'k2', msg => 'SPAM-COMMENT', status => 'spam' } );
insert_row( $d, 'comments',   { slug => 'k3', msg => 'GOOD-COMMENT', status => 'ok' } );

my @ALL = qw(ui manage_users manage_data write_data webdav api mcp);
$s->add_user('mia');    # the reported member
$s->grant( 'mia', 'members', [qw(ui manage_data)], \@ALL );
$s->add_user('ed');
$s->grant( 'ed', 'editors', [qw(ui manage_data)], \@ALL );
$s->add_user('hal');
$s->grant( 'hal', 'hr', [qw(ui manage_data)], \@ALL );
$s->add_user('boss');    # the operator
$s->grant( 'boss', 'sysops', [qw(ui manage_users manage_data)], \@ALL );
# SM991: the operator is a member of the operator group (the `manager` flag).
$s->users( 'group-set', 'sysops', 'manager', 'on' );

# The tables' own rules, as data-table-acl-set stores them.
{
    no warnings 'once';
    local $Lazysite::Auth::Acl::DOCROOT = $d;
    my $acls = Lazysite::Auth::Acl::load_acls();
    $acls->{'lazysite/db/tables/categories'} = { owner => 'ed', write => ['@editors'] };
    $acls->{'lazysite/db/tables/people'} = { owner => 'hal', read => ['@hr'], write => ['@hr'] };
    Lazysite::Auth::Acl::save_acls($acls) or BAIL_OUT('cannot write the ACL store');
}

sub row_of {
    my ( $t, $k ) = @_;
    my $r = read_rows( $d, $t, as => 'operator', limit => 100 );
    my ($row) = grep { $_->{slug} eq $k } @{ $r->{rows} || [] };
    return $row || {};
}
sub save_row { my ( $u, $t, $k, $row ) = @_; return $s->call( $u, 'data-row-save', body => { table => $t, key => $k, row => $row } ) }
sub refused {
    my ( $r, $label ) = @_;
    ok( !$r->{ok} && ( $r->{kind} // '' ) eq 'forbidden', "$label: refused" ) or diag( explain $r );
    like( $r->{error} // '', qr/access rule does not let this account/, "$label: naming the table's rule" );
}

subtest 'the reported case: manage_data does not override a table\'s rule' => sub {
    refused( save_row( 'mia', 'categories', 'c1', { name => 'CHANGED' } ), 'a row write the write rule does not list' );
    is( row_of( 'categories', 'c1' )->{name}, 'ORIGINAL', 'and the row is unchanged' );
    refused( save_row( 'mia', 'people', 'p1', { name => 'CHANGED' } ), 'nor in a private table' );
    refused( $s->call( 'mia', 'data-row-delete', body => { table => 'categories', key => 'c1' } ), 'a delete' );
    ok( row_of( 'categories', 'c1' )->{slug}, 'and the row is still there' );
    my $r = $s->call( 'mia', 'data-rows', query => 'action=data-rows&table=people' );
    refused( $r, 'a read the read rule excludes' );
    unlike( encode_json($r), qr/PRIVATE-PERSON/, 'and no row is in the answer' );
    $r = $s->call( 'mia', 'data-export', query => 'action=data-export&table=people&format=json' );
    unlike( encode_json($r) . ( $r->{_raw} // '' ), qr/PRIVATE-PERSON/, 'nor through the download' );
};

subtest 'whoever the rule names - and the operator - still does' => sub {
    my $r = save_row( 'ed', 'categories', 'c1', { name => 'BY-ED' } );
    ok( $r->{ok}, 'an editor writes categories' ) or diag( explain $r );
    is( row_of( 'categories', 'c1' )->{name}, 'BY-ED', '...and the row says so' );
    $r = $s->call( 'hal', 'data-rows', query => 'action=data-rows&table=people' );
    ok( $r->{ok} && grep( { $_->{name} eq 'PRIVATE-PERSON' } @{ $r->{rows} || [] } ), 'hr reads people' )
        or diag( explain $r );
    $r = $s->call( 'mia', 'data-rows', query => 'action=data-rows&table=categories' );
    ok( $r->{ok}, 'a table with no read rule is read by any manage_data holder' ) or diag( explain $r );
    $r = save_row( 'boss', 'people', 'p1', { name => 'BY-THE-OPERATOR' } );
    ok( $r->{ok}, 'the operator is unaffected: it writes a table whose rule names hr' ) or diag( explain $r );
    $r = $s->call( 'boss', 'data-rows', query => 'action=data-rows&table=people' );
    ok( $r->{ok}, 'and reads it' ) or diag( explain $r );
};

# --- MCP: a token partner holding manage_data -----------------------------------
my $stub = "$d/../users-stub.pl";
spit( $stub, "#!/usr/bin/perl\nuse JSON::PP qw(encode_json);\n"
        . "print encode_json({ ok => 1, settings => { manage_data => 1, api => 1, mcp => 1 } });\n" );
chmod 0755, $stub;
sub mcp {
    my ( $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, REQUEST_METHOD => 'POST',
        CONTENT_LENGTH     => length $body, LAZYSITE_USERS_TOOL => $stub,
        HTTP_AUTHORIZATION => 'Bearer tester:lzs_tok' );
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ],
        stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || {};
}

subtest 'over MCP too: a token is never the operator' => sub {
    my $r = mcp( 'read_data_rows', { table => 'people' } );
    ok( !$r->{ok}, 'read_data_rows on a table whose read rule excludes it' ) or diag( explain $r );
    unlike( encode_json($r), qr/BY-THE-OPERATOR/, 'and no row is in the answer' );
    $r = mcp( 'save_data_row', { table => 'categories', key => 'c1', row => { name => 'BY-TOKEN' } } );
    ok( !$r->{ok}, 'save_data_row on a table whose write rule excludes it' ) or diag( explain $r );
    is( row_of( 'categories', 'c1' )->{name}, 'BY-ED', 'and the row is unchanged' );
};

# --- the data endpoint ------------------------------------------------------------
sub endpoint {
    my (%env) = @_;
    local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, REQUEST_METHOD => 'GET', QUERY_STRING => '', %env );
    my $body = delete $ENV{_BODY};
    my $out;
    if ( defined $body ) {
        $ENV{CONTENT_LENGTH} = length $body;
        $out = run_child( [ $^X, "$root/lazysite-data.pl" ],
            stdin => $body, stderr => 'inherit' )->{out};
    }
    else { $out = qx($^X \Q$root/lazysite-data.pl\E 2>/dev/null) }
    my ($st) = $out =~ /Status:\s*(\d+)/;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return ( $st // 0, ( eval { decode_json( $jb // '' ) } || {} ), $out );
}

subtest 'the data endpoint: the write rule binds manage_data there too' => sub {
    my ( $st, $r ) = endpoint( REQUEST_METHOD => 'POST', QUERY_STRING => 'table=categories',
        HTTP_COOKIE  => $s->cookie_for('mia'), HTTP_X_CSRF_TOKEN => $s->csrf_for('mia'),
        CONTENT_TYPE => 'application/json',
        _BODY => encode_json( { key => 'c1', row => { name => 'BY-ENDPOINT' } } ) );
    is( $st, 403, 'a manage_data member is refused a table its write rule does not list' ) or diag( explain $r );
    is( row_of( 'categories', 'c1' )->{name}, 'BY-ED', 'and the row is unchanged' );
};

subtest 'a published table shows only the rows its condition names' => sub {
    my ( $st, $r, $raw ) = endpoint( QUERY_STRING => 'table=feedback' );
    is( $st, 200, 'an anonymous request reads the published table' ) or diag($raw);
    like( $raw, qr/SHOWN-OK/, 'the rows the condition names' );
    unlike( $raw, qr/HIDDEN-ROW|SPAM-ROW/, 'and none of the rows it hides' );
    is( $r->{total}, 1, 'the total counts only what is shown' ) if exists $r->{total};

    ( $st, $r, $raw ) = endpoint( QUERY_STRING => 'table=feedback&status=hidden' );
    unlike( $raw, qr/HIDDEN-ROW/, 'a filter on the hidden value cannot reach them' );

    ( $st, $r, $raw ) = endpoint( QUERY_STRING => 'table=comments' );
    like( $raw, qr/PLAIN-COMMENT/, '!=: a row with no status is shown (it is unmarked)' );
    like( $raw, qr/GOOD-COMMENT/,  '!=: and a row with another status' );
    unlike( $raw, qr/SPAM-COMMENT/, '!=: but not the row it excludes' );

    my $m = $s->call( 'ed', 'data-rows', query => 'action=data-rows&table=feedback' );
    is( scalar @{ $m->{rows} || [] }, 3, 'the manager (manage_data) still sees every row - how a moderator finds them' )
        or diag( explain $m );
};

subtest 'and so does a page that binds it' => sub {
    spit( "$d/fb.md", "---\ntitle: FB\ntt_page_var:\n  rows: db:feedback\n  n: db:feedback.count\n"
            . "  one: db:feedback.field(msg,key=f2)\n---\n"
            . "[% FOREACH r IN rows %]<li>[% r.msg %]</li>[% END %] count=[% n %] one=[% one %]\n" );
    my $out = TestHelper::run_processor( $d, '/fb', HTTP_X_REMOTE_USER => undef, LAZYSITE_AUTH_TRUSTED => undef );
    like( $out, qr/SHOWN-OK/, 'the page renders the rows the condition names' ) or diag($out);
    unlike( $out, qr/HIDDEN-ROW|SPAM-ROW/, 'and none it hides' );
    like( $out, qr/count=1\b/, '.count counts only what is shown' );
    unlike( $out, qr/one=HIDDEN/, '.field by a hidden row\'s key answers nothing' );
};

subtest 'the condition is checked when the table is declared' => sub {
    require Lazysite::Data::Descriptor;
    my $fields = { status => { type => 'enum', values => [qw(ok spam)] }, n => { type => 'integer' } };
    my $load = sub { Lazysite::Data::Descriptor::load_descriptor( 't', { fields => $fields, where => $_[0] } ) };
    ok( $load->('status = ok')->{ok},    'field = value' );
    ok( $load->('status != spam')->{ok}, 'field != value' );
    is_deeply( $load->("n = '3'")->{where}, { field => 'n', op => '=', value => 3 }, 'the value is read as the field\'s type' );
    for my $bad ( 'status', 'status > ok', 'status = ok OR 1=1', 'nope = 1', 'status = maybe', 'n = x', 'status =', ['a'] ) {
        my $r = $load->($bad);
        ok( !$r->{ok} && ( $r->{rule} // '' ) eq 'where', 'refused: ' . ( ref $bad ? 'a list' : $bad ) )
            or diag( explain $r );
    }
    like( $load->('nope = 1')->{error} // '', qr/'nope', which is not a declared field/,
        'an undeclared field is refused by name, not as an odd value' );
};

done_testing();
