#!/usr/bin/perl
# SM1145 (OOM Lab finding L-2): a page cannot show who is signed in to Odoo after
# a reload. The identity cookie is HttpOnly and `?csrf=1` returned only
# `odoo_signed_in`, so the lab called an Odoo operation on every page only to show
# a name. `?csrf=1` now carries the display name from the identity
# cookie the endpoint already verifies - and nothing else about the person.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready quiet fake_shop odoo_site);

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
        'jane@example.com' => { password => $PW, uid => 7, name => 'Jane <b>Doe</b>', login => 'jane@example.com' },
} );
$Lazysite::Odoo::Session::HTTP = $http;
$Lazysite::Odoo::TRANSPORT     = $conn_fake;
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}

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

my ( undef, $vc, $tok ) = request( 'GET', 'csrf=1' );
my $VC = 'lzs_odoo_visitor=' . cv( $vc, 'lzs_odoo_visitor' );
my $VT = $tok->{visitor_token};

subtest 'nobody signed in: no identity in the answer' => sub {
    ok( !exists $tok->{identity}, 'no identity key for a visitor' );
    is( $tok->{odoo_signed_in}, 0, 'and not signed in' );
};

my ( $st, $ck ) = request( 'POST', '',
    { signin => 1, login => 'jane@example.com', password => $PW, visitor_token => $VT }, HTTP_COOKIE => $VC );
is( $st, 200, 'signed in' );
my $SESSION = 'lzs_odoo_session=' . cv( $ck, 'lzs_odoo_session' );
my $IDENT   = 'lzs_odoo_identity=' . cv( $ck, 'lzs_odoo_identity' );

subtest '?csrf=1 names the person from the identity cookie, and asks Odoo nothing' => sub {
    my $posts = scalar @{ $http->posts };
    my $calls = scalar @{ $conn_fake->calls };
    my ( $s, undef, $j, $raw ) = request( 'GET', 'csrf=1', undef, HTTP_COOKIE => "$VC; $SESSION; $IDENT" );
    is( $s, 200, 'answered' );
    is_deeply( $j->{identity}, { name => 'Jane <b>Doe</b>' },
        'the display name, exactly (not the login)' );
    is( $j->{odoo_signed_in}, 1, 'and signed in' );
    is( scalar @{ $http->posts },      $posts, 'no round trip to Odoo through the session' );
    is( scalar @{ $conn_fake->calls }, $calls, 'and none as the connection user' );
    unlike( $raw, qr/company|groups|lang|Europe|login|jane\@example/, 'nothing else about the person: no login, company, groups, language or zone' );
};

subtest 'the identity is shown only while it can be trusted' => sub {
    my ( undef, undef, $j ) = request( 'GET', 'csrf=1', undef, HTTP_COOKIE => "$VC; $SESSION" );
    ok( !exists $j->{identity}, 'no identity cookie: no identity (and no Odoo call to find one)' );
    is( $j->{odoo_signed_in}, 1, 'still signed in' );

    my $old = Lazysite::Odoo::Identity::mint_cookie( { name => 'Jane' }, now => time - 5000 );
    ( undef, undef, $j ) = request( 'GET', 'csrf=1', undef, HTTP_COOKIE => "$VC; $SESSION; lzs_odoo_identity=$old" );
    ok( !exists $j->{identity}, 'an identity cookie past its time shows nothing' );

    ( my $bad = $IDENT ) =~ s/.\z/Q/;
    ( undef, undef, $j ) = request( 'GET', 'csrf=1', undef, HTTP_COOKIE => "$VC; $SESSION; $bad" );
    ok( !exists $j->{identity}, 'a tampered identity cookie shows nothing' );

    ( undef, undef, $j ) = request( 'GET', 'csrf=1', undef, HTTP_COOKIE => "$VC; $IDENT" );
    ok( !exists $j->{identity}, 'an identity cookie with no Odoo session behind it shows nothing' );
    is( $j->{odoo_signed_in}, 0, 'and is not signed in' );
};

subtest 'the cookie stays HttpOnly and the answer is never cached' => sub {
    my $l = ( grep { /\Alzs_odoo_identity=/ } @$ck )[0];
    like( $l, qr/; HttpOnly/, 'HttpOnly' );
    my ( undef, undef, undef, $raw ) = request( 'GET', 'csrf=1', undef, HTTP_COOKIE => "$VC; $SESSION; $IDENT" );
    like( $raw, qr/^Cache-Control: no-store/mi, 'no-store' );
};

done_testing;
