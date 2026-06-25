#!/usr/bin/perl
# lazysite-oauth.pl - SM076 OAuth 2.1 authorization server for the MCP connector
# (Claude.ai web custom connectors are OAuth-only). Endpoints (query ?action=):
#   register  - RFC 7591 dynamic client registration (public clients)
#   authorize - consent page; the operator-issued connect code authorises a
#               partner; mints a PKCE-bound authorization code
#   token     - authorization_code (+ PKCE verifier) / refresh_token exchange
# The discovery metadata are api pages under /.well-known/. Store + crypto live
# in Lazysite::Auth::OAuth. See docs/feature-requests/SM076-oauth.md.
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Basename qw(dirname);
use IPC::Open2;

BEGIN {
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}
use Lazysite::Util qw(log_event);
use Lazysite::Audit qw(audit_log);
use Lazysite::Auth::OAuth
    qw(register_client get_client mint_code redeem_code issue_token refresh_access);

my $DOCROOT = $ENV{DOCUMENT_ROOT} // $ENV{REDIRECT_DOCUMENT_ROOT} // '';
my $LAZYSITE_DIR = "$DOCROOT/lazysite";
$Lazysite::Auth::OAuth::LAZYSITE_DIR = $LAZYSITE_DIR;
$Lazysite::Audit::LAZYSITE_DIR        = $LAZYSITE_DIR;

# --- helpers --------------------------------------------------------------

sub respond_json {
    my ( $code, $obj ) = @_;
    my %reason = ( 200 => 'OK', 201 => 'Created', 400 => 'Bad Request',
        401 => 'Unauthorized', 404 => 'Not Found', 501 => 'Not Implemented' );
    binmode STDOUT;    # encode_json emits UTF-8 bytes; do not re-encode
    print "Status: $code " . ( $reason{$code} // 'Status' ) . "\r\n";
    print "Content-Type: application/json; charset=utf-8\r\nCache-Control: no-store\r\n\r\n";
    print encode_json($obj);
    exit 0;
}

sub read_body {
    my $len = $ENV{CONTENT_LENGTH} || 0;
    my $body = '';
    read( STDIN, $body, $len ) if $len > 0;
    return $body;
}

sub parse_form {
    my ($s) = @_;
    my %f;
    for my $pair ( split /&/, $s // '' ) {
        my ( $k, $v ) = split /=/, $pair, 2;
        next unless defined $k;
        for ( $k, $v ) { next unless defined; s/\+/ /g; s/%([0-9A-Fa-f]{2})/chr hex $1/ge }
        $f{$k} = ( defined $v ? $v : '' );
    }
    return %f;
}

sub url_enc {
    my $s = shift;
    $s //= '';
    $s =~ s/([^A-Za-z0-9_.~-])/sprintf '%%%02X', ord $1/ge;
    return $s;
}

sub hesc {
    my $s = shift;
    $s //= '';
    $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g; $s =~ s/'/&#39;/g;
    return $s;
}

sub redirect {
    my ($url) = @_;
    print "Status: 302 Found\r\nLocation: $url\r\nCache-Control: no-store\r\n\r\n";
    exit 0;
}

# Talk to the users tool (for connect-code redemption).
sub users_api {
    my ($payload) = @_;
    my $tool;
    for my $c ( $ENV{LAZYSITE_USERS_TOOL},
        dirname( Cwd::abs_path(__FILE__) ) . "/tools/lazysite-users.pl",
        dirname( Cwd::abs_path(__FILE__) ) . "/../tools/lazysite-users.pl",
        "$DOCROOT/../tools/lazysite-users.pl" ) {
        if ( defined $c && -f $c ) { $tool = $c; last }
    }
    return { ok => 0 } unless $tool;
    my ( $out, $in );
    my $pid = eval { open2( $out, $in, $^X, $tool, '--api', '--docroot', $DOCROOT ) }
        or return { ok => 0 };
    print $in encode_json($payload);
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return eval { decode_json( $resp // '{}' ) } // { ok => 0 };
}

# Render the consent page (GET, or POST with an error). The OAuth params ride
# as hidden fields so the POST can re-validate them.
sub consent_page {
    my ( $p, $error ) = @_;
    my $err = $error
        ? '<p style="color:#c33">' . hesc($error) . '</p>' : '';
    binmode STDOUT, ':utf8';
    print "Status: 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n\r\n";
    print <<"HTML";
<!doctype html><html><head><meta charset="utf-8">
<title>Authorise connection</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{font-family:system-ui,sans-serif;max-width:30rem;margin:3rem auto;padding:0 1rem}
input[type=text]{width:100%;padding:.5rem;font-size:1rem;box-sizing:border-box}
button{padding:.5rem 1rem;font-size:1rem;margin-top:.8rem}.m{color:#666;font-size:.9rem}</style>
</head><body>
<h2>Authorise this connection</h2>
<p>An application (@{[ hesc($p->{client_name} || 'an MCP client') ]}) is asking to
connect to this site as a publishing partner.</p>
$err
<p class="m">Enter the one-time <b>connect code</b> your operator generated for
this site (Users page &rarr; the partner &rarr; <i>Set up Claude.ai</i>).</p>
<form method="post" action="?action=authorize">
<input type="hidden" name="client_id" value="@{[ hesc($p->{client_id}) ]}">
<input type="hidden" name="redirect_uri" value="@{[ hesc($p->{redirect_uri}) ]}">
<input type="hidden" name="code_challenge" value="@{[ hesc($p->{code_challenge}) ]}">
<input type="hidden" name="state" value="@{[ hesc($p->{state}) ]}">
<input type="text" name="connect_code" placeholder="lzo_..." autofocus autocomplete="off">
<button type="submit">Authorise</button>
</form>
</body></html>
HTML
    exit 0;
}

# --- routing --------------------------------------------------------------

my %q      = parse_form( $ENV{QUERY_STRING} );
my $action = $q{action} // '';
my $method = $ENV{REQUEST_METHOD} // 'GET';

if ( $action eq 'register' ) {
    my $req  = eval { decode_json( read_body() ) } || {};
    my @uris = ref $req->{redirect_uris} eq 'ARRAY' ? @{ $req->{redirect_uris} } : ();
    respond_json( 400, { error => 'invalid_redirect_uri',
        error_description => 'redirect_uris required' } ) unless @uris;
    my $client_id = register_client( \@uris, $req->{client_name} );
    my $total = scalar keys %{ Lazysite::Auth::OAuth::load_store()->{clients} };
    log_event( 'INFO', 'oauth', 'client registered',
        client_id => $client_id, redirect => $uris[0], total_clients => $total );
    respond_json( 201, {
        client_id                  => $client_id,
        client_id_issued_at        => time(),
        redirect_uris              => \@uris,
        token_endpoint_auth_method => 'none',
        grant_types                => [ 'authorization_code', 'refresh_token' ],
        response_types             => ['code'],
    } );
}
elsif ( $action eq 'authorize' ) {
    my %p = $method eq 'POST' ? parse_form( read_body() ) : %q;
    my $client = get_client( $p{client_id} // '' );
    unless ($client) {
        log_event( 'WARN', 'oauth', 'authorize: client_id not registered',
            method => $method, client_id => ( $p{client_id} // '(none)' ),
            known_clients => scalar keys %{ Lazysite::Auth::OAuth::load_store()->{clients} } );
        respond_json( 400, { error => 'invalid_client' } );
    }
    my $redirect_uri = $p{redirect_uri} // '';
    my $ok_uri = grep { $_ eq $redirect_uri } @{ $client->{redirect_uris} || [] };
    unless ($ok_uri) {
        log_event( 'WARN', 'oauth', 'authorize: redirect_uri mismatch',
            got => $redirect_uri, registered => join( ' ', @{ $client->{redirect_uris} || [] } ) );
        respond_json( 400, { error => 'invalid_redirect_uri' } );
    }

    if ( $method ne 'POST' ) {
        respond_json( 400, { error => 'unsupported_response_type' } )
            unless ( $p{response_type} // '' ) eq 'code';
        respond_json( 400, { error => 'invalid_request',
            error_description => 'PKCE S256 required' } )
            unless ( $p{code_challenge_method} // '' ) eq 'S256'
            && length( $p{code_challenge} // '' );
        $p{client_name} = $client->{client_name};
        consent_page( \%p );
    }

    # POST: redeem the connect code -> partner, then mint the auth code.
    my $r = users_api( { action => 'redeem-connect-code', code => $p{connect_code} } );
    unless ( $r->{ok} ) {
        $p{client_name} = $client->{client_name};
        consent_page( \%p, 'That connect code is not valid (check it, or ask your operator for a fresh one).' );
    }
    my $code = mint_code( $p{client_id}, $r->{username}, $p{code_challenge}, $redirect_uri );
    log_event( 'INFO', 'oauth', 'authorization code issued', partner => $r->{username} );
    my $sep = ( index( $redirect_uri, '?' ) >= 0 ) ? '&' : '?';
    redirect( $redirect_uri . $sep . 'code=' . url_enc($code) . '&state=' . url_enc( $p{state} ) );
}
elsif ( $action eq 'token' ) {
    my %p = parse_form( read_body() );
    my $grant = $p{grant_type} // '';
    if ( $grant eq 'authorization_code' ) {
        my $partner = redeem_code( $p{code}, $p{client_id}, $p{code_verifier}, $p{redirect_uri} );
        respond_json( 400, { error => 'invalid_grant' } ) unless defined $partner;
        my ( $access, $refresh, $ttl ) = issue_token($partner);
        log_event( 'INFO', 'oauth', 'access token issued', partner => $partner );
        # Material event: an AI assistant just authenticated this partner over
        # OAuth (the "connected" moment the operator wants to see).
        audit_log( $partner, 'connect', 'oauth', $ENV{REMOTE_ADDR} // '', 'ok', 'mcp' );
        respond_json( 200, {
            access_token  => $access, token_type => 'Bearer',
            expires_in    => $ttl,    refresh_token => $refresh, scope => 'mcp' } );
    }
    elsif ( $grant eq 'refresh_token' ) {
        my ( $access, $refresh, $ttl ) = refresh_access( $p{refresh_token} );
        respond_json( 400, { error => 'invalid_grant' } ) unless defined $access;
        respond_json( 200, {
            access_token  => $access, token_type => 'Bearer',
            expires_in    => $ttl,    refresh_token => $refresh, scope => 'mcp' } );
    }
    else {
        respond_json( 400, { error => 'unsupported_grant_type' } );
    }
}
else {
    respond_json( 400, { error => 'invalid_request',
        error_description => 'unknown or missing action' } );
}
