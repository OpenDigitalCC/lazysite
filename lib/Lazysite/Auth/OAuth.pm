package Lazysite::Auth::OAuth;

# SM076 OAuth 2.1 store + helpers for the MCP authorization server. Holds the
# registered clients, short-lived authorization codes (PKCE-bound), and the
# opaque access/refresh tokens that map to a lazysite partner. Shared by
# lazysite-oauth.pl (the endpoints) and lazysite-mcp.pl (token validation).
# Records are keyed by sha256 of the high-entropy secret (no salt needed for
# random tokens) so a presented secret can be looked up in O(1). Context:
# $LAZYSITE_DIR. The store lives in the write-denied lazysite/auth/ tree, 0600.

use strict;
use warnings;
use JSON::PP ();
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Digest::SHA qw(sha256_hex sha256);
use MIME::Base64 qw(encode_base64);
use Lazysite::Auth::Credential qw(generate_random_hex);
use Exporter 'import';

our @EXPORT_OK = qw(
    register_client get_client mint_code redeem_code
    issue_token validate_token refresh_access
);

our $LAZYSITE_DIR;

our $CODE_TTL    = 120;          # authorization code: seconds
our $ACCESS_TTL  = 3600;         # access token: 1 hour
our $REFRESH_TTL = 30 * 86400;   # refresh token: 30 days

sub _now  { time }
sub _hash { sha256_hex( $_[0] ) }

# base64url(no padding) - for PKCE S256 challenge comparison.
sub _b64url {
    my $d = encode_base64( $_[0], '' );
    $d =~ tr{+/}{-_};
    $d =~ s/=+$//;
    return $d;
}

sub _path { "$LAZYSITE_DIR/auth/oauth.json" }

sub load_store {
    my $p = _path();
    my $empty = { clients => {}, codes => {}, tokens => {} };
    return $empty unless defined $LAZYSITE_DIR && -f $p;
    open my $fh, '<', $p or return $empty;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $m = eval { JSON::PP::decode_json( $raw // '{}' ) };
    return ref $m eq 'HASH' ? { %$empty, %$m } : $empty;
}

sub save_store {
    my ($m) = @_;
    my $p   = _path();
    my $dir = dirname($p);
    make_path($dir) unless -d $dir;
    my $tmp = "$p.tmp.$$";
    open my $fh, '>', $tmp or return 0;
    print {$fh} JSON::PP->new->canonical->encode($m);
    close $fh;
    chmod 0600, $tmp;
    return rename $tmp, $p;
}

# Drop expired codes/tokens whenever we write (cheap housekeeping).
sub _gc {
    my ($m) = @_;
    my $now = _now();
    for my $k ( keys %{ $m->{codes} } ) {
        delete $m->{codes}{$k} if ( $m->{codes}{$k}{exp} || 0 ) < $now;
    }
    for my $k ( keys %{ $m->{tokens} } ) {
        my $t = $m->{tokens}{$k};
        delete $m->{tokens}{$k}
            if ( $t->{refresh_exp} || $t->{exp} || 0 ) < $now;
    }
    return $m;
}

# --- clients (RFC 7591) ---------------------------------------------------

sub register_client {
    my ( $redirect_uris, $name ) = @_;
    my $id = 'lzcid_' . generate_random_hex(16);
    my $m  = load_store();
    $m->{clients}{$id} = {
        redirect_uris => $redirect_uris,
        client_name   => ( $name // '' ),
        created       => _now(),
    };
    save_store( _gc($m) );
    return $id;
}

sub get_client { return load_store()->{clients}{ $_[0] } }

# --- authorization codes (PKCE-bound) -------------------------------------

sub mint_code {
    my ( $client_id, $partner, $challenge, $redirect_uri ) = @_;
    my $code = 'lzac_' . generate_random_hex(24);
    my $m = load_store();
    $m->{codes}{ _hash($code) } = {
        client_id    => $client_id,
        partner      => $partner,
        challenge    => $challenge,
        redirect_uri => $redirect_uri,
        exp          => _now() + $CODE_TTL,
    };
    save_store( _gc($m) );
    return $code;
}

# Validate + consume a code. Returns the partner on success, or undef. Checks
# the client, the redirect_uri, expiry, and the PKCE S256 verifier.
sub redeem_code {
    my ( $code, $client_id, $verifier, $redirect_uri ) = @_;
    my $m = load_store();
    my $k = _hash( $code // '' );
    my $rec = $m->{codes}{$k} or return undef;
    delete $m->{codes}{$k};          # single use, even on failure
    save_store($m);
    return undef if ( $rec->{exp} || 0 ) < _now();
    return undef unless ( $rec->{client_id}    // '' ) eq ( $client_id    // '' );
    return undef unless ( $rec->{redirect_uri} // '' ) eq ( $redirect_uri // '' );
    return undef unless defined $verifier
        && _b64url( sha256($verifier) ) eq ( $rec->{challenge} // '' );
    return $rec->{partner};
}

# --- access / refresh tokens ----------------------------------------------

sub issue_token {
    my ($partner) = @_;
    my $access  = 'lzat_' . generate_random_hex(32);
    my $refresh = 'lzrt_' . generate_random_hex(32);
    my $m = load_store();
    $m->{tokens}{ _hash($access) } = {
        partner      => $partner,
        exp          => _now() + $ACCESS_TTL,
        refresh_hash => _hash($refresh),
        refresh_exp  => _now() + $REFRESH_TTL,
    };
    save_store( _gc($m) );
    return ( $access, $refresh, $ACCESS_TTL );
}

# Resolve a presented access token to its partner, or undef if unknown/expired.
sub validate_token {
    my ($access) = @_;
    return undef unless defined $access && length $access;
    my $rec = load_store()->{tokens}{ _hash($access) } or return undef;
    return undef if ( $rec->{exp} || 0 ) < _now();
    return $rec->{partner};
}

# Exchange a refresh token for a fresh access (+ rotated refresh) token.
sub refresh_access {
    my ($refresh) = @_;
    return () unless defined $refresh && length $refresh;
    my $m  = load_store();
    my $rh = _hash($refresh);
    my ( $key, $rec );
    for my $k ( keys %{ $m->{tokens} } ) {
        if ( ( $m->{tokens}{$k}{refresh_hash} // '' ) eq $rh ) { $key = $k; $rec = $m->{tokens}{$k}; last }
    }
    return () unless $rec && ( $rec->{refresh_exp} || 0 ) >= _now();
    delete $m->{tokens}{$key};        # rotate
    save_store($m);
    return issue_token( $rec->{partner} );
}

1;
