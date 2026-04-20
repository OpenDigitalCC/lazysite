#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha256_hex);

# lazysite auth stores SHA256 hex hashes of passwords in $LAZYSITE_DIR/auth/users.
# Both lazysite-auth.pl (handle_login) and tools/lazysite-users.pl (cmd_add,
# cmd_passwd) use Digest::SHA::sha256_hex. These tests pin that contract.

is( length sha256_hex('testpassword'), 64, 'hash is 64 hex chars' );
like( sha256_hex('testpassword'), qr/^[0-9a-f]{64}$/, 'hash is lowercase hex' );

# Deterministic
is( sha256_hex('testpassword'), sha256_hex('testpassword'),
    'same input produces same hash' );

isnt( sha256_hex('password1'), sha256_hex('password2'),
    'different inputs produce different hashes' );

# Known-answer value pins the exact digest algorithm in use.
is(
    sha256_hex('password'),
    '5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8',
    'SHA256("password") matches published digest'
);

# Empty string is hashed without error.
ok( sha256_hex(''), 'empty password hashes without dying' );
is(
    sha256_hex(''),
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    'SHA256("") matches published digest'
);

done_testing();
