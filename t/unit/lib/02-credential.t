#!/usr/bin/perl
# SM079 step 2: Lazysite::Auth::Credential - credential primitives, unit-tested
# in-process (the logic that the subprocess tests could only reach indirectly).
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Auth::Credential
    qw(generate_random_hex hash_password verify_password hash_token verify_secret generate_token);

# CSPRNG
like( generate_random_hex(16), qr/^[0-9a-f]{32}$/, '16 bytes -> 32 hex chars' );
isnt( generate_random_hex(8), generate_random_hex(8), 'successive draws differ' );

# password roundtrip
my $h = hash_password('s3cret');
like( $h, qr/^sha256iter:[0-9a-f]{32}:100000:[0-9a-f]{64}$/, 'salted 100k format' );
ok( verify_password( 's3cret', $h ),  'correct password verifies' );
ok( !verify_password( 'wrong', $h ),  'wrong password fails' );
ok( !verify_password( 's3cret', undef ), 'undef stored fails' );
ok( !verify_password( undef, $h ),    'undef password fails' );

# legacy unsalted SHA-256 accepted (caller rehashes)
ok( verify_password( 'legacy', sha256_hex('legacy') ), 'legacy unsalted verifies' );

# token + single-use secret
my $t = generate_token();
like( $t, qr/^lzs_[0-9a-f]{64}$/, 'token format' );
my $th = hash_token($t);
like( $th, qr/^sha256iter:[0-9a-f]{32}:1:[0-9a-f]{64}$/, 'token hash is single-iteration' );
ok( verify_secret( $t, $th ),          'token verifies via verify_secret' );
ok( !verify_secret( 'lzs_other', $th ), 'wrong secret fails' );
ok( !verify_secret( $t, 'not-a-hash' ), 'malformed stored fails' );

done_testing();
