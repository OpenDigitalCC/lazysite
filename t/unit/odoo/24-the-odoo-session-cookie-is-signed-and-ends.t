#!/usr/bin/perl
# SM747 B: the Odoo session id is a CREDENTIAL - whoever holds it is that person
# in Odoo. It travels in one cookie, and the cookie is:
#
#   * SIGNED with the extension's own secret, so a value this server did not
#     mint (or one edited by a byte) names no session at all;
#   * bounded in time by the signature itself (12 hours), not only by Odoo;
#   * HttpOnly, SameSite=Strict, Secure over HTTPS, and scoped to the path of
#     the Odoo endpoint - so a page's script cannot read it, a cross-site
#     request does not carry it, and nothing else on the site ever receives it;
#   * cleared by an explicit header that carries no value.
# The id is never put in a URL, and what a record names is a hash of it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);

use Lazysite::Odoo::Session ();
use Lazysite::Odoo::Visitor ();

my $d = site_tempdir();
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}

my $SID = 'aB3_-xyz0123456789ABCDEFGHIJKLMNOPQRSTUVWX';

subtest 'a minted cookie carries the id back, and only when it is ours' => sub {
    my $c = Lazysite::Odoo::Session::mint_cookie($SID);
    ok( $c, 'a cookie value is minted' );
    is( Lazysite::Odoo::Session::sid_from_cookie("lzs_odoo_session=$c"), $SID, 'and verifies' );
    is( Lazysite::Odoo::Session::sid_from_cookie("a=1; lzs_odoo_session=$c; b=2"), $SID, 'among other cookies' );
    ( my $edited = $c ) =~ s/\A./X/;
    is( Lazysite::Odoo::Session::sid_from_cookie("lzs_odoo_session=$edited"), undef, 'an edited id names nothing' );
    my ( $sid, $at, $sig ) = split /\./, $c;
    my $forged = join '.', $sid, $at + 1, $sig;
    is( Lazysite::Odoo::Session::sid_from_cookie("lzs_odoo_session=$forged"), undef, 'an edited time names nothing' );
    my $other = join '.', 'someoneelse12345', $at, $sig;
    is( Lazysite::Odoo::Session::sid_from_cookie("lzs_odoo_session=$other"), undef, 'a signature does not move to another id' );
    is( Lazysite::Odoo::Session::sid_from_cookie("lzs_odoo_session=$SID"), undef, 'a bare id, unsigned, names nothing' );
    is( Lazysite::Odoo::Session::sid_from_cookie(''),    undef, 'no cookie, no session' );
    is( Lazysite::Odoo::Session::sid_from_cookie(undef), undef, 'undef is no session' );
};

subtest 'an id of the wrong shape is never minted' => sub {
    is( Lazysite::Odoo::Session::mint_cookie("a b"),       undef, 'a space' );
    is( Lazysite::Odoo::Session::mint_cookie("a;b=c"),     undef, 'a cookie separator' );
    is( Lazysite::Odoo::Session::mint_cookie(""),          undef, 'nothing' );
    is( Lazysite::Odoo::Session::mint_cookie("a.b"),       undef, 'the field separator' );
    is( Lazysite::Odoo::Session::mint_cookie( 'a' x 300 ), undef, 'far too long' );
    is( Lazysite::Odoo::Session::mint_cookie("short"), undef, 'too short to be a session' );
};

subtest 'the signature ends the cookie in twelve hours, and not before' => sub {
    my $now = time;
    my $c   = Lazysite::Odoo::Session::mint_cookie( $SID, now => $now );
    is( Lazysite::Odoo::Session::sid_from_cookie( "lzs_odoo_session=$c", now => $now + 11 * 3600 ), $SID, 'at eleven hours' );
    is( Lazysite::Odoo::Session::sid_from_cookie( "lzs_odoo_session=$c", now => $now + 12 * 3600 + 5 ),
        undef, 'past twelve hours' );
    my $future = Lazysite::Odoo::Session::mint_cookie( $SID, now => $now + 7200 );
    is( Lazysite::Odoo::Session::sid_from_cookie( "lzs_odoo_session=$future", now => $now ),
        undef, 'a cookie dated in the future is refused' );
};

subtest 'the header: HttpOnly, SameSite=Strict, scoped, Secure over HTTPS' => sub {
    my $c = Lazysite::Odoo::Session::mint_cookie($SID);
    my $h = Lazysite::Odoo::Session::set_cookie_header( $c, path => '/cgi-bin/lazysite-odoo.pl', secure => 1 );
    like( $h, qr/\ASet-Cookie: lzs_odoo_session=\Q$c\E;/, 'the cookie' );
    like( $h, qr/; HttpOnly/,                             'HttpOnly' );
    like( $h, qr/; SameSite=Strict/,                      'SameSite=Strict' );
    like( $h, qr/; Secure/,                               'Secure over HTTPS' );
    like( $h, qr{; Path=/cgi-bin/lazysite-odoo\.pl(?:;|\z)}, 'scoped to the endpoint\'s own path' );
    unlike( $h, qr/Max-Age|Expires/, 'a browser-session cookie: the signature carries the time' );
    my $plain = Lazysite::Odoo::Session::set_cookie_header( $c, path => '/x', secure => 0 );
    unlike( $plain, qr/Secure/, 'no Secure over plain HTTP' );
    like( Lazysite::Odoo::Session::set_cookie_header( $c, path => "/a\r\nSet-Cookie: x=y" ), qr/Path=\/cgi-bin\/lazysite-odoo\.pl/,
        'a path with a line break is not trusted: the endpoint\'s own is used' );
    my $clear = Lazysite::Odoo::Session::clear_cookie_header( path => '/cgi-bin/lazysite-odoo.pl', secure => 1 );
    like( $clear, qr/\ASet-Cookie: lzs_odoo_session=;/, 'a clear header carries no value' );
    like( $clear, qr/Max-Age=0/,                        'and ends the cookie' );
    unlike( $clear, qr/\Q$SID\E/, 'and has no id in it' );
};

subtest 'a record names a hash, never the id' => sub {
    my $l = Lazysite::Odoo::Session::session_label($SID);
    like( $l, qr/\Asession:[0-9a-f]{16}\z/, 'a short hash with a prefix' );
    unlike( $l, qr/\Q$SID\E/, 'not the id' );
    is( $l, Lazysite::Odoo::Session::session_label($SID), 'the same id, the same label' );
    isnt( $l, Lazysite::Odoo::Session::session_label( $SID . 'x' ), 'another id, another label' );
};

done_testing();
