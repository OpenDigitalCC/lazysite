#!/usr/bin/perl
# SM1408: A TOKEN'S GROUP REFUSAL SAYS WHAT IT IS.
#
# Lazysite::Manager::Groups sets `confined` for every token, so a token deletes
# and changes only the groups it created with group-set (set_group over MCP).
# The rule is right. Its words were "A domain-confined caller deletes only the
# groups it created ...; ask the operator", and a sysops token confined to no
# domain read that as wrong (0.16.7 edge, T-104). The refusal now says a token
# is bound by it and the operator deletes (changes) any group from the
# manager's Groups page, on group-delete and group-set, over the control API
# and over MCP. The MCP tool's description says the same.
#
# With the change reverted: the refusals say "domain-confined caller" and name
# no Groups page.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use MIME::Base64   qw(encode_base64);
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL  = qw(ui api mcp manage_users);
my %CAPS = ( tks => [qw(api manage_users)], mcs => [qw(mcp manage_users)] );

my $s = new_site( root => $root, conf => "control_api_enabled: true\nmcp_enabled: true\n" );
my $d = $s->docroot;
for my $u ( sort keys %CAPS ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", $CAPS{$u}, \@ALL );
}

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
my %tok = map { $_ => ( uapi( { action => 'token', username => $_ } )->{token} // '' ) } qw(tks mcs);

sub api {
    my ( $action, $body ) = @_;
    my $json = encode_json($body);
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "tks:$tok{tks}", '' );
    $ENV{QUERY_STRING}       = "action=$action";
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $json;
    my $out = run_child( [ $^X, "$root/lazysite-manager-api.pl" ], stdin => $json )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub mcp_rpc {
    my ( $method, $params ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => $method, params => $params } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer mcs:$tok{mcs}";
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } || {};
}

sub mcp {
    my ( $tool, $args ) = @_;
    my $j = mcp_rpc( 'tools/call', { name => $tool, arguments => $args } );
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}

uapi( { action => 'group-create', group => 'theirs' } );

sub says_what_it_is {
    my ( $r, $verb, $door ) = @_;
    ok( !$r->{ok}, "$door: refused a group the token did not create" ) or return;
    is( $r->{kind}, 'forbidden', "$door: forbidden" );
    my $e = $r->{error} // '';
    like( $e, qr/not created by this account/, "$door: says why" );
    like( $e, qr/A token, or an account whose groups confine it to a domain, $verb only the groups it created/,
        "$door: says a token is bound by the rule" );
    like( $e, qr/group-set, or set_group over MCP/, "$door: names the door that creates one" );
    like( $e, qr/the operator $verb any group from the manager's Groups page/, "$door: and who is not" );
    unlike( $e, qr/domain-confined caller/, "$door: no longer calls an unscoped token domain-confined" );
}

subtest 'group-delete and delete_group' => sub {
    says_what_it_is( api( 'group-delete', { group => 'theirs' } ), 'deletes', 'control API' );
    says_what_it_is( mcp( 'delete_group', { group => 'theirs' } ), 'deletes', 'MCP' );
};

subtest 'group-set and set_group' => sub {
    says_what_it_is( api( 'group-set', { group => 'theirs', caps => {} } ), 'changes', 'control API' );
    says_what_it_is( mcp( 'set_group', { group => 'theirs', caps => {} } ), 'changes', 'MCP' );
};

subtest 'the rule itself is unchanged' => sub {
    ok( api( 'group-set', { group => 'tk-made', caps => {} } )->{ok}, 'a token makes a group' );
    ok( api( 'group-delete', { group => 'tk-made' } )->{ok}, '...and deletes it' );
    my $gs = eval { decode_json( do { local $/; open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or die $!; <$fh> } ) } || {};
    ok( $gs->{theirs}, 'the group it did not create is still there' );
};

subtest 'delete_group\'s description says the same' => sub {
    my $tools = mcp_rpc( 'tools/list', {} )->{result}{tools} || [];
    my ($t) = grep { $_->{name} eq 'delete_group' } @$tools;
    ok( $t, 'delete_group is listed' ) or return;
    like( $t->{description}, qr/A token deletes only the groups it created with set_group/, 'a token' );
    like( $t->{description}, qr/the operator deletes any group from the manager's Groups page/, 'and the operator' );
};

done_testing;
