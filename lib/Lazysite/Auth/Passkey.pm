package Lazysite::Auth::Passkey;

# SM1352: PASSKEYS (WebAuthn), THE SIMPLE WAY (ruling 187).
#
# A passkey is a key pair the person's phone or computer keeps; the site keeps
# the public half with the account and never a secret. Signing in, the site sends
# a fresh challenge, the authenticator signs it, and this module checks the
# signature with the public key stored at enrolment. The sign-in then mints an
# ordinary local session, exactly as a password does (lazysite-auth.pl).
#
# ATTESTATION 'none', AND NO CBOR. The browser's getPublicKey() hands over the
# credential's public key as SPKI DER, which CryptX imports directly, so the
# attestation object - CBOR, and only needed to prove which make of
# authenticator this is - is never read. The authenticator data's first 37 bytes
# (the RP ID hash, the flags, the counter) are fixed-width and read as bytes.
#
# WHAT IS CHECKED, at enrolment and at every sign-in:
#   - the client data's type (webauthn.create / webauthn.get) and origin - the
#     site's own address, never one the request names;
#   - its challenge: one this site issued, for this purpose, not yet used and not
#     older than $CHALLENGE_TTL. A challenge is spent by the first attempt that
#     names it, whatever the outcome, so a captured answer cannot be replayed;
#   - the authenticator data's RP ID hash (this host) and its user-present flag;
#   - at sign-in, the signature over authenticator data || SHA-256(client data),
#     with the key AND THE ALGORITHM stored at enrolment, and a signature counter
#     that does not go backwards (a cloned authenticator).
#
# STORE. The passkeys live in the account's own record in user-settings.json, as
# `passkeys: [ { id, key, alg, label, created, used, count } ]` - id and key
# base64url, alg the COSE number. Written only by the users tool (passkey-add,
# passkey-remove, passkey-used, passkey-wipe, claim-redeem), the store's single
# writer; this module only reads it. The challenges live one file each under
# lazysite/auth/passkey-challenges/, named by the challenge's SHA-256.
#
# CryptX is lazy-required (Lazysite::Crypto): without it every verification
# refuses with the sentence that says so.
#
# Index
#   b64u_encode, b64u_decode   base64url without padding, as WebAuthn uses
#   rp_of                      the RP ID and origin of this request
#   issue_challenge            a fresh challenge for signin / enrol / claim
#   verify_registration        an enrolment's answer -> the passkey to store
#   verify_assertion           a sign-in's answer -> the account it proves
#   find_passkey               which account holds a credential id
#   passkeys_of                an account's passkeys, as stored
#   passkey_only               does one of the account's groups refuse its password
#   operator_by_name           the operator group by name, when the group store cannot be read (r197)

use strict;
use warnings;
use Digest::SHA                qw(sha256 sha256_hex);
use JSON::PP                   ();
use MIME::Base64               ();
use File::Path                 qw(make_path);
use Lazysite::Crypto           ();
use Lazysite::Auth::Credential qw(generate_random_hex);

our $CHALLENGE_TTL   = 300;     # seconds a challenge may be answered in
our $MAX_PENDING     = 1000;    # unanswered challenges kept at once, per site
our $MAX_PER_ACCOUNT = 20;      # passkeys one account may hold

# COSE algorithm numbers this site verifies, and the CryptX class for each.
my %ALG = ( -7 => 'ES256', -257 => 'RS256', -8 => 'EdDSA' );
sub algorithms { my @a = sort { $a <=> $b } keys %ALG; return @a }

sub b64u_encode { return MIME::Base64::encode_base64url( $_[0] // '' ) }

sub b64u_decode {
    my ($s) = @_;
    return undef unless defined $s && !ref $s && $s =~ /\A[A-Za-z0-9_-]*={0,2}\z/;
    return MIME::Base64::decode_base64url($s);
}

# The RP ID (the host, no port) and the origin a browser on this request's host
# reports. Off loopback the origin is https: browsers offer WebAuthn only in a
# secure context, which on a real host means https. ( undef ) for a Host header
# that is not a host name.
sub rp_of {
    my ($env) = @_;
    $env ||= \%ENV;
    my $host = lc( $env->{HTTP_HOST} // '' );
    return () unless $host =~ /\A([a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?)(?::\d{1,5})?\z/;
    my $rp     = $1;
    my $local  = $rp eq 'localhost' || $rp eq '127.0.0.1';
    my $https  = ( $env->{HTTPS} // '' ) ne '' && lc( $env->{HTTPS} ) ne 'off';
    my $scheme = ( $https || !$local ) ? 'https' : 'http';
    return ( $rp, "$scheme://$host" );
}

# --- challenges ----------------------------------------------------------------

sub _challenge_dir { return "$_[0]/passkey-challenges" }

# A fresh challenge: 32 random bytes, base64url. `purpose` is signin, enrol or
# claim; `user` binds an enrol or claim challenge to the account it is for.
# Returns ( $challenge, '' ) or ( undef, $why ).
sub issue_challenge {
    my ( $auth_dir, %o ) = @_;
    my $purpose = $o{purpose} // '';
    return ( undef, 'unknown purpose' ) unless $purpose =~ /\A(?:signin|enrol|claim)\z/;
    my $dir = _challenge_dir($auth_dir);
    make_path( $dir, { mode => 0o2770 } ) unless -d $dir;
    my ( $pending, $now ) = ( 0, time );
    if ( opendir my $dh, $dir ) {
        for my $f ( readdir $dh ) {
            next unless $f =~ /\A[0-9a-f]{64}\z/;
            my @st = stat "$dir/$f";
            if ( !@st || $st[9] < $now - $CHALLENGE_TTL ) { unlink "$dir/$f"; next }
            $pending++;
        }
        closedir $dh;
    }
    return ( undef, 'too many passkey requests are waiting; try again in a few minutes' )
        if $pending >= $MAX_PENDING;
    my $raw  = pack 'H*', generate_random_hex(32);
    my $file = "$dir/" . sha256_hex($raw);
    open my $fh, '>', $file or return ( undef, "the challenge could not be written ($!)" );
    print {$fh} JSON::PP::encode_json( { purpose => $purpose, user => ( $o{user} // '' ), t => $now } );
    close $fh;
    chmod 0o660, $file;
    return ( b64u_encode($raw), '' );
}

# Spend a challenge: the record it was issued with, or undef. A rename is the
# claim, so of two answers naming one challenge only one can have it.
sub _spend_challenge {
    my ( $auth_dir, $raw ) = @_;
    return undef unless defined $raw && length $raw == 32;
    my $file  = _challenge_dir($auth_dir) . '/' . sha256_hex($raw);
    my $taken = "$file.spent.$$." . generate_random_hex(4);
    rename $file, $taken or return undef;
    open my $fh, '<', $taken or do { unlink $taken; return undef };
    my $rec = eval { JSON::PP::decode_json( do { local $/; <$fh> } // '' ) };
    close $fh;
    unlink $taken;
    return undef unless ref $rec eq 'HASH';
    return undef if ( $rec->{t} // 0 ) < time - $CHALLENGE_TTL;
    return $rec;
}

# --- the two answers -----------------------------------------------------------

# The client data, checked: type, origin and a challenge this site issued for
# this purpose. Returns ( $raw_json, $challenge_record ) or ( undef, $why ).
sub _client_data {
    my ( $b64, $type, %o ) = @_;
    my $raw = b64u_decode($b64);
    return ( undef, 'the client data is missing' ) unless defined $raw && length $raw;
    my $cd = eval { JSON::PP::decode_json($raw) };
    return ( undef, 'the client data is not JSON' )    unless ref $cd eq 'HASH';
    return ( undef, "the client data is not a $type" ) unless ( $cd->{type} // '' ) eq $type;
    return ( undef, 'the passkey answered for another site (' . ( $cd->{origin} // 'no origin' ) . ')' )
        unless defined $o{origin} && ( $cd->{origin} // '' ) eq $o{origin};
    my $rec = _spend_challenge( $o{auth_dir}, b64u_decode( $cd->{challenge} ) );
    return ( undef, 'the challenge was not issued here, was already used, or has expired' )
        unless $rec;
    return ( undef, 'the challenge was issued for something else' )
        unless grep { ( $rec->{purpose} // '' ) eq $_ } @{ $o{purposes} };
    return ( undef, 'the challenge was issued for another account' )
        if defined $o{user} && ( $rec->{user} // '' ) ne $o{user};
    return ( $raw, $rec );
}

# The authenticator data's fixed head: the RP ID hash must be this host's, and
# the user must have been present. Returns ( $flags, $count ) or ( undef, $why ).
sub _auth_data {
    my ( $raw, $rp ) = @_;
    return ( undef, 'the authenticator data is missing' ) unless defined $raw && length $raw >= 37;
    return ( undef, 'the passkey belongs to another site' ) unless substr( $raw, 0, 32 ) eq sha256( $rp // '' );
    my $flags = ord substr( $raw, 32, 1 );
    return ( undef, 'the authenticator did not confirm the person was present' ) unless $flags & 0x01;
    return ( $flags, unpack( 'N', substr( $raw, 33, 4 ) ) );
}

# The stored key as a CryptX object for its algorithm, or ( undef, $why ).
sub _key_object {
    my ( $der, $alg ) = @_;
    return ( undef, 'unsupported algorithm' ) unless defined $alg && $ALG{$alg};
    my $pk = eval {
        if ( $alg == -7 ) {
            require Crypt::PK::ECC;
            my $k = Crypt::PK::ECC->new( \$der );
            my $c = $k->key2hash->{curve_name} // '';
            die "the key is not on the P-256 curve ($c)\n" unless $c =~ /\A(?:secp256r1|nistp256|prime256v1)\z/i;
            $k;
        }
        elsif ( $alg == -257 ) { require Crypt::PK::RSA; Crypt::PK::RSA->new( \$der ) }
        else { require Crypt::PK::Ed25519; Crypt::PK::Ed25519->new( \$der ) }
    };
    return ( undef, 'the public key could not be read: ' . ( $@ =~ s/\s+\z//r ) ) unless $pk;
    return ( undef, 'the public key is a private key' ) if $pk->is_private;
    return ($pk);
}

# An enrolment's answer. %a: auth_dir, origin, rp, user, purposes (enrol or
# claim), id, client_data, authenticator_data, public_key (SPKI DER), alg, all
# base64url but alg. Returns { ok => 1, passkey => {...} } or { ok => 0, error }.
sub verify_registration {
    my (%a) = @_;
    if ( my $m = Lazysite::Crypto::cryptx_missing() ) { return { ok => 0, kind => 'unavailable', error => $m } }
    my ( $cd, $why ) = _client_data( $a{client_data}, 'webauthn.create',
        auth_dir => $a{auth_dir}, origin => $a{origin}, purposes => $a{purposes} || ['enrol'],
        user     => $a{user} );
    return { ok => 0, error => $why } unless defined $cd;
    my ( $flags, $count ) = _auth_data( b64u_decode( $a{authenticator_data} ), $a{rp} );
    return { ok => 0, error => $count } unless defined $flags;
    my $id = b64u_decode( $a{id} );
    return { ok => 0, error => 'the credential id is missing or too long' }
        unless defined $id && length $id >= 16 && length $id <= 1023;
    my $alg = defined $a{alg} && $a{alg} =~ /\A-?\d+\z/ ? 0 + $a{alg} : undef;
    my $der = b64u_decode( $a{public_key} );
    return { ok => 0, error => 'the public key is missing' } unless defined $der && length $der;
    my ( $pk, $kwhy ) = _key_object( $der, $alg );
    return { ok => 0, error => $kwhy } unless $pk;
    my $label = defined $a{label} && !ref $a{label} ? $a{label} : '';
    $label =~ s/[\x00-\x1f\x7f]+/ /g;
    $label = substr( $label, 0, 64 );
    return { ok => 1, passkey => {
            id    => b64u_encode($id), key     => b64u_encode($der), alg => $alg,
            label => $label,           created => time, count => $count + 0 } };
}

# A sign-in's answer. %a: auth_dir, origin, rp, id, client_data,
# authenticator_data, signature (base64url). The account is the one whose record
# holds the credential. Returns { ok => 1, user, id, count } or { ok => 0, error }.
sub verify_assertion {
    my (%a) = @_;
    if ( my $m = Lazysite::Crypto::cryptx_missing() ) { return { ok => 0, kind => 'unavailable', error => $m } }
    my ( $cd, $why ) = _client_data( $a{client_data}, 'webauthn.get',
        auth_dir => $a{auth_dir}, origin => $a{origin}, purposes => ['signin'] );
    return { ok => 0, error => $why } unless defined $cd;
    my $ad = b64u_decode( $a{authenticator_data} );
    my ( $flags, $count ) = _auth_data( $ad, $a{rp} );
    return { ok => 0, error => $count } unless defined $flags;
    my ( $user, $pkrec ) = find_passkey( $a{id} );
    return { ok => 0, error => 'no account holds that passkey' } unless defined $user;
    my ( $pk, $kwhy ) = _key_object( b64u_decode( $pkrec->{key} ), $pkrec->{alg} );
    return { ok => 0, error => $kwhy } unless $pk;
    my $sig = b64u_decode( $a{signature} );
    return { ok => 0, error => 'the signature is missing' } unless defined $sig && length $sig;
    my $msg  = $ad . sha256($cd);
    my $alg  = $pkrec->{alg};
    my $good = eval {
        $alg == -7         ? $pk->verify_message( $sig, $msg, 'SHA256' )
            : $alg == -257 ? $pk->verify_message( $sig, $msg, 'SHA256', 'v1.5' )
            :                $pk->verify_message( $sig, $msg );
    };
    return { ok => 0, error => 'the signature does not verify' } unless $good;
    my $had = $pkrec->{count} // 0;
    return { ok => 0, error => 'the signature counter went backwards (a copied authenticator?)' }
        if ( $count || $had ) && $count <= $had;
    return { ok => 1, user => $user, id => $pkrec->{id}, count => $count + 0 };
}

# --- the store, read ------------------------------------------------------------

sub _settings {
    require Lazysite::Auth::Settings;
    my $all = Lazysite::Auth::Settings::read_settings();
    return ref $all eq 'HASH' ? $all : {};
}

sub passkeys_of {
    my ( $user, $all ) = @_;
    my $s = ( $all || _settings() )->{ $user // '' };
    return [] unless ref $s eq 'HASH' && ref $s->{passkeys} eq 'ARRAY';
    return [ grep { ref $_ eq 'HASH' && defined $_->{id} } @{ $s->{passkeys} } ];
}

# ( $user, $passkey ) for a credential id (base64url), or ().
sub find_passkey {
    my ($id) = @_;
    return () unless defined $id && !ref $id && length $id;
    my $raw = b64u_decode($id);
    return () unless defined $raw;
    my $want = b64u_encode($raw);
    my $all  = _settings();
    for my $u ( sort keys %$all ) {
        for my $p ( @{ passkeys_of( $u, $all ) } ) {
            return ( $u, $p ) if $p->{id} eq $want;
        }
    }
    return ();
}

# Does one of the account's groups say "passkey only"? The group key is
# `passkey_only`, set like any group setting; it is checked in the password
# branch of sign-in and nowhere else. 1, 0, or undef when the group store exists
# and cannot be read - cannot tell, which the caller refuses on.
sub passkey_only {
    my ($user) = @_;
    require Lazysite::Auth::Settings;
    my $gs = Lazysite::Auth::Settings::read_group_settings();
    return undef if Lazysite::Auth::Settings::group_settings_unreadable();
    return 0 unless ref $gs eq 'HASH';
    for my $g ( Lazysite::Auth::Settings::effective_groups($user) ) {
        return 1 if ref $gs->{$g} eq 'HASH' && $gs->{$g}{passkey_only};
    }
    return 0;
}

# Ruling 197: is the account in the operator group, asked when the group settings
# (which carry the operator flag) cannot be read? By name, from what CAN be read:
# the groups file's membership (nesting included) of `sysops`, the operator group
# setup-sysop makes. (The retired manager_groups conf key is not read: SM138.)
sub operator_by_name {
    my ($user) = @_;
    return 0 unless defined $user && length $user;
    require Lazysite::Auth::Settings;
    my %op = ( sysops => 1 );
    for my $g ( Lazysite::Auth::Settings::effective_groups($user) ) {
        return 1 if $op{$g};
    }
    return 0;
}

1;
