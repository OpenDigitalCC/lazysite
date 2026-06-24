#!/usr/bin/perl
# SM079 step 2d: Lazysite::Auth::Session - manager CSRF tokens, unit-tested
# in-process (previously only reachable through the subprocess control-API).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Auth::Session qw(generate_csrf_token verify_csrf_token);

# With a seeded site secret (deterministic).
my $d = tempdir( CLEANUP => 1 );
make_path("$d/auth");
open my $s, '>', "$d/auth/.secret" or die $!;
print {$s} 'deadbeef' x 8;
close $s;
$Lazysite::Auth::Session::LAZYSITE_DIR = $d;

my $tok = generate_csrf_token('alice');
like( $tok, qr/^[0-9a-f]{64}$/, 'token is a hex HMAC' );
ok( verify_csrf_token( $tok, 'alice' ),  'valid token verifies' );
ok( !verify_csrf_token( $tok, 'bob' ),   'token is bound to the user' );
ok( !verify_csrf_token( 'tampered', 'alice' ), 'tampered token fails' );
ok( !verify_csrf_token( '', 'alice' ),   'empty token fails' );
ok( !verify_csrf_token( $tok, '' ),      'empty user fails' );

# With no site secret, a dedicated manager secret is minted and still works.
my $d2 = tempdir( CLEANUP => 1 );
$Lazysite::Auth::Session::LAZYSITE_DIR = $d2;
my $t2 = generate_csrf_token('x');
ok( verify_csrf_token( $t2, 'x' ), 'works with a minted manager secret' );
ok( -f "$d2/manager/.csrf-secret", 'manager secret minted on demand' );

done_testing();
