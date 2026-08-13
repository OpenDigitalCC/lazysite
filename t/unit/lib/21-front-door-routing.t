#!/usr/bin/perl
# SM293 step 5: the routing table, tested.
#
# These decisions have always existed - as a dozen RewriteRules in every shipped
# vhost template. They could not be tested there: testing a vhost means
# installing it on the web server the operator actually runs, which is the thing
# lazysite cannot do. So they were verified by reading, and three times the
# reading was wrong: SM248 (a secondary domain served the primary's registries),
# SM268 H17 (a rule that resolved to the wrong path and 404'd every static file
# on a Hestia layout), SM283 (a proxy answering by extension before the engine
# was consulted, live across a fleet for weeks).
#
# route() is a pure function, so every one of those decisions is now an
# assertion. That is the whole argument for step 5: not that a daemon is faster,
# but that the routing becomes something a test can hold.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::FrontDoor qw(route);

my $base = tempdir( CLEANUP => 1 );
my $d    = "$base/public_html";
make_path( "$d/lazysite/auth", "$d/assets" );

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} ( $t // "x\n" );
    close $fh;
    return;
}

sub r {
    my ( $uri, %o ) = @_;
    return route( { docroot => $d, uri => $uri, method => 'GET', %o } );
}

sub acls_on  { spit( "$d/lazysite/auth/acls.json", "{}\n" ); return }
sub acls_off { unlink "$d/lazysite/auth/acls.json";          return }

spit("$d/assets/logo.png");
spit("$d/index.md");

subtest 'the engine-owned paths are refused outright' => sub {
    is( r('/lazysite/auth/users')->{surface}, 'denied', 'the engine tree' );
    is( r('/lazysite')->{surface},            'denied', 'and its root' );
    is( r('/page.md.brief')->{surface}, 'denied',
        'and an authoring sidecar - content about the content' );

    isnt( r('/lazysite-assets/x.css')->{surface}, 'denied',
        'the control: lazysite-assets is a SERVED directory and must not be '
            . 'caught by a prefix match on "lazysite"' );
};

subtest 'the CGI surfaces route by name, and only two are wrapped' => sub {
    my $p = r('/cgi-bin/lazysite-processor.pl');
    is( $p->{surface}, 'cgi', 'the processor is a cgi surface' );
    ok( $p->{wrapped}, 'and goes through the auth wrapper' );

    my $m = r('/cgi-bin/lazysite-manager-api.pl');
    ok( $m->{wrapped}, 'so does the manager API' );

    # dav, mcp and oauth authenticate themselves. Wrapping dav would strip the
    # Authorization header its Basic auth depends on.
    for my $s (qw(dav mcp oauth)) {
        my $x = r("/cgi-bin/lazysite-$s.pl");
        is( $x->{surface}, 'cgi', "$s is a cgi surface" );
        ok( !$x->{wrapped}, "$s is NOT wrapped - it authenticates itself" );
    }
};

subtest 'webdav answers at its own prefix' => sub {
    for my $u ( '/dav', '/dav/', '/dav/content/page.md' ) {
        my $x = r($u);
        is( $x->{target}, 'lazysite-dav.pl', "$u reaches dav" );
        ok( !$x->{wrapped}, "$u is not wrapped" );
    }
};

subtest 'an existing static file: served, unless the site protects anything' => sub {
    # SM223, and the condition is the whole of why it was safe to ship. A site
    # that has never protected anything keeps serving its assets from disk; only
    # a site with a store pays the indirection.
    acls_off();
    my $off = r('/assets/logo.png');
    is( $off->{surface}, 'static',          'no acl store: served directly' );
    is( $off->{target},  'assets/logo.png', 'as itself' );

    acls_on();
    my $on = r('/assets/logo.png');
    is( $on->{surface}, 'processor',
        'acl store present: handed to the engine, because a file the web '
            . 'server hands over directly cannot be gated by anything the '
            . 'engine decides' );
    ok( $on->{wrapped}, 'through the wrapper, so an identity is available' );
    acls_off();
};

subtest 'a legacy .html/.shtml page is content too' => sub {
    spit("$d/legacy.html");
    spit("$d/oldshtml.shtml");

    acls_off();
    is( r('/legacy')->{target},   'legacy.html',    'extensionless -> .html' );
    is( r('/oldshtml')->{target}, 'oldshtml.shtml', 'and -> .shtml' );

    acls_on();
    is( r('/legacy')->{surface}, 'processor',
        'with a store, a migrated static page is gated like any other content' );
    acls_off();

    # The control: a page with a .md source is the engine's, never the .html
    # beside it - that .html is lazysite's own render cache, and serving it
    # directly is how the admin bar disappears.
    spit("$d/real.md");
    spit("$d/real.html");
    is( r('/real')->{surface}, 'processor',
        'a page with a .md source goes to the engine, not its render cache' );
};

subtest 'the root, when there is no index.md' => sub {
    my $bare = "$base/bare";
    make_path("$bare/lazysite/auth");
    spit("$bare/index.html");
    my $x = route( { docroot => $bare, uri => '/', method => 'GET' } );
    is( $x->{surface}, 'static',     'a legacy index.html is served' );
    is( $x->{target},  'index.html', 'as itself' );

    # And with a .md present it is the engine's, so the homepage keeps its
    # admin bar and its cache behaviour.
    is( r('/')->{surface}, 'processor', 'but index.md wins where it exists' );
};

subtest 'a signed-in visitor reaches the engine even on a miss' => sub {
    my $anon = r('/nothing-here');
    is( $anon->{surface}, 'processor', 'an anonymous miss is a page' );
    ok( !$anon->{wrapped}, 'and needs no wrapper' );

    my $in = r( '/nothing-here', cookie => 'lazysite_auth=abc' );
    ok( $in->{wrapped},
        'a session cookie means the request is wrapped, or the admin bar and '
            . 'the manager never work' );
};

subtest 'the generated registries need no rule of their own' => sub {
    # SM293 step 3 stopped writing them into the docroot, so they are misses and
    # reach the engine like any other page. The shipped templates still carry an
    # explicit rewrite for them - the first vhost rule this work has earned the
    # right to delete.
    for my $n (@Lazysite::FrontDoor::RETIRED_REGISTRY_ROUTES) {
        is( r("/$n")->{surface}, 'processor', "/$n reaches the engine" );
    }
};

subtest 'a query string never changes the decision' => sub {
    # Every rule above is about the path. A decision that varied with the query
    # would be a way to ask for a different surface than the path names.
    acls_on();
    is( r('/assets/logo.png?v=2')->{surface}, 'processor',
        'a cache-busting query does not turn a gated static into a miss' );
    acls_off();
    is( r('/lazysite/auth/users?x=1')->{surface}, 'denied',
        'and cannot get past a deny' );
};

done_testing();
