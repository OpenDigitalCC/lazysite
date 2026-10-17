#!/usr/bin/perl
# SM1138 (slice A of SM1134): the address lists over the manager API, the
# control API and MCP.
#
# Read: `address-lists` / `list_address_lists`, manage_users. Written:
# `address-list-set` / `address-list-delete`, THE OPERATOR's, cookie only. The
# store is written by the users tool, audited, and read back by the one module.
#
# Callers (all gated through the real CGIs):
#   op   a cookie account in the operator group (the `manager` flag, SM991)
#   ckm  a cookie account with manage_users who is NOT the operator
#   noc  a cookie account with the manager UI and no manage_users
#   tks  a token holding manage_users (domain-confined, as every token is)
#   mcs  an MCP grant holding manage_users (confined, as every MCP grant is)
#   mcn  an MCP grant holding manage_content only
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use IPC::Open2     qw(open2);
use IPC::Open3     qw(open3);
use Symbol         qw(gensym);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL  = qw(ui api mcp webdav manage_users manage_domains manage_content write_data);
my %CAPS = (
    op  => [qw(ui manage_users manage_content)],
    ckm => [qw(ui manage_users manage_content)],
    noc => [qw(ui manage_content)],
    tks => [qw(api manage_users manage_content webdav)],
    mcs => [qw(mcp manage_users manage_content webdav)],
    mcn => [qw(mcp manage_content webdav)],
);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $s = new_site( root => $root, conf => "control_api_enabled: true\nmcp_enabled: true\n" );
my $d = $s->docroot;
make_path( "$d/sites/mine" );
spit( "$d/sites/mine/index.md", "# mine\n" );
for my $u ( sort keys %CAPS ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", $CAPS{$u}, \@ALL );
}
$s->users( 'group-set', 'g-op', 'manager', 'on' );

sub uapi {
    my ($p) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
my %tok = map { $_ => ( uapi( { action => 'token', username => $_ } )->{token} // '' ) } qw(tks mcs mcn);

sub api {
    my ( $who, $action, $body, $query ) = @_;
    $query //= "action=$action";
    return $s->call( $who, $action, ( defined $body ? ( body => $body ) : () ), query => $query )
        if $who !~ /^tk/;
    my $json = defined $body ? encode_json($body) : undef;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "$who:$tok{$who}", '' );
    $ENV{QUERY_STRING}       = $query;
    $ENV{REQUEST_METHOD}     = defined $json ? 'POST'       : 'GET';
    $ENV{CONTENT_LENGTH}     = defined $json ? length $json : 0;
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, "$root/lazysite-manager-api.pl" );
    print {$w} ( $json // '' );
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub mcp_rpc {
    my ( $who, $method, $params ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => $method, params => $params } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer $who:$tok{$who}";
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } || {};
}

sub mcp {
    my ( $who, $tool, $args ) = @_;
    my $j = mcp_rpc( $who, 'tools/call', { name => $tool, arguments => $args } );
    return { ok => 0, error => $j->{error}{message}, code => $j->{error}{code} } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}

sub store_text {
    open my $fh, '<', "$d/lazysite/auth/address-lists.json" or return '';
    local $/;
    return <$fh>;
}
sub audit_lines {
    open my $fh, '<', "$d/lazysite/logs/audit.log" or return ();
    return grep { /address-list/ } <$fh>;
}

subtest 'the operator creates a list; the page and the module read it back' => sub {
    my $r = $s->call( 'op', 'address-list-set', body => { name => 'office', kind => 'allow',
            entries => [ { cidr => '203.0.113.0/24', note => 'HQ' }, { cidr => '2001:db8::/32', note => '' } ] },
        query => 'action=address-list-set' );
    ok( $r->{ok}, 'accepted' ) or diag( $r->{error} // $r->{_raw} // '' );
    is( $r->{change}, 'created kind allow +203.0.113.0/24,+2001:db8::/32', 'the change is named' );
    my $g = $s->call( 'op', 'address-lists', query => 'action=address-lists' );
    ok( $g->{ok}, 'address-lists reads' ) or diag( $g->{error} // '' );
    ok( $g->{can_edit}, 'the operator is shown the controls' );
    is_deeply( [ map { $_->{name} } @{ $g->{lists} } ], ['office'], 'one list' );
    is_deeply( $g->{lists}[0]{entries}, [ { cidr => '203.0.113.0/24', note => 'HQ' }, { cidr => '2001:db8::/32', note => '' } ],
        'with its entries and notes' );
    is( $g->{lists}[0]{entry_count}, 2, 'and the count' );

    require Lazysite::Auth::AddressLists;
    no warnings 'once';
    local $Lazysite::Auth::AddressLists::AUTH_DIR = "$d/lazysite/auth";
    ok( Lazysite::Auth::AddressLists::in_list( '203.0.113.9', 'office' ), 'the module reads what the tool wrote' );
    ok( !Lazysite::Auth::AddressLists::in_list( '198.51.100.9', 'office' ), '...and the outside is outside' );

    my @a = audit_lines();
    is( scalar @a, 1, 'one audit row' ) or diag(@a);
    like( $a[0] // '', qr/\| op \| address-list-set \| address list office \|.*\| ok \| ui \| created kind allow \+203\.0\.113\.0\/24,\+2001:db8::\/32/,
        'it names who, the list, the door and what changed' );

    $r = $s->call( 'op', 'address-list-set', body => { name => 'blocked', kind => 'deny', entries => ['198.51.100.7=scanner'] },
        query => 'action=address-list-set' );
    ok( $r->{ok}, 'a deny list' ) or diag( $r->{error} // '' );
    $r = $s->call( 'op', 'address-list-set', body => { name => 'blocked', kind => 'deny', entries => ['198.51.100.7=scanner', '192.0.2.1'] },
        query => 'action=address-list-set' );
    is( $r->{change}, '+192.0.2.1', 'an edit names what came' );
    ok( ( grep { /address list blocked \|.*\+192\.0\.2\.1/ } audit_lines() ), 'and the audit row says so' );
};

subtest 'validation reaches the operator as a sentence naming the entry' => sub {
    my $before = store_text();
    my $r = $s->call( 'op', 'address-list-set', body => { name => 'office', kind => 'allow', entries => ['0.0.0.0/0'] },
        query => 'action=address-list-set' );
    ok( !$r->{ok}, 'a prefix of 0 is refused' );
    like( $r->{error} // '', qr/0\.0\.0\.0\/0/, '...naming it' );
    $r = $s->call( 'op', 'address-list-set', body => { name => 'Not A Name', kind => 'allow' }, query => 'action=address-list-set' );
    ok( !$r->{ok} && ( $r->{field} // '' ) eq 'name', 'a bad name is refused' );
    $r = $s->call( 'op', 'address-list-set', body => { kind => 'allow' }, query => 'action=address-list-set' );
    ok( !$r->{ok}, 'a missing name is refused' );
    is( store_text(), $before, 'the store is as it was' );
};

subtest 'a manage_users holder reads and is refused the write' => sub {
    my $before = store_text();
    my $g = $s->call( 'ckm', 'address-lists', query => 'action=address-lists' );
    ok( $g->{ok}, 'reads' ) or diag( $g->{error} // $g->{_raw} // '' );
    ok( !$g->{can_edit}, 'and is shown no controls' );
    is( scalar @{ $g->{lists} }, 2, 'both lists' );
    my $r = $s->call( 'ckm', 'address-list-set', body => { name => 'sneak', kind => 'allow', entries => ['0.0.0.1'] },
        query => 'action=address-list-set' );
    ok( !$r->{ok}, 'set refused' );
    is( $r->{kind}, 'forbidden', '...forbidden' );
    like( $r->{error}, qr/Only the operator changes address lists/, '...saying whose they are' );
    $r = $s->call( 'ckm', 'address-list-delete', body => { name => 'office' }, query => 'action=address-list-delete' );
    ok( !$r->{ok} && $r->{kind} eq 'forbidden', 'delete refused' );
    is( store_text(), $before, 'the store is untouched' );
};

subtest 'without manage_users the page and the API refuse the account' => sub {
    my $g = $s->call( 'noc', 'address-lists', query => 'action=address-lists' );
    ok( !$g->{ok}, 'the read is refused' );
    ok( ManagerSession->refused_for_capability($g), 'and for the capability' ) or diag( $g->{error} // $g->{_raw} // '' );
    my $r = $s->call( 'noc', 'address-list-set', body => { name => 'x', kind => 'allow' }, query => 'action=address-list-set' );
    ok( ManagerSession->refused_for_capability($r), 'the write is refused for the capability' ) or diag( $r->{error} // $r->{_raw} // '' );
    ok( !-e "$d/lazysite/auth/address-lists.json.tmp" && store_text() !~ /"x"/, 'nothing written' );
};

subtest 'a token reads names and counts, never the writes' => sub {
    my $g = api( 'tks', 'address-lists' );
    ok( $g->{ok}, 'a manage_users token reads' ) or diag( $g->{error} // $g->{_raw} // '' );
    ok( $g->{confined}, '...as a confined caller' );
    is_deeply( [ map { $_->{name} } @{ $g->{lists} } ], [qw(blocked office)], '...the names' );
    ok( !( grep { exists $_->{entries} } @{ $g->{lists} } ), '...no entries (the site\'s addresses stay in the manager)' );
    is_deeply( [ map { $_->{entry_count} } @{ $g->{lists} } ], [ 2, 2 ], '...with the counts' );
    ok( $g->{can_edit} ? 0 : 1, '...and no controls' );
    unlike( encode_json($g), qr/203\.0\.113|198\.51\.100|HQ|scanner/, 'no address and no note anywhere in the answer' );

    my $before = store_text();
    for my $act ( 'address-list-set', 'address-list-delete' ) {
        my $r = api( 'tks', $act, { name => 'office', kind => 'deny' } );
        ok( !$r->{ok}, "$act is refused to a token" );
        like( $r->{error} // '', qr/cookie|manager|not available|operator/i, "...with a reason ($r->{kind})" );
    }
    is( store_text(), $before, 'the store is untouched' );
    my $acts = api( 'tks', 'actions-list' );
    my %by = map { $_->{action} => $_ } @{ $acts->{actions} || [] };
    ok( $by{'address-lists'} && !$by{'address-list-set'}, 'actions-list shows the read and not the cookie-only writes to a token' )
        or diag( join ',', sort keys %by );
};

subtest 'MCP: list_address_lists for manage_users, nothing for anyone else, no write tool' => sub {
    my $r = mcp( 'mcs', 'list_address_lists', {} );
    ok( $r->{ok}, 'a manage_users grant reads' ) or diag( $r->{error} // '' );
    is_deeply( [ map { $_->{name} } @{ $r->{lists} } ], [qw(blocked office)], '...the names' );
    unlike( encode_json($r), qr/203\.0\.113|198\.51\.100|HQ|scanner/, '...and no address or note' );
    my $n = mcp( 'mcn', 'list_address_lists', {} );
    ok( !$n->{ok}, 'a grant without manage_users is refused' );
    like( $n->{error} // '', qr/manage_users/, '...naming the capability' );
    my %tools = map { $_->{name} => 1 } @{ mcp_rpc( 'mcs', 'tools/list', {} )->{result}{tools} || [] };
    ok( $tools{list_address_lists}, 'tools/list offers the read to manage_users' );
    ok( !( grep { /address_list/ && $_ ne 'list_address_lists' } keys %tools ), 'and offers no write tool' );
    my %tn = map { $_->{name} => 1 } @{ mcp_rpc( 'mcn', 'tools/list', {} )->{result}{tools} || [] };
    ok( !$tn{list_address_lists}, 'and does not offer it without manage_users' );
    my $w = mcp( 'mcs', 'set_address_list', { name => 'x', kind => 'allow' } );
    ok( !$w->{ok}, 'a write tool by that name does not exist' );
};

subtest 'the operator deletes a list; the audit row names it' => sub {
    my $r = $s->call( 'op', 'address-list-delete', body => { name => 'blocked' }, query => 'action=address-list-delete' );
    ok( $r->{ok}, 'deleted' ) or diag( $r->{error} // '' );
    like( $r->{change}, qr/\Adeleted \(2 entries, deny\)\z/, 'the change' );
    ok( ( grep { /\| op \| address-list-delete \| address list blocked \|.*deleted \(2 entries, deny\)/ } audit_lines() ), 'the audit row' );
    $r = $s->call( 'op', 'address-list-delete', body => { name => 'blocked' }, query => 'action=address-list-delete' );
    ok( !$r->{ok} && $r->{kind} eq 'not-found', 'again: not found' );
    my @refused = grep { /address-list-set \| address list sneak/ } audit_lines();
    ok( scalar @refused, 'a refused change is on the trail as a failure too' ) or diag( join '', audit_lines() );
    like( $refused[0] // '', qr/\| ckm \|.*\| fail \|/, '...as ckm, failed' );
};

subtest 'the manager module refuses a non-operator before the users tool is asked' => sub {
    require Lazysite::Manager::AddressLists;
    require Lazysite::Manager::Common;
    my $asked = 0;
    no warnings 'redefine';
    local *Lazysite::Manager::Common::users_api = sub { $asked++; return { ok => 1 } };
    for my $who ( { actor => 'ckm', operator => 0 }, { actor => 'tks', operator => 0, confined => 1 }, { actor => '', operator => 1 } ) {
        my $r = Lazysite::Manager::AddressLists::address_list_set( { name => 'x', kind => 'allow' }, %$who );
        ok( !$r->{ok} && $r->{kind} eq 'forbidden', "set refused for actor '$who->{actor}' operator=$who->{operator}" );
        $r = Lazysite::Manager::AddressLists::address_list_delete( { name => 'x' }, %$who );
        ok( !$r->{ok} && $r->{kind} eq 'forbidden', '...and delete' );
    }
    is( $asked, 0, 'the users tool was never asked' );
    my $r = Lazysite::Manager::AddressLists::address_list_set( { name => 'x', kind => 'allow' }, actor => 'op', operator => 1 );
    ok( $r->{ok} && $asked == 1, 'the operator is passed through to the tool' );
};

subtest 'a store that does not decode is shown as such, never as no lists' => sub {
    spit( "$d/lazysite/auth/address-lists.json", '{ "office": ' );
    my $g = $s->call( 'op', 'address-lists', query => 'action=address-lists' );
    ok( !$g->{ok}, 'the read is not ok' );
    is( $g->{kind}, 'cannot-tell', '...cannot-tell' );
    like( $g->{error} // '', qr/does not decode as a JSON object/, '...and says what is wrong' );
    my $r = $s->call( 'op', 'address-list-set', body => { name => 'x', kind => 'allow' }, query => 'action=address-list-set' );
    ok( !$r->{ok} && $r->{kind} eq 'cannot-tell', 'a write refuses over it' );
    is( store_text(), '{ "office": ', 'the file is as it was' );
};

done_testing;
