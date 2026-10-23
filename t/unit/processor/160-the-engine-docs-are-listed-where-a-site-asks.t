#!/usr/bin/perl
# SM1284 (ruling 35): THE ENGINE'S /docs PAGES STAY OUT OF A SITE'S OWN LISTINGS
# UNLESS THE SITE PUTS THEM IN.
#
# The manual serves at /docs/ on every site, but a site's search, sitemap, feeds
# and llms.txt are about the site: a business site's sitemap listing seventy
# pages of lazysite's manual is content its owner never wrote. A site that IS
# the product's documentation (lazysite.io) sets `engine_docs_public: true`.
#
# Two things hold either way: the manual's OWN listings see the engine tree (the
# features index is a scan of /docs/features/, and was empty on any site with no
# docs copy), and a site's page at the same path is the one listed - once, at
# its URL - as it is the one served.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site site_tempdir run_processor);

sub spit {
    my ( $p, $t ) = @_;
    make_path( dirname($p) );
    open my $fh, '>:raw', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    setup_minimal_site($d);
    if ( $o{public} ) {
        open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
        print {$cf} "engine_docs_public: true\n";
        close $cf;
    }
    my $eng = "$d/lazysite/templates/docs";
    spit( "$eng/guide.md", "---\ntitle: Engine guide\nsearch: true\nregister:\n  - sitemap.xml\n---\nENGINE-GUIDE\n" );
    spit( "$eng/twin.md",  "---\ntitle: Engine twin\nsearch: true\nregister:\n  - sitemap.xml\n---\nENGINE-TWIN\n" );
    spit( "$eng/index.md", "---\ntitle: Manual\n"
            . "tt_page_var:\n  pages: scan:/docs/*.md sort=title asc\n---\n"
            . "[% FOREACH p IN pages %]<li>[% p.url %]|[% p.title %]</li>[% END %]\n" );
    spit( "$d/docs/twin.md", "---\ntitle: Site twin\nsearch: true\nregister:\n  - sitemap.xml\n---\nSITE-TWIN\n" )
        if $o{twin};
    spit( "$d/mine.md", "---\ntitle: Mine\nsearch: true\nregister:\n  - sitemap.xml\n---\nMINE\n" );
    spit( "$d/find.md", "---\ntitle: Find\n"
            . "tt_page_var:\n  all: scan:/**/*.md filter=searchable:true sort=title asc\n---\n"
            . "[% FOREACH p IN all %]<li>[% p.url %]|[% p.title %]</li>[% END %]\n" );
    spit( "$d/lazysite/templates/registries/sitemap.xml.tt", "[% FOREACH p IN pages %][% p.url %]\n[% END %]" );
    return $d;
}

subtest 'by default: served, and listed only by the manual itself' => sub {
    my $d = site();
    like( run_processor( $d, '/docs/guide' ), qr/ENGINE-GUIDE/, 'the engine page serves' );
    my $map = run_processor( $d, '/sitemap.xml' );
    like( $map, qr{^/mine$}m, 'the sitemap lists the site\'s page' );
    unlike( $map, qr{/docs/}, 'and no engine page' );
    my $find = run_processor( $d, '/find' );
    like( $find, qr{<li>/mine\|Mine</li>}, 'a site page\'s scan (the search shape) finds the site\'s page' );
    unlike( $find, qr{/docs/}, 'and no engine page' );
    my $idx = run_processor( $d, '/docs/' );
    like( $idx, qr{<li>/docs/guide\|Engine guide</li>}, 'the manual\'s own index lists its pages' );
};

subtest 'engine_docs_public: true puts them in' => sub {
    my $d = site( public => 1 );
    my $map = run_processor( $d, '/sitemap.xml' );
    like( $map, qr{^/docs/guide$}m, 'the sitemap lists the engine page at its URL' );
    like( $map, qr{^/mine$}m,       'beside the site\'s own' );
    my $find = run_processor( $d, '/find' );
    like( $find, qr{<li>/docs/guide\|Engine guide</li>}, 'and a site page\'s scan finds it' );
};

subtest 'a site page at the same path is the one listed, once' => sub {
    my $d = site( public => 1, twin => 1 );
    my $map = run_processor( $d, '/sitemap.xml' );
    my @twin = $map =~ m{^(/docs/twin)$}mg;
    is( scalar @twin, 1, 'the sitemap lists /docs/twin once' );
    my $find = run_processor( $d, '/find' );
    like( $find, qr{<li>/docs/twin\|Site twin</li>}, 'the scan lists the site\'s copy' );
    unlike( $find, qr{Engine twin}, 'and not the engine\'s it shadows' );
    my $idx = run_processor( $d, '/docs/' );
    like( $idx, qr{<li>/docs/twin\|Site twin</li>}, 'so does the manual\'s own index' );
};

done_testing();
