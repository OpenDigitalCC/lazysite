#!/usr/bin/perl
# SM747 B, the endpoint: a page's own JavaScript signs a person in to Odoo, runs
# bindings as them, and signs them out - and the credential cookie is handled as
# the credential it is.
#
#   * a sign-in is a POST that needs the visitor token (bound to the visitor
#     cookie, which SameSite=Strict keeps off a cross-site request): without it,
#     nothing reaches Odoo;
#   * the cookie it sets is signed, HttpOnly, SameSite=Strict, scoped to the
#     endpoint's path, Secure over HTTPS; the password and the session id are in
#     no body, header (apart from that cookie), log or record;
#   * a session binding runs on the cookie; with none, or a tampered one, it is
#     a 401 and the connection user is not asked;
#   * Odoo ending the session clears the cookie and says to sign in again;
#   * signing out ends it at Odoo and clears the cookie;
#   * sign-in attempts are counted by the site's own sign-in limiter.
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
use Lazysite::Odoo          ();
use Lazysite::Odoo::Session ();
use Lazysite::Odoo::Visitor ();

my $root = repo_root();
my ( $d, $conn_fake ) = shop_ready();
setup_minimal_site($d);
odoo_site($d);
my $PW          = 'Quite-a-long-password-for-Jane-1';
my $person_fake = fake_shop();
my $http        = OdooSessionHTTP->new( fake => $person_fake, people => {
        'jane@example.com' => { password => $PW, uid => 7, name => 'Jane', login => 'jane@example.com' },
        'otp@example.com' => { password => $PW, uid => 8, name => 'Otto', login => 'otp@example.com', two_factor => 1 },
} );
$Lazysite::Odoo::Session::HTTP = $http;
$Lazysite::Odoo::TRANSPORT     = $conn_fake;
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;    # the test reads the cookie it was given
}
bind( $d, id => 'mine', operation => 'shop.products', credential => 'session', modes => 'authenticated' );
bind( $d, id => 'my-add', operation => 'shop.add', credential => 'session', modes => 'authenticated',
    params => 'product=product', fixed => 'basket_key=mine' );
bind( $d, id => 'shared', operation => 'shop.products', modes => 'public' );

require "$root/lazysite-odoo.pl";
$Lazysite::Odoo::TRANSPORT = $conn_fake;

my $SCRIPT   = '/cgi-bin/lazysite-odoo.pl';
my $all_logs = '';

# One request to the endpoint, in this process. Returns ( status, \@set_cookie_lines, \%json, $raw_response ).
sub request {
    my ( $method, $query, $body, %env ) = @_;
    my $out  = '';
    my $json = defined $body ? encode_json($body) : '';
    {
        local %ENV = (
            PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => $method, QUERY_STRING => $query // '',
            REMOTE_ADDR => '198.51.100.3', SCRIPT_NAME => $SCRIPT, CONTENT_LENGTH => length $json,
            HTTP_HOST => 'localhost', %env,
        );
        local *STDOUT;
        open STDOUT, '>', \$out or die $!;
        local *STDIN;
        open STDIN, '<', \$json or die $!;
        my ($log) = quiet( sub { main::main() } );
        $all_logs .= $log;
    }
    my ( $head, $payload ) = split /\r\n\r\n/, $out, 2;
    my ($status) = $head =~ /Status:\s*(\d+)/;
    my @cookies = $head =~ /^Set-Cookie:\s*(.*?)\r?$/mg;
    return ( $status // 0, \@cookies, ( eval { decode_json( $payload // '' ) } || {} ), $out );
}

sub cookie_value {
    my ( $cookies, $name ) = @_;
    for my $c (@$cookies) { return $1 if $c =~ /\A\Q$name\E=([^;]*)/ }
    return undef;
}

# the visitor's tokens, as a page fetches them first
my ( undef, $vc, $tok ) = request( 'GET', 'csrf=1' );
my $VISITOR_COOKIE = 'lzs_odoo_visitor=' . cookie_value( $vc, 'lzs_odoo_visitor' );
my $VT             = $tok->{visitor_token};
ok( $VT && $VISITOR_COOKIE =~ /=[0-9a-f]{64}\./, 'the page has its visitor cookie and token' );
is( $tok->{odoo_signed_in}, 0, 'and is told it is not signed in to Odoo' );

sub sign_in {
    my (%o) = @_;
    return request( 'POST', '', { signin => 1, login => $o{login} // 'jane@example.com', password => $o{password} // $PW,
            ( $o{no_token} ? () : ( visitor_token => $VT ) ) },
        HTTP_COOKIE => $VISITOR_COOKIE, %{ $o{env} // {} } );
}

subtest 'a sign-in needs the visitor token, and reaches Odoo only with it' => sub {
    my $p0 = scalar @{ $http->posts };
    my ( $st, $ck, $j ) = sign_in( no_token => 1 );
    is( $st,                      403,    'no token: forbidden' );
    is( $j->{kind},               'csrf', 'as csrf' );
    is( scalar @{ $http->posts }, $p0,    'and Odoo was not contacted' );
    ok( !cookie_value( $ck, 'lzs_odoo_session' ), 'no session cookie' );
    ( $st, $ck, $j ) = request( 'POST', '', { signin => 1, login => 'jane@example.com', password => $PW, visitor_token => $VT } );
    is( $st, 403, 'a token with no visitor cookie (a cross-site post): forbidden' );
    is( scalar @{ $http->posts }, $p0, 'Odoo was not contacted' );
};

my ( $SID, $SESSION_COOKIE );
subtest 'signing in sets the signed cookie, and shows the person nothing else' => sub {
    my ( $st, $ck, $j, $raw ) = sign_in();
    is( $st,                  200,    'signed in' ) or diag $raw;
    is( $j->{identity}{name}, 'Jane', 'a name for a greeting' );
    my ($line) = grep { /\Alzs_odoo_session=/ } @$ck;
    ok( $line, 'a session cookie' );
    like( $line, qr/; HttpOnly/,                 'HttpOnly' );
    like( $line, qr/; SameSite=Strict/,          'SameSite=Strict' );
    like( $line, qr{; Path=\Q$SCRIPT\E(?:;|\z)}, 'scoped to this endpoint' );
    unlike( $line, qr/; Secure/, 'no Secure over plain HTTP' );
    $SESSION_COOKIE = 'lzs_odoo_session=' . cookie_value( $ck, 'lzs_odoo_session' );
    $SID            = Lazysite::Odoo::Session::sid_from_cookie($SESSION_COOKIE);
    ok( $SID, 'it carries a session this server signed' );
    my ($body) = $raw =~ /\r\n\r\n(.*)\z/s;
    unlike( $body, qr/\Q$SID\E/, 'the session id is in no part of the response body' );
    unlike( $body, qr/\Q$PW\E/,  'nor the password' );
    my ( undef, $ck2 ) = sign_in( env => { HTTPS => 'on' } );
    like( ( grep { /\Alzs_odoo_session=/ } @$ck2 )[0], qr/; Secure/, 'Secure over HTTPS' );
    my ( $s2, undef, $j2 ) = sign_in( password => 'not-the-password' );
    is( $s2,         401,              'a wrong password: 401' );
    is( $j2->{kind}, 'signin-refused', 'signin-refused' );
    my ( $s3, undef, $j3 ) = sign_in( login => 'otp@example.com' );
    is( $s3,         403,          'a two-factor account: 403' );
    is( $j3->{kind}, 'two-factor', 'refused by name' );
};

subtest 'a session binding runs on the cookie, and without one is a 401' => sub {
    my $c0 = scalar @{ $conn_fake->calls };
    my ( $st, undef, $j, $raw ) = request( 'GET', 'binding=mine', undef, HTTP_COOKIE => "$VISITOR_COOKIE; $SESSION_COOKIE" );
    is( $st,                            200, 'runs' ) or diag $raw;
    is( scalar @{ $j->{report}{rows} }, 2,   'with the rows' );
    like( $raw, qr/^Cache-Control: no-store/mi, 'never cached' );
    unlike( $raw, qr/\Q$SID\E/, 'the session id is not in the response' );
    is( scalar @{ $conn_fake->calls }, $c0, 'the connection user was not asked' );
    ( $st, undef, $j ) = request( 'GET', 'binding=mine', undef, HTTP_COOKIE => $VISITOR_COOKIE );
    is( $st,        401,               'no session cookie: 401' );
    is( $j->{kind}, 'signin-required', 'sign in' );
    ( my $bad = $SESSION_COOKIE ) =~ s/(.)(\.[0-9a-f]{64})\z/X$2/;
    ( $st, undef, $j ) = request( 'GET', 'binding=mine', undef, HTTP_COOKIE => "$VISITOR_COOKIE; $bad" );
    is( $st, 401, 'a tampered cookie: 401' );
    ( $st, undef, $j ) = request( 'GET', 'binding=mine&session_id=' . $SID, undef, HTTP_COOKIE => $VISITOR_COOKIE );
    is( $st, 401, 'a session id in the URL is not a session: 401' );
    is( scalar @{ $conn_fake->calls }, $c0, 'the connection user is still not asked' );
    ( $st, undef, $j ) = request( 'GET', 'binding=shared', undef, HTTP_COOKIE => "$VISITOR_COOKIE; $SESSION_COOKIE" );
    is( $st, 200, 'a connection binding still runs' );
    ok( scalar @{ $conn_fake->calls } > $c0, 'as the connection user' );
};

subtest 'a write by a session: its token, its plan, its confirm' => sub {
    my ( $st, undef, $j ) = request( 'POST', '', { binding => 'my-add', params => { product => 1 } },
        HTTP_COOKIE => "$VISITOR_COOKIE; $SESSION_COOKIE" );
    is( $st, 403, 'no token: forbidden' );
    ( $st, undef, $j ) = request( 'POST', '', { binding => 'my-add', params => { product => 1 }, visitor_token => $VT },
        HTTP_COOKIE => "$VISITOR_COOKIE; $SESSION_COOKIE" );
    is( $st, 200, 'with the token: a plan' ) or diag explain $j;
    ok( $j->{planned}, 'planned' );
    is( scalar @{ $person_fake->all_ids('x.basket') }, 0, 'nothing written yet' );
    my $plan = $j->{plan};
    ( $st, undef, $j ) = request( 'POST', '', { plan => $plan, confirm => 1, visitor_token => $VT }, HTTP_COOKIE => $VISITOR_COOKIE );
    is( $st, 404, 'a confirm with no session: not found' );
    ( $st, undef, $j ) = request( 'POST', '', { plan => $plan, confirm => 1, visitor_token => $VT },
        HTTP_COOKIE => "$VISITOR_COOKIE; $SESSION_COOKIE" );
    is( $st, 200, 'her confirm applies it' ) or diag explain $j;
    is( scalar @{ $person_fake->all_ids('x.basket') }, 1, 'over her session' );
    is( scalar @{ $conn_fake->all_ids('x.basket') }, 0, 'not through the connection user' );
};

subtest 'Odoo ending the session clears the cookie and says to sign in' => sub {
    $http->expire($SID);
    my $c0 = scalar @{ $conn_fake->calls };
    my ( $st, $ck, $j, $raw ) = request( 'GET', 'binding=mine', undef, HTTP_COOKIE => "$VISITOR_COOKIE; $SESSION_COOKIE" );
    is( $st,        401,               'refused with 401' );
    is( $j->{kind}, 'signin-required', 'sign in again' );
    my ($clear) = grep { /\Alzs_odoo_session=;/ } @$ck;
    ok( $clear, 'the cookie is cleared' );
    like( $clear, qr/Max-Age=0/, 'ended' );
    ok( !exists $j->{clear_session}, 'and the internal flag is not in the body' );
    unlike( $raw, qr/\Q$SID\E/, 'no id in the response' );
    is( scalar @{ $conn_fake->calls }, $c0, 'the connection user was not asked in its place' );
};

subtest 'signing out ends the session at Odoo and clears the cookie' => sub {
    my ( $st, $ck, $j ) = sign_in();
    my $cookie = 'lzs_odoo_session=' . cookie_value( $ck, 'lzs_odoo_session' );
    my $sid    = Lazysite::Odoo::Session::sid_from_cookie($cookie);
    ok( $http->sessions->{$sid}, 'live at Odoo' );
    ( $st, $ck, $j ) = request( 'POST', '', { signout => 1 }, HTTP_COOKIE => "$VISITOR_COOKIE; $cookie" );
    is( $st, 403, 'a sign-out needs the token too' );
    ok( $http->sessions->{$sid}, 'and did nothing' );
    ( $st, $ck, $j ) = request( 'POST', '', { signout => 1, visitor_token => $VT }, HTTP_COOKIE => "$VISITOR_COOKIE; $cookie" );
    is( $st, 200, 'signed out' );
    ok( !$http->sessions->{$sid},                 'Odoo has ended it' );
    ok( ( grep { /\Alzs_odoo_session=;/ } @$ck ), 'and the cookie is cleared' );
};

subtest 'what was typed and the session are in no log or record' => sub {
    my $files = '';
    for my $f ( grep { -f } glob("$d/lazysite/odoo/*"), glob("$d/lazysite/logs/*") ) {
        open my $fh, '<', $f or next;
        local $/;
        $files .= <$fh>;
    }
    unlike( $all_logs . $files, qr/\Q$PW\E/,            'the password' );
    unlike( $all_logs . $files, qr/\Q$SID\E/,           'the session id' );
    unlike( $all_logs . $files, qr/jane\@example\.com/, 'nor the login that was typed' );
};

subtest 'sign-in attempts are counted by the site\'s own limiter' => sub {
    plan skip_all => 'DB_File is not installed' unless eval { require DB_File; 1 };
    open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "  - plugins/login-rate-limit.pl\n";
    close $cf;
    my @st;
    push @st, ( sign_in( password => 'wrong', env => { REMOTE_ADDR => '203.0.113.9' } ) )[0] for 1 .. 6;
    is_deeply( [ @st[ 0 .. 4 ] ], [ (401) x 5 ], 'five attempts are answered' );
    is( $st[5], 429, 'the sixth is refused for rate' );
    my ($s) = sign_in( env => { REMOTE_ADDR => '203.0.113.9' } );
    is( $s, 429, 'and a right password from there is refused too' );
};

done_testing();
