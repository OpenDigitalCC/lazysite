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
use TestHelper qw(repo_root env_passthrough site_tempdir);

my $root    = repo_root();
my $docroot = site_tempdir();
make_path( "$docroot/lazysite", "$docroot/assets" );
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

my $asset = "$root/starter/assets/lazysite-odoo.js";
ok( -f $asset, 'the helper is a shipped asset' ) or BAIL_OUT('starter/assets/lazysite-odoo.js is missing');

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
    my $d = site_tempdir();
    make_path("$d/lazysite/layouts/plain");
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: T\nlayout: plain\n";
    close $c;
    open my $lt, '>', "$d/lazysite/layouts/plain/layout.tt" or die $!;
    print {$lt} '<!DOCTYPE html><html><head><title>[% page_title %]</title></head><body><main>[% content %]</main></body></html>';
    close $lt;
    page( $d, 'laid-out.md', "---\ntitle: Laid out\n---\n\n<div data-ls-odoo=\"x\"></div>\n" );
    my $html = visit( $d, '/laid-out' );
    like( $html, qr{<main>}, 'the declared layout rendered (this is the layout path)' );
    like( $html, qr{/assets/lazysite-odoo\.js}, 'and the helper is injected on it too' );
};

subtest 'SM382: THE ASSET RESOLVES ON A CONTENT-ROOTED DOMAIN, by an exact list' => sub {
    my $src = do {
        open my $fh, '<', "$root/lazysite-processor/pipeline.pm" or die $!;
        local $/;
        <$fh>;
    };
    my ($sub) = $src =~ /sub _is_engine_asset \{(.*?)\n\}/s;
    ok( $sub, 'the engine-asset list is found' ) or BAIL_OUT('cannot read it');
    like( $sub, qr{/assets/lazysite-odoo\.js}, 'the helper is on it' )
        or diag('Without this it 404s on any domain with its own content root, silently.');
    unlike( $sub, qr{index\s*\(|=~\s*m?\{?\^?/assets/\[}, 'and it is still exact paths, not a prefix' );
};

done_testing();
