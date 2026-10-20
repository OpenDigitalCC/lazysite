#!/usr/bin/perl
# SM1118 (ruled 2026-10-20, #338): A SITE CAN BE PUT INTO MAINTENANCE - the page
# requests, through the REAL auth wrapper and straight to the processor.
#
# The rulings, one row each:
#   Q1  302 to the maintenance page; the page itself answers 503 with Retry-After
#   Q2/Q3 a request whose verified identity holds `maintenance_access` passes (and
#       sees a banner); everyone else - anonymous, signed in, a forged identity -
#       is sent to the page. The maintenance page, the sign-in pages and the
#       assets they need stay reachable so an operator can sign in
#   Q4  per domain, with an instance switch covering all
#   Q5  a request that is not a GET or HEAD is refused, not redirected or stored
#
# THE PLACEMENT. The filing put the check beside the bad-URL guard in the wrapper.
# It sits in the processor's main(), where every route a page request takes ends
# (the wrapper, the split templates' direct processor, the pool's worker - the
# last in t/integration/316), asked of the one identity reader. So this runs each
# row BOTH ways: signed in through the wrapper, anonymous straight to the
# processor.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use MaintenanceRig qw(build_site cookie_for conf_set via_wrapper via_processor slurp spit);

my $UNTIL = do {
    my @g = gmtime( time() + 7200 );
    sprintf '%04d-%02d-%02d %02d:%02d', $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1];
};

sub loc { return $_[0]{headers}{location} // '' }
sub is_redirect_to {
    my ( $r, $to, $name ) = @_;
    is( $r->{code}, 302, "$name: 302" );
    like( loc($r), qr{\A\Q$to\E(?:\?|\z)}, "$name: to $to" );
}

my $d = build_site( conf => "maintenance: on\nmaintenance_until: $UNTIL\n" );

# ---------------------------------------------------------------------------
subtest 'Q1: a visitor is sent to the page by a temporary redirect, never cached' => sub {
    my $r = via_processor( $d, uri => '/about' );
    is_redirect_to( $r, '/maintenance', 'anonymous, straight to the processor' );
    like( loc($r), qr{from=%2Fabout\z}, 'the original address travels with it' );
    like( $r->{headers}{'cache-control'} // '', qr/no-store/, 'the redirect is no-store' );
    unlike( $r->{body}, qr/ABOUT BODY/, 'the page was not served' );

    $r = via_wrapper( $d, uri => '/about' );
    is_redirect_to( $r, '/maintenance', 'anonymous, through the wrapper' );

    $r = via_wrapper( $d, uri => '/' );
    is_redirect_to( $r, '/maintenance', 'the home page' );

    $r = via_wrapper( $d, uri => '/about', method => 'HEAD' );
    is( $r->{code}, 302, 'a HEAD is redirected as a GET is' );
};

subtest 'Q1: the page answers 503 with Retry-After, and is not cached' => sub {
    for my $how ( [ wrapper => \&via_wrapper ], [ processor => \&via_processor ] ) {
        my $r = $how->[1]->( $d, uri => '/maintenance' );
        is( $r->{code}, 503, "$how->[0]: the maintenance page is a 503" );
        like( $r->{body}, qr/in maintenance/i, '...and says so' );
        my $ra = $r->{headers}{'retry-after'};
        ok( defined $ra && $ra =~ /\A\d+\z/, '...with a Retry-After in seconds' );
        cmp_ok( abs( ( $ra // 0 ) - 7200 ), '<=', 120, '...which is the time to maintenance_until' );
        like( $r->{headers}{'cache-control'} // '', qr/no-store/, '...and is no-store' );
        unlike( $r->{headers}{'cache-control'} // '', qr/public|max-age=[1-9]/, '...never public' );
    }
    my $nountil = build_site( conf => "maintenance: on\n" );
    my $r       = via_processor( $nountil, uri => '/maintenance' );
    is( $r->{headers}{'retry-after'}, 3600, 'with no time named, Retry-After is an hour' );
};

subtest 'Q2/Q3: the capability, and only the capability, gets through' => sub {
    my $r = via_wrapper( $d, uri => '/about', cookie => cookie_for('boss') );
    is( $r->{code}, 200, 'boss holds maintenance_access: the page is served' );
    like( $r->{body}, qr/ABOUT BODY/, '...as it is' );
    like( $r->{body}, qr/lazysite-maintenance-banner/, '...with the banner that says the site is in maintenance' );

    $r = via_wrapper( $d, uri => '/about', cookie => cookie_for('alice') );
    is_redirect_to( $r, '/maintenance', 'alice is signed in and holds other capabilities, not this one' );

    $r = via_wrapper( $d, uri => '/about', cookie => cookie_for('bob') );
    is_redirect_to( $r, '/maintenance', 'bob holds nothing' );

    # Only a VERIFIED identity counts.
    $r = via_wrapper( $d, uri => '/about', cookie => cookie_for( 'boss', bad_sig => 1 ) );
    is_redirect_to( $r, '/maintenance', "boss's cookie with a bad signature is nobody" );

    $r = via_wrapper( $d, uri => '/about', env => { HTTP_X_REMOTE_USER => 'boss', HTTP_X_REMOTE_GROUPS => 'members,role-boss' } );
    is_redirect_to( $r, '/maintenance', 'a client-supplied X-Remote-User through the wrapper is stripped' );

    $r = via_processor( $d, uri => '/about',
        env => { HTTP_X_REMOTE_USER => 'boss', HTTP_X_REMOTE_GROUPS => 'members,role-boss', LAZYSITE_AUTH_TRUSTED => 1 } );
    is( $r->{code}, 200, 'the wrapper-vouched sentinel IS the wrapper speaking (what the processor trusts)' );
    $r = via_processor( $d, uri => '/about', env => { HTTP_X_REMOTE_USER => 'boss', HTTP_X_REMOTE_GROUPS => 'members,role-boss' } );
    is_redirect_to( $r, '/maintenance', '...and without it the same headers are only a client talking' );

    # The page a holder is sent to by name is a normal 200 for them.
    $r = via_wrapper( $d, uri => '/maintenance', cookie => cookie_for('boss') );
    is( $r->{code}, 200, 'the maintenance page, to a holder, is not a 503' );

    # The capability, not the role: take it away and boss is a visitor.
    require TestHelper;
    TestHelper::revoke_caps( $d, 'boss', 'maintenance_access' );
    $r = via_wrapper( $d, uri => '/about', cookie => cookie_for('boss') );
    is_redirect_to( $r, '/maintenance', 'boss without the capability is sent to the page' );
    TestHelper::grant_caps( $d, 'boss', 'ui', 'maintenance_access' );

    # ...and giving it to another group is all it takes for bob.
    TestHelper::grant_caps( $d, 'bob', 'maintenance_access' );
    $r = via_wrapper( $d, uri => '/about', cookie => cookie_for('bob') );
    is( $r->{code}, 200, 'bob, once granted it, is let through' );
    TestHelper::revoke_caps( $d, 'bob', 'maintenance_access' );
};

subtest 'what stays reachable, so an operator can sign in' => sub {
    for my $p (qw(/login /logout /forgot /claim)) {
        my $r = via_processor( $d, uri => $p );
        isnt( $r->{code}, 302, "$p is not redirected" ) or diag( loc($r) );
        unlike( loc($r), qr{maintenance}, "$p does not go to the maintenance page" );
    }
    is( via_processor( $d, uri => '/login' )->{code}, 200, 'the sign-in page is served' );
    for my $p ( '/lazysite-assets/theme/site.css', '/images/logo.png', '/.well-known/security.txt', '/robots.txt' ) {
        my $r = via_processor( $d, uri => $p );
        unlike( loc($r), qr{maintenance}, "$p is not sent to the maintenance page" );
    }
    # The wrapper's own actions (sign-in, sign-out) never reach the processor.
    my $r = via_wrapper( $d, uri => '/login?action=logout' );
    unlike( loc($r), qr{maintenance}, 'the wrapper signs a visitor out in maintenance' );
};

subtest 'Q5: anything that is not a GET or HEAD is refused, not redirected' => sub {
    for my $m (qw(POST PUT DELETE)) {
        my $r = via_wrapper( $d, uri => '/about', method => $m, body => 'a=1' );
        is( $r->{code}, 503, "$m: 503" );
        like( $r->{body}, qr/in maintenance/i, "$m: with the maintenance message" );
        ok( $r->{headers}{'retry-after'}, "$m: and Retry-After" );
        ok( !loc($r),                     "$m: no redirect to follow with a GET" );
    }
    my $r = via_wrapper( $d, uri => '/about', method => 'POST', body => 'a=1', cookie => cookie_for('boss') );
    isnt( $r->{code}, 503, 'a holder is not refused' );
};

subtest 'the manager is the capability\'s, like any page' => sub {
    my $r = via_wrapper( $d, uri => '/manager/', cookie => cookie_for('alice') );
    is_redirect_to( $r, '/maintenance', 'a signed-in account without it is sent to the page' );
    $r = via_wrapper( $d, uri => '/manager/', cookie => cookie_for('boss') );
    isnt( $r->{code}, 302, 'the operator reaches it' ) or diag( loc($r) );
};

subtest 'turning it off takes effect at once (nothing was cached)' => sub {
    # Render the page for a holder first: the cache now holds /about.
    via_wrapper( $d, uri => '/about', cookie => cookie_for('boss') );
    is_redirect_to( via_processor( $d, uri => '/about' ), '/maintenance', 'a visitor is still redirected after a cached render' );
    conf_set( $d, 'maintenance', 'off' );
    my $r = via_processor( $d, uri => '/about' );
    is( $r->{code}, 200, 'off: the visitor gets the page' );
    like( $r->{body}, qr/ABOUT BODY/, '...' );
    unlike( $r->{body}, qr/lazysite-maintenance-banner/, '...with no banner' );
    $r = via_processor( $d, uri => '/maintenance' );
    isnt( $r->{code}, 503, 'the maintenance page is no 503 when the site is open' );
    conf_set( $d, 'maintenance', 'on' );
    is_redirect_to( via_processor( $d, uri => '/about' ), '/maintenance', 'on again: redirected again' );
    conf_set( $d, 'maintenance', undef );
    is( via_processor( $d, uri => '/about' )->{code}, 200, 'no key at all is open' );
    conf_set( $d, 'maintenance', 'on' );
};

subtest 'the page can be any page of the site, or an address elsewhere' => sub {
    conf_set( $d, 'maintenance_page', '/closed' );
    my $r = via_processor( $d, uri => '/about' );
    is_redirect_to( $r, '/closed', 'a page the site wrote' );
    $r = via_processor( $d, uri => '/closed' );
    is( $r->{code}, 503, 'it answers 503' );
    like( $r->{body}, qr/MY OWN CLOSED PAGE/, '...with its own content' );
    ok( $r->{headers}{'retry-after'}, '...and Retry-After' );

    conf_set( $d, 'maintenance_page', 'https://status.example.com/down' );
    $r = via_processor( $d, uri => '/about' );
    is( $r->{code}, 302, 'an address elsewhere' );
    like( loc($r), qr{\Ahttps://status\.example\.com/down\?from=%2Fabout\z}, '...is where the redirect goes' );

    conf_set( $d, 'maintenance_page', "javascript:alert(1)" );
    $r = via_processor( $d, uri => '/about' );
    is_redirect_to( $r, '/maintenance', 'a value that is no address falls back to the default' );
    conf_set( $d, 'maintenance_page', undef );
};

subtest 'Q4: per domain, with an instance switch covering all' => sub {
    my $m = build_site( conf => "alias_hosts: a.example, b.example\nalias.a.example.maintenance: on\n" );
    is_redirect_to( via_processor( $m, uri => '/about', host => 'a.example' ), '/maintenance', 'the domain in maintenance' );
    is( via_processor( $m, uri => '/about', host => 'b.example' )->{code}, 200, '...and its sibling is open' );
    is( via_processor( $m, uri => '/about', host => 'site.test' )->{code}, 200, '...and the default host' );
    is( via_processor( $m, uri => '/maintenance', host => 'a.example' )->{code}, 503, 'the page answers 503 on that domain' );
    isnt( via_processor( $m, uri => '/maintenance', host => 'b.example' )->{code}, 503, '...and not on the open one' );
    my $r = via_wrapper( $m, uri => '/about', host => 'a.example', cookie => cookie_for('boss') );
    is( $r->{code}, 200, 'the operator browses the domain in maintenance' );
    $r = via_wrapper( $m, uri => '/about', host => 'a.example', cookie => cookie_for('bob') );
    is( $r->{code}, 302, 'a member does not' );

    conf_set( $m, 'maintenance', 'on' );
    for my $h (qw(a.example b.example site.test)) {
        is( via_processor( $m, uri => '/about', host => $h )->{code}, 302, "the instance switch covers $h" );
    }
    conf_set( $m, 'alias.a.example.maintenance', 'off' );
    is( via_processor( $m, uri => '/about', host => 'a.example' )->{code}, 302, 'an alias line cannot take its host out of it' );

    my $u = build_site( conf => "alias.a.example.maintenance: on\n" );
    is( via_processor( $u, uri => '/about', host => 'a.example' )->{code}, 200,
        'an alias line for a host alias_hosts does not declare changes nothing' );
};

done_testing;
