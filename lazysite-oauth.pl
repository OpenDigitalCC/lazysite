#!/usr/bin/perl
# lazysite-oauth.pl - SM076 OAuth 2.1 authorization server for the MCP connector
# (Claude.ai web custom connectors are OAuth-only). Stage 1: RFC 7591 dynamic
# client registration + the shared token store; the authorize + token endpoints
# (stages 2-3) are stubbed. The metadata documents live as api pages under
# /.well-known/. See docs/feature-requests/SM076-oauth.md.
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Basename qw(dirname);
use File::Path qw(make_path);

BEGIN {
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}
use Lazysite::Util qw(log_event);
use Lazysite::Auth::Credential qw(generate_random_hex);

my $DOCROOT      = $ENV{DOCUMENT_ROOT} // $ENV{REDIRECT_DOCUMENT_ROOT} // '';
my $LAZYSITE_DIR = "$DOCROOT/lazysite";

# --- response helpers -----------------------------------------------------

sub respond_json {
    my ( $code, $obj ) = @_;
    my %reason = ( 200 => 'OK', 201 => 'Created', 400 => 'Bad Request',
        401 => 'Unauthorized', 404 => 'Not Found', 501 => 'Not Implemented' );
    binmode STDOUT, ':utf8';
    print "Status: $code " . ( $reason{$code} // 'Status' ) . "\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n";
    print "Cache-Control: no-store\r\n\r\n";
    print encode_json($obj);
    exit 0;
}

sub read_body {
    my $len = $ENV{CONTENT_LENGTH} || 0;
    my $body = '';
    read( STDIN, $body, $len ) if $len > 0;
    return $body;
}

# --- the shared OAuth store (hashed records; write-denied auth tree) -------

sub _store_path { "$LAZYSITE_DIR/auth/oauth.json" }

sub load_store {
    my $p = _store_path();
    my $empty = { clients => {}, codes => {}, tokens => {} };
    return $empty unless -f $p;
    open my $fh, '<', $p or return $empty;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $m = eval { decode_json( $raw // '{}' ) };
    return ref $m eq 'HASH' ? { %$empty, %$m } : $empty;
}

sub save_store {
    my ($m) = @_;
    my $p   = _store_path();
    my $dir = dirname($p);
    make_path($dir) unless -d $dir;
    my $tmp = "$p.tmp.$$";
    open my $fh, '>', $tmp or return 0;
    print {$fh} JSON::PP->new->canonical->encode($m);
    close $fh;
    chmod 0600, $tmp;
    return rename $tmp, $p;
}

# --- request routing ------------------------------------------------------

my %q;
for my $pair ( split /&/, $ENV{QUERY_STRING} // '' ) {
    my ( $k, $v ) = split /=/, $pair, 2;
    next unless defined $k;
    $v //= '';
    s/%([0-9A-Fa-f]{2})/chr hex $1/ge for ( $k, $v );
    $q{$k} = $v;
}
my $action = $q{action} // '';

if ( $action eq 'register' ) {
    # RFC 7591 dynamic client registration. Claude.ai self-registers a public
    # client; we record its redirect_uris and issue a client_id (no secret).
    my $req  = eval { decode_json( read_body() ) } || {};
    my @uris = ref $req->{redirect_uris} eq 'ARRAY' ? @{ $req->{redirect_uris} } : ();
    respond_json( 400, { error => 'invalid_redirect_uri',
        error_description => 'redirect_uris required' } ) unless @uris;

    my $client_id = 'lzcid_' . generate_random_hex(16);
    my $store = load_store();
    $store->{clients}{$client_id} = {
        redirect_uris => \@uris,
        client_name   => ( $req->{client_name} // '' ),
        created       => time(),
    };
    save_store($store);
    log_event( 'INFO', 'oauth', 'client registered',
        client_id => $client_id, name => ( $req->{client_name} // '' ) );

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
    # Stage 2: consent page + connect-code validation + auth-code mint.
    print "Status: 501 Not Implemented\r\n";
    print "Content-Type: text/plain; charset=utf-8\r\n\r\n";
    print "The authorize endpoint is not yet enabled (SM076 OAuth stage 2).\n";
    exit 0;
}
elsif ( $action eq 'token' ) {
    # Stage 3: authorization_code (+ PKCE) / refresh_token exchange.
    respond_json( 501, { error => 'temporarily_unavailable',
        error_description => 'token endpoint not yet enabled (SM076 OAuth stage 3)' } );
}
else {
    respond_json( 400, { error => 'invalid_request',
        error_description => 'unknown or missing action' } );
}
