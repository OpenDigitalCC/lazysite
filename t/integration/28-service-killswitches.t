#!/usr/bin/perl
# SERVICE KILLSWITCHES (0.9.0): every network surface beyond the public page
# render is OFF unless the operator enables it in lazysite.conf - the posture
# WebDAV always had (webdav_enabled). This test verifies, on every build, that
# each surface is refused by default and reachable only once its key is set:
#   MCP            -> mcp_enabled
#   OAuth          -> oauth_enabled
#   control-API    -> control_api_enabled   (the token path; cookie UI unaffected)
#   token exchange -> token_exchange_enabled (lazysite-auth.pl exchange/rotate)
# A disabled surface must not even do its work (MCP/OAuth refuse before auth;
# the control API refuses before verifying a token).
use strict;
use warnings;
use Test::More;
use MIME::Base64 qw(encode_base64);
use IPC::Open3   qw(open3);
use Symbol       qw(gensym);
use File::Path   qw(make_path);
use File::Temp   qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# Build a fresh docroot whose conf is exactly the given extra lines (so "no
# extra" == a default site with every surface off).
sub site {
    my ($extra) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: T\n" . ( $extra // '' );
    close $cf;
    return $d;
}

# Spawn a repo CGI with the given env + stdin; return the raw response.
sub cgi {
    my ( $script, $env, $stdin ) = @_;
    local %ENV = ( %ENV, %$env );
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, "$root/$script" );
    print $w ( defined $stdin ? $stdin : '' );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    do { local $/; <$e> };
    waitpid $pid, 0;
    return $out // '';
}

# ---- MCP (mcp_enabled) --------------------------------------------------------
my $mcp_req = '{"jsonrpc":"2.0","id":1,"method":"tools/list"}';
{
    my $off = cgi( 'lazysite-mcp.pl',
        { DOCUMENT_ROOT => site(''), REQUEST_METHOD => 'POST', CONTENT_LENGTH => length $mcp_req },
        $mcp_req );
    like( $off, qr/not enabled/i, 'MCP: OFF by default -> refused (even tools/list, pre-auth)' );
    unlike( $off, qr/"tools"\s*:/, 'MCP: OFF discloses no tool list' );

    my $on = cgi( 'lazysite-mcp.pl',
        { DOCUMENT_ROOT => site("mcp_enabled: true\n"), REQUEST_METHOD => 'POST', CONTENT_LENGTH => length $mcp_req },
        $mcp_req );
    like( $on, qr/"tools"\s*:/, 'MCP: ON -> tools/list answers' );
}

# ---- OAuth (oauth_enabled) ----------------------------------------------------
{
    my $off = cgi( 'lazysite-oauth.pl',
        { DOCUMENT_ROOT => site(''), REQUEST_METHOD => 'GET', QUERY_STRING => 'action=authorize' }, '' );
    like( $off, qr/404|not enabled/i, 'OAuth: OFF by default -> 404' );

    my $on = cgi( 'lazysite-oauth.pl',
        { DOCUMENT_ROOT => site("oauth_enabled: true\n"), REQUEST_METHOD => 'GET', QUERY_STRING => 'action=authorize' }, '' );
    unlike( $on, qr/Status:\s*404/, 'OAuth: ON -> the authorize endpoint is reachable (not 404)' );
}

# ---- control-API token path (control_api_enabled) -----------------------------
my $tokauth = 'Basic ' . encode_base64( 'someone:lzs_faketoken', '' );
{
    my $off = cgi( 'lazysite-manager-api.pl',
        { DOCUMENT_ROOT => site(''), REQUEST_METHOD => 'GET',
            QUERY_STRING => 'action=whoami', HTTP_AUTHORIZATION => $tokauth }, '' );
    like( $off, qr/control API.*not.*enabled/i,
        'control-API: OFF by default -> a token is refused before it is even verified' );
    unlike( $off, qr/Invalid credentials/i, 'control-API: OFF short-circuits before credential verification' );

    my $on = cgi( 'lazysite-manager-api.pl',
        { DOCUMENT_ROOT => site("control_api_enabled: true\n"), REQUEST_METHOD => 'GET',
            QUERY_STRING => 'action=whoami', HTTP_AUTHORIZATION => $tokauth }, '' );
    like( $on, qr/Invalid credentials/i,
        'control-API: ON -> the (fake) token now reaches verification and is rejected as invalid' );
}
# The cookie manager UI is unaffected by control_api_enabled (an unsecured/dev
# site with no auth: any request is the local operator).
{
    my $cookie = cgi( 'lazysite-manager-api.pl',
        { DOCUMENT_ROOT => site(''), REQUEST_METHOD => 'GET', QUERY_STRING => 'action=whoami' }, '' );
    unlike( $cookie, qr/control API.*not.*enabled/i,
        'control-API killswitch does NOT affect the cookie manager UI path' );
}

# ---- token exchange (token_exchange_enabled) ----------------------------------
my $ex = 'pairing_key=lzp_nope';
{
    my $off = cgi( 'lazysite-auth.pl',
        { DOCUMENT_ROOT => site(''), REQUEST_METHOD => 'POST',
            QUERY_STRING => 'action=exchange', CONTENT_LENGTH => length $ex }, $ex );
    like( $off, qr/not enabled/i, 'token exchange: OFF by default -> refused' );

    my $on = cgi( 'lazysite-auth.pl',
        { DOCUMENT_ROOT => site("token_exchange_enabled: true\n"), REQUEST_METHOD => 'POST',
            QUERY_STRING => 'action=exchange', CONTENT_LENGTH => length $ex }, $ex );
    unlike( $on, qr/not enabled/i,
        'token exchange: ON -> the endpoint runs (a bad key fails for its own reason, not the killswitch)' );
}

done_testing();
