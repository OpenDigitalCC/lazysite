#!/usr/bin/perl
# SM747 C (OI1-OI3), the endpoint's half: the identity cookie is set at sign-in,
# is short, and is refreshed from the person's own session on the next call after
# it has ended. When Odoo has ended the session, BOTH cookies go and nothing is
# shown. Signing out clears both.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready bind quiet fake_shop odoo_site);

BEGIN { oom_or_skip() }
use OdooSessionHTTP;
use Lazysite::Odoo           ();
use Lazysite::Odoo::Session  ();
use Lazysite::Odoo::Identity ();
use Lazysite::Odoo::Visitor  ();

my $root = repo_root();
my ( $d, $conn_fake ) = shop_ready();
setup_minimal_site($d);
odoo_site($d);
my $PW   = 'Quite-a-long-password-for-Jane-1';
my $http = OdooSessionHTTP->new( fake => fake_shop(), people => {
        'jane@example.com' => { password => $PW, uid => 7, name => 'Jane', login => 'jane@example.com' },
} );
$Lazysite::Odoo::Session::HTTP = $http;
$Lazysite::Odoo::TRANSPORT     = $conn_fake;
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}
bind( $d, id => 'mine', operation => 'shop.products', credential => 'session', modes => 'authenticated' );

require "$root/lazysite-odoo.pl";
$Lazysite::Odoo::TRANSPORT = $conn_fake;
my $SCRIPT = '/cgi-bin/lazysite-odoo.pl';

sub request {
    my ( $method, $query, $body, %env ) = @_;
    my $out  = '';
    my $json = defined $body ? encode_json($body) : '';
    {
        local %ENV = ( PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => $method, QUERY_STRING => $query // '',
            REMOTE_ADDR => '198.51.100.3', SCRIPT_NAME => $SCRIPT, CONTENT_LENGTH => length $json,
            HTTP_HOST => 'localhost', %env );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        local *STDIN;
        open STDIN, '<', \$json or die $!;
        quiet( sub { main::main() } );
    }
    my ( $head, $payload ) = split /\r\n\r\n/, $out, 2;
    my ($status) = $head =~ /Status:\s*(\d+)/;
    my @cookies = $head =~ /^Set-Cookie:\s*(.*?)\r?$/mg;
    return ( $status // 0, \@cookies, ( eval { decode_json( $payload // '' ) } || {} ), $out );
}

sub cv { my ( $c, $n ) = @_; for (@$c) { return $1 if /\A\Q$n\E=([^;]*)/ } return undef }
sub line { my ( $c, $n ) = @_; return ( grep { /\A\Q$n\E=/ } @$c )[0] }
sub refreshes { return scalar grep { $_->{path} eq '/web/session/get_session_info' } @{ $http->posts } }

my ( undef, $vc, $tok ) = request( 'GET', 'csrf=1' );
my $VC = 'lzs_odoo_visitor=' . cv( $vc, 'lzs_odoo_visitor' );
my $VT = $tok->{visitor_token};

my ( $st, $ck, $j ) = request( 'POST', '',
    { signin => 1, login => 'jane@example.com', password => $PW, visitor_token => $VT }, HTTP_COOKIE => $VC );
is( $st, 200, 'signed in' );
my $SESSION = 'lzs_odoo_session=' . cv( $ck, 'lzs_odoo_session' );
my $SID     = Lazysite::Odoo::Session::sid_from_cookie($SESSION);
my $IDENT   = 'lzs_odoo_identity=' . ( cv( $ck, 'lzs_odoo_identity' ) // '' );

subtest 'sign-in sets the identity cookie, beside the credential and apart from it' => sub {
    my $l = line( $ck, 'lzs_odoo_identity' );
    ok( $l, 'an identity cookie' );
    like( $l, qr{; Path=/(?:;|\z)},      'sent to the pages' );
    like( $l, qr/; HttpOnly/,            'HttpOnly' );
    like( $l, qr/; SameSite=Lax/,        'SameSite=Lax' );
    like( $l, qr/; Max-Age=900(?:;|\z)/, 'for fifteen minutes by default' );
    my $id = Lazysite::Odoo::Identity::identity_from_cookie($IDENT);
    is( $id->{name}, 'Jane', 'it verifies and says who' );
    is_deeply( $id->{company_ids}, [1], 'and the companies' );
    unlike( $IDENT, qr/\Q$SID\E|\Q$PW\E/, 'it holds neither the session nor the password' );
    isnt( cv( $ck, 'lzs_odoo_identity' ), cv( $ck, 'lzs_odoo_session' ), 'and it is not the credential cookie' );
};

subtest 'a call with a current identity cookie asks Odoo nothing about who' => sub {
    my $r0 = refreshes();
    my ( $s, $c, $body ) = request( 'GET', 'binding=nonesuch', undef, HTTP_COOKIE => "$VC; $SESSION; $IDENT" );
    is( $s,          404, 'no such binding, so nothing but the identity is in question' );
    is( refreshes(), $r0, 'no identity round trip' );
    ok( !line( $c, 'lzs_odoo_identity' ), 'and no new identity cookie' );
};

subtest 'once it has ended, the next call refreshes it from the session' => sub {
    my $r0 = refreshes();
    my ( $s, $c ) = request( 'GET', 'binding=nonesuch', undef, HTTP_COOKIE => "$VC; $SESSION" );
    is( $s,          404,     'no binding runs' );
    is( refreshes(), $r0 + 1, 'one round trip to Odoo, through the session' );
    my $fresh = Lazysite::Odoo::Identity::identity_from_cookie( 'lzs_odoo_identity=' . ( cv( $c, 'lzs_odoo_identity' ) // '' ) );
    is( $fresh->{name}, 'Jane', 'a fresh identity cookie' );

    my $old = Lazysite::Odoo::Identity::mint_cookie( { name => 'Jane' }, now => time - 5000 );
    $r0 = refreshes();
    ( $s, $c ) = request( 'GET', 'binding=nonesuch', undef, HTTP_COOKIE => "$VC; $SESSION; lzs_odoo_identity=$old" );
    is( refreshes(), $r0 + 1, 'an identity cookie past its time is the same: refreshed' );
    ok( line( $c, 'lzs_odoo_identity' ), 'with a new one' );

    ( my $bad = $IDENT ) =~ s/.\z/Q/;
    $r0 = refreshes();
    ( $s, $c ) = request( 'GET', 'binding=nonesuch', undef, HTTP_COOKIE => "$VC; $SESSION; $bad" );
    is( refreshes(), $r0 + 1, 'a tampered identity cookie is no identity: refreshed, not trusted' );
};

subtest 'the TTL is the operator\'s, 60 seconds to a day' => sub {
    open my $fh, '>>', "$d/lazysite/odoo.conf" or die $!;
    print {$fh} "odoo_identity_ttl: 120\n";
    close $fh;
    my ( undef, $c ) = request( 'GET', 'binding=nonesuch', undef, HTTP_COOKIE => "$VC; $SESSION" );
    like( line( $c, 'lzs_odoo_identity' ), qr/; Max-Age=120(?:;|\z)/, 'two minutes, as set' );
    is( Lazysite::Odoo::identity_ttl(), 120, 'read back' );
    open $fh, '>>', "$d/lazysite/odoo.conf" or die $!;
    print {$fh} "odoo_identity_ttl: 5\n";
    close $fh;
    is( Lazysite::Odoo::identity_ttl(), 900, 'five seconds is not a TTL: the default' );
};

subtest 'Odoo ending the session clears both, and the call is told to sign in' => sub {
    $http->expire($SID);
    my ( $s, $c, $body ) = request( 'GET', 'binding=mine', undef, HTTP_COOKIE => "$VC; $SESSION" );
    is( $s,            401,               'refused with 401' );
    is( $body->{kind}, 'signin-required', 'sign in again' );
    like( line( $c, 'lzs_odoo_session' ), qr/Max-Age=0/, 'the credential cookie is cleared' );
    like( line( $c, 'lzs_odoo_identity' ), qr/Max-Age=0/, 'and so is the identity' );
};

subtest 'signing out clears both' => sub {
    my ( undef, $c ) = request( 'POST', '', { signin => 1, login => 'jane@example.com', password => $PW, visitor_token => $VT },
        HTTP_COOKIE => $VC );
    my $sess = 'lzs_odoo_session=' . cv( $c, 'lzs_odoo_session' );
    ( my $s, $c ) = request( 'POST', '', { signout => 1, visitor_token => $VT }, HTTP_COOKIE => "$VC; $sess" );
    is( $s, 200, 'signed out' );
    like( line( $c, 'lzs_odoo_session' ), qr/Max-Age=0/, 'the credential cookie is cleared' );
    like( line( $c, 'lzs_odoo_identity' ), qr/Max-Age=0/, 'and the identity cookie' );
};

done_testing();
