#!/usr/bin/perl
# SM1157 (L4, OOM agent 2026-10-17): Odoo's own two-factor code in the extension's
# sign-in. With OOM 0.27 a right password for an account with two-factor on is not
# a sign-in and not a refusal: it is a step. Through the REAL endpoint, OOM's real
# session transport and a stand-in for Odoo's HTTP that plays auth_totp:
#
#   * the password answers { second_factor: 'totp' } and sets a PENDING cookie
#     (signed, HttpOnly, SameSite=Strict, this endpoint's path, five minutes) and no
#     session cookie; the pending cookie is not a session, and a session cookie is
#     not a pending sign-in;
#   * the code finishes it: the session cookie is set, the pending one cleared;
#   * a WRONG code says so and leaves the pending sign-in for another try (Odoo
#     counts them and says when it has had enough); the right one then signs in;
#   * a pending sign-in that has run out - by the clock, by Odoo forgetting it, or by
#     a forged cookie - asks for the password again and reaches nobody;
#   * "remember this device" is the SITE's choice (a setting, off unless said) and is
#     offered only over HTTPS; the value Odoo returns is kept in ONE cookie
#     (HttpOnly, Secure, SameSite=Strict, this endpoint's path), never in a body or a
#     store, and sent back to Odoo on the next password, which then needs no code;
#   * the visitor's own User-Agent goes with a remember post (Odoo fails on one it
#     cannot place);
#   * the code, the password and the device value are in no call record, audit line,
#     log or response body;
#   * an OOM that cannot finish the step refuses the account by name, as before.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root setup_minimal_site);
use OdooTest   qw(oom_or_skip shop_ready bind quiet fake_shop odoo_site write_conf);

BEGIN { oom_or_skip() }
use OdooSessionHTTP;
use Lazysite::Odoo          ();
use Lazysite::Odoo::Session ();
use Lazysite::Odoo::Visitor ();

my $root = repo_root();
my ( $d, $conn_fake ) = shop_ready();
setup_minimal_site($d);
odoo_site($d);

my $PW    = 'Quite-a-long-password-for-Tove-1';
my $CODE  = '482915';
my $WRONG = '730164';
my $UA    = 'Mozilla/5.0 (X11; Linux x86_64) TestBrowser/9.9';

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

my $SCRIPT   = '/cgi-bin/lazysite-odoo.pl';
my $all_logs = '';
my $all_body = '';
my $n_ip     = 0;

sub request {
    my ( $method, $query, $body, %env ) = @_;
    my $out  = '';
    my $json = defined $body ? encode_json($body) : '';
    {
        local %ENV = (
            PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => $method, QUERY_STRING => $query // '',
            REMOTE_ADDR => '198.51.100.' . ( 10 + ++$n_ip ), SCRIPT_NAME => $SCRIPT, CONTENT_LENGTH => length $json,
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
    $all_body .= $payload // '';
    return ( $status // 0, \@cookies, ( eval { decode_json( $payload // '' ) } || {} ), $out );
}

sub cookie_value {
    my ( $cookies, $name ) = @_;
    for my $c (@$cookies) { return $1 if $c =~ /\A\Q$name\E=([^;]*)/ }
    return undef;
}

sub cookie_line {
    my ( $cookies, $name ) = @_;
    return ( grep { /\A\Q$name\E=/ } @$cookies )[0];
}

my ( undef, $vc, $tok ) = request( 'GET', 'csrf=1' );
my $VISITOR = 'lzs_odoo_visitor=' . cookie_value( $vc, 'lzs_odoo_visitor' );
my $VT      = $tok->{visitor_token};

# A fresh two-factor person for every sign-in: the limiter counts per login.
my $nperson = 0;
sub new_person {
    my $login = 'tove' . ++$nperson . '@example.com';
    $http->{people}{$login} = { password => $PW, uid => 100 + $nperson, name => "Tove $nperson", login => $login, totp => $CODE };
    return $login;
}

# The password step. %o: login, cookies (extra cookie header text), env.
sub password_step {
    my (%o) = @_;
    my $login = $o{login} // new_person();
    return ( $login,
        request( 'POST', '', { signin => 1, login => $login, password => $PW, visitor_token => $VT },
            HTTP_COOKIE => join( '; ', $VISITOR, ( $o{cookies} ? ($o{cookies}) : () ) ), %{ $o{env} // {} } ) );
}

sub code_step {
    my (%o) = @_;
    return request( 'POST', '', { signin_code => 1, code => $o{code} // $CODE, visitor_token => $VT,
            ( exists $o{remember} ? ( remember => $o{remember} ) : () ) },
        HTTP_COOKIE => join( '; ', $VISITOR, ( $o{cookies} ? ($o{cookies}) : () ) ), %{ $o{env} // {} } );
}

sub with_conf {
    my (%over) = @_;
    write_conf( $d,
        odoo_url          => 'https://odoo.example',
        odoo_db           => 'shopdb',
        odoo_login        => 'site-connection',
        odoo_allow_writes => 'true',
        odoo_packs        => OdooTest::shop_namespace(),
        %over );
}

my $PENDING_RE = qr/\Alzs_odoo_pending=/;

subtest 'the password answers with a step, not a session, and sets only the pending cookie' => sub {
    my ( undef, $st, $ck, $j, $raw ) = password_step();
    is( $st,                  200,    'a 200' ) or diag $raw;
    ok( $j->{ok},             'ok' );
    is( $j->{second_factor},  'totp', 'the dialog is told to ask for the code' );
    ok( !$j->{signed_in},     'and that it is not signed in' );
    is( $j->{remember_offered}, 0,    'remembering is not offered (the site has not turned it on)' );
    ok( !cookie_value( $ck, 'lzs_odoo_session' ), 'no session cookie' );
    my $line = cookie_line( $ck, 'lzs_odoo_pending' );
    ok( $line, 'a pending cookie' );
    like( $line, qr/; HttpOnly/,                 'HttpOnly' );
    like( $line, qr/; SameSite=Strict/,          'SameSite=Strict' );
    like( $line, qr{; Path=\Q$SCRIPT\E(?:;|\z)}, 'scoped to this endpoint' );
    like( $line, qr/; Max-Age=300/,              'five minutes' );
    unlike( $line, qr/; Secure/, 'no Secure over plain HTTP' );
    my $pending = 'lzs_odoo_pending=' . cookie_value( $ck, 'lzs_odoo_pending' );
    my $sid = Lazysite::Odoo::Session::pending_from_cookie($pending);
    ok( $sid, 'it carries a pending sign-in this server signed' );
    ok( !Lazysite::Odoo::Session::sid_from_cookie($pending), 'it is NOT a session cookie' );
    my ($body) = $raw =~ /\r\n\r\n(.*)\z/s;
    unlike( $body, qr/\Q$sid\E/, 'the pending session id is in no body' );

    # a person holding only the pending cookie is signed in to nothing
    my ( $s2, undef, $j2 ) = request( 'GET', 'binding=mine', undef, HTTP_COOKIE => "$VISITOR; $pending" );
    is( $s2, 401, 'a session binding with only the pending cookie: 401' );
    is( $j2->{kind}, 'signin-required', 'sign in' );

    # and the reverse: a session cookie is not a pending sign-in
    my $sess = 'lzs_odoo_session=' . Lazysite::Odoo::Session::mint_cookie('sid0123456789abcdef');
    ok( !Lazysite::Odoo::Session::pending_from_cookie($sess), 'a session cookie is not a pending one' );
    my ( $s3, $c3, $j3 ) = code_step( cookies => $sess );
    is( $s3, 401, 'the code step with only a session cookie: 401' );
    is( $j3->{kind}, 'signin-required', 'sign in again' );
    ok( $c3, 'answered' );
};

subtest 'the code finishes the sign-in: session cookie set, pending cleared, and the session works' => sub {
    my ( $login, undef, $ck ) = password_step();
    my $pending = 'lzs_odoo_pending=' . cookie_value( $ck, 'lzs_odoo_pending' );
    my ( $st, $ck2, $j, $raw ) = code_step( cookies => $pending );
    is( $st, 200, 'signed in' ) or diag $raw;
    ok( $j->{signed_in}, 'signed in' );
    like( $j->{identity}{name}, qr/\ATove/, 'a name for a greeting' );
    my $line = cookie_line( $ck2, 'lzs_odoo_session' );
    ok( $line, 'a session cookie' );
    like( $line, qr/; HttpOnly/,        'HttpOnly' );
    like( $line, qr/; SameSite=Strict/, 'SameSite=Strict' );
    like( cookie_line( $ck2, 'lzs_odoo_pending' ), qr/; Max-Age=0/, 'the pending cookie is cleared' );
    ok( !cookie_line( $ck2, 'lzs_odoo_device' ), 'no device cookie: nothing was asked to be remembered' );
    my $sess = 'lzs_odoo_session=' . cookie_value( $ck2, 'lzs_odoo_session' );
    my $sid  = Lazysite::Odoo::Session::sid_from_cookie($sess);
    ok( $sid, 'the cookie carries a session this server signed' );
    ok( $http->sessions->{$sid}, 'which Odoo holds' );
    my ($body) = $raw =~ /\r\n\r\n(.*)\z/s;
    unlike( $body, qr/\Q$sid\E|\Q$CODE\E/, 'neither the session id nor the code is in the body' );
    my $form = $http->forms->[-1];
    is( $form->{fields}{totp_token}, $CODE, 'the code went to Odoo as totp_token' );
    ok( !exists $form->{fields}{remember}, 'with no remember field' );
    my ( $s2, undef, $j2 ) = request( 'GET', 'binding=mine', undef, HTTP_COOKIE => "$VISITOR; $sess" );
    is( $s2, 200, 'a session binding runs as the person' ) or diag encode_json($j2);

    # the pending sign-in is spent: sending the code again with the old pending cookie reaches no session
    my ( $s3, undef, $j3 ) = code_step( cookies => $pending );
    is( $s3, 401, 'a spent pending cookie: 401' );
    is( $j3->{kind}, 'signin-required', 'back to the password' );
};

subtest 'a wrong code is tried again within Odoo\'s own limit; the right code then signs in' => sub {
    my ( $login, undef, $ck ) = password_step();
    my $pending = 'lzs_odoo_pending=' . cookie_value( $ck, 'lzs_odoo_pending' );
    my $before = scalar @{ $http->forms };
    for my $try ( 1 .. 3 ) {
        my ( $st, $ck2, $j ) = code_step( code => $WRONG, cookies => $pending );
        is( $st,        401,            "try $try: refused" );
        is( $j->{kind}, 'second-factor', '...as a wrong code' );
        ok( !cookie_value( $ck2, 'lzs_odoo_session' ), '...no session' );
        ok( !cookie_line( $ck2, 'lzs_odoo_pending' ), '...and the pending sign-in is left as it was' );
    }
    my ( $st4, undef, $j4 ) = code_step( code => $WRONG, cookies => $pending );
    is( $j4->{kind}, 'second-factor', 'past Odoo\'s limit it is still that kind' );
    unlike( $j4->{error}, qr/Too many|double-check/, 'in this site\'s words, not Odoo\'s' );
    like( $j4->{error}, qr/limits how many tries/, 'which say Odoo limits the tries' );
    is( scalar @{ $http->forms } - $before, 4, 'every try went to Odoo: the limit is Odoo\'s' );
    my ( $st, $ck3, $j ) = code_step( cookies => $pending );
    is( $st, 200, 'the right code then signs in' );
    ok( cookie_value( $ck3, 'lzs_odoo_session' ), 'with a session cookie' );
    # a code that is not six digits never reaches Odoo
    my $n = scalar @{ $http->forms };
    my ( $se, undef, $je ) = code_step( code => 'abc', cookies => $pending );
    is( $je->{kind}, 'invalid', 'not six digits: invalid' );
    is( scalar @{ $http->forms }, $n, 'and Odoo was not asked' );
    my ( undef, undef, $ckp ) = password_step();
    my ( $sp, undef, $jp ) = code_step( code => '482 915', cookies => 'lzs_odoo_pending=' . cookie_value( $ckp, 'lzs_odoo_pending' ) );
    is( $sp, 200, 'an authenticator\'s spaced digits ("482 915") are the code' );
};

subtest 'a pending sign-in that has run out asks for the password again, reaching nobody' => sub {
    my ( $login, undef, $ck ) = password_step();
    my $sid = Lazysite::Odoo::Session::pending_from_cookie( 'lzs_odoo_pending=' . cookie_value( $ck, 'lzs_odoo_pending' ) );

    # by the clock
    my $old = 'lzs_odoo_pending=' . Lazysite::Odoo::Session::mint_pending_cookie( $sid, now => time - 400 );
    ok( !Lazysite::Odoo::Session::pending_from_cookie($old), 'older than five minutes: not read' );
    my $n = scalar @{ $http->forms };
    my ( $st, $ck2, $j ) = code_step( cookies => $old );
    is( $st, 401, 'refused' );
    is( $j->{kind}, 'signin-required', 'as a sign-in to make again' );
    is( scalar @{ $http->forms }, $n, 'Odoo was not asked' );

    # forged
    my $forged = 'lzs_odoo_pending=' . cookie_value( $ck, 'lzs_odoo_pending' );
    $forged =~ s/([0-9a-f])\z/ $1 eq 'a' ? 'b' : 'a' /e;
    my ( $sf, undef, $jf ) = code_step( cookies => $forged );
    is( $sf, 401, 'a tampered cookie: refused' );
    is( scalar @{ $http->forms }, $n, 'Odoo was not asked' );

    # Odoo forgot it
    my $pending = 'lzs_odoo_pending=' . cookie_value( $ck, 'lzs_odoo_pending' );
    $http->expire_pending;
    my ( $sg, $ckg, $jg ) = code_step( cookies => $pending );
    is( $sg, 401, 'Odoo no longer knows the pending sign-in: 401' );
    is( $jg->{kind}, 'signin-required', 'sign in again' );
    like( cookie_line( $ckg, 'lzs_odoo_pending' ), qr/; Max-Age=0/, 'and the dead cookie is cleared' );

    # no pending cookie at all
    my ( $sn, $ckn, $jn ) = code_step();
    is( $sn, 401, 'no pending sign-in: 401' );
    is( $jn->{kind}, 'signin-required', 'sign in' );

    # signing out ends a pending sign-in the person gave up on
    my ( undef, undef, $ckp ) = password_step();
    my $pend2 = 'lzs_odoo_pending=' . cookie_value( $ckp, 'lzs_odoo_pending' );
    my $psid  = Lazysite::Odoo::Session::pending_from_cookie($pend2);
    ok( $http->pending->{$psid}, 'Odoo holds the half-open session' );
    my ( $so, $cko ) = request( 'POST', '', { signout => 1, visitor_token => $VT }, HTTP_COOKIE => "$VISITOR; $pend2" );
    is( $so, 200, 'sign-out answers' );
    ok( !$http->pending->{$psid}, 'the half-open session is ended at Odoo' );
    like( cookie_line( $cko, 'lzs_odoo_pending' ), qr/; Max-Age=0/, 'and the cookie cleared' );
};

subtest 'a code step needs the visitor token' => sub {
    my ( undef, undef, $ck ) = password_step();
    my $pending = 'lzs_odoo_pending=' . cookie_value( $ck, 'lzs_odoo_pending' );
    my $n = scalar @{ $http->forms };
    my ( $st, undef, $j ) = request( 'POST', '', { signin_code => 1, code => $CODE }, HTTP_COOKIE => "$VISITOR; $pending" );
    is( $st, 403, 'no token: forbidden' );
    is( $j->{kind}, 'csrf', 'as csrf' );
    is( scalar @{ $http->forms }, $n, 'and Odoo was not asked' );
};

subtest 'remember this device is the site\'s choice, off unless said, and only over HTTPS' => sub {
    my $UAENV = { HTTP_USER_AGENT => $UA };

    # off: the box is not offered, and a remember in the request is not honoured
    my ( undef, undef, $ck, $j ) = password_step( env => { HTTPS => 'on' } );
    is( $j->{remember_offered}, 0, 'off: not offered even over HTTPS' );
    my $pending = 'lzs_odoo_pending=' . cookie_value( $ck, 'lzs_odoo_pending' );
    my ( $st, $ck2 ) = code_step( cookies => $pending, remember => JSON::PP::true, env => { HTTPS => 'on', %$UAENV } );
    is( $st, 200, 'signed in' );
    ok( !exists $http->forms->[-1]{fields}{remember}, 'a remember in the request is not passed to Odoo' );
    ok( !cookie_line( $ck2, 'lzs_odoo_device' ), 'and no device cookie is set' );

    with_conf( odoo_remember_device => 'true' );

    # on, plain HTTP: not offered (the value would travel in the clear)
    my ( undef, undef, $ckh, $jh ) = password_step();
    is( $jh->{remember_offered}, 0, 'on, over plain HTTP: not offered' );
    my $ph = 'lzs_odoo_pending=' . cookie_value( $ckh, 'lzs_odoo_pending' );
    my ( undef, $ckh2 ) = code_step( cookies => $ph, remember => JSON::PP::true, env => $UAENV );
    ok( !cookie_line( $ckh2, 'lzs_odoo_device' ), 'a remember over plain HTTP sets no device cookie' );

    # on, HTTPS, not asked for: offered, nothing set
    my ( $l3, undef, $ck3, $j3 ) = password_step( env => { HTTPS => 'on' } );
    is( $j3->{remember_offered}, 1, 'on, over HTTPS: offered' );
    my $p3 = 'lzs_odoo_pending=' . cookie_value( $ck3, 'lzs_odoo_pending' );
    like( cookie_line( $ck3, 'lzs_odoo_pending' ), qr/; Secure/, 'the pending cookie is Secure over HTTPS' );
    my ( undef, $ck3b ) = code_step( cookies => $p3, remember => JSON::PP::false, env => { HTTPS => 'on', %$UAENV } );
    ok( !cookie_line( $ck3b, 'lzs_odoo_device' ), 'offered and declined: no device cookie' );
    ok( !exists $http->forms->[-1]{fields}{remember}, '...and no remember field to Odoo' );

    # on, HTTPS, asked for
    my ( $l4, undef, $ck4 ) = password_step( env => { HTTPS => 'on' } );
    my $p4 = 'lzs_odoo_pending=' . cookie_value( $ck4, 'lzs_odoo_pending' );
    my ( $s4, $ck4b, $j4, $raw4 ) = code_step( cookies => $p4, remember => JSON::PP::true, env => { HTTPS => 'on', %$UAENV } );
    is( $s4, 200, 'signed in with remember' ) or diag $raw4;
    my $form = $http->forms->[-1];
    is( $form->{fields}{remember}, 1, 'Odoo was asked to remember the device' );
    is( $form->{agent}, $UA, 'with the visitor\'s own User-Agent' );
    my $dline = cookie_line( $ck4b, 'lzs_odoo_device' );
    ok( $dline, 'the device cookie is set' );
    like( $dline, qr/; HttpOnly/,                 'HttpOnly' );
    like( $dline, qr/; Secure/,                   'Secure' );
    like( $dline, qr/; SameSite=Strict/,          'SameSite=Strict' );
    like( $dline, qr{; Path=\Q$SCRIPT\E(?:;|\z)}, 'scoped to this endpoint' );
    like( $dline, qr/; Max-Age=7776000/,          'for the ninety days Odoo trusts a device' );
    my $td = cookie_value( $ck4b, 'lzs_odoo_device' );
    ok( exists $http->devices->{$td}, 'the value is the one Odoo issued' );
    unlike( $raw4 =~ s/\A.*?\r\n\r\n//sr, qr/\Q$td\E/, 'the value is in no body' );
    my $before = scalar @{ $http->posts };

    # the next password, carrying the device cookie: no code asked
    my $device = "lzs_odoo_device=$td";
    my ( $s5, $ck5, $j5 ) = request( 'POST', '', { signin => 1, login => $l4, password => $PW, visitor_token => $VT },
        HTTP_COOKIE => "$VISITOR; $device", REMOTE_ADDR => '203.0.113.77', HTTPS => 'on', HTTP_USER_AGENT => $UA );
    is( $s5, 200, 'a trusted device signs in at the password' );
    ok( $j5->{signed_in}, 'signed in, with no code' );
    ok( cookie_value( $ck5, 'lzs_odoo_session' ), 'with a session cookie' );
    ok( !cookie_line( $ck5, 'lzs_odoo_pending' ), 'and no pending one' );
    is( $http->gets->[-1]{cookie} =~ /td_id=\Q$td\E/ ? 1 : 0, 1, 'the device value went back to Odoo as td_id' );

    # Odoo no longer trusts it: the code is asked again, and the dead cookie is dropped
    delete $http->devices->{$td};
    my ( $s6, $ck6, $j6 ) = request( 'POST', '', { signin => 1, login => $l4, password => $PW, visitor_token => $VT },
        HTTP_COOKIE => "$VISITOR; $device", REMOTE_ADDR => '203.0.113.78', HTTPS => 'on' );
    is( $j6->{second_factor}, 'totp', 'a device Odoo no longer trusts: the code is asked for' );
    like( cookie_line( $ck6, 'lzs_odoo_device' ), qr/; Max-Age=0/, 'and the dead device cookie is cleared' );

    # the site turns the choice off: the cookie is not sent to Odoo, and is cleared
    with_conf();
    my $td2 = 'TD' . ( 'ab' x 12 );
    my ( $s7, $ck7, $j7 ) = request( 'POST', '', { signin => 1, login => new_person(), password => $PW, visitor_token => $VT },
        HTTP_COOKIE => "$VISITOR; lzs_odoo_device=$td2", REMOTE_ADDR => '203.0.113.79', HTTPS => 'on' );
    is( $j7->{second_factor}, 'totp', 'choice off: the code is asked for' );
    unlike( $http->posts->[-1]{cookie} // '', qr/td_id/, 'the device value was not sent to Odoo' );
    like( cookie_line( $ck7, 'lzs_odoo_device' ), qr/; Max-Age=0/, 'and the browser is told to drop it' );
};

subtest 'the code, the password and the device value are in no record, log or body' => sub {
    with_conf( odoo_remember_device => 'true' );
    my ( $l, undef, $ck ) = password_step( env => { HTTPS => 'on' } );
    my $p = 'lzs_odoo_pending=' . cookie_value( $ck, 'lzs_odoo_pending' );
    my ( undef, $cb ) = code_step( code => $WRONG, cookies => $p, env => { HTTPS => 'on' } );
    my ( undef, $ckd ) = code_step( cookies => $p, remember => JSON::PP::true, env => { HTTPS => 'on', HTTP_USER_AGENT => $UA } );
    my $td = cookie_value( $ckd, 'lzs_odoo_device' );
    ok( $td, 'a device value was issued' );

    my $files = '';
    for my $f ( Lazysite::Odoo::calls_file(), glob("$d/lazysite/odoo/*"), glob("$d/lazysite/logs/*"), glob("$d/lazysite/*.log"),
        glob("$d/lazysite/audit*"), glob("$d/lazysite/logs/*/*") ) {
        next unless -f $f;
        open my $fh, '<', $f or next;
        local $/;
        $files .= <$fh>;
    }
    ok( length $files, 'there is a record to search' );
    like( $files, qr/signin-code/, 'it records the code step' );
    my $sid_hash = qr/session:[0-9a-f]{16}/;
    like( $files, $sid_hash, 'naming the session by a hash' );
    for my $secret ( [ password => $PW ], [ 'right code' => $CODE ], [ 'wrong code' => $WRONG ], [ 'device value' => $td ] ) {
        my ( $what, $v ) = @$secret;
        unlike( $files,    qr/\Q$v\E/, "the $what is in no call record, audit line or file the engine wrote" );
        unlike( $all_logs, qr/\Q$v\E/, "the $what is in no log line" );
        unlike( $all_body, qr/\Q$v\E/, "the $what is in no response body" );
    }
    unlike( $files . $all_logs, qr/\Q$l\E/, 'nor is the login (a hash names it)' );
    like( $files, qr/second-factor/, 'a wrong code is recorded by its kind' );
};

subtest 'an OOM that cannot finish the step refuses the account by name, as before' => sub {
    my ( $conn, $why ) = Lazysite::Odoo::connection();
    my $login = new_person();
    my $r;
    my $held = scalar keys %{ $http->pending };
    {
        no warnings qw(once redefine);
        local *Odoo::Transport::Session::complete_totp;
        ( undef, $r ) = quiet( sub { Lazysite::Odoo::Session::sign_in( $conn, $login, $PW ) } );
    }
    is( $r->{kind}, 'two-factor', 'refused by name' );
    ok( !$r->{pending} && !$r->{session_id}, 'with nothing to carry' );
    is( scalar keys %{ $http->pending }, $held, 'and the half-open session Odoo opened was ended' );
};

done_testing();
