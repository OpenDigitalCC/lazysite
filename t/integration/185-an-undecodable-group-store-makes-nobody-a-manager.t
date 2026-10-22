#!/usr/bin/perl
# SM1024 (ruled 2026-10-12, "fail closed everywhere"): a groups-settings.json
# that exists and does not decode is answered exactly as one that will not open.
#
# SM906 made an UNREADABLE store fail closed: the manager answers cannot-tell and
# nobody becomes a manager by it. A store that OPENED and did not decode still
# read as "no groups" in Lazysite::Auth::Settings - and no group granting manager
# access is the unsecured mode (SM138), in which every authenticated account is
# a manager and an operator. Measured on n436 before the change, with a stray
# truncation in the store: a signed-in account in no group at all was served the
# manager API (200) and was an ACL operator, while the render path already
# treated the same file as a secured site.
#
# Now every reader agrees with the render path: the manager refuses every door
# with kind `cannot-tell` naming the store until it is repaired, the resolvers
# answer "secured" and "not assignable", and no writer replaces the store it
# could not decode.
use strict;
use warnings;
use Test::More;
use JSON::PP      qw(encode_json decode_json);
use MIME::Base64  ();
use File::Compare qw(compare);
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough run_child);
use ManagerSession;

my $root = repo_root();
my $ms   = ManagerSession::new_site( root => $root,
    conf => "site_name: T\ncontrol_api_enabled: true\nmcp_enabled: true\n" );
my $d    = $ms->docroot;
my $auth = "$d/lazysite/auth";
my $GS   = "$auth/groups-settings.json";

$ms->users( 'setup-sysop', '--user', 'ada' );
$ms->users( 'add',         'agent',  'pw123456789-long-enough' );
$ms->users( 'group-add',   'agent',  'agents' );
$ms->users( 'group-set',   'agents', $_,   'on' ) for qw(api mcp manage_content);
$ms->users( 'set',         'agent',  'ui', 'off' );
my ($tok) = $ms->users( 'token', 'agent' ) =~ /^(lzs_\S+)/m;
ok( $tok, 'the agent holds a real credential' ) or BAIL_OUT('no token');
$ms->users( 'add', 'bob', 'pw123456789-long-enough' );    # signed in, in no group at all

sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or die "$p: $!"; local $/; return scalar <$fh> }
sub put { my ( $p, $c ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

my $GOOD = slurp($GS);
ok( length $GOOD, 'the tool wrote a group store' );

sub token_api {
    my ($q) = @_;
    local %ENV = ( env_passthrough(),
        DOCUMENT_ROOT      => $d,
        REQUEST_METHOD     => 'GET',
        QUERY_STRING       => $q,
        HTTP_AUTHORIZATION => 'Basic ' . MIME::Base64::encode_base64( "agent:$tok", '' ),
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

sub is_cannot_tell {
    my ( $label, $status, $body ) = @_;
    is( $status,        503,           "$label: answers 503" ) or diag( explain($body) );
    is( $body->{kind},  'cannot-tell', "$label: kind cannot-tell" );
    is( $body->{store}, 'lazysite/auth/groups-settings.json', "$label: names the store" );
    like( $body->{error} // '', qr/does not decode/, "$label: says the store does not decode" );
    unlike( $body->{error} // '', qr/permission fault/i,
        "$label: and does not call it a permission fault" );
    ok( length( $body->{repair} // '' ), "$label: carries a repair" );
    unlike( $body->{error} // '', qr/\Q$d\E/, "$label: and no filesystem path" );
    ok( !exists $body->{capabilities}, "$label: reports no capability list" );
}

# Asked in-process, as the manager API and the auth wrapper ask it.
sub resolver {
    require Lazysite::Auth::Settings;
    require Lazysite::Auth::Acl;
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = $auth;
    local $Lazysite::Auth::Acl::DOCROOT       = $d;
    local $Lazysite::Auth::Acl::auth_user     = 'bob';
    local $Lazysite::Auth::Acl::token_auth    = 0;
    local $ENV{HTTP_X_REMOTE_GROUPS}          = '';
    return {
        secured    => Lazysite::Auth::Settings::site_grants_manager(),
        cannot     => Lazysite::Auth::Settings::auth_cannot_tell(),
        assignable => Lazysite::Auth::Settings::group_is_assignable('cap-content'),
        operator   => Lazysite::Auth::Acl::_is_operator(),
    };
}

subtest 'THE CONTROL: a readable store keeps a non-manager out' => sub {
    my $r = $ms->call( 'bob', 'users' );
    isnt( $ms->last_status, 200, 'bob is not served the account list' );
    $r = $ms->call( 'ada', 'whoami' );
    is( $ms->last_status, 200, 'the sysop is served' );
    my ( $s, $b ) = token_api('action=whoami');
    is( $s, 200, 'the agent token is served' );
    my $v = resolver();
    is( $v->{secured},  1,  'the site reads as secured' );
    is( $v->{cannot},   '', 'and the engine can tell' );
    is( $v->{operator}, 0,  'bob is not an operator' );
};

for my $case (
    [ 'a truncated object', qq({ "sysops": { "ui": 1, "manager": 1 \n) ],
    [ 'a JSON array',       qq([ "sysops" ]\n) ],
    [ 'an empty file',      '' ],
    )
{
    my ( $what, $bytes ) = @$case;
    subtest "UNDECODABLE ($what): nobody becomes a manager" => sub {
        put( $GS, $bytes );

        my $r = $ms->call( 'bob', 'users' );
        is_cannot_tell( 'cookie, a signed-in account in no group', $ms->last_status, $r );
        $r = $ms->call( 'bob', 'whoami' );
        is_cannot_tell( 'cookie whoami', $ms->last_status, $r );
        $r = $ms->call( 'ada', 'pages' );
        is_cannot_tell( 'cookie, the sysop too', $ms->last_status, $r );
        is_cannot_tell( 'token whoami', token_api('action=whoami') );

        my ( $s, $m ) = mcp_call('list_files');
        is( $s,                 503,   'MCP answers 503' );
        is( $m->{error}{code}, -32003, 'MCP -32003' );
        is( $m->{error}{data}{store}, 'lazysite/auth/groups-settings.json', 'MCP names the store' );

        my $v = resolver();
        is( $v->{secured}, 1, 'site_grants_manager: secured, not the unsecured mode' );
        is( $v->{cannot}, 'lazysite/auth/groups-settings.json', 'auth_cannot_tell names it' );
        is( $v->{assignable}, 0, 'group_is_assignable: strict' );
        is( $v->{operator},   0, 'Auth::Acl: bob is not an operator' );

        my $out = $ms->users( 'group-set', 'agents', 'manage_users', 'on' );
        like( $out, qr/does not decode/, 'the users tool refuses to write over it' );
        is( slurp($GS), $bytes, 'and the store is byte-for-byte as it was' );
    };
}

subtest 'REPAIRED: the store answers again' => sub {
    put( $GS, $GOOD );
    my $r = $ms->call( 'ada', 'whoami' );
    is( $ms->last_status, 200, 'the sysop is served' );
    $r = $ms->call( 'bob', 'users' );
    isnt( $ms->last_status, 200, 'bob is still kept out' );
    isnt( $ms->last_status, 503, 'by an ordinary refusal, not cannot-tell' );
    is( resolver()->{cannot}, '', 'the engine can tell' );
};

subtest 'an ABSENT store is still the unsecured mode' => sub {
    unlink $GS;
    my $v = resolver();
    is( $v->{secured}, 0,  'absent: no group grants manager access (SM138)' );
    is( $v->{cannot},  '', 'and nothing to be unable to read' );
    put( $GS, $GOOD );
};

done_testing();
