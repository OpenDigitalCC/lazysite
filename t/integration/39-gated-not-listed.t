#!/usr/bin/perl
# SM268 H13: a gated page must not be published by the things that LIST pages.
#
# resolve_scan and scan_pages read .md sources directly and applied no filter at
# all. Gating a section stopped its pages being served and left their titles,
# subtitles, paths, custom front-matter keys and a 500-character BODY EXCERPT
# reachable through any page that scans the tree - including the starter's own
# /search-index, which is api: true with ttl: 3600 and is therefore served
# Cache-Control: public, max-age=3600. The originating case for SM223 was a named
# person's account of their own working life; "protected" that publishes the
# opening paragraph to a shared cache for an hour is not protected.
#
# Two different rules, deliberately:
#
#   scan:        answers a REQUEST, so it filters on the requesting identity -
#                a member of the group still sees their own section.
#   registries   are STATIC artefacts written to disk and served to anyone, so
#                they filter on "is it gated at all", identity playing no part.
#
# Every assertion below was confirmed FAILING before the fix: the excerpt came
# back in the scan, and both URLs were in sitemap.xml.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $docroot = tempdir( CLEANUP => 1 );
make_path( "$docroot/lazysite/auth", "$docroot/private", "$docroot/open" );

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

spit( "$docroot/lazysite/lazysite.conf", "site_name: T\n" );

# The scanning page: a plain scan of every page in the tree, rendered as the
# excerpt-bearing JSON the starter's /search-index produces.
spit( "$docroot/list.md", <<'MD' );
---
title: List
tt_page_var:
  all_pages: scan:/**/*.md
---
[% FOREACH p IN all_pages %]ITEM:[% p.url %]:[% p.excerpt %]
[% END %]
MD

spit( "$docroot/open/free.md",
    "---\ntitle: Free\nregister:\n  - sitemap.xml\n---\nPUBLIC-BODY-MARKER\n" );
spit( "$docroot/private/secret.md",
    "---\ntitle: Secret\nsubtitle: sensitive subtitle\n"
        . "register:\n  - sitemap.xml\n---\nSECRET-BODY-MARKER private material.\n" );

# One folder entry - the SM181 shape an operator actually writes.
spit( "$docroot/lazysite/auth/acls.json",
    encode_json( { 'private' => { read => ['@editors'] } } ) );

sub clear_cache {
    for my $f (qw(list.html open/free.html private/secret.html)) {
        unlink "$docroot/$f" if -f "$docroot/$f";
    }
    unlink "$docroot/sitemap.xml" if -f "$docroot/sitemap.xml";
    return;
}

sub get {
    my ( $uri, %env ) = @_;
    clear_cache();
    return run_processor( $docroot, $uri, %env );
}

subtest 'an anonymous scan does not carry the gated page' => sub {
    my $out = get('/list');
    like( $out, qr/ITEM:\/open\/free/, 'the public page is listed' );
    unlike( $out, qr{ITEM:/private/secret},
        'the gated page is not listed at all' );
    unlike( $out, qr/SECRET-BODY-MARKER/,
        'and its body excerpt did not travel with the listing - the excerpt was '
            . 'the disclosure, not the URL' );
};

subtest 'a member of the granted group still sees their own section' => sub {
    my $out = get(
        '/list',
        LAZYSITE_AUTH_TRUSTED => '1',
        HTTP_X_REMOTE_USER    => 'alice',
        HTTP_X_REMOTE_GROUPS  => 'editors',
    );
    like( $out, qr{ITEM:/private/secret},
        'scan filters on the REQUESTING identity - a filter that hid the page '
            . 'from everyone would pass the subtest above for the wrong reason' );
    like( $out, qr/SECRET-BODY-MARKER/, 'excerpt and all' );
};

subtest 'a signed-in NON-member does not see it' => sub {
    my $out = get(
        '/list',
        LAZYSITE_AUTH_TRUSTED => '1',
        HTTP_X_REMOTE_USER    => 'mallory',
        HTTP_X_REMOTE_GROUPS  => 'visitors',
    );
    unlike( $out, qr/SECRET-BODY-MARKER/, 'being logged in is not membership' );
};

subtest 'the generated sitemap omits the gated page' => sub {
    # SM293 step 3: the sitemap is generated on request and served by the
    # engine, not written into the document root - so fetch it the way a
    # crawler would, which is also the only way that proves what a crawler
    # would actually receive.
    make_path("$docroot/lazysite/templates/registries");
    spit( "$docroot/lazysite/templates/registries/sitemap.xml.tt", <<'TT' );
<?xml version="1.0" encoding="UTF-8"?>
<urlset>[% FOREACH p IN pages %]<url><loc>[% p.url %]</loc></url>[% END %]</urlset>
TT
    my $xml = get('/sitemap.xml');
    like( $xml, qr{<urlset}, 'a sitemap was served at all' ) or return;

    like( $xml, qr{<loc>/open/free</loc>}, 'the public page is in the sitemap' );
    unlike( $xml, qr{<loc>/private/secret</loc>},
        'the gated page is not - a sitemap that lists a closed section is how '
            . 'it gets crawled' );
};

done_testing();
