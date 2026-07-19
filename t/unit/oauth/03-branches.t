#!/usr/bin/perl
# SM076 OAuth branch coverage (2026-07-10 review D3, recommendation 2):
# the error and refusal paths of lazysite-oauth.pl that 01/02 leave
# untested - malformed registration, redirect_uri mismatch, the GET
# consent page and its PKCE refusals, the invalid-connect-code retry,
# the refresh_token grant (rotation + refusals), and form-parsing edges.
use strict;
use warnings;
use Test::More;
use File::Temp   qw(tempdir);
use File::Path   qw(make_path);
use JSON::PP     qw(encode_json decode_json);
use Digest::SHA  qw(sha256);
use MIME::Base64 qw(encode_base64);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper            qw(repo_root);
use Lazysite::Auth::OAuth qw(validate_token);

my $root  = repo_root();
my $oauth = "$root/lazysite-oauth.pl";
my $users = "$root/tools/lazysite-users.pl";
my $CB    = 'https://claude.ai/api/mcp/auth_callback';

sub b64url { my $d = encode_base64( $_[0], '' ); $d =~ tr{+/}{-_}; $d =~ s/=+$//; $d }
sub _enc { my $s = shift; $s =~ s/([^A-Za-z0-9_.~-])/sprintf '%%%02X', ord $1/ge; $s }

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
{ open my $oc, '>', "$d/lazysite/lazysite.conf" or die $!; print $oc "oauth_enabled: true\n"; close $oc; }
$Lazysite::Auth::OAuth::LAZYSITE_DIR = "$d/lazysite";

sub run {
    my (%o) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{QUERY_STRING}   = $o{qs} // '';
    $ENV{REQUEST_METHOD} = $o{method} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $o{body} ? length $o{body} : 0;
    $ENV{$_}             = $o{env}{$_} for keys %{ $o{env} || {} };
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $oauth );
    print $in ( defined $o{body} ? $o{body} : '' );
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return $resp;
}

sub status { my ($r) = @_; my ($s) = $r =~ /Status:\s*(\d+)/; return $s }
sub jbody { my ($r) = @_; my ($b) = $r =~ /\r?\n\r?\n(.*)/s; return decode_json( $b // '{}' ) }

sub uapi {
    my ($p) = @_;
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $users, '--api', '--docroot', $d );
    print $in encode_json($p); close $in;
    my $r = do { local $/; <$out> }; close $out; waitpid $pid, 0;
    return decode_json($r);
}

# --- registration refusals -------------------------------------------------

my $r = run( method => 'POST', qs => 'action=register', body => 'this is {not json' );
is( status($r),         400, 'register with a malformed JSON body -> 400' );
is( jbody($r)->{error}, 'invalid_redirect_uri', 'malformed body reads as no redirect_uris' );

$r = run( method => 'POST', qs => 'action=register',
    body => encode_json( { redirect_uris => $CB } ) );
is( status($r), 400, 'register with redirect_uris not an array -> 400' );

# a nameless client registers fine (client_name is optional)
$r = run( method => 'POST', qs => 'action=register',
    body => encode_json( { redirect_uris => [$CB] } ) );
is( status($r), 201, 'register without client_name -> 201' );
my $anon_id = jbody($r)->{client_id};
like( $anon_id, qr/^lzcid_/, 'nameless client gets an id' );

# a named client for the consent-page tests
$r = run( method => 'POST', qs => 'action=register',
    body => encode_json( { redirect_uris => [$CB], client_name => 'Branch Tester' } ) );
my $client_id = jbody($r)->{client_id};
like( $client_id, qr/^lzcid_/, 'named client registered' );

# --- authorize: redirect_uri validation ------------------------------------

$r = run( qs => "action=authorize&client_id=$client_id&redirect_uri=" . _enc('https://evil.example/cb') );
is( status($r), 400, 'registered client with an unregistered redirect_uri -> 400' );
is( jbody($r)->{error}, 'invalid_redirect_uri', 'invalid_redirect_uri error' );

# a store record with NO redirect_uris list refuses every redirect_uri
{
    my $m = Lazysite::Auth::OAuth::load_store();
    $m->{clients}{lzcid_bare} = { client_name => 'bare', created => time() };
    Lazysite::Auth::OAuth::save_store($m);
}
$r = run( qs => 'action=authorize&client_id=lzcid_bare&redirect_uri=' . _enc($CB) );
is( status($r),         400, 'client record without redirect_uris refuses -> 400' );
is( jbody($r)->{error}, 'invalid_redirect_uri', 'invalid_redirect_uri for a bare client' );

# --- authorize GET: response_type and PKCE refusals, then the consent page --

my $base = "action=authorize&client_id=$client_id&redirect_uri=" . _enc($CB);

$r = run( qs => $base );
is( status($r),         400, 'GET authorize without response_type -> 400' );
is( jbody($r)->{error}, 'unsupported_response_type', 'unsupported_response_type error' );

$r = run( qs => "$base&response_type=code&code_challenge_method=plain&code_challenge=abc" );
is( status($r), 400, 'PKCE method plain -> 400' );
my $j = jbody($r);
is( $j->{error}, 'invalid_request', 'invalid_request for non-S256 PKCE' );
like( $j->{error_description}, qr/S256/, 'the error names the required method' );

$r = run( qs => "$base&response_type=code&code_challenge_method=S256&code_challenge=" );
is( status($r),         400, 'S256 with an empty challenge -> 400 invalid_request' );
is( jbody($r)->{error}, 'invalid_request', 'empty challenge refused' );

my $challenge = b64url( sha256( 'v' x 50 ) );
$r = run( qs => "$base&response_type=code&code_challenge_method=S256"
        . "&code_challenge=$challenge&state=st1" );
is( status($r), 200, 'valid GET authorize -> 200 consent page' );
like( $r, qr/Branch Tester/, 'the consent page names the client' );
like( $r, qr/name="client_id" value="\Q$client_id\E"/, 'client_id rides as a hidden field' );
like( $r, qr/name="connect_code"/, 'the consent form asks for the connect code' );
unlike( $r, qr/color:#c33/, 'no error banner on first render' );

# a nameless client falls back to the generic label
$r = run( qs => "action=authorize&client_id=$anon_id&redirect_uri=" . _enc($CB)
        . "&response_type=code&code_challenge_method=S256&code_challenge=$challenge" );
like( $r, qr/an MCP client/, 'nameless client shown as "an MCP client"' );

# --- authorize POST: connect-code refusals ----------------------------------

my $form = "client_id=$client_id&redirect_uri=" . _enc($CB)
    . "&code_challenge=$challenge&state=st2&connect_code=lzo_wrong";
$r = run( method => 'POST', qs => 'action=authorize', body => $form );
is( status($r), 200, 'invalid connect code re-renders the consent page' );
like( $r, qr/not valid/,  'the page explains the code was refused' );
like( $r, qr/color:#c33/, 'the refusal renders as an error banner' );
unlike( $r, qr/Status:\s*302/, 'no redirect on a refused code' );
{
    open my $al, '<', "$d/lazysite/logs/audit.log" or die "no audit log: $!";
    my @lines = <$al>;
    close $al;
    ok( ( grep { /oauth-authorize.*fail.*invalid-connect-code/ } @lines ),
        'the refused connect code is audit-logged as a failure' );
}

# a users tool that answers garbage reads as a refusal, not a crash
my $garbage = "$d/garbage-users.pl";
{
    open my $fh, '>', $garbage or die $!;
    print {$fh} "local \$/; my \$x = <STDIN>; print 'this is not json';\n";
    close $fh;
}
$r = run( method => 'POST', qs => 'action=authorize', body => $form,
    env => { LAZYSITE_USERS_TOOL => $garbage } );
is( status($r), 200, 'garbage from the users tool -> consent page again' );
like( $r, qr/not valid/, 'garbage users-tool output is treated as a refusal' );

# --- authorize POST: redirect_uri that already carries a query string --------

uapi( { action => 'add', username => 'claude.ai', password => 'x' } );
uapi( { action => 'settings-set', username => 'claude.ai', key => 'webdav', value => 'on' } );

my $qcb = 'https://client.example/cb?x=1';
$r = run( method => 'POST', qs => 'action=register',
    body => encode_json( { redirect_uris => [$qcb], client_name => 'q' } ) );
my $qid = jbody($r)->{client_id};
my $cc  = uapi( { action => 'connect-code', username => 'claude.ai' } );
like( $cc->{code}, qr/^lzo_/, 'operator issues a connect code' );
$form = "client_id=$qid&redirect_uri=" . _enc($qcb)
    . "&code_challenge=$challenge&connect_code=$cc->{code}";
$r = run( method => 'POST', qs => 'action=authorize', body => $form );
like( $r, qr/Status:\s*302/, 'valid connect code redirects' );
my ($loc) = $r =~ /Location:\s*(\S+)/;
like( $loc, qr/\?x=1&code=/, 'the code is appended with & when the uri has a query' );
like( $loc, qr/&state=$/,    'an absent state is echoed empty, not dropped' );
my ($code) = $loc =~ /[?&]code=([^&\s]+)/;
ok( $code, 'an authorization code came back' );

# --- token: the refresh_token grant ------------------------------------------

my $tok = jbody( run( method => 'POST', qs => 'action=token',
        body => "grant_type=authorization_code&code=$code&code_verifier=" . ( 'v' x 50 )
            . '&redirect_uri=' . _enc($qcb) . "&client_id=$qid" ) );
like( $tok->{access_token}, qr/^lzat_/, 'access token issued for the refresh tests' );
ok( $tok->{refresh_token}, 'refresh token issued' );

$r = run( method => 'POST', qs => 'action=token',
    body => "grant_type=refresh_token&refresh_token=$tok->{refresh_token}" );
is( status($r), 200, 'refresh_token grant -> 200' );
my $tok2 = jbody($r);
like( $tok2->{access_token}, qr/^lzat_/, 'a fresh access token is minted' );
isnt( $tok2->{access_token}, $tok->{access_token}, 'the access token is new' );
ok( $tok2->{refresh_token}, 'a rotated refresh token is returned' );
isnt( $tok2->{refresh_token}, $tok->{refresh_token}, 'the refresh token rotates' );
cmp_ok( $tok2->{expires_in}, '>', 0, 'expires_in is a positive TTL' );
is( validate_token( $tok2->{access_token} ), 'claude.ai',
    'the refreshed access token maps to the partner' );
{
    open my $al, '<', "$d/lazysite/logs/audit.log" or die "no audit log: $!";
    my @lines = <$al>;
    close $al;
    ok( ( grep { /\| claude\.ai \| oauth-refresh \|/ } @lines ),
        'the refresh is audit-logged for the partner' );
}

# rotation: the spent refresh token is dead
$r = run( method => 'POST', qs => 'action=token',
    body => "grant_type=refresh_token&refresh_token=$tok->{refresh_token}" );
is( status($r),         400,             'a spent refresh token -> 400' );
is( jbody($r)->{error}, 'invalid_grant', 'spent refresh token is invalid_grant' );

$r = run( method => 'POST', qs => 'action=token',
    body => 'grant_type=refresh_token&refresh_token=lzrt_bogus' );
is( jbody($r)->{error}, 'invalid_grant', 'an unknown refresh token is refused' );

$r = run( method => 'POST', qs => 'action=token', body => 'grant_type=refresh_token' );
is( jbody($r)->{error}, 'invalid_grant', 'refresh without a token is refused' );

# --- request-parsing edges ----------------------------------------------------

$r = run( method => 'POST', qs => 'action=token', body => '' );
is( jbody($r)->{error}, 'unsupported_grant_type', 'an empty POST body -> unsupported_grant_type' );

$r = run( method => 'POST', qs => 'action=token', body => 'grant_type=nope&&flag' );
is( jbody($r)->{error}, 'unsupported_grant_type',
    'empty and valueless form pairs parse without error' );

done_testing();
