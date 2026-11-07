#!/usr/bin/perl
# SM747 D (OA6): the Odoo browser helper, shipped as the data helper is (t/
# integration/64 is this file's model) - and the ways it silently fails to arrive,
# which are invisible from outside because a script that never loads reports
# nothing:
#
#   1. it is injected on every page, or on none. Only a page whose rendered
#      markup carries a region or control it binds gets it - the markup is the
#      trigger, not a binding;
#   2. only one of the two render paths injects it (a site with a layout, and the
#      fallback that returns early);
#   3. it 404s on a domain with its own content root, because static resolution
#      is content-root scoped and an engine asset is served only if it is on the
#      exact list.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough site_tempdir index_extensions);

my $root = repo_root();

# SM1369 X5: the helper is an asset the Odoo extension DECLARES (owns.hooks.assets,
# inject_when data-ls-odoo, alias /assets/lazysite-odoo.js), served and injected
# by the processor from the hook index the manager writes when the extension is
# enabled - so each fixture enables it and builds the index as the manager would.
sub odoo_site {
    my (%o) = @_;
    my $d = site_tempdir( extensions => 1 );
    make_path( "$d/lazysite", "$d/assets" );
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n" . ( $o{conf} // '' ) . "extensions:\n  - extensions/odoo.pl\n";
    close $cf;
    index_extensions($d);
    return $d;
}
my $docroot = odoo_site();

my $asset = "$root/extensions/odoo/assets/lazysite-odoo.js";
ok( -f $asset, 'the helper is a shipped asset' ) or BAIL_OUT('extensions/odoo/assets/lazysite-odoo.js is missing');

sub page {
    my ( $dir, $path, $body ) = @_;
    open my $fh, '>', "$dir/$path" or die $!;
    print {$fh} $body;
    close $fh;
}

sub visit {
    my ( $dir, $uri ) = @_;
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT  => $dir,
        REDIRECT_URL   => $uri,
        REQUEST_URI    => $uri,
        REQUEST_METHOD => 'GET',
        HTTP_HOST      => 'example.test',
    );
    delete $ENV{LAZYSITE_AUTH_TRUSTED};
    return qx($^X \Q$root/lazysite-processor.pl\E 2>/dev/null);
}

subtest 'a page with no Odoo region or control does not get the script' => sub {
    page( $docroot, 'plain.md', "---\ntitle: Plain\n---\n\nJust words.\n" );
    my $html = visit( $docroot, '/plain' );
    unlike( $html, qr{/assets/lazysite-odoo\.js}, 'no helper on a page that has no use for it' );
    like( $html, qr{/assets/lazysite-chrome\.js}, 'chrome still is on it' );
    page( $docroot, 'data.md', "---\ntitle: D\n---\n\n<div data-ls-db=\"t\"><template><i data-ls-field=\"a\"></i></template></div>\n" );
    unlike( visit( $docroot, '/data' ), qr{/assets/lazysite-odoo\.js}, 'a data region is not an Odoo region' );
};

subtest 'a region, or a sign-in control, gets it - once, versioned' => sub {
    page( $docroot, 'region.md', "---\ntitle: R\n---\n\n<div data-ls-odoo=\"shop-list\"><template><li data-ls-field=\"name\"></li></template></div>\n" );
    my $html = visit( $docroot, '/region' );
    like( $html, qr{/assets/lazysite-odoo\.js\?v=}, 'injected, with a version query' );
    page( $docroot, 'two.md', "---\ntitle: T\n---\n\n<div data-ls-odoo=\"a\"></div>\n\n<div data-ls-odoo=\"b\"></div>\n\n<button data-ls-odoo-signin>Sign in</button>\n" );
    my $n = () = visit( $docroot, '/two' ) =~ m{/assets/lazysite-odoo\.js}g;
    is( $n, 1, 'one reference for two regions and a control' );
    page( $docroot, 'btn.md', "---\ntitle: B\n---\n\n<button data-ls-odoo-signout>Out</button>\n" );
    like( visit( $docroot, '/btn' ), qr{/assets/lazysite-odoo\.js}, 'a sign-out control alone is enough' );
};

subtest 'BOTH RENDER PATHS INJECT IT' => sub {
    my $d = odoo_site( conf => "layout: plain\n" );
    make_path("$d/lazysite/layouts/plain");
    open my $lt, '>', "$d/lazysite/layouts/plain/layout.tt" or die $!;
    print {$lt} '<!DOCTYPE html><html><head><title>[% page_title %]</title></head><body><main>[% content %]</main></body></html>';
    close $lt;
    page( $d, 'laid-out.md', "---\ntitle: Laid out\n---\n\n<div data-ls-odoo=\"x\"></div>\n" );
    my $html = visit( $d, '/laid-out' );
    like( $html, qr{<main>}, 'the declared layout rendered (this is the layout path)' );
    like( $html, qr{/assets/lazysite-odoo\.js}, 'and the helper is injected on it too' );
};

subtest 'SM382, SM1369 X5: THE ASSET IS SERVED FROM THE EXTENSION\'S PAYLOAD, on every domain' => sub {
    my $bytes = do { open my $fh, '<', $asset or die $!; local $/; <$fh> };
    for my $path ( '/assets/lazysite-odoo.js', '/assets/odoo-lazysite-odoo.js' ) {
        my $out = visit( $docroot, $path );
        like( $out, qr{^Status: 200 OK}m, "$path answers 200 (the alias, and the declared path)" );
        like( $out, qr{^Content-Type: text/javascript}m, '...as a script' );
        ok( index( $out, substr( $bytes, 0, 200 ) ) >= 0, '...with the helper\'s own bytes, from extensions/odoo/assets' );
    }
    ok( !-e "$docroot/assets/lazysite-odoo.js", 'and no copy of it is in the docroot' );

    # A domain with its own content root: static resolution is content-root
    # scoped, and the engine's and the extensions' assets are not site content.
    my $d = odoo_site( conf => "domains:\n  - host: two.test\n    root: two\n" );
    make_path("$d/two");
    page( $d, 'two/index.md', "---\ntitle: Two\n---\n\nTwo.\n" );
    local $ENV{HTTP_HOST} = 'two.test';
    my $out = do {
        local %ENV = ( env_passthrough(), DOCUMENT_ROOT => $d, REDIRECT_URL => '/assets/lazysite-odoo.js',
            REQUEST_URI => '/assets/lazysite-odoo.js', REQUEST_METHOD => 'GET', HTTP_HOST => 'two.test' );
        delete $ENV{LAZYSITE_AUTH_TRUSTED};
        qx($^X \Q$root/lazysite-processor.pl\E 2>/dev/null);
    };
    like( $out, qr{^Status: 200 OK}m, 'on a content-rooted domain the alias answers too' );

    # Off means off (G-1): with the extension disabled nothing is injected and
    # the path is not found, as any asset of a disabled extension.
    my $off = site_tempdir( extensions => 1 );
    make_path("$off/lazysite");
    page( $off, 'lazysite/lazysite.conf', "site_name: T\n" );
    page( $off, 'region.md', "---\ntitle: R\n---\n\n<div data-ls-odoo=\"shop-list\"></div>\n" );
    unlike( visit( $off, '/region' ), qr{/assets/lazysite-odoo\.js}, 'extension off: no helper on the page' );
    like( visit( $off, '/assets/lazysite-odoo.js' ), qr{^Status: 404}m, 'extension off: the alias is not found' );
};

done_testing();
