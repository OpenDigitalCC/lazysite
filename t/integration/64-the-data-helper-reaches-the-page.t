#!/usr/bin/perl
# DP-3b: the helper script that makes `mode=live` and `mode=client` mean
# something, and the two ways it silently fails to arrive.
#
# WHAT THE HELPER IS FOR. A `db:` binding renders rows at request time or at
# render time; neither refreshes a list a visitor is already looking at, and
# neither can populate a region the server deliberately left empty. The helper
# fetches from the data endpoint and fills a region declared in the markup.
#
# TWO FAILURES THIS FILE EXISTS TO CATCH, both of which are invisible from the
# outside because a script that never loads reports nothing:
#
#   1. It is injected on every page, or on no page. Chrome belongs everywhere;
#      this does not - shipping it to every visitor so a handful of pages can
#      refresh a list is a cost everyone pays for a few. The trigger is the
#      RENDERED MARKUP, because a binding declares a mode and the markup
#      declares a region, and the two can disagree in both directions.
#
#   2. It 404s on a domain with its own content root. Static resolution is
#      content-root scoped; the engine's own assets are not site content and
#      resolve from the docroot, but ONLY via an exact list. SM382 measured
#      exactly this for the chrome bundle - 200 on the primary, 404 on the
#      secondary - and a new asset inherits none of that reasoning.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path( "$docroot/lazysite", "$docroot/assets" );

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

# The shipped asset, as install puts it into a site.
my $asset = "$root/starter/assets/lazysite-data.js";
ok( -f $asset, 'the helper is a shipped asset' )
    or BAIL_OUT('starter/assets/lazysite-data.js is missing');
open my $src, '<', $asset or die $!;
my $js = do { local $/; <$src> };
close $src;
open my $dst, '>', "$docroot/assets/lazysite-data.js" or die $!;
print {$dst} $js;
close $dst;

sub page {
    my ( $path, $body ) = @_;
    open my $fh, '>', "$docroot/$path" or die $!;
    print {$fh} $body;
    close $fh;
}

sub visit {
    my ($uri) = @_;
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REDIRECT_URL   => $uri,
        REQUEST_URI    => $uri,
        REQUEST_METHOD => 'GET',
        HTTP_HOST      => 'example.test',
    );
    delete $ENV{LAZYSITE_AUTH_TRUSTED};
    return qx($^X \Q$root/lazysite-processor.pl\E 2>/dev/null);
}

subtest 'a page with no data region does not get the script' => sub {
    page( 'plain.md', "---\ntitle: Plain\n---\n\nJust words.\n" );
    my $html = visit('/plain');
    unlike( $html, qr{/assets/lazysite-data\.js},
        'no helper on a page that has no use for it' )
        or diag( 'Every visitor to every page would pay for this so that a '
            . 'handful of pages could refresh a list.' );

    # The chrome bundle IS on every page, and stays there - this is a check
    # that the two decisions have not been confused for each other.
    like( $html, qr{/assets/lazysite-chrome\.js}, 'but chrome still is' );
};

subtest 'a page that declares a region gets it' => sub {
    page( 'live.md', <<'MD' );
---
title: Live
---

<div data-ls-db="products" data-ls-db-limit="5">
  <template><li data-ls-field="name"></li></template>
</div>
MD
    my $html = visit('/live');
    like( $html, qr{/assets/lazysite-data\.js}, 'the helper is injected' )
        or diag( 'A region with no helper is a region that never fills. '
            . 'Nothing on the page reports it.' );
    like( $html, qr{lazysite-data\.js\?v=}, 'with a version query, so a '
            . 'released change is not served from a stale cache' );
};

subtest 'it is injected once, not once per region' => sub {
    page( 'two.md', <<'MD' );
---
title: Two
---

<div data-ls-db="products"><template><li data-ls-field="a"></li></template></div>
<div data-ls-db="events"><template><li data-ls-field="b"></li></template></div>
MD
    my $html = visit('/two');
    my $n = () = $html =~ m{/assets/lazysite-data\.js}g;
    is( $n, 1, 'one reference for two regions' )
        or diag( 'The bundle is self-contained and finds every region itself.' );
};

subtest 'BOTH RENDER PATHS INJECT IT' => sub {
    # THE ONE THAT CAUGHT ME. There are two: a site with a layout, and a site
    # without one, which falls back to a built-in template and RETURNS EARLY.
    # The first version wired the injector into the layout path only, and this
    # whole file passed - because the fixture above has no layout and never
    # went near it. The processor's own comment at the fallback return makes
    # the same point about generator meta and canonical links, which is how the
    # gap was found rather than shipped.
    #
    # ITS OWN DOCROOT, so the subtests above keep exercising the fallback. A
    # layout is chosen in lazysite.conf, so switching it here would move every
    # other case onto the path this one is for.
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/layouts/plain");
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: T\nlayout: plain\n";
    close $c;
    open my $lt, '>', "$d/lazysite/layouts/plain/layout.tt" or die $!;
    print {$lt} '<!DOCTYPE html><html><head><title>[% page_title %]</title>'
        . '</head><body><main>[% content %]</main></body></html>';
    close $lt;
    open my $pg, '>', "$d/laid-out.md" or die $!;
    print {$pg} "---\ntitle: Laid out\n---\n\n"
        . '<div data-ls-db="products">'
        . '<template><li data-ls-field="n"></li></template></div>' . "\n";
    close $pg;

    my $html = do {
        local %ENV = (
            env_passthrough(),
            DOCUMENT_ROOT  => $d,
            REDIRECT_URL   => '/laid-out',
            REQUEST_URI    => '/laid-out',
            REQUEST_METHOD => 'GET',
            HTTP_HOST      => 'example.test',
        );
        delete $ENV{LAZYSITE_AUTH_TRUSTED};
        qx($^X \Q$root/lazysite-processor.pl\E 2>/dev/null);
    };

    like( $html, qr{<main>}, 'the declared layout rendered' )
        or diag( 'If the layout did not apply, this subtest is exercising the '
            . 'fallback path again and proves nothing new - which is exactly '
            . 'what it did the first time it was written.' );
    like( $html, qr{/assets/lazysite-data\.js},
        'and the helper is injected on the layout path too' );
};


subtest 'SM382: THE ASSET RESOLVES ON A CONTENT-ROOTED DOMAIN' => sub {
    # Static resolution is content-root scoped and refuses anything outside it,
    # so an engine asset on a secondary domain 404s unless it is on the exact
    # list. The chrome bundle was measured failing exactly this way.
    my $src = do {
        open my $fh, '<', "$root/lazysite-processor.pl" or die $!;
        local $/;
        <$fh>;
    };
    my ($sub) = $src =~ /sub _is_engine_asset \{(.*?)\n\}/s;
    ok( $sub, 'the engine-asset list is found' ) or BAIL_OUT('cannot read it');
    like( $sub, qr{/assets/lazysite-data\.js},
        'the helper is on the engine-asset list' )
        or diag( 'Without this it 404s on any domain with its own content '
            . 'root, and a live table simply never refreshes - silently, '
            . 'because a script that does not load reports nothing.' );

    # AND THE LIST IS STILL A LIST. A prefix would be the easy fix and the
    # wrong one: it would hand the exemption to every future file under
    # /assets/, including ones nobody weighed.
    unlike( $sub, qr{index\s*\(|=~\s*m?\{?\^?/assets/\[},
        'and it is still exact paths, not a prefix' );
};

subtest 'THE HELPER NEVER PUTS A VALUE INTO MARKUP' => sub {
    # The single most important property in the file. Rows can come from a form
    # submission (DP-4), so a helper that interpolated them into HTML would
    # turn a public contact form into script execution on every visitor's page.
    unlike( $js, qr/\binnerHTML\b/, 'no innerHTML' )
        or diag( 'A row containing a script tag must render as those '
            . 'characters and do nothing.' );
    unlike( $js, qr/\bouterHTML\b/,           'no outerHTML' );
    unlike( $js, qr/\bdocument\.write\b/,     'no document.write' );
    unlike( $js, qr/\binsertAdjacentHTML\b/,  'no insertAdjacentHTML' );
    unlike( $js, qr/\beval\s*\(/,             'no eval' );
    like( $js, qr/\btextContent\b/, 'values go in as text' );
};

subtest 'the helper fetches from the endpoint and nowhere else' => sub {
    # No CDN, no third-party origin - the standing rule for every shipped
    # asset. A helper that reached out would take a lazysite site off its own
    # origin without anybody deciding to.
    unlike( $js, qr{https?://}, 'no absolute URL anywhere in it' )
        or diag( 'Everything a lazysite serves comes from its own origin.' );
    like( $js, qr{/cgi-bin/lazysite-data\.pl}, 'it calls the data endpoint' );
};

done_testing();
