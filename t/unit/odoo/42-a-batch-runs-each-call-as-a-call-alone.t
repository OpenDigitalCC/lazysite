#!/usr/bin/perl
# SM1146 (OOM Lab P2): a page with several reads paid the endpoint's start-up for
# each. `POST {calls: [{binding, params}, ...]}` runs up to ten calls in one
# request and answers each in order. What it must NOT do is become a way round
# anything a single call is held to:
#
#   * every call is checked (the token), authorised (the mode), recorded (one
#     call-record line) and rate-counted as the same call sent alone;
#   * a call that fails does not stop the others, and says so in its own status;
#   * a write follows the plan/apply rules of its binding;
#   * more than the cap is refused whole, before any call reaches Odoo;
#   * a call carries no token of its own, a sign-in is not a batch call, and a
#     session Odoo has ended is not used by the calls after it.
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
bind( $d, id => 'shared', operation => 'shop.products', modes => 'public' );
bind( $d, id => 'basket', operation => 'shop.basket', modes => 'public', visitor_param => 'basket_key' );
bind( $d, id => 'add', operation => 'shop.add', modes => 'public', apply => 'immediate',
    params => 'product=product, qty=qty', visitor_param => 'basket_key' );
bind( $d, id => 'add-later', operation => 'shop.add', modes => 'public',
    params => 'product=product', visitor_param => 'basket_key' );
bind( $d, id => 'staff', operation => 'shop.products', modes => 'authenticated', callers => 'staff' );
bind( $d, id => 'mine', operation => 'shop.products', credential => 'session', modes => 'authenticated' );

require "$root/lazysite-odoo.pl";
$Lazysite::Odoo::TRANSPORT = $conn_fake;
my $SCRIPT = '/cgi-bin/lazysite-odoo.pl';

sub request {
    my ( $method, $query, $body, %env ) = @_;
    my $out  = '';
    my $json = defined $body ? ( ref $body ? encode_json($body) : $body ) : '';
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

sub records {
    my $f = Lazysite::Odoo::calls_file();
    return 0 unless -f $f;
    open my $fh, '<', $f or die $!;
    my @l = <$fh>;
    return scalar @l;
}

sub basket_lines {
    my ($key) = @_;
    return scalar grep { $_->{basket_key} eq $key }
        map { $conn_fake->record( 'x.basket', $_ ) } @{ $conn_fake->all_ids('x.basket') };
}

my ( undef, $vc, $tok ) = request( 'GET', 'csrf=1' );
my $VC  = 'lzs_odoo_visitor=' . cv( $vc, 'lzs_odoo_visitor' );
my $VT  = $tok->{visitor_token};
my $KEY = Lazysite::Odoo::Visitor::key_from_cookie($VC);

sub batch {
    my ( $calls, %o ) = @_;
    return request( 'POST', '', { calls => $calls, ( $o{no_token} ? () : ( visitor_token => $VT ) ) },
        HTTP_COOKIE => ( $o{cookie} // $VC ) );
}

subtest 'the calls are answered in order, each with its own status' => sub {
    my $r0 = records();
    my ( $st, undef, $j, $raw ) = batch( [
            { binding => 'shared' },
            { binding => 'basket' },
            { binding => 'add', params => { product => 1, qty => 2 } },
            { binding => 'nonesuch' },
            { binding => 'staff' },
            { binding => 'add-later', params => { product => 2 } },
            { binding => 'add', params => { product => 1, bogus => 1 } },
        ] );
    is( $st, 200, 'the batch is answered' ) or diag $raw;
    ok( $j->{ok}, 'ok' );
    my @r = @{ $j->{results} // [] };
    is( scalar @r, 7, 'one answer per call' );
    is_deeply( [ map { $_->{status} } @r ], [ 200, 200, 200, 404, 403, 200, 400 ],
        'each its own status, in the order sent: a failing call stopped no other' ) or diag explain \@r;
    is( scalar @{ $r[0]{report}{rows} }, 2, 'the first read has its rows' );
    ok( $r[2]{applied}, 'an apply: immediate write applied' );
    is( basket_lines($KEY), 1, 'and the visitor\'s line is in Odoo' );
    is( $r[3]{kind}, 'not-found', 'no such binding, by name' );
    is( $r[4]{kind}, 'mode',      'a binding this caller may not run, by name' );
    ok( $r[5]{planned} && $r[5]{plan}, 'a confirm-write returns a plan to confirm, as it does alone' );
    is( $r[6]{kind}, 'invalid', 'an unmapped field is refused, as it is alone' );
    unlike( $raw, qr/\Q$KEY\E/, 'the visitor key is in no answer' );

    # one record per call that reached the engine's gate: the 6 bindings that exist
    is( records() - $r0, 6, 'each call that named a binding is one line in the call record' );
};

subtest 'a plan made in a batch is confirmed as it is alone' => sub {
    my ( undef, undef, $j ) = batch( [ { binding => 'add-later', params => { product => 2 } } ] );
    my $plan = $j->{results}[0]{plan};
    ok( $plan, 'a plan' );
    my $before = basket_lines($KEY);
    ( undef, undef, $j ) = batch( [ { plan => $plan, confirm => JSON::PP::true } ] );
    ok( $j->{results}[0]{applied}, 'confirmed in a batch: applied' ) or diag explain $j;
    is( basket_lines($KEY), $before + 1, 'the line is in Odoo' );
    ( undef, undef, $j ) = batch( [ { plan => $plan, confirm => JSON::PP::true } ] );
    isnt( $j->{results}[0]{status}, 200, 'and not applied twice' );
    my ( $other, $ocookie ) = Lazysite::Odoo::Visitor::mint();
    my ( undef, undef, $j2 ) = request( 'POST', '', { calls => [ { plan => $plan, confirm => JSON::PP::true } ],
            visitor_token => Lazysite::Odoo::Visitor::csrf_token($other) },
        HTTP_COOKIE => "lzs_odoo_visitor=$ocookie" );
    is( $j2->{results}[0]{status}, 404, 'another visitor cannot confirm it: not found' );
};

subtest 'more than the cap is refused whole, and nothing reaches Odoo' => sub {
    my $c0 = scalar @{ $conn_fake->calls };
    my $r0 = records();
    my ( $st, undef, $j ) = batch( [ map { { binding => 'shared' } } 1 .. 11 ] );
    is( $st,        400,       'eleven calls: 400' );
    is( $j->{kind}, 'invalid', 'invalid' );
    like( $j->{error}, qr/1 to 10 calls/, 'the cap is said' );
    is( scalar @{ $conn_fake->calls }, $c0, 'Odoo was not asked' );
    is( records(),                     $r0, 'and nothing was recorded' );
    ( $st, undef, $j ) = batch( [ map { { binding => 'shared' } } 1 .. 10 ] );
    is( $st, 200, 'ten is allowed' );
    is( scalar @{ $j->{results} }, 10, 'ten answers' );
    ( $st, undef, $j ) = batch( [] );
    is( $st, 400, 'none is refused' );
    ( $st, undef, $j ) = request( 'POST', '', { calls => 'shared', visitor_token => $VT }, HTTP_COOKIE => $VC );
    is( $st, 400, 'calls that is not a list is refused' );
};

subtest 'every call needs the token, and a call cannot bring its own' => sub {
    my $c0 = scalar @{ $conn_fake->calls };
    my ( $st, undef, $j ) = batch( [ { binding => 'add', params => { product => 1 } }, { binding => 'shared' } ], no_token => 1 );
    is( $st, 200, 'the batch is answered' );
    is_deeply( [ map { $_->{status} } @{ $j->{results} } ], [ 403, 403 ], 'with no token every call is refused' );
    is( $j->{results}[0]{kind}, 'csrf', 'as csrf' );
    is( scalar @{ $conn_fake->calls }, $c0, 'and Odoo was not asked' );

    ( $st, undef, $j ) = request( 'POST', '', { calls => [ { binding => 'add', params => { product => 1 }, visitor_token => $VT } ] },
        HTTP_COOKIE => $VC );
    is( $j->{results}[0]{status}, 403, 'a token inside a call is not the request\'s token' );

    ( $st, undef, $j ) = batch( [ { binding => 'add', params => { product => 1 } } ], cookie => 'x=1' );
    is( $j->{results}[0]{status}, 403, 'a token with no visitor cookie (a cross-site post): refused' );
};

subtest 'a sign-in or sign-out is not a batch call' => sub {
    my $p0 = scalar @{ $http->posts };
    my ( undef, undef, $j ) = batch( [ { signin => 1, login => 'jane@example.com', password => $PW }, { signout => 1 }, { calls => [] }, 'x' ] );
    is_deeply( [ map { $_->{status} } @{ $j->{results} } ], [ 400, 400, 400, 400 ], 'each refused' );
    is( scalar @{ $http->posts }, $p0, 'Odoo was not contacted' );
};

subtest 'a session Odoo has ended is not used by the calls after it' => sub {
    my ( $st, $ck ) = request( 'POST', '', { signin => 1, login => 'jane@example.com', password => $PW, visitor_token => $VT },
        HTTP_COOKIE => $VC );
    is( $st, 200, 'signed in' );
    my $SESSION = 'lzs_odoo_session=' . cv( $ck, 'lzs_odoo_session' );
    my $SID     = Lazysite::Odoo::Session::sid_from_cookie($SESSION);
    my $IDENT   = 'lzs_odoo_identity=' . cv( $ck, 'lzs_odoo_identity' );    # current: no identity round trip
    my ( undef, undef, $j ) = batch( [ { binding => 'mine' }, { binding => 'shared' } ], cookie => "$VC; $SESSION" );
    is_deeply( [ map { $_->{status} } @{ $j->{results} } ], [ 200, 200 ], 'a session binding runs as the person' );

    $http->expire($SID);
    my $p0 = scalar @{ $http->posts };
    my ( $s2, $ck2, $j2 ) = batch( [ { binding => 'mine' }, { binding => 'mine' }, { binding => 'shared' } ],
        cookie => "$VC; $SESSION; $IDENT" );
    is( $s2, 200, 'answered' );
    is_deeply( [ map { $_->{status} } @{ $j2->{results} } ], [ 401, 403, 200 ],
        'the ended session: sign in; then no session left, so the person\'s token has nothing to fit (as a single POST with no session); and a public call still runs' )
        or diag explain $j2;
    is( $j2->{results}[0]{kind}, 'signin-required', 'the first is told to sign in, by name' );
    is( scalar @{ $http->posts }, $p0 + 1, 'Odoo was asked once, by the first call, and never again on the dead session' );
    like( ( grep { /\Alzs_odoo_session=/ } @$ck2 )[0] // '', qr/Max-Age=0/, 'and the credential cookie is cleared' );
};

done_testing;
