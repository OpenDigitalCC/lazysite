#!/usr/bin/perl
# SM906 T3 (ruled 2026-09-29): the control API answers a distinct CANNOT-TELL
# state when an auth store exists and the web server cannot read it.
#
# Measured before the change, on a site built by setup-sysop with an agent
# account holding api, mcp and manage_content:
#
#   groups-settings.json chmod 000
#     token  whoami  200, 0 of 29 held
#     token  pages   403 permission "Ask the operator to grant the api capability"
#                    - to an account that held it
#     cookie pages   200 for ANY signed-in account: no group could be seen
#                    granting manager access, so the site read as unsecured and
#                    every session was an operator
#     MCP    whoami  0 of 29; list_files -32002 "Ask the sysop to grant mcp"
#   groups chmod 000              the same refusals, cookie 403 "An administrator
#                                 can grant it on the Groups page"
#   user-settings.json chmod 000  a DISABLED account's token verified and was
#                                 served (200; 400 with the store readable)
#   users chmod 000 (cookie)      whoami 0 held
#
# Every one of those is a statement about the ACCOUNT made from a fault in a
# FILE. Now each door answers kind `cannot-tell`, HTTP 503, naming the store by
# its docroot-relative path and the repair - and none of them grants anything a
# readable store would refuse.
use strict;
use warnings;
use Test::More;
use JSON::PP     qw(encode_json decode_json);
use MIME::Base64 ();
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough run_child);
use ManagerSession;

plan skip_all => 'running as root - file modes do not bind' if $> == 0;

my $root = repo_root();
my $ms   = ManagerSession::new_site( root => $root,
    conf => "site_name: T\ncontrol_api_enabled: true\nmcp_enabled: true\n" );
my $d    = $ms->docroot;
my $auth = "$d/lazysite/auth";

# Built the way an operator builds it, through the tool that owns the stores.
$ms->users( 'setup-sysop', '--user', 'ada' );
$ms->users( 'add',         'agent',  'pw123456789-long-enough' );
$ms->users( 'group-add',   'agent',  'agents' );
$ms->users( 'group-set',   'agents', $_,   'on' ) for qw(api mcp manage_content);
$ms->users( 'set',         'agent',  'ui', 'off' );    # an agent account (SM127)
my ($tok) = $ms->users( 'token', 'agent' ) =~ /^(lzs_\S+)/m;
ok( $tok, 'the agent holds a real credential' ) or BAIL_OUT('no token');

# A second agent, disabled, for the fail-closed case.
$ms->users( 'add',       'gone', 'pw123456789-long-enough' );
$ms->users( 'group-add', 'gone', 'agents' );
$ms->users( 'set',       'gone', 'ui', 'off' );
my ($gone_tok) = $ms->users( 'token', 'gone' ) =~ /^(lzs_\S+)/m;
$ms->users( 'account-disable', 'gone' );

sub token_api {
    my ( $q, $who, $secret ) = @_;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT      => $d,
        REQUEST_METHOD     => 'GET',
        QUERY_STRING       => $q,
        HTTP_AUTHORIZATION => 'Basic '
            . MIME::Base64::encode_base64( ( $who // 'agent' ) . ':' . ( $secret // $tok ), '' ),
    );
    my $out  = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    my ($st) = $out =~ /^Status:\s*(\d+)/m;
    ( my $j = $out ) =~ s/\A.*?\r?\n\r?\n//s;
    return ( $st // 0, eval { decode_json($j) } || {} );
}

sub mcp_call {
    my ($tool) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => {} } } );
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT      => $d,
        REQUEST_METHOD     => 'POST',
        CONTENT_LENGTH     => length $body,
        HTTP_AUTHORIZATION => "Bearer agent:$tok",
    );
    my $r = run_child( [ $^X, "$root/lazysite-mcp.pl" ],
        stdin => $body, stderr => 'inherit' )->{out};
    my ($st) = $r =~ /^Status:\s*(\d+)/m;
    my ($jb) = $r =~ /\r?\n\r?\n(.*)/s;
    return ( $st // 0, eval { decode_json( $jb // '' ) } || {} );
}

sub held { my ($c) = @_; return scalar grep { $c->{$_} } keys %{ $c || {} } }

# One answer, asserted the same way wherever it appears.
sub is_cannot_tell {
    my ( $label, $status, $body, $store ) = @_;
    is( $status, 503, "$label: answers 503" );
    ok( defined $body->{ok} && !$body->{ok}, "$label: refuses (ok false)" );
    is( $body->{kind}, 'cannot-tell',           "$label: kind cannot-tell" );
    is( $body->{store}, "lazysite/auth/$store", "$label: names the store, docroot-relative" );
    like( $body->{error} // '', qr/\Qlazysite check --docroot <docroot> --fix\E/,
        "$label: carries the repair" );
    unlike( $body->{error} // '', qr/\Q$d\E/, "$label: and no filesystem path" );
    unlike( $body->{error} // '', qr/ask the operator|grant it on the Groups page/i,
        "$label: and does not send the caller for a grant" );
    ok( !exists $body->{capabilities}, "$label: reports no capability list at all" );
}

subtest 'THE CONTROL: readable stores answer exactly as before' => sub {
    my ( $s, $b ) = token_api('action=whoami');
    is( $s, 200, 'token whoami 200' );
    cmp_ok( held( $b->{capabilities} ), '>=', 3, 'and the grant is held' );
    ( $s, $b ) = token_api('action=pages');
    is( $s, 200, 'token pages 200' );
    my $r = $ms->call( 'ada', 'whoami' );
    is( $ms->last_status, 200, 'cookie whoami 200' );
    cmp_ok( held( $r->{capabilities} ), '>=', 20, 'the sysop holds the sysops grant' );
    ( $s, $b ) = mcp_call('whoami');
    is( $s, 200, 'MCP whoami 200' );
    ok( $b->{result}, 'with a result' );
    ( $s, $b ) = token_api( 'action=whoami', 'gone', $gone_tok );
    is( $s,          400,                   'a disabled account is refused' );
    is( $b->{error}, 'Invalid credentials', 'as invalid credentials' );
};

for my $store (qw(groups-settings.json groups user-settings.json)) {
    subtest "UNREADABLE $store: every door says it cannot tell" => sub {
        chmod 0000, "$auth/$store" or BAIL_OUT("chmod $store: $!");
        is_cannot_tell( 'token whoami',       token_api('action=whoami'), $store );
        is_cannot_tell( 'token gated action', token_api('action=pages'),  $store );
        my $r = $ms->call( 'ada', 'whoami' );
        is_cannot_tell( 'cookie whoami', $ms->last_status, $r, $store );
        $r = $ms->call( 'ada', 'pages' );
        is_cannot_tell( 'cookie gated action', $ms->last_status, $r, $store );

        my ( $s, $m ) = mcp_call('list_files');
        is( $s,                        503,   'MCP answers 503' );
        is( $m->{error}{code},        -32003, 'with its own code, not -32001 or -32002' );
        is( $m->{error}{data}{kind},  'cannot-tell',          'kind cannot-tell' );
        is( $m->{error}{data}{store}, "lazysite/auth/$store", 'the store' );
        ( $s, $m ) = mcp_call('whoami');
        is( $m->{error}{code}, -32003, 'MCP whoami too: no empty grant' );
        chmod 0660, "$auth/$store" or BAIL_OUT("chmod back $store: $!");
    };
}

subtest 'UNREADABLE users: the cookie session cannot be resolved either' => sub {
    chmod 0000, "$auth/users" or BAIL_OUT("chmod users: $!");
    my $r = $ms->call( 'ada', 'whoami' );
    is_cannot_tell( 'cookie whoami', $ms->last_status, $r, 'users' );
    chmod 0660, "$auth/users" or BAIL_OUT("chmod back users: $!");
};

subtest 'UNREADABLE users, token caller: cannot-tell, naming nothing (ruled 2026-10-07)' => sub {
    # The secret cannot be checked, so the caller has proved nothing: it is told
    # this is not a verdict on its credential, and nothing about the host.
    chmod 0000, "$auth/users" or BAIL_OUT("chmod users: $!");
    my ( $s, $b ) = token_api('action=whoami');
    is( $s, 503, 'the API answers 503, not 400 "Invalid credentials"' );
    is( $b->{kind}, 'cannot-tell', 'kind cannot-tell' );
    ok( !exists $b->{store}, 'and names no store' );
    unlike( $b->{error} // '', qr{lazysite/|auth/|users|\Q$d\E}, 'no path or file in the message' );
    like( $b->{error} // '', qr/do not reissue/i, 'and tells the caller not to reissue a credential' );
    my ( $ms, $m ) = mcp_call('whoami');
    is( $ms, 503, 'MCP answers 503 too' );
    is( $m->{error}{code}, -32003, 'with -32003, not -32001 "reissue the token"' );
    ok( !exists $m->{error}{data}{store}, 'and names no store' );
    chmod 0660, "$auth/users" or BAIL_OUT("chmod back users: $!");
    my ( $s2, $b2 ) = token_api( 'action=whoami', 'agent', 'not-the-secret' );
    isnt( $s2, 503, 'a wrong secret on a readable store is still an ordinary refusal' );
};

subtest 'FAIL CLOSED: cannot-tell grants nothing a readable store refuses' => sub {
    chmod 0000, "$auth/user-settings.json" or BAIL_OUT("chmod: $!");
    my ( $s, $b ) = token_api( 'action=pages', 'gone', $gone_tok );
    isnt( $s, 200, "a disabled account's token is not served" );
    is( $b->{kind}, 'cannot-tell', 'it is told the engine cannot tell' );
    ok( !exists $b->{pages} && !exists $b->{urls}, 'and gets no content' );
    chmod 0660, "$auth/user-settings.json" or BAIL_OUT("chmod back: $!");

    # An unauthenticated caller learns nothing about the host's stores: a wrong
    # secret is still just invalid, whatever is unreadable.
    chmod 0000, "$auth/groups-settings.json" or BAIL_OUT("chmod: $!");
    ( $s, $b ) = token_api( 'action=whoami', 'agent', 'lzs_wrong' );
    is( $b->{error}, 'Invalid credentials', 'a wrong secret is invalid, not cannot-tell' );
    ok( !exists $b->{store}, 'and names no store' );

    # The resolver that decides "is this site secured" must not read an
    # unreadable store as an unsecured site - every session an operator.
    {
        require Lazysite::Auth::Settings;
        no warnings 'once';
        local $Lazysite::Auth::Settings::AUTH_DIR = $auth;
        is( Lazysite::Auth::Settings::site_grants_manager(), 1,
            'an unreadable group store reads as SECURED' );
    }
    chmod 0660, "$auth/groups-settings.json" or BAIL_OUT("chmod back: $!");
};

subtest 'an ABSENT store is still an answer' => sub {
    require Lazysite::Auth::Settings;
    my $empty = "$d/../empty-auth";
    mkdir $empty;
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = $empty;
    is( Lazysite::Auth::Settings::auth_cannot_tell(), '', 'nothing to be unable to read' );
    is( Lazysite::Auth::Settings::site_grants_manager(), 0,
        'and a site with no group settings is unsecured, as before' );
};

subtest 'the kind reaches the status it names' => sub {
    require Lazysite::Manager::Common;
    is( Lazysite::Manager::Common::refusal_status('cannot-tell'),
        '503 Service Unavailable', 'cannot-tell is 503' );
};

done_testing();
