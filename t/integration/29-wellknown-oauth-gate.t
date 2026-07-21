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

done_testing();
