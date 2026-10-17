#!/usr/bin/perl
# SM1168 (OOM Lab, session mode): a POST for a `credential: session` binding from
# a visitor with NO Odoo session answered 403 kind csrf, because the token check
# ran first and, with no session, had no token to fit. The helper
# (starter/assets/lazysite-odoo.js) opens its sign-in prompt only on 401
# signin-required, so the person was never asked to sign in.
#
# Held here:
#   * no session, a session binding: 401 signin-required, with or without a token,
#     alone and as a call of a batch, and Odoo is not asked;
#   * nothing of the binding is told (no rows, no operation) - the answer is "you
#     are not signed in", which the visitor knows;
#   * the token check is not weakened: a request WITH a session and a wrong or
#     missing token is still 403 csrf, and with the right one runs;
#   * a public binding's visitor token is checked as before.
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

my ( undef, $vc, $tok ) = request( 'GET', 'csrf=1' );
my $VC = 'lzs_odoo_visitor=' . cv( $vc, 'lzs_odoo_visitor' );
my $VT = $tok->{visitor_token};

subtest 'no Odoo session: a session binding asks for the sign-in, token or not' => sub {
    my $c0 = scalar @{ $conn_fake->calls };
    my ( $st, undef, $j, $raw ) = request( 'POST', '', { binding => 'mine', visitor_token => $VT }, HTTP_COOKIE => $VC );
    is( $st, 401, 'with the visitor token: 401' ) or diag $raw;
    is( $j->{kind}, 'signin-required', 'by name' );
    ( $st, undef, $j ) = request( 'POST', '', { binding => 'mine' }, HTTP_COOKIE => $VC );
    is( $st, 401, 'with no token: 401, not 403 csrf' );
    is( $j->{kind}, 'signin-required', 'by name' );
    ( $st, undef, $j ) = request( 'POST', '', { binding => 'mine' } );
    is( $st, 401, 'with no cookie at all: 401' );
    is( $j->{kind}, 'signin-required', 'by name' );
    is( scalar @{ $conn_fake->calls }, $c0, 'Odoo was not asked' );
    ok( !exists $j->{report} && !exists $j->{operation}, 'the answer says nothing of the binding' );
};

subtest 'the same in a batch: that call answers 401 inside it, the others run' => sub {
    my ( $st, undef, $j ) = request( 'POST', '', { calls => [ { binding => 'mine' }, { binding => 'shared' } ], visitor_token => $VT },
        HTTP_COOKIE => $VC );
    is( $st, 200, 'the batch is answered' );
    is_deeply( [ map { $_->{status} } @{ $j->{results} } ], [ 401, 200 ], 'sign in; and the public call runs' ) or diag explain $j;
    is( $j->{results}[0]{kind}, 'signin-required', 'by name' );
    ( undef, undef, $j ) = request( 'POST', '', { calls => [ { binding => 'mine' }, { binding => 'shared' } ] }, HTTP_COOKIE => $VC );
    is_deeply( [ map { $_->{status} } @{ $j->{results} } ], [ 401, 403 ],
        'with no token: the session call asks for the sign-in, the public call is still 403 csrf' ) or diag explain $j;
};

subtest 'a public binding: the visitor token is checked as before' => sub {
    my ( $st, undef, $j ) = request( 'POST', '', { binding => 'shared', visitor_token => 'bad' }, HTTP_COOKIE => $VC );
    is( $st, 403, 'a bad visitor token: 403' );
    is( $j->{kind}, 'csrf', 'csrf' );
    ( $st, undef, $j ) = request( 'POST', '', { binding => 'shared', visitor_token => $VT }, HTTP_COOKIE => $VC );
    is( $st, 200, 'the right one: runs' );
};

subtest 'with a session the token is still required' => sub {
    my ( $st, $ck ) = request( 'POST', '', { signin => 1, login => 'jane@example.com', password => $PW, visitor_token => $VT },
        HTTP_COOKIE => $VC );
    is( $st, 200, 'signed in' );
    my $SESSION = 'lzs_odoo_session=' . cv( $ck, 'lzs_odoo_session' );
    my $ck_all  = "$VC; $SESSION";
    my ( $s1, undef, $j1 ) = request( 'POST', '', { binding => 'mine', visitor_token => 'wrong' }, HTTP_COOKIE => $ck_all );
    is( $s1, 403, 'a wrong token: 403' );
    is( $j1->{kind}, 'csrf', 'csrf' );
    my ( $s2, undef, $j2 ) = request( 'POST', '', { binding => 'mine' }, HTTP_COOKIE => $ck_all );
    is( $s2, 403, 'no token: 403' );
    is( $j2->{kind}, 'csrf', 'csrf' );
    my ( $s3 ) = request( 'POST', '', { binding => 'mine', visitor_token => $VT }, HTTP_COOKIE => $ck_all );
    is( $s3, 200, 'the right token: runs' );
};

done_testing;
