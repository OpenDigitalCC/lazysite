#!/usr/bin/perl
# SM747 CU / Q1: an anonymous visitor's identity is a key the SERVER mints and
# signs. A key the server did not mint names nobody; the cookie carrying it is
# HttpOnly and SameSite=Strict; the CSRF token is bound to the key; and a record
# names the visitor by a hash, never by the key.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper              qw(site_tempdir);
use Lazysite::Odoo::Visitor ();

my $d = site_tempdir();
local $Lazysite::Odoo::Visitor::DOCROOT = $d;
my $C = $Lazysite::Odoo::Visitor::COOKIE;

my ( $key, $cookie ) = Lazysite::Odoo::Visitor::mint();
like( $key, qr/\A[0-9a-f]{64}\z/, 'a key is 256 bits of hex' );
my ($key2) = Lazysite::Odoo::Visitor::mint();
isnt( $key2, $key, 'and a second visitor gets another' );

is( Lazysite::Odoo::Visitor::key_from_cookie("other=1; $C=$cookie; x=y"), $key,
    'the key comes back from the cookie this server minted' );

subtest 'a key the server did not mint names nobody' => sub {
    my $forged = ( 'a' x 64 ) . '.' . ( 'b' x 64 );
    is( Lazysite::Odoo::Visitor::key_from_cookie("$C=$forged"), undef, 'a made-up key and signature' );
    my ( $k, $sig ) = split /\./, $cookie;
    my $other = ( '0' x 64 ) . ".$sig";
    is( Lazysite::Odoo::Visitor::key_from_cookie("$C=$other"), undef, 'another key under a real signature' );
    ( my $flipped = $cookie ) =~ s/.\z/ $& eq 'a' ? 'b' : 'a' /e;
    is( Lazysite::Odoo::Visitor::key_from_cookie("$C=$flipped"), undef, 'one character of the signature changed' );
    is( Lazysite::Odoo::Visitor::key_from_cookie("$C=$key"), undef, 'a bare key with no signature' );
    is( Lazysite::Odoo::Visitor::key_from_cookie("x$C=$cookie"), undef, 'a cookie of another name' );
};

subtest 'the secret is the extension\'s, kept and private' => sub {
    my $f = "$d/lazysite/odoo/visitor.secret";
    ok( -f $f, 'it exists after the first mint' );
    is( sprintf( '%04o', ( stat $f )[2] & 07777 ), '0600', 'and is 0600' );
    is( Lazysite::Odoo::Visitor::key_from_cookie("$C=$cookie"), $key, 'a later read verifies with it' );
    my $d2 = site_tempdir();
    local $Lazysite::Odoo::Visitor::DOCROOT = $d2;
    is( Lazysite::Odoo::Visitor::key_from_cookie("$C=$cookie"), undef,
        'another site\'s secret does not verify this site\'s visitor' );
};

subtest 'the CSRF token is bound to the key' => sub {
    my $t = Lazysite::Odoo::Visitor::csrf_token($key);
    ok( Lazysite::Odoo::Visitor::verify_csrf( $t, $key ),   'it verifies for its key' );
    ok( !Lazysite::Odoo::Visitor::verify_csrf( $t, $key2 ), 'and not for another visitor' );
    ok( !Lazysite::Odoo::Visitor::verify_csrf( '', $key ), 'an empty token fails' );
    ok( !Lazysite::Odoo::Visitor::verify_csrf( $t, '' ),   'a token with no key fails' );
};

subtest 'a record names a hash, never the key' => sub {
    my $id = Lazysite::Odoo::Visitor::visitor_id($key);
    like( $id, qr/\A[0-9a-f]{16}\z/, 'sixteen hex' );
    unlike( $key, qr/\Q$id\E/, 'not a piece of the key' );
    is( Lazysite::Odoo::Visitor::visitor_id(''), '', 'no key, no id' );
};

subtest 'the cookie\'s flags' => sub {
    my $h = Lazysite::Odoo::Visitor::set_cookie_header($cookie);
    like( $h, qr/; HttpOnly/, 'HttpOnly - page script cannot read it' );
    like( $h, qr/; SameSite=Strict/, 'SameSite=Strict - a cross-site request does not carry it' );
    unlike( $h, qr/Secure/, 'Secure only when the request was https' );
    like( Lazysite::Odoo::Visitor::set_cookie_header( $cookie, secure => 1 ), qr/; Secure/, 'and then set' );
};

done_testing();
