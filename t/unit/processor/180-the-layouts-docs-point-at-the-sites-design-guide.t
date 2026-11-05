#!/usr/bin/perl
# SM1340 (ruling 79): THE ENGINE'S LAYOUTS DOCS POINT AT THIS SITE'S DESIGN GUIDE
# WHEN THE SITE NAMES ONE.
#
# A site can publish a guide for whoever designs for it (lazysite.io's is a page
# with a downloadable design kit). The two pages a designer or an agent starts
# from - /docs/layouts and /docs/ai-briefing-layouts - are the engine's, the
# same on every site, so they cannot name one site's page. `design_guide: /path`
# in lazysite.conf does: both pages then carry a "This site's design guide" line
# linking it, and with no setting they carry nothing.
#
# The value goes into an href on a page every agent reads, so it is held to the
# rule sanitise_next applies to ?next=: a path on this site. Anything else - an
# absolute URL, //host, a backslash, a space, markup - is no guide at all. The
# processor holds its own copy of the rule (ADR 0001), and it answers as
# Lazysite::Util::sanitise_next does for every value here.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_minimal_site site_tempdir run_processor repo_root load_processor);
use Lazysite::Util ();

my $DOCS = repo_root() . '/starter/lazysite/templates/docs';
my @PAGES = qw(layouts ai-briefing-layouts);

sub site {
    my ($conf) = @_;
    my $d = site_tempdir();
    setup_minimal_site($d);
    make_path("$d/lazysite/templates/docs");
    copy( "$DOCS/$_.md", "$d/lazysite/templates/docs/$_.md" ) or die "$_: $!" for @PAGES;
    if ( defined $conf ) {
        open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
        print {$cf} $conf;
        close $cf;
    }
    return $d;
}

my $LINE = qr/This site's design guide/;

subtest 'set: both pages link the guide' => sub {
    my $d = site("design_guide: /guides/design-a-theme\n");
    for my $p (@PAGES) {
        my $html = run_processor( $d, "/docs/$p" );
        like( $html, qr{\QThis site's design guide:</strong> <a href="/guides/design-a-theme">/guides/design-a-theme</a>\E},
            "/docs/$p carries the line, linking the path" );
        unlike( $html, qr/design_guide/, "/docs/$p leaks no template tag" );
    }
};

subtest 'unset: neither page says anything about one' => sub {
    my $d = site();
    for my $p (@PAGES) {
        my $html = run_processor( $d, "/docs/$p" );
        like( $html, qr/<h2/, "/docs/$p renders" );
        unlike( $html, $LINE, "/docs/$p has no design-guide line" );
        unlike( $html, qr/design_guide/, "/docs/$p leaks no template tag" );
    }
};

subtest 'invalid: an off-site or malformed value is no guide' => sub {
    for my $bad ( 'https://elsewhere.example/guide', '//elsewhere.example/guide', '/a//b',
        '\\\\elsewhere\\guide', 'guides/no-leading-slash', '/guide"><script>x</script>',
        '/a b', 'javascript:alert(1)' )
    {
        my $d = site("design_guide: $bad\n");
        for my $p (@PAGES) {
            my $html = run_processor( $d, "/docs/$p" );
            unlike( $html, $LINE, "/docs/$p: '$bad' gives no line" );
            unlike( $html, qr/elsewhere|<script>x|alert\(1\)/, "/docs/$p: and none of the value reaches the page" );
        }
    }
};

subtest 'a host with a content root of its own links none' => sub {
    my $d = site( "design_guide: /guides/design\nalias_hosts: other.example\n"
            . "alias.other.example.content_root: other\n" );
    make_path("$d/other");
    local $ENV{HTTP_HOST} = 'other.example';
    unlike( run_processor( $d, '/docs/layouts' ), $LINE, 'the other site\'s /docs/layouts has no line' );
};

subtest 'the processor\'s copy of the rule is sanitise_next\'s' => sub {
    my $d = site();
    load_processor($d);
    for my $v ( '/', '/guides/design', '/a/b.c-d_e', '//x', '/a//b', '\\x', 'x', '/a b', '/a?b', '/a#b',
        'https://x.example/', '/é' )
    {
        my $util = Lazysite::Util::sanitise_next($v);
        my $want = $util eq $v ? $v : '';    # sanitise_next answers '/' for a refusal
        is( main::_design_guide_path($v), $want, "'$v'" );
    }
    is( main::_design_guide_path(undef), '', 'unset is none' );
    is( main::_design_guide_path('  /guides/design  '), '/guides/design', 'surrounding space is trimmed' );
};

done_testing();
