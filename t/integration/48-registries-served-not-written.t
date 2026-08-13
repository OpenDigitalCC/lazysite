#!/usr/bin/perl
# SM293 step 3: the generated registries are served by the engine and never
# written into the document root.
#
# They used to be files at the content root, produced as a side effect of a page
# render. That is how SM248 happened: a file at the docroot root is resolved by
# the front end BEFORE the engine is consulted, so a secondary domain was handed
# the primary's sitemap - the engine knew which domain had been asked and was
# never given the chance to say.
#
# The operator's call (2026-08-13) was generated-on-request with a cache: it uses
# the machinery already there, a registry being a little stale does not matter,
# and it keeps a high-demand artefact out of the served tree entirely.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $repo = "$FindBin::Bin/../..";
my $d    = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/templates/registries", "$d/pages" );

copy( "$repo/starter/lazysite/templates/registries/sitemap.xml.tt",
    "$d/lazysite/templates/registries/sitemap.xml.tt" )
    or die "copy sitemap.tt: $!";

open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\nsite_url: https://example.test\n";
close $c;

for my $p (qw(index about)) {
    open my $f, '>', "$d/$p.md" or die $!;
    print {$f} "---\ntitle: $p\nregister:\n  - sitemap.xml\n---\n\nbody\n";
    close $f;
}

subtest 'a sitemap is served, and nothing lands in the document root' => sub {
    my $out = run_processor( $d, '/sitemap.xml' );

    like( $out, qr{Content-Type: application/xml}, 'served as XML' );
    like( $out, qr{<loc>https://example\.test/about</loc>},
        'and it lists the registered pages' );

    ok( !-e "$d/sitemap.xml",
        'and NOTHING was written to the document root - a file there is '
            . 'resolved by the front end before the engine is asked which '
            . 'domain was requested, which is SM248' );

    ok( -f "$d/lazysite/cache/registries/_root/sitemap.xml",
        'the generated copy is cached under the engine tree instead' );
};

subtest 'a second request is served from the cache' => sub {
    # The point of caching: one render per TTL, not one per crawler hit. Proven
    # by making the cached bytes distinctive and checking they come back, rather
    # than by timing anything.
    my $cache = "$d/lazysite/cache/registries/_root/sitemap.xml";
    open my $fh, '>', $cache or die $!;
    print {$fh} "<urlset>CACHED-MARKER</urlset>\n";
    close $fh;

    my $out = run_processor( $d, '/sitemap.xml' );
    like( $out, qr/CACHED-MARKER/,
        'the cached copy is served rather than regenerated' );
};

subtest 'a site with no registry template still 404s' => sub {
    # The control. Serving an empty document to every site that never asked for
    # a sitemap would be worse than the 404 it used to give.
    my $bare = tempdir( CLEANUP => 1 );
    make_path("$bare/lazysite");
    open my $bc, '>', "$bare/lazysite/lazysite.conf" or die $!;
    print {$bc} "site_name: B\n";
    close $bc;
    open my $bi, '>', "$bare/index.md" or die $!;
    print {$bi} "---\ntitle: home\n---\n\nhome\n";
    close $bi;

    my $out = run_processor( $bare, '/sitemap.xml' );
    like( $out, qr/404 Not Found/,
        'a site that ships no sitemap template answers as it always did' );
};

subtest 'a hand-authored file in the content still wins' => sub {
    # An operator who wrote their own sitemap.xml as content should keep it.
    # The registry route sits AFTER the static handler for exactly this, and
    # declines outright when a real file is there - so the answer does not
    # depend on which route the request took.
    #
    # Set up WITH an ACL store, because that is the condition under which the
    # engine is handed static requests at all (SM223). Without one the front end
    # serves the file and never asks; testing the bare processor would be
    # testing a path production does not use.
    my $own = tempdir( CLEANUP => 1 );
    make_path( "$own/lazysite/templates/registries", "$own/lazysite/auth" );
    open my $ac, '>', "$own/lazysite/auth/acls.json" or die $!;
    print {$ac} "{}\n";
    close $ac;
    copy( "$repo/starter/lazysite/templates/registries/sitemap.xml.tt",
        "$own/lazysite/templates/registries/sitemap.xml.tt" )
        or die $!;
    open my $oc, '>', "$own/lazysite/lazysite.conf" or die $!;
    print {$oc} "site_name: O\nsite_url: https://own.test\n";
    close $oc;
    open my $oi, '>', "$own/index.md" or die $!;
    print {$oi} "---\ntitle: home\nregister:\n  - sitemap.xml\n---\n\nhome\n";
    close $oi;
    open my $os, '>', "$own/sitemap.xml" or die $!;
    print {$os} "<urlset>HAND-AUTHORED</urlset>\n";
    close $os;

    my $out = run_processor( $own, '/sitemap.xml' );
    like( $out, qr/HAND-AUTHORED/,
        "the operator's own file is served, not overwritten by a generated one" );
};

done_testing();
