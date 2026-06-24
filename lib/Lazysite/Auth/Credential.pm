package Lazysite::Auth::Credential;

# Credential primitives shared by the modular lazysite scripts (SM079): a
# /dev/urandom CSPRNG, password + token hashing and verification, single-use
# secret verification, and token minting. Stored credentials are
# `sha256iter:salt:iters:hash` (passwords iters=100k, tokens iters=1). The
# processor does not use this module.

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Lazysite::Util qw(const_eq);
use Exporter 'import';

our @EXPORT_OK = qw(
    generate_random_hex hash_password verify_password
    hash_token verify_secret generate_token
);

# CSPRNG: $bytes of /dev/urandom as a hex string. Dies (fail-closed) if the
# kernel CSPRNG is unavailable or short-reads.
sub generate_random_hex {
    my ($bytes) = @_;
    open my $fh, '<:raw', '/dev/urandom'
        or die "Cannot open /dev/urandom - no CSPRNG available: $!\n";
    my $raw = '';
    my $got = read( $fh, $raw, $bytes );
    close $fh;
    die "Short read from /dev/urandom ($got of $bytes bytes)\n"
        unless defined $got && $got == $bytes;
    return unpack( 'H*', $raw );
}

# Salted, iterated password hash (100k iterations).
sub hash_password {
    my ($password) = @_;
    my $salt  = generate_random_hex(16);    # 32 hex chars = 16 bytes
    my $iters = 100_000;
    my $hash  = $password;
    $hash = sha256_hex( $salt . $hash ) for 1 .. $iters;
    return "sha256iter:$salt:$iters:$hash";
}

# Verify a password against a stored hash. Handles the salted format and the
# legacy unsalted SHA-256 (which the caller rehashes on success). Constant-time.
sub verify_password {
    my ( $password, $stored ) = @_;
    return 0 unless defined $password && defined $stored && length $stored;
    if ( $stored =~ /\Asha256iter:([0-9a-f]{32}):(\d+):([0-9a-f]{64})\z/ ) {
        my ( $salt, $iters, $expected ) = ( $1, $2, $3 );
        return 0 if $iters < 1 || $iters > 1_000_000;    # sanity cap
        my $hash = $password;
        $hash = sha256_hex( $salt . $hash ) for 1 .. $iters;
        return const_eq( $hash, $expected );
    }
    elsif ( $stored =~ /\A[0-9a-f]{64}\z/ ) {
        # Legacy unsalted SHA-256 - accept, caller rehashes on success.
        return const_eq( sha256_hex($password), $stored );
    }
    return 0;
}

# Single-iteration salted hash for an access token (the token is high-entropy,
# so one round suffices; this just avoids storing it in the clear).
sub hash_token {
    my ($token) = @_;
    my $salt = generate_random_hex(16);
    my $hash = sha256_hex( $salt . $token );
    return "sha256iter:$salt:1:$hash";
}

# Verify a single-use secret (claim / pairing key / recovery code) against its
# stored sha256iter hash. Constant-time.
sub verify_secret {
    my ( $plain, $stored ) = @_;
    return 0 unless defined $plain && defined $stored;
    return 0 unless $stored =~ /\Asha256iter:([0-9a-f]+):(\d+):([0-9a-f]{64})\z/;
    my ( $salt, $iters, $want ) = ( $1, $2, $3 );
    my $h = $plain;
    $h = sha256_hex( $salt . $h ) for 1 .. $iters;
    return 0 unless length $h == length $want;
    my $diff = 0;
    $diff |= ord( substr $h, $_, 1 ) ^ ord( substr $want, $_, 1 )
        for 0 .. length($h) - 1;
    return $diff == 0;
}

# Mint a new access token (lzs_ + 32 random bytes).
sub generate_token {
    return 'lzs_' . generate_random_hex(32);    # 64 hex chars = 32 bytes
}

1;
