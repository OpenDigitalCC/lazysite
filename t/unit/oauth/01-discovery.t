#!/usr/bin/perl
# SM076 OAuth stage 1: dynamic client registration, the stubbed authorize/token
# endpoints, and the discovery metadata documents.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $oauth = "$root/lazysite-oauth.pl";

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");

sub oauth {
    my ( $qs, $body ) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{QUERY_STRING}   = $qs;
    $ENV{REQUEST_METHOD} = defined $body ? 'POST' : 'GET';
    $ENV{CONTENT_LENGTH} = defined $body ? length($body) : 0;
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $oauth );
    print $in ( defined $body ? $body : '' );
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($status) = $resp =~ /Status:\s*(\d+)/;
    my ($jb)     = $resp =~ /\r?\n\r?\n(.*)/s;
    return ( $status, eval { decode_json( $jb // '' ) } // { _raw => $jb } );
}

# --- dynamic client registration (RFC 7591) ---
my ( $st, $r ) = oauth( 'action=register',
    encode_json( { redirect_uris => ['https://claude.ai/api/mcp/auth_callback'],
                   client_name => 'claude.ai' } ) );
is( $st, 201, 'register -> 201 Created' );
like( $r->{client_id}, qr/^lzcid_/, 'a client_id is issued' );
is( $r->{token_endpoint_auth_method}, 'none', 'public client (PKCE, no secret)' );
is_deeply( $r->{redirect_uris}, ['https://claude.ai/api/mcp/auth_callback'],
    'redirect_uris echoed' );

# persisted to the hashed store
my $store = decode_json( do {
    open my $fh, '<', "$d/lazysite/auth/oauth.json" or die $!; local $/; <$fh> } );
ok( $store->{clients}{ $r->{client_id} }, 'client recorded in oauth.json' );

# missing redirect_uris is rejected
( $st, $r ) = oauth( 'action=register', encode_json( {} ) );
is( $st, 400, 'register without redirect_uris -> 400' );

# --- authorize / token are stubbed in stage 1 ---
( $st ) = oauth('action=authorize&client_id=x');
is( $st, 501, 'authorize -> 501 (stage 2)' );
( $st, $r ) = oauth( 'action=token', 'grant_type=authorization_code' );
is( $st, 501, 'token -> 501 (stage 3)' );
is( $r->{error}, 'temporarily_unavailable', 'token stub returns an OAuth error' );

( $st, $r ) = oauth('');
is( $st, 400, 'no action -> 400 invalid_request' );

# --- discovery metadata documents carry the required fields ---
my $as = do {
    open my $fh, '<', "$root/starter/.well-known/oauth-authorization-server.md" or die $!;
    local $/; <$fh> };
like( $as, qr/"code_challenge_methods_supported":\s*\["S256"\]/, 'AS metadata mandates PKCE S256' );
like( $as, qr/"authorization_endpoint".*lazysite-oauth\.pl\?action=authorize/s, 'AS metadata points at authorize' );
like( $as, qr/"token_endpoint".*lazysite-oauth\.pl\?action=token/s, 'AS metadata points at token' );
my $pr = do {
    open my $fh, '<', "$root/starter/.well-known/oauth-protected-resource.md" or die $!;
    local $/; <$fh> };
like( $pr, qr/"resource".*lazysite-mcp\.pl/s, 'protected-resource names the MCP endpoint' );
like( $pr, qr/"authorization_servers"/, 'protected-resource names the auth server' );

done_testing();
