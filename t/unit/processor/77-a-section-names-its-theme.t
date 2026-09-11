#!/usr/bin/perl
# SM812: a theme set on a section's index dresses every page beneath it.
#
# The field report: a page can choose its layout but setting a theme across a
# section means setting it on every page - the per-page discipline that already
# goes wrong with auth: and search:, where one missed page is a page dressed in
# the public theme. So a section says it once, on the index page where a section
# already describes itself (SM656 reads admin_bar: there).
#
# The rules pinned here, each against the case that would break it:
#   - the page wins, then the NEAREST section, then the site or domain theme;
#   - the content root's own index is NOT a section, so a home-page theme never
#     restyles the site - and a domain's root is its own, never a section of
#     the primary docroot it lives inside;
#   - a gated section's index is found in the private store (SM286);
#   - a cached page goes stale when a section index above it changes, including
#     the change that removes the key.
#
# Driven through the real request path, reading the theme_assets the layout
# prints: that is what a visitor's browser loads.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir run_processor);

my $d = site_tempdir();
make_path("$d/lazysite/layouts/default");

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

spit( "$d/lazysite/layouts/default/layout.tt",
    '<html><head><meta name="theme-assets" content="[% theme_assets %]"></head><body>[% content %]</body></html>' );
spit( "$d/lazysite/layouts/default/layout.json", encode_json( { default_theme => 'public' } ) );
for my $t (qw(public intranet archive)) {
    spit( "$d/lazysite/layouts/default/themes/$t/theme.json",
        encode_json( { name => $t, version => '1.0', layouts => ['default'] } ) );
}
spit( "$d/lazysite/lazysite.conf",
    "site_name: T\nlayout: default\ntheme: public\n"
        . "alias_hosts: second.test\nalias.second.test.content_root: sites/second\n" );
spit( "$d/404.md", "---\ntitle: NF\n---\nNot found.\n" );

sub page { my ( $rel, $fm ) = @_; spit( "$d/$rel", "---\ntitle: P\n$fm---\nBody of $rel.\n" ); return }

sub theme_of {
    my ( $uri, $host ) = @_;
    local $ENV{HTTP_HOST} = $host if defined $host;
    my $out = run_processor( $d, $uri ) // '';
    my ($t) = $out =~ m{name="theme-assets" content="/lazysite-assets/default/([^"]+)"};
    return $t // "(none: $out)";
}

# The root index names a theme of its own - the home page's treatment.
page( 'index.md',           "theme: archive\n" );
page( 'about.md',           '' );
page( 'docs/index.md',      "theme: intranet\n" );
page( 'docs/guide.md',      '' );
page( 'docs/own.md',        "theme: archive\n" );
page( 'docs/deep/page.md',  '' );
page( 'notes/index.md',     "theme: intranet\n" );
page( 'notes/sub/index.md', "theme: \"not a theme!\"\n" );
page( 'notes/sub/n.md',     '' );

subtest 'the canary: a page with nothing to inherit gets the site theme' => sub {
    is( theme_of('/about'), 'public', 'the rig can tell one theme from another' );
};

subtest 'a section dresses its pages' => sub {
    is( theme_of('/docs/guide'), 'intranet', 'a page in the section' );
    is( theme_of('/docs/deep/page'), 'intranet', 'and a page two levels down, with no index between' );
    is( theme_of('/docs/'), 'intranet', 'and the section index itself, by its own key' );
};

subtest 'the page wins over its section' => sub {
    is( theme_of('/docs/own'), 'archive', 'a page that names a theme keeps it' );
};

subtest 'the nearest section wins' => sub {
    # The page was cached above; an index ADDED between it and the section is
    # a change the freshness check has to see (dated ahead: mtimes are seconds).
    page( 'docs/deep/index.md', "theme: archive\n" );
    my $later = time + 2;
    utime $later, $later, "$d/docs/deep/index.md";
    is( theme_of('/docs/deep/page'), 'archive', 'a nearer index overrides the one above it' );
    unlink "$d/docs/deep/index.md", "$d/docs/deep/page.html";
};

subtest 'an unusable value reads as absent' => sub {
    # Recorded, it would end the walk at a name nothing resolves - the page
    # would lose the section above as well as this one.
    is( theme_of('/notes/sub/n'), 'intranet',
        'a name the page key would refuse is passed over, and the walk carries on upwards' );
};

subtest 'the root index is the home page, not a section' => sub {
    is( theme_of('/'),      'archive', 'the home page wears its own theme' );
    is( theme_of('/about'), 'public',  'and a top-level page does not inherit it' );
};

subtest 'a domain\'s root is its own' => sub {
    page( 'sites/index.md',              "theme: archive\n" );
    page( 'sites/second/index.md',       "theme: intranet\n" );
    page( 'sites/second/about.md',       '' );
    page( 'sites/second/team/index.md',  "theme: archive\n" );
    page( 'sites/second/team/people.md', '' );
    is( theme_of( '/about', 'second.test' ), 'public',
        'the domain\'s own index is its home page, and nothing above its content root is a section' );
    is( theme_of( '/team/people', 'second.test' ), 'archive', 'while a section inside the domain dresses its pages' );
};

subtest 'a gated section\'s index is found in the private store' => sub {
    my $priv = "$d-lazysite-private";
    spit( "$priv/staff/index.md", "---\ntitle: Staff\ntheme: intranet\n---\nStaff.\n" );
    page( 'staff/rota.md', '' );
    is( theme_of('/staff/rota'), 'intranet', 'the section index is read where the store keeps it' );
};

subtest 'a cached page follows its section' => sub {
    is( theme_of('/docs/guide'), 'intranet', 'rendered and cached under the section theme' );
    ok( -f "$d/docs/guide.html", 'the cache file exists, so the next answers come from the freshness check' );

    my $later = time + 5;
    spit( "$d/docs/index.md", "---\ntitle: Docs\ntheme: archive\n---\nDocs.\n" );
    utime $later, $later, "$d/docs/index.md";
    is( theme_of('/docs/guide'), 'archive', 'the section changing its theme stales the page beneath it' );

    $later += 5;
    spit( "$d/docs/index.md", "---\ntitle: Docs\n---\nDocs.\n" );
    utime $later, $later, "$d/docs/index.md";
    is( theme_of('/docs/guide'), 'public', 'and so does removing the key - the edit that leaves nothing to find' );
};

done_testing();
