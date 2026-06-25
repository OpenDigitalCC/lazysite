#!/usr/bin/perl
# SM076 OAuth stages 2-4 end to end: register -> connect code -> authorize
# (consent, PKCE) -> token -> the MCP server accepting the opaque access token.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use Digest::SHA qw(sha256);
use MIME::Base64 qw(encode_base64);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use Lazysite::Auth::OAuth qw(validate_token);

my $root  = repo_root();
my $oauth = "$root/lazysite-oauth.pl";
my $users = "$root/tools/lazysite-users.pl";
my $mcp   = "$root/lazysite-mcp.pl";
my $CB    = 'https://claude.ai/api/mcp/auth_callback';

sub b64url { my $d = encode_base64( $_[0], '' ); $d =~ tr{+/}{-_}; $d =~ s/=+$//; $d }

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
$Lazysite::Auth::OAuth::LAZYSITE_DIR = "$d/lazysite";

sub run {
    my ( $script, %o ) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{QUERY_STRING}   = $o{qs} // '';
    $ENV{REQUEST_METHOD} = $o{method} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $o{body} ? length $o{body} : 0;
    $ENV{HTTP_AUTHORIZATION} = $o{auth} if defined $o{auth};
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $script );
    print $in ( defined $o{body} ? $o{body} : '' );
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return $resp;
}
sub uapi {
    my ($p) = @_;
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $users, '--api', '--docroot', $d );
    print $in encode_json($p); close $in;
    my $r = do { local $/; <$out> }; close $out; waitpid $pid, 0;
    return decode_json($r);
}
sub jbody { my ($r) = @_; my ($b) = $r =~ /\r?\n\r?\n(.*)/s; return decode_json( $b // '{}' ) }

# --- set up a partner + an operator connect code ---
uapi( { action => 'add', username => 'claude.ai', password => 'x' } );
uapi( { action => 'settings-set', username => 'claude.ai', key => 'webdav', value => 'on' } );
my $cc = uapi( { action => 'connect-code', username => 'claude.ai' } );
like( $cc->{code}, qr/^lzo_/, 'operator issues a connect code' );

# --- 1. dynamic client registration ---
my $reg = jbody( run( $oauth, method => 'POST', qs => 'action=register',
    body => encode_json( { redirect_uris => [$CB], client_name => 'claude.ai' } ) ) );
my $client_id = $reg->{client_id};
like( $client_id, qr/^lzcid_/, 'client registered' );

# --- 2. authorize (consent POST with the connect code + PKCE) ---
my $verifier  = 'verifier-' . ( 'a' x 50 );
my $challenge = b64url( sha256($verifier) );
my $form = join '&',
    "client_id=$client_id",
    'redirect_uri=' . _enc($CB),
    "code_challenge=$challenge",
    'state=xyz',
    "connect_code=$cc->{code}";
my $auth_resp = run( $oauth, method => 'POST', qs => 'action=authorize', body => $form );
like( $auth_resp, qr/Status:\s*302/, 'authorize redirects back to the client' );
my ($code) = $auth_resp =~ /[?&]code=([^&\s]+)/;
ok( $code, 'an authorization code is returned' );
like( $auth_resp, qr/state=xyz/, 'state is echoed' );

# --- 3. token (authorization_code + PKCE verifier) ---
my $tok = jbody( run( $oauth, method => 'POST', qs => 'action=token',
    body => "grant_type=authorization_code&code=$code&code_verifier=$verifier"
          . '&redirect_uri=' . _enc($CB) . "&client_id=$client_id" ) );
like( $tok->{access_token}, qr/^lzat_/, 'access token issued' );
is( $tok->{token_type}, 'Bearer', 'bearer token type' );
ok( $tok->{refresh_token}, 'refresh token issued' );

# the access token resolves to the partner
is( validate_token( $tok->{access_token} ), 'claude.ai', 'access token maps to the partner' );

# the OAuth connect is a MATERIAL audit event ("X connected") - this is what the
# operator wants to see when an AI authenticates.
{
    open my $al, '<', "$d/lazysite/logs/audit.log" or die "no audit log: $!";
    my @lines = <$al>;
    close $al;
    ok( ( grep { /\| claude\.ai \| connect \| oauth \|/ } @lines ),
        'OAuth token issue records a material connect event for the partner' );
}

# --- 4. the MCP server accepts the opaque OAuth access token ---
my $who = jbody( run( $mcp, method => 'POST',
    body => encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
        params => { name => 'whoami', arguments => {} } } ),
    auth => "Bearer $tok->{access_token}" ) );
ok( !$who->{error}, 'whoami over OAuth token is authorized' ) or diag( encode_json($who) );
is( $who->{result}{structuredContent}{user}, 'claude.ai', 'whoami returns the partner identity' );
is( $who->{result}{structuredContent}{auth}{method}, 'oauth', 'whoami reports method=oauth for an OAuth session' );
ok( $who->{result}{structuredContent}{auth}{expires_at} > time(), 'whoami surfaces the OAuth access-token expiry (not null)' );

# detection: partner-caps stamped the credential used
ok( uapi( { action => 'credential-status', username => 'claude.ai' } )->{used},
    'the OAuth tool call marks the connector as connected (detection)' );

# --- negatives ---
my $bad = jbody( run( $oauth, method => 'POST', qs => 'action=token',
    body => "grant_type=authorization_code&code=$code&code_verifier=$verifier"
          . '&redirect_uri=' . _enc($CB) . "&client_id=$client_id" ) );
is( $bad->{error}, 'invalid_grant', 'an authorization code is single-use' );

my $cc2 = uapi( { action => 'connect-code', username => 'claude.ai' } );
my $form2 = "client_id=$client_id&redirect_uri=" . _enc($CB)
    . "&code_challenge=$challenge&state=s&connect_code=$cc2->{code}";
my ($code2) = run( $oauth, method => 'POST', qs => 'action=authorize', body => $form2 )
    =~ /[?&]code=([^&\s]+)/;
my $wrong = jbody( run( $oauth, method => 'POST', qs => 'action=token',
    body => "grant_type=authorization_code&code=$code2&code_verifier=WRONG"
          . '&redirect_uri=' . _enc($CB) . "&client_id=$client_id" ) );
is( $wrong->{error}, 'invalid_grant', 'wrong PKCE verifier is rejected' );

done_testing();

sub _enc { my $s = shift; $s =~ s/([^A-Za-z0-9_.~-])/sprintf '%%%02X', ord $1/ge; $s }
