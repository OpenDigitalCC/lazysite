#!/usr/bin/perl
# SM190: the OAuth discovery metadata (.well-known/oauth-authorization-server,
# oauth-protected-resource) ship as api: content pages, so they render and cache
# like any page. They must not advertise an OAuth AS that lazysite-oauth.pl 404s
# while oauth_enabled is off (the default). The processor gates them on the
# killswitch BEFORE the render/cache path: 404 when off, served when on. A 404 is
# not cached, so a disabled service leaves no stale "advertising" cache entry.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
make_path("$docroot/.well-known");

my @wk = qw(oauth-authorization-server oauth-protected-resource);
for my $n (@wk) {
    open my $f, '>', "$docroot/.well-known/$n.md" or die $!;
    print $f "---\ntitle: OAuth\napi: true\ncontent_type: application/json; charset=utf-8\n---\n"
        . qq({"issuer":"[% site_url %]"}\n);
    close $f;
}

# oauth_enabled OFF (default) -> the discovery pages 404 (not advertised)
for my $n (@wk) {
    my $out = run_processor( $docroot, "/.well-known/$n" );
    like( $out, qr/Status:\s*404/, "SM190: /$n is 404 when oauth_enabled is off" );
}

# turn it on -> the pages are served
open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "oauth_enabled: enabled\n";
close $cf;
for my $n (@wk) {
    my $out = run_processor( $docroot, "/.well-known/$n" );
    like( $out, qr/Status:\s*200/, "SM190: /$n is served when oauth_enabled is on" );
    like( $out, qr/issuer/, "SM190: /$n renders the discovery JSON when on" );
}

# SM190 part 2: the ai-partner bootstrap is CODE-SERVED from the live config - it
# is always served (200, no-store) but lists ONLY the endpoints whose service is
# enabled, so it cannot advertise an endpoint that 404s.
{
    my $d2 = tempdir( CLEANUP => 1 );
    setup_minimal_site($d2);

    # Everything off (default): served, but no machine endpoints advertised.
    # Assert on the endpoint URL values, which are unambiguous (the scope object
    # also has a "webdav" KEY, so key-name regexes would false-match).
    my $out = run_processor( $d2, '/.well-known/ai-partner' );
    like( $out, qr/Status:\s*200/, 'SM190: ai-partner is always served (200)' );
    like( $out, qr/no-store/, 'SM190: ai-partner is no-store (a later toggle shows at once)' );
    unlike( $out, qr{/dav/},              'SM190: no webdav endpoint while webdav_enabled is off' );
    unlike( $out, qr{lazysite-mcp\.pl},   'SM190: no mcp endpoint while mcp_enabled is off' );
    unlike( $out, qr{action=exchange},    'SM190: no exchange endpoint while token_exchange_enabled is off' );

    # Enable webdav + mcp only.
    open my $c2, '>>', "$d2/lazysite/lazysite.conf" or die $!;
    print $c2 "webdav_enabled: enabled\nmcp_enabled: enabled\n";
    close $c2;
    $out = run_processor( $d2, '/.well-known/ai-partner' );
    like( $out, qr{/dav/},            'SM190: webdav endpoint appears when webdav_enabled is on' );
    like( $out, qr{lazysite-mcp\.pl}, 'SM190: mcp endpoint appears when mcp_enabled is on' );
    unlike( $out, qr{action=exchange}, 'SM190: exchange still absent (token_exchange_enabled off)' );

    # Enable token exchange -> exchange + rotate appear.
    open my $c3, '>>', "$d2/lazysite/lazysite.conf" or die $!;
    print $c3 "token_exchange_enabled: enabled\n";
    close $c3;
    $out = run_processor( $d2, '/.well-known/ai-partner' );
    like( $out, qr{action=exchange}, 'SM190: exchange endpoint appears when token_exchange_enabled is on' );
    like( $out, qr{action=rotate},   'SM190: rotate endpoint appears too' );
}

done_testing();
