#!/usr/bin/perl
# SM1190 (edge test plan 0.15.10, F-4): `/zz60-form?form=zz60-f&outcome=...`
# rendered og:url and <link rel="canonical"> as `...?form=zz60-f&amp;amp;outcome=...`.
#
# Two faults in one: `request_uri` carried the QUERY (it is REDIRECT_URL or the
# raw REQUEST_URI), and it is already HTML-escaped in the stash, so a layout's
# own `| html` escaped the ampersand a second time. The canonical address is the
# PAGE - scheme, host and path - so a query must never be in it, and the
# address is escaped once. Asserted for a layout that writes its own tags from
# `request_uri` (what the catalogue layouts do), for the engine-injected
# canonical, and for the new `page_url`; and for a cached hit opened with a
# different query, which must not carry the first visitor's.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_processor setup_test_site site_tempdir);

my $d = site_tempdir();
setup_test_site($d);
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

spit( "$d/lazysite/lazysite.conf", "site_name: Test\nsite_url: https://site.test\nlayout: test\n" );
spit( "$d/lazysite/layouts/test/layout.tt",
      '<!DOCTYPE html><html><head><title>[% page_title %]</title>'
    . '<link rel="canonical" href="[% site_url | html %][% request_uri | html %]">'
    . '<meta property="og:url" content="[% site_url | html %][% request_uri | html %]">'
    . '<meta name="x-page-url" content="[% page_url %]">'
    . '</head><body>[% content %]<nav>[% request_uri %]</nav></body></html>' );
spit( "$d/about.md", "---\ntitle: About\n---\nAbout.\n" );
spit( "$d/bare.md",  "---\ntitle: Bare\n---\nBare.\n" );

# A front end that sets REDIRECT_URL to the path, and one that sets only the raw
# REQUEST_URI (the edge's case): both must come out the same.
sub get_redirect { my ( $path, $qs ) = @_; return scalar run_processor( $d, $path, QUERY_STRING => $qs // '' ) }
sub get_raw {
    my ( $path, $qs ) = @_;
    return scalar run_processor( $d, undef, REDIRECT_URL => undef,
        REQUEST_URI => $path . ( length( $qs // '' ) ? "?$qs" : '' ), QUERY_STRING => $qs // '' );
}
sub tags {
    my ($o) = @_;
    return (
        ( $o =~ /<link rel="canonical" href="([^"]*)"/ )[0] // '(none)',
        ( $o =~ /<meta property="og:url" content="([^"]*)"/ )[0] // '(none)',
        ( $o =~ /<meta name="x-page-url" content="([^"]*)"/ )[0] // '(none)',
    );
}

for my $mode ( [ redirect => \&get_redirect ], [ raw => \&get_raw ] ) {
    my ( $name, $get ) = @$mode;
    subtest "a page opened with a query names the page ($name)" => sub {
        my $o = $get->( '/about', 'a=1&b=2' );
        my ( $canon, $og, $pu ) = tags($o);
        is( $canon, 'https://site.test/about', 'canonical is the page, no query' );
        is( $og,    'https://site.test/about', 'og:url is the page, no query' );
        is( $pu,    'https://site.test/about', 'page_url is the page, no query' );
        unlike( $o, qr/amp;amp;/, 'nothing is escaped twice' );
        unlike( $o, qr/a=1|b=2/,  'the query is nowhere in the head or nav' );
        like( $o, qr{<nav>/about</nav>}, 'request_uri is the path' );
    };
    subtest "a page without a query is unchanged ($name)" => sub {
        my ( $canon, $og, $pu ) = tags( $get->( '/bare', '' ) );
        is_deeply( [ $canon, $og, $pu ], [ ('https://site.test/bare') x 3 ], 'all three name the page' );
    };
}

subtest 'a cached hit opened with another query carries no query' => sub {
    get_redirect( '/about', 'first=visitor&secret=1' );    # the render that fills the cache
    ok( -f "$d/about.html", 'fixture: the first request left a cached page' );
    my $o = get_redirect( '/about', 'second=1' );
    my ( $canon, $og ) = tags($o);
    is( $canon, 'https://site.test/about', 'canonical still the bare page' );
    is( $og,    'https://site.test/about', 'og:url still the bare page' );
    unlike( $o, qr/first=visitor|secret|second/, 'no visitor\'s query anywhere in the served page' );
    open my $fh, '<', "$d/about.html" or die $!;
    local $/;
    unlike( <$fh>, qr/first=visitor|secret/, 'and none baked into the cached file' );
};

subtest 'a front end that gives only REQUEST_URI cannot leak a query into the cache' => sub {
    unlink "$d/bare.html";
    get_raw( '/bare', 'first=visitor&secret=1' );
    my $o = get_raw( '/bare', 'second=1' );
    unlike( $o, qr/first=visitor|secret|second/, 'the served page carries no visitor\'s query' );
    open my $fh, '<', "$d/bare.html" or die "no cached page: $!";
    local $/;
    unlike( <$fh>, qr/first=visitor|secret|second/, 'and none is baked into the cached file' );
};

done_testing;
