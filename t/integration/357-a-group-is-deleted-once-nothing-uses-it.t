#!/usr/bin/perl
# SM1387: A GROUP IS DELETED ONCE NOTHING USES IT, on every door.
#
# No token, MCP or control-API action deleted a group. group-delete (control
# API), delete_group (MCP) and the manager's Groups page (which now calls
# group-delete) need manage_users, are audited, and are refused while the group
# holds a member or anything names it - the refusal naming what. Every place a
# group name is stored (Lazysite::Auth::GroupRefs) is tried here, one at a time:
# a page's auth_groups, an access rule's @group (read and write), a domain's
# allowed_groups and locked_groups (the primary's and an alias's), auth_group_map,
# a data table's writable_by, an Odoo binding's
# callers, a connector's callers and odoo.conf's odoo_group_map. Each is refused
# naming the place, and deleted once the reference is gone.
#
# The operator group is never deleted, by the operator either. An empty agent
# role (SM1371) is deletable. A domain-confined caller (a token, an MCP grant)
# deletes only a group it created with group-set.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL  = qw(ui api mcp webdav manage_users manage_domains manage_content);
my %CAPS = (
    op  => [qw(ui manage_users manage_domains manage_content)],
    tks => [qw(api manage_users manage_content)],
    mcs => [qw(mcp manage_users manage_content)],
);

sub spit { my ( $p, $t ) = @_; ( my $dir = $p ) =~ s{/[^/]+\z}{}; make_path($dir); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; my $t = <$fh>; close $fh; return $t }

my $s = new_site( root => $root, conf => "control_api_enabled: true\nmcp_enabled: true\n" );
my $d = $s->docroot;
make_path("$d/sites/mine");
spit( "$d/sites/mine/index.md", "# mine\n" );
for my $u ( sort keys %CAPS ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", $CAPS{$u}, \@ALL );
}
$s->users( 'group-set', 'g-op', 'manager', 'on' );
$s->add_user( 'alice', 'pw-alice-0123456789' );

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
my %tok = map { $_ => ( uapi( { action => 'token', username => $_ } )->{token} // '' ) } qw(tks mcs);

sub api {
    my ( $who, $action, $body ) = @_;
    return $s->call( $who, $action, body => $body, query => "action=$action" ) if $who !~ /^tk/;
    my $json = encode_json($body);
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "$who:$tok{$who}", '' );
    $ENV{QUERY_STRING}       = "action=$action";
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $json;
    my $out = run_child( [ $^X, "$root/lazysite-manager-api.pl" ], stdin => $json )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub mcp {
    my ( $who, $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer $who:$tok{$who}";
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}

for my $set (
    [ 'domain-add', { host => 'mine.example.org', content_root => 'sites/mine' } ],
    [ 'domain-set', { host => 'mine.example.org', key => 'allowed_groups', value => 'g-tks, g-mcs' } ],
    )
{
    my $r = api( 'op', @$set );
    ok( $r->{ok}, "set up: $set->[0]" ) or diag( $r->{error} // '' );
}

sub exists_group {
    my $j = eval { decode_json( slurp("$d/lazysite/auth/groups-settings.json") ) } || {};
    return exists $j->{ $_[0] } ? 1 : 0;
}
sub del { return api( 'op', 'group-delete', { group => $_[0] } ) }

subtest 'an empty group nothing names is deleted, and audited' => sub {
    uapi( { action => 'group-create', group => 'spare' } );
    ok( exists_group('spare'), 'set up' );
    my $r = del('spare');
    ok( $r->{ok}, 'deleted' ) or diag explain $r;
    ok( !exists_group('spare'), 'gone from the store' );
    like( slurp("$d/lazysite/logs/audit.log"), qr/group-delete.*\@spare/, 'the audit row names it' );
    is( del('spare')->{kind}, 'not-found', 'a group that is not there is not-found' );
};

subtest 'refused while it holds a member, naming it' => sub {
    uapi( { action => 'group-create', group => 'crew' } );
    $s->users( 'group-add', 'alice', 'crew' );
    my $r = del('crew');
    ok( !$r->{ok}, 'refused' );
    is( $r->{kind}, 'in-use', 'as in use' );
    like( $r->{error}, qr/alice/, 'naming the member' );
    ok( exists_group('crew'), 'still there' );
    $s->users( 'group-remove', 'alice', 'crew' );
    ok( del('crew')->{ok}, 'deleted once empty' );
};

# Each place a group is named: [ label, write the reference, remove it, pattern ].
my $conf0 = slurp("$d/lazysite/lazysite.conf");
my @PLACES = (
    [ 'a page\'s auth_groups',
        sub { spit( "$d/club.md", "---\ntitle: Club\nauth: required\nauth_groups: [ref]\n---\nHi\n" ) },
        sub { unlink "$d/club.md" }, qr/page club\.md/ ],
    [ 'a page\'s auth_groups block list',
        sub { spit( "$d/sites/mine/club.md", "---\ntitle: Club\nauth: required\nauth_groups:\n  - other\n  - ref\n---\nHi\n" ) },
        sub { unlink "$d/sites/mine/club.md" }, qr/page sites\/mine\/club\.md/ ],
    [ 'an access rule\'s read list',
        sub { spit( "$d/lazysite/auth/acls.json", encode_json( { 'members/' => { read => ['@ref'], owner => 'op' } } ) ) },
        sub { spit( "$d/lazysite/auth/acls.json", '{}' ) }, qr/access rule for members\// ],
    [ 'an access rule\'s write list',
        sub { spit( "$d/lazysite/auth/acls.json", encode_json( { 'docs/a.md' => { write => [ 'alice', '@ref' ] } } ) ) },
        sub { spit( "$d/lazysite/auth/acls.json", '{}' ) }, qr/access rule for docs\/a\.md/ ],
    [ 'an alias domain\'s allowed_groups',
        sub { spit( "$d/lazysite/lazysite.conf", $conf0 =~ s/allowed_groups: g-tks, g-mcs/allowed_groups: g-tks, g-mcs, ref/r ) },
        sub { spit( "$d/lazysite/lazysite.conf", $conf0 ) }, qr/domain mine\.example\.org allowed_groups/ ],
    [ 'an alias domain\'s locked_groups',
        sub { spit( "$d/lazysite/lazysite.conf", $conf0 . "alias.mine.example.org.locked_groups: ref\n" ) },
        sub { spit( "$d/lazysite/lazysite.conf", $conf0 ) }, qr/domain mine\.example\.org locked_groups/ ],
    [ 'the primary\'s allowed_groups',
        sub { spit( "$d/lazysite/lazysite.conf", $conf0 . "allowed_groups: ref\n" ) },
        sub { spit( "$d/lazysite/lazysite.conf", $conf0 ) }, qr/domain \(default\) allowed_groups/ ],
    [ 'auth_group_map',
        sub { spit( "$d/lazysite/lazysite.conf", $conf0 . "auth_group_map: Staff Team = ref\n" ) },
        sub { spit( "$d/lazysite/lazysite.conf", $conf0 ) }, qr/lazysite\.conf key auth_group_map/ ],
    [ 'a data table\'s writable_by',
        sub { spit( "$d/lazysite/db/tables/notes.yaml", "name: notes\nwritable_by: [editors, ref]\ncolumns: []\n" ) },
        sub { unlink "$d/lazysite/db/tables/notes.yaml" }, qr/data table notes/ ],
    [ 'an Odoo binding\'s callers',
        sub { spit( "$d/lazysite/forms/handlers.conf", "handlers:\n  - id: crm\n    type: odoo\n    callers: staff, ref\n" ) },
        sub { unlink "$d/lazysite/forms/handlers.conf" }, qr/Odoo binding crm/ ],
    [ 'a connector\'s callers',
        sub { spit( "$d/lazysite/connectors/connectors.json", encode_json( { shop => { callers => ['ref'] } } ) ) },
        sub { unlink "$d/lazysite/connectors/connectors.json" }, qr/connector shop/ ],
    [ 'odoo.conf\'s odoo_group_map',
        sub { spit( "$d/lazysite/odoo.conf", "odoo_group_map: base.group_user = ref\n" ) },
        sub { unlink "$d/lazysite/odoo.conf" }, qr/odoo\.conf key odoo_group_map/ ],
);
for my $p (@PLACES) {
    my ( $label, $add, $remove, $where ) = @$p;
    subtest "refused while $label names it" => sub {
        uapi( { action => 'group-create', group => 'ref' } );
        $add->();
        my $r = del('ref');
        ok( !$r->{ok}, 'refused' );
        is( $r->{kind}, 'in-use', 'as in use' );
        like( $r->{error} // '', $where, 'naming the place' );
        ok( exists_group('ref'), 'still there' );
        $remove->();
        $r = del('ref');
        ok( $r->{ok}, 'deleted once nothing names it' ) or diag explain $r;
    };
}

subtest 'the operator group is never deleted' => sub {
    my $r = del('g-op');
    ok( !$r->{ok}, 'refused, to the operator too' );
    like( $r->{error} // '', qr/operator group/, 'saying why' );
    ok( exists_group('g-op'), 'still there' );
};

subtest 'an empty agent role may be deleted' => sub {
    plan skip_all => 'content-agent is not seeded on this site' unless exists_group('content-agent');
    my $r = del('content-agent');
    ok( $r->{ok}, 'deleted' ) or diag explain $r;
    ok( !exists_group('content-agent'), 'gone' );
};

subtest 'a confined caller deletes only a group it created' => sub {
    uapi( { action => 'group-create', group => 'theirs' } );
    my $r = api( 'tks', 'group-delete', { group => 'theirs' } );
    ok( !$r->{ok}, 'a token is refused a group it did not create' );
    like( $r->{error} // '', qr/not created by this account/, 'saying so' );
    ok( exists_group('theirs'), 'still there' );
    ok( api( 'tks', 'group-set', { group => 'tk-made', caps => {} } )->{ok}, 'the token makes one' );
    $r = api( 'tks', 'group-delete', { group => 'tk-made' } );
    ok( $r->{ok}, '...and deletes it' ) or diag explain $r;
    ok( mcp( 'mcs', 'set_group', { group => 'mcp-made' } )->{ok}, 'an MCP grant makes one' );
    $r = mcp( 'mcs', 'delete_group', { group => 'mcp-made' } );
    ok( $r->{ok}, '...and deletes it with delete_group' ) or diag explain $r;
    ok( !exists_group('mcp-made'), 'gone' );
    $r = mcp( 'mcs', 'delete_group', { group => 'theirs' } );
    ok( !$r->{ok}, 'delete_group refuses a group it did not create' );
};

subtest 'manage_users is needed' => sub {
    $s->add_user( 'bob', 'pw-bob-0123456789' );
    $s->grant( 'bob', 'g-bob', [qw(ui manage_content)], \@ALL );
    uapi( { action => 'group-create', group => 'kept' } );
    my $r = api( 'bob', 'group-delete', { group => 'kept' } );
    ok( !$r->{ok}, 'refused without manage_users' );
    ok( exists_group('kept'), 'still there' );
};

done_testing;
