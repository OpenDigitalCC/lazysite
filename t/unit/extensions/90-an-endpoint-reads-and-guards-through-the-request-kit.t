#!/usr/bin/perl
# SM1369 X5, H-4 (ruling 55): THE REQUEST KIT AN EXTENSION'S ENDPOINT USES.
#
# Lazysite::Endpoint holds what every extension endpoint needs and none may
# write for itself (t/lint/351):
#
#   * the body is capped BEFORE it is read: a declared length over the cap is
#     refused 413 and the bytes are left unread; a short body is refused;
#   * the visitor key is core's: a key, a cookie and a token minted the way the
#     Odoo extension minted them before the move still verify, under the same
#     cookie name and the same secret file, so no visitor in the field is lost;
#     each extension's secret is its own;
#   * post_guard, the kit's check of a POST, passes the session's token for the
#     verified account or the visitor token bound to the visitor's cookie, and
#     refuses anything else as 403 csrf, saying what to fetch first;
#   * `hooks.endpoints` names one of the extension's own owns.endpoints, as a
#     script name, once.
#
# Sabotage: make post_guard return undef for a request with no token, and the
# refusal cases fail; drop the cap test from read_body and the unread-body case
# fails.
use strict;
use warnings;
use Test::More;
use File::Path  qw(make_path);
use Digest::SHA qw(hmac_sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Endpoint          ();
use Lazysite::Extensions::Hooks ();
use Lazysite::Extensions::Owns  ();

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';

sub spit { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

sub with_stdin {
    my ( $bytes, $code ) = @_;
    local *STDIN;
    open STDIN, '<', \$bytes or die $!;
    my @r = $code->();
    my $rest = do { local $/; <STDIN> } // '';
    return ( $rest, @r );
}

subtest 'the body is capped before it is read' => sub {
    my ( $rest, $raw, $refused ) = with_stdin( 'x' x 100, sub { Lazysite::Endpoint::read_body( 100, 99 ) } );
    ok( !defined $raw, 'over the cap: nothing returned' );
    is( $refused->[0], '413 Payload Too Large', '...refused 413' );
    is( $refused->[1]{kind}, 'too-large', '...as too-large' );
    is( length $rest, 100, '...and not a byte of it was read' );

    ( $rest, $raw, $refused ) = with_stdin( '{"a":1}tail', sub { Lazysite::Endpoint::read_body( 7, 64 ) } );
    is( $raw, '{"a":1}', 'within the cap: exactly the declared length' );
    ok( !$refused, '...not refused' );
    is( $rest, 'tail', '...and nothing past it' );

    ( undef, $raw, $refused ) = with_stdin( 'abc', sub { Lazysite::Endpoint::read_body( 10, 64 ) } );
    is( $refused->[0], '400 Bad Request', 'shorter than it said: refused' );
    like( $refused->[1]{error}, qr/3 bytes where Content-Length said 10/, '...saying so' );

    ( undef, $raw, $refused ) = with_stdin( '', sub { Lazysite::Endpoint::read_body( 0, 64 ) } );
    is( $raw, '', 'no body: empty' );
};

my $d = site_tempdir();
make_path("$d/lazysite/odoo");

subtest 'a visitor key minted before the move still verifies' => sub {
    # The secret and the cookie exactly as the Odoo extension wrote them.
    my $secret = 'ab' x 32;
    spit( "$d/lazysite/odoo/visitor.secret", "$secret\n" );
    chmod 0600, "$d/lazysite/odoo/visitor.secret";
    my $key    = 'c' x 64;
    my $cookie = "$key." . hmac_sha256_hex( "visitor|$key", $secret );
    my $token  = hmac_sha256_hex( "csrf|$key", $secret );

    is( Lazysite::Endpoint::visitor_cookie_name('odoo'), 'lzs_odoo_visitor', 'the cookie keeps its name' );
    is( Lazysite::Endpoint::visitor_key( $d, 'odoo', "a=1; lzs_odoo_visitor=$cookie" ), $key,
        'the old cookie names its key' );
    is( Lazysite::Endpoint::visitor_token( $d, 'odoo', $key ), $token, 'the token is the one it always was' );
    ok( Lazysite::Endpoint::verify_visitor_token( $d, 'odoo', $token, $key ), '...and verifies' );
    {
        require Lazysite::Extensions;
        Lazysite::Extensions::add_payload_lib( "$FindBin::Bin/../../../extensions/odoo.pl" );
        require Lazysite::Odoo::Visitor;
        no warnings 'once';
        local $Lazysite::Odoo::Visitor::DOCROOT = $d;
        is( Lazysite::Odoo::Visitor::key_from_cookie("lzs_odoo_visitor=$cookie"), $key,
            'the extension\'s own names answer the same' );
        ok( Lazysite::Odoo::Visitor::verify_csrf( $token, $key ), '...for the token too' );
    }
    my $forged = "$key." . ( '0' x 64 );
    ok( !defined Lazysite::Endpoint::visitor_key( $d, 'odoo', "lzs_odoo_visitor=$forged" ), 'a forged signature names nothing' );

    # Another extension has a secret of its own: the odoo key is nobody else's.
    my ( $k2, $c2 ) = Lazysite::Endpoint::visitor_mint( $d, 'probe' );
    ok( defined $k2, 'another extension mints its own' );
    ok( -f "$d/lazysite/probe/visitor.secret", '...under its own secret' );
    is( ( stat "$d/lazysite/probe/visitor.secret" )[2] & 0777, 0600, '...0600' );
    ok( !defined Lazysite::Endpoint::visitor_key( $d, 'probe', "lzs_probe_visitor=$cookie" ),
        'the odoo cookie is not a probe visitor' );
    ok( !Lazysite::Endpoint::verify_visitor_token( $d, 'probe', $token, $key ), 'nor its token a probe token' );
    like( Lazysite::Endpoint::visitor_cookie_header( 'probe', $c2, secure => 1 ),
        qr/\ASet-Cookie: lzs_probe_visitor=\Q$c2\E; Path=\/; HttpOnly; SameSite=Strict; Max-Age=\d+; Secure\z/,
        'the cookie is HttpOnly, SameSite=Strict, Secure on https' );
};

subtest 'the kit guards a POST' => sub {
    my ( $key, $cookie ) = Lazysite::Endpoint::visitor_mint( $d, 'odoo' );
    my $vt = Lazysite::Endpoint::visitor_token( $d, 'odoo', $key );

    my $r = Lazysite::Endpoint::post_guard( docroot => $d, id => 'odoo', req => {} );
    is( $r->[0], '403 Forbidden', 'no account, no cookie, no token: refused' );
    is( $r->[1]{kind}, 'csrf', '...as csrf' );
    like( $r->[1]{error}, qr/fetch tokens from \?csrf=1 first/, '...saying what to fetch first' );

    $r = Lazysite::Endpoint::post_guard( docroot => $d, id => 'odoo', req => { visitor_token => 'nope' }, visitor => $key );
    like( $r->[1]{error}, qr/missing or stale token/, 'a wrong visitor token: refused' );

    ok( !Lazysite::Endpoint::post_guard( docroot => $d, id => 'odoo', req => { visitor_token => $vt }, visitor => $key ),
        'the visitor token bound to the cookie: passes' );
    ok( Lazysite::Endpoint::post_guard( docroot => $d, id => 'odoo', req => { visitor_token => $vt } ),
        'the same token with no cookie (a cross-site post): refused' );

    require Lazysite::Auth::Session;
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/auth/.secret", ( 'f' x 64 ) . "\n" );
    no warnings 'once';
    local $Lazysite::Auth::Session::LAZYSITE_DIR = "$d/lazysite";
    my $st = Lazysite::Auth::Session::generate_csrf_token('alice');
    ok( !Lazysite::Endpoint::post_guard( docroot => $d, id => 'odoo', req => { token => $st }, user => 'alice' ),
        'the session token for the verified account: passes' );
    {
        local $ENV{HTTP_X_CSRF_TOKEN} = $st;
        ok( !Lazysite::Endpoint::post_guard( docroot => $d, id => 'odoo', req => {}, user => 'alice' ),
            '...in the X-CSRF-Token header too' );
    }
    ok( Lazysite::Endpoint::post_guard( docroot => $d, id => 'odoo', req => { token => $st }, user => 'bob' ),
        'another account\'s token: refused' );
};

subtest 'hooks.endpoints names the extension\'s own script' => sub {
    is_deeply( [ Lazysite::Extensions::Hooks::validate_hooks( 'probe', { endpoints => [ { script => 'lazysite-probe.pl' } ] } ) ],
        [], 'a script name is accepted' );
    my @bad = map { $_->{error} } Lazysite::Extensions::Hooks::validate_hooks( 'probe',
        { endpoints => [ { script => '../x.pl' } ] } );
    ok( ( grep {/endpoints\[0\]\.script must be a script name/} @bad ), 'a path is refused' ) or diag explain \@bad;
    @bad = map { $_->{error} } Lazysite::Extensions::Hooks::validate_hooks( 'probe', { endpoints => [ { file => 'x' } ] } );
    ok( ( grep {/unknown key 'file'/} @bad ), 'an unknown key is refused' ) or diag explain \@bad;
    @bad = map { $_->{error} } Lazysite::Extensions::Hooks::validate_hooks( 'probe',
        { endpoints => [ { script => 'lazysite-a.pl' }, { script => 'lazysite-a.pl' } ] } );
    ok( ( grep {/declared twice/} @bad ), 'a script twice is refused' ) or diag explain \@bad;
    @bad = map { $_->{error} } Lazysite::Extensions::Owns::validate_owns( 'probe',
        { endpoints => ['lazysite-probe.pl'], hooks => { endpoints => [ { script => 'lazysite-odoo.pl' } ] } } );
    ok( ( grep {/'lazysite-odoo\.pl' is not one of this extension's endpoints/} @bad ),
        'another extension\'s script is refused' ) or diag explain \@bad;
};

done_testing;
