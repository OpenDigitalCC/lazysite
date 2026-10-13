#!/usr/bin/perl
# SM747 C (OI1-OI4): who a person is in Odoo, for a page to GREET them by - and
# for nothing else. It rides in a SECOND cookie, distinct from the credential:
#
#   * SIGNED with the extension's secret, so a tampered one (a person editing
#     their own company or name) is rejected and the page renders as though
#     nobody had signed in;
#   * SHORT-LIVED: dated inside the signature and ended by it (odoo_identity_ttl,
#     default fifteen minutes), because groups and companies change in Odoo and
#     a cookie will not know;
#   * PRESENTATION ONLY: it carries a name, a language, a time zone, the
#     companies and the groups - never the session id, a credential, a user id
#     or anything a call could be authorised by - and a page that reads it is
#     only ever shown what it says, never allowed anything because of it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);

use Lazysite::Odoo::Identity ();
use Lazysite::Odoo::Visitor  ();

my $d = site_tempdir();
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}

my %ID = ( name => 'Jane <b>Doe</b>', lang => 'en_GB', tz => 'Europe/London', company_id => 1, company_ids => [ 1, 3 ],
    groups => [], uid => 7, login => 'jane@example.com', is_admin => 1, partner_id => 17,
    session_id => 'sidabcdef0123456789', password => 'hunter2', raw => { x => 1 } );

subtest 'a cookie carries what a page may show, and not a key to anything' => sub {
    my $c = Lazysite::Odoo::Identity::mint_cookie( \%ID );
    ok( $c, 'minted' );
    my $got = Lazysite::Odoo::Identity::identity_from_cookie("lzs_odoo_identity=$c");
    is( $got->{name}, 'Jane <b>Doe</b>', 'the name, as Odoo said it (a page escapes it)' );
    is( $got->{lang},       'en_GB',         'the language' );
    is( $got->{tz},         'Europe/London', 'the time zone' );
    is( $got->{company_id}, 1,               'the company' );
    is_deeply( $got->{company_ids}, [ 1, 3 ], 'and those allowed' );
    is_deeply( $got->{groups}, [], 'and the groups, as many as OOM gives (none, until it gives any)' );
    is_deeply( [ sort keys %$got ], [qw(company_id company_ids groups lang name tz)],
        'and nothing else: no id, no login, no admin flag, no session, no password' );
    unlike( $c, qr/sidabcdef0123456789|hunter2|jane\@example/, 'and none of it is in the cookie value either' );
    my ($b64) = split /\./, $c;
    require MIME::Base64;
    ( my $std = $b64 ) =~ tr{-_}{+/};
    unlike( MIME::Base64::decode_base64($std), qr/sidabcdef|hunter2|uid|login/, 'not even encoded' );
};

subtest 'a tampered cookie is no identity' => sub {
    my $c = Lazysite::Odoo::Identity::mint_cookie( \%ID );
    my ( $b64, $at, $sig ) = split /\./, $c;
    ( my $edited = $b64 ) =~ s/.\z/A/;
    $edited .= 'A' if $edited eq $b64;
    is( Lazysite::Odoo::Identity::identity_from_cookie("lzs_odoo_identity=$edited.$at.$sig"), undef, 'an edited body' );
    is( Lazysite::Odoo::Identity::identity_from_cookie( "lzs_odoo_identity=$b64." . ( $at + 1 ) . ".$sig" ), undef, 'an edited time' );
    is( Lazysite::Odoo::Identity::identity_from_cookie( "lzs_odoo_identity=$b64.$at." . ( '0' x 64 ) ), undef, 'a wrong signature' );
    is( Lazysite::Odoo::Identity::identity_from_cookie("lzs_odoo_identity=$b64"), undef, 'a bare body' );
    is( Lazysite::Odoo::Identity::identity_from_cookie(''),    undef, 'no cookie' );
    is( Lazysite::Odoo::Identity::identity_from_cookie(undef), undef, 'undef' );

    # The session cookie's signature does not stand in for an identity's.
    require Lazysite::Odoo::Session;
    # the worst case: a session id that IS a valid identity body, signed as a session
    my $evil = MIME::Base64::encode_base64( '{"name":"Mallory"}', '' );
    $evil =~ tr{+/}{-_};
    $evil =~ s/=+\z//;
    my $s = Lazysite::Odoo::Session::mint_cookie($evil);
    ok( $s, 'a session cookie whose id reads as an identity body' );
    my ( $sid, $sat, $ssig ) = split /\./, $s;
    is( Lazysite::Odoo::Identity::identity_from_cookie("lzs_odoo_identity=$sid.$sat.$ssig"), undef,
        'a session cookie is not an identity cookie' );
};

subtest 'it ends: the signature dates it, the configured TTL bounds it' => sub {
    my $now = time;
    my $c   = Lazysite::Odoo::Identity::mint_cookie( \%ID, now => $now );
    ok( Lazysite::Odoo::Identity::identity_from_cookie( "lzs_odoo_identity=$c", now => $now + 800 ), 'at 13 minutes' );
    is( Lazysite::Odoo::Identity::identity_from_cookie( "lzs_odoo_identity=$c", now => $now + 901 ), undef, 'past fifteen minutes' );
    ok( Lazysite::Odoo::Identity::identity_from_cookie( "lzs_odoo_identity=$c", now => $now + 901, ttl => 3600 ),
        'a longer TTL, when the operator sets one' );
    is( Lazysite::Odoo::Identity::identity_from_cookie( "lzs_odoo_identity=$c", now => $now + 4000, ttl => 3600 ), undef,
        'which still ends it' );
    my $future = Lazysite::Odoo::Identity::mint_cookie( \%ID, now => $now + 7200 );
    is( Lazysite::Odoo::Identity::identity_from_cookie( "lzs_odoo_identity=$future", now => $now ), undef, 'one dated ahead' );
};

subtest 'the headers: scoped to the site, HttpOnly, short, Secure over HTTPS' => sub {
    my $c = Lazysite::Odoo::Identity::mint_cookie( \%ID );
    my $h = Lazysite::Odoo::Identity::set_cookie_header( $c, secure => 1, ttl => 900 );
    like( $h, qr/\ASet-Cookie: lzs_odoo_identity=\Q$c\E;/, 'the cookie' );
    like( $h, qr{; Path=/(?:;|\z)}, 'sent to the pages, which is where it is read' );
    like( $h, qr/; HttpOnly/,       'HttpOnly: page script does not read it' );
    like( $h, qr/; SameSite=Lax/, 'SameSite=Lax: a link from another site still greets the person' );
    like( $h, qr/; Max-Age=900/, 'and the browser drops it with the TTL' );
    like( $h, qr/; Secure/,      'Secure over HTTPS' );
    unlike( Lazysite::Odoo::Identity::set_cookie_header( $c, secure => 0, ttl => 900 ), qr/Secure/, 'not over plain HTTP' );
    my $x = Lazysite::Odoo::Identity::clear_cookie_header( secure => 1 );
    like( $x, qr/\ASet-Cookie: lzs_odoo_identity=;/, 'cleared with no value' );
    like( $x, qr/Max-Age=0/,                         'ended' );
};

subtest 'a cookie that would not fit is not made' => sub {
    my %big = ( %ID, name => 'x' x 5000 );
    is( Lazysite::Odoo::Identity::mint_cookie( \%big ), undef, 'a name of five thousand characters' );
    my $c = Lazysite::Odoo::Identity::mint_cookie( { name => 'A' } );
    ok( $c, 'a small identity is' );
    is( Lazysite::Odoo::Identity::mint_cookie(undef), undef, 'nothing is not' );
};

done_testing();
