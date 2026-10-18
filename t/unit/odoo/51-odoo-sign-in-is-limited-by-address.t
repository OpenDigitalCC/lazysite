#!/usr/bin/perl
# SM1159 (L2, OOM agent 2026-10-17: "sign-in (lazysite's own, and the Odoo extension's
# sign-in through a page) can be limited to address ranges per site, and optionally per
# binding"): the Odoo endpoint's signin AND its two-factor signin_code step are refused
# from an address lazysite.conf `signin_addresses` / `signin_addresses_deny` does not
# admit - before the token is read, before the password reaches Odoo, before
# Auth::LoginRate counts it (a refused address is not a rate) - exactly as lazysite's
# own login is (t/unit/auth/67).
#
# THE PER-BINDING RULE. The sign-in requests name no binding, so the endpoint cannot
# know at sign-in which binding's page the person is on. A session binding may carry
# `signin_addresses` / `signin_addresses_deny`, which narrow and never widen the site's,
# and they are held where the binding IS named: on its calls.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use File::Path ();
use DB_File;
use Fcntl qw(O_RDWR);
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

my ( $IN, $OUT ) = ( '203.0.113.9', '198.51.100.9' );
my $PW   = 'Quite-a-long-password-for-Tove-1';
my $CODE = '482915';

sub spit  { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; $t }

my $http = OdooSessionHTTP->new( fake => fake_shop(), people => {} );
$Lazysite::Odoo::Session::HTTP = $http;
$Lazysite::Odoo::TRANSPORT     = $conn_fake;
{
    no warnings 'once';
    $Lazysite::Odoo::Visitor::DOCROOT = $d;
}
File::Path::make_path("$d/lazysite/auth", "$d/lazysite/logs");
spit( "$d/lazysite/auth/address-lists.json", encode_json( {
        office  => { kind => 'allow', entries => [ { cidr => '203.0.113.0/24', note => '' } ] },
        desk    => { kind => 'allow', entries => [ { cidr => '203.0.113.9',    note => '' } ] },
        blocked => { kind => 'deny',  entries => [ { cidr => $IN,              note => '' } ] },
} ) );

sub set_conf {
    my (%k) = @_;
    spit( "$d/lazysite/lazysite.conf",
        "site_name: T\nplugins:\n  - plugins/odoo.pl\n  - plugins/login-rate-limit.pl\ntrusted_proxies: 127.0.0.1\n"
            . join( '', map { "$_: $k{$_}\n" } sort keys %k ) );
}
set_conf();
bind( $d, id => 'mine', operation => 'shop.products', credential => 'session', modes => 'authenticated' );

require "$root/lazysite-odoo.pl";
$Lazysite::Odoo::TRANSPORT = $conn_fake;

my $SCRIPT = '/cgi-bin/lazysite-odoo.pl';
sub request {
    my ( $method, $query, $body, %env ) = @_;
    my $out  = '';
    my $json = defined $body ? encode_json($body) : '';
    {
        local %ENV = (
            PATH => $ENV{PATH}, DOCUMENT_ROOT => $d, REQUEST_METHOD => $method, QUERY_STRING => $query // '',
            REMOTE_ADDR => '127.0.0.1', SCRIPT_NAME => $SCRIPT, CONTENT_LENGTH => length $json,
            HTTP_HOST => 'localhost', %env,
        );
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

sub cookie_value {
    my ( $cookies, $name ) = @_;
    for my $c (@$cookies) { return $1 if $c =~ /\A\Q$name\E=([^;]*)/ }
    return undef;
}

my ( undef, $vc, $tok ) = request('GET', 'csrf=1');
my $VISITOR = 'lzs_odoo_visitor=' . cookie_value( $vc, 'lzs_odoo_visitor' );
my $VT      = $tok->{visitor_token};

my $n = 0;
sub person {
    my (%o) = @_;
    my $login = 'tove' . ++$n . '@example.com';
    $http->{people}{$login} = { password => $PW, uid => 100 + $n, name => "Tove $n", login => $login, ( $o{totp} ? ( totp => $CODE ) : () ) };
    return $login;
}

# from => the visitor (X-Forwarded-For, via the trusted proxy 127.0.0.1)
sub signin {
    my ( $from, %o ) = @_;
    my $login = $o{login} // person( totp => $o{totp} );
    return ( $login, request( 'POST', '', { signin => 1, login => $login, password => $o{password} // $PW, visitor_token => $VT },
            HTTP_COOKIE => $VISITOR, HTTP_X_FORWARDED_FOR => $from, %{ $o{env} // {} } ) );
}

sub code_step {
    my ( $from, $pending ) = @_;
    return request( 'POST', '', { signin_code => 1, code => $CODE, visitor_token => $VT },
        HTTP_COOKIE => join( '; ', $VISITOR, ( $pending ? ($pending) : () ) ), HTTP_X_FORWARDED_FOR => $from );
}

sub counted {
    my ($addr) = @_;
    my %db;
    tie %db, 'DB_File', "$d/lazysite/auth/.login-rate.db", O_RDWR, 0o600 or return 0;
    my $v = $db{ "odoo-ip=$addr:" . int( time() / 300 ) } // 0;
    untie %db;
    return $v;
}

sub audit_rows { my ($t) = @_; return scalar( () = slurp("$d/lazysite/logs/audit.log") =~ /\| address-refused \| \Q$t\E \|/g ) }

subtest 'no limit: sign-in is as before' => sub {
    my ( undef, $st, $ck, $j ) = signin($OUT);
    is( $st, 200, 'signed in' ) or diag encode_json($j);
    ok( $j->{signed_in}, '...' );
};

subtest 'outside the allow list: the password step is refused before Odoo and before the rate counter' => sub {
    set_conf( signin_addresses => 'office' );
    my $posts = scalar @{ $http->posts };
    my $c0    = counted($OUT);
    my ( undef, $st, $ck, $j ) = signin($OUT);
    is( $st, 403, 'refused with a 403' );
    is( $j->{kind}, 'address', 'with its own kind' );
    is( $j->{error}, 'Sign-in is not available from your address.', 'and the plain sentence' );
    ok( !cookie_value( $ck, 'lzs_odoo_session' ), 'no session' );
    is( scalar @{ $http->posts }, $posts, 'Odoo was not asked: the password never left' );
    is( counted($OUT), $c0, 'the rate limiter counted nothing' );
    signin($OUT) for 1 .. 7;
    my ( undef, $st2, undef, $j2 ) = signin($OUT);
    is( $j2->{kind}, 'address', 'and it is never rate-limited into another answer, however often it tries' );
    is( counted($OUT), $c0, '...still nothing counted' );
};

subtest 'outside the allow list: the code step is refused the same' => sub {
    set_conf();
    my ( $login, undef, $ck ) = signin( $IN, totp => 1 );    # a pending sign-in, made while allowed
    my $pending = 'lzs_odoo_pending=' . cookie_value( $ck, 'lzs_odoo_pending' );
    ok( cookie_value( $ck, 'lzs_odoo_pending' ), 'a pending cookie to carry' );
    set_conf( signin_addresses => 'office' );
    my $forms = scalar @{ $http->forms };
    my ( $st, $ck2, $j ) = code_step( $OUT, $pending );
    is( $st, 403, 'refused with a 403' );
    is( $j->{kind}, 'address', 'kind address' );
    is( $j->{error}, 'Sign-in is not available from your address.', 'the plain sentence' );
    ok( !cookie_value( $ck2, 'lzs_odoo_session' ), 'no session' );
    is( scalar @{ $http->forms }, $forms, 'Odoo was not asked for the code' );
    my ( $sti, undef, $ji ) = code_step( $IN, $pending );
    is( $sti, 200, 'from inside the same code step goes through' ) or diag encode_json($ji);
};

subtest 'inside: the password is checked and counted as ever' => sub {
    set_conf( signin_addresses => 'office' );
    my $c0 = counted($IN);
    my ( undef, $st, undef, $j ) = signin($IN);
    is( $st, 200, 'signed in' ) or diag encode_json($j);
    is( counted($IN), $c0 + 1, 'and counted' );
    my ( undef, $stw, undef, $jw ) = signin( $IN, password => 'wrong' );
    isnt( $jw->{kind}, 'address', 'a wrong password from inside is a credential failure, not an address refusal' );
};

subtest 'deny wins' => sub {
    set_conf( signin_addresses => 'office', signin_addresses_deny => 'blocked' );
    my ( undef, $st, undef, $j ) = signin($IN);
    is( $j->{kind}, 'address', 'inside the allow list and in the deny list: refused' );
    set_conf( signin_addresses_deny => 'blocked' );
    my ( undef, undef, undef, $j2 ) = signin($IN);
    is( $j2->{kind}, 'address', 'a deny list alone refuses its address' );
    my ( undef, $st3 ) = signin($OUT);
    is( $st3, 200, '...and admits everyone else' );
};

subtest 'behind a trusted proxy the trusted address is used; an untrusted X-Forwarded-For is ignored' => sub {
    set_conf( signin_addresses => 'office' );
    my ( undef, $st ) = signin( $IN, env => { REMOTE_ADDR => '127.0.0.1' } );
    is( $st, 200, 'the proxy vouches for an inside visitor: in' );
    # a stranger outside trusted_proxies claims to be inside
    my ( undef, $st2, undef, $j2 ) = signin( $IN, env => { REMOTE_ADDR => $OUT } );
    is( $st2, 403, 'an untrusted peer claiming an inside address through X-Forwarded-For is refused' );
    is( $j2->{kind}, 'address', '...as an address refusal' );
    my ( undef, $st3 ) = signin( '', env => { REMOTE_ADDR => $IN, HTTP_X_FORWARDED_FOR => '' } );
    is( $st3, 200, 'a direct inside peer is in' );
};

subtest 'audit: one `address-refused signin` row per address per hour, for both steps' => sub {
    set_conf( signin_addresses => 'office' );
    unlink "$d/lazysite/auth/.address-refused.db";
    my $a0 = audit_rows('signin');
    signin('198.51.100.77') for 1 .. 3;
    code_step( '198.51.100.77', undef ) for 1 .. 2;
    is( audit_rows('signin') - $a0, 1, 'five refusals from one address in an hour: one row' );
    signin('198.51.100.78');
    is( audit_rows('signin') - $a0, 2, 'another address has its own' );
};

subtest 'a faulted address-list store refuses (fails closed)' => sub {
    set_conf( signin_addresses => 'office' );
    my $good = slurp("$d/lazysite/auth/address-lists.json");
    spit( "$d/lazysite/auth/address-lists.json", 'not json' );
    my ( undef, $st, undef, $j ) = signin($IN);
    is( $j->{kind}, 'address', 'never quietly admits' );
    spit( "$d/lazysite/auth/address-lists.json", $good );
};

subtest 'signing out is never refused' => sub {
    set_conf( signin_addresses => 'office' );
    my ( $st, undef, $j ) = request( 'POST', '', { signout => 1, visitor_token => $VT }, HTTP_COOKIE => $VISITOR, HTTP_X_FORWARDED_FOR => $OUT );
    is( $st, 200, 'a person outside can still end a session' );
};

subtest 'a session binding may narrow the site\'s limit, on its calls' => sub {
    set_conf( signin_addresses => 'office' );
    unlink "$d/lazysite/auth/.login-rate.db";    # the office address has signed in a good many times above
    bind( $d, id => 'desk', operation => 'shop.products', credential => 'session', modes => 'authenticated',
        signin_addresses => 'desk' );
    my ( undef, $sst, $sck ) = signin($IN);
    my $sess = 'lzs_odoo_session=' . cookie_value( $sck, 'lzs_odoo_session' );
    ok( cookie_value( $sck, 'lzs_odoo_session' ), 'signed in from inside the office' );
    my %c = ( HTTP_COOKIE => "$VISITOR; $sess" );

    my ( $s1, undef, $j1 ) = request( 'GET', 'binding=mine', undef, %c, HTTP_X_FORWARDED_FOR => $IN );
    is( $s1, 200, 'a binding with no rule of its own runs for the office' ) or diag encode_json($j1);
    my ( $s2, undef, $j2 ) = request( 'GET', 'binding=desk', undef, %c, HTTP_X_FORWARDED_FOR => $IN );
    is( $s2, 200, 'the binding limited to the desk runs from the desk' ) or diag encode_json($j2);
    my ( $s3, undef, $j3 ) = request( 'GET', 'binding=desk', undef, %c, HTTP_X_FORWARDED_FOR => '203.0.113.50' );
    is( $s3, 403, 'from elsewhere in the office it is refused: the binding narrows the site\'s' );
    is( $j3->{kind}, 'address', '...kind address' );
    my ( $s4, undef, $j4 ) = request( 'POST', '', { binding => 'desk', visitor_token => $VT, params => {} }, %c, HTTP_X_FORWARDED_FOR => '203.0.113.50' );
    is( $s4, 403, 'and a POST call of it' );
    is( $j4->{kind}, 'address', '...kind address' );
    ok( audit_rows('signin desk') >= 1, 'with its own audit row' );

    # SM1159 before SM1168: with no Odoo session, a call from an address the binding
    # refuses is refused by address, not asked to sign in - a sign-in from there would
    # be refused too. From the desk the same call is asked to sign in.
    my ( $s5, undef, $j5 ) = request( 'POST', '', { binding => 'desk', visitor_token => $VT, params => {} },
        HTTP_COOKIE => $VISITOR, HTTP_X_FORWARDED_FOR => '203.0.113.50' );
    is( $s5, 403, 'no session, from an address the binding refuses: 403, not 401' ) or diag encode_json($j5);
    is( $j5->{kind}, 'address', '...kind address' );
    my ( $s6, undef, $j6 ) = request( 'POST', '', { binding => 'desk', visitor_token => $VT, params => {} },
        HTTP_COOKIE => $VISITOR, HTTP_X_FORWARDED_FOR => $IN );
    is( $s6, 401, 'no session, from the desk: asked to sign in' ) or diag encode_json($j6);
    is( $j6->{kind}, 'signin-required', '...signin-required' );

    # never widening: the site's own sign-in limit still refuses an address the binding would admit
    bind( $d, id => 'wide', operation => 'shop.products', credential => 'session', modes => 'authenticated',
        signin_addresses => 'office' );
    my ( undef, $sw, undef, $jw ) = signin($OUT);
    is( $jw->{kind}, 'address', 'a binding\'s list cannot widen the site\'s: sign-in from outside is still refused' );

    # a connection binding has no sign-in: a rule there is refused, not ignored
    my $r = eval { bind( $d, id => 'conn', operation => 'shop.products', modes => 'authenticated', signin_addresses => 'desk' ); 1 };
    ok( !$r, 'a connection binding carrying signin_addresses is not saved' );
    like( $@, qr/signin_addresses/, '...naming the field' );
};

done_testing();
