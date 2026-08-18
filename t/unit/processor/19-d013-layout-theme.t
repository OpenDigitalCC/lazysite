#!/usr/bin/perl
# D013: unit tests for the layout/theme architecture. Covers
# resolve_theme's strict compatibility check (theme.json's
# layouts[] must contain the active layout), generate_theme_css
# naming convention, asset URL resolution, and the embedded-
# fallback behaviour when no layout is installed.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use JSON::PP qw(encode_json);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor run_processor);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite");
make_path("$docroot/lazysite/layouts/default");

# Minimal layout at the new path.
open my $lfh, '>', "$docroot/lazysite/layouts/default/layout.tt" or die $!;
print $lfh "<!DOCTYPE html><html><head>"
    . "<title>[% page_title %]</title>"
    . "[% theme_css %]"
    . '<meta name="theme-assets" content="[% theme_assets %]">'
    . "</head><body>"
    . "[% content %]"
    . "</body></html>";
close $lfh;

# A default_theme declaration so the theme_assets fallback (SM: no active theme)
# has something to fall back to.
open my $ljf, '>', "$docroot/lazysite/layouts/default/layout.json" or die $!;
print $ljf encode_json( { default_theme => 'odcc' } );
close $ljf;

# A theme installed under the default layout.
my $theme_dir = "$docroot/lazysite/layouts/default/themes/odcc";
make_path($theme_dir);
open my $tjf, '>', "$theme_dir/theme.json" or die $!;
print $tjf encode_json( {
        name    => 'odcc',
        version => '1.0',
        layouts => ['default'],
        config  => {
            colours => { primary => '#332b82', text => '#2a2a2a' },
            fonts   => { body    => 'Open Sans' },
        },
} );
close $tjf;

# A theme that does NOT target the 'default' layout (incompatibility).
my $bad_theme_dir = "$docroot/lazysite/layouts/default/themes/foreign";
make_path($bad_theme_dir);
open my $fj, '>', "$bad_theme_dir/theme.json" or die $!;
print $fj encode_json( {
        name    => 'foreign',
        version => '1.0',
        layouts => ['some-other-layout'],
        config  => { colours => { primary => '#ff0000' } },
} );
close $fj;

# Conf file and minimal pages.
sub write_conf {
    my ($content) = @_;
    open my $fh, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print $fh $content;
    close $fh;
}
write_conf("site_name: Test\nlayout: default\ntheme: odcc\n");

open my $idx, '>', "$docroot/index.md" or die $!;
print $idx "---\ntitle: Home\n---\nHome.\n";
close $idx;
open my $nf, '>', "$docroot/404.md" or die $!;
print $nf "---\ntitle: NF\n---\nNot found.\n";
close $nf;

load_processor($docroot);
main::reset_request_state();

# --- 1. resolve_theme: valid layout compatibility ---
subtest 'resolve_theme accepts compatible theme' => sub {
    my $info = main::resolve_theme( 'default', 'odcc' );
    ok( $info->{is_active}, 'theme is active' );
    is( $info->{theme_name},     'odcc', 'theme_name' );
    is( ref $info->{theme_data}, 'HASH', 'theme_data parsed' );
    is( $info->{theme_data}{config}{colours}{primary}, '#332b82',
        'config value read through' );
};

# --- 2. resolve_theme: layouts[] mismatch = empty result ---
subtest 'resolve_theme refuses incompatible theme' => sub {
    my $info = main::resolve_theme( 'default', 'foreign' );
    ok( !$info->{is_active}, 'not active' );
    is( $info->{theme_name}, undef, 'no theme_name' );
};

# --- 3. resolve_theme: missing theme returns empty ---
subtest 'resolve_theme with missing theme.json' => sub {
    my $info = main::resolve_theme( 'default', 'nonexistent' );
    ok( !$info->{is_active}, 'not active' );
};

# --- 4. generate_theme_css: naming + values ---
subtest 'generate_theme_css naming convention' => sub {
    my $theme = {
        config => {
            colours => { primary => '#332b82', accent => '#ff6b35' },
            fonts   => { body    => 'Open Sans' },
        },
    };
    my $css = main::generate_theme_css($theme);
    like( $css, qr/:root \{/,                          'root declaration' );
    like( $css, qr/--theme-colours-primary: #332b82;/, 'colour var' );
    like( $css, qr/--theme-colours-accent: #ff6b35;/,  'accent var' );
    like( $css, qr/--theme-fonts-body: Open Sans;/,    'font var' );
};

# --- 5. generate_theme_css: empty config yields empty string ---
subtest 'generate_theme_css empty config' => sub {
    is( main::generate_theme_css( {} ),               '', 'no config' );
    is( main::generate_theme_css( { config => {} } ), '', 'empty config' );
    is( main::generate_theme_css(undef),              '', 'undef' );
};

# --- 6. generate_theme_css: strip dangerous chars from values ---
subtest 'generate_theme_css sanitises values' => sub {
    my $css = main::generate_theme_css( {
            config => { colours => { primary => '#000;}{evil' } },
    } );
    unlike( $css, qr/[;{}]evil/, 'dangerous chars stripped from value' );
};

# clear the HTML cache between subtests that re-render /
sub clear_cache {
    unlink "$docroot/index.html" if -f "$docroot/index.html";
}

# --- 7. End-to-end: rendered HTML contains theme_css + asset URL ---
subtest 'render with active theme emits theme_css and asset URL' => sub {
    clear_cache();
    my $out = run_processor( $docroot, '/' );
    like( $out, qr/--theme-colours-primary: #332b82/,
        'theme_css injected into rendered layout' );
    like( $out, qr/<title>Home<\/title>/, 'layout rendered (not fallback)' );
};

# --- 7b. SM352 step 4: the MIRRORED FILE is preferred over the inline block ---
# The last inline <style> a visitor received. The generator stays as the
# fallback for a site whose asset mirror predates the change - SM365's lesson,
# that an upgrade does not refresh what it does not touch - so BOTH branches
# are asserted here, and the presence of the file is the only difference
# between them.
subtest 'theme tokens link the mirrored file when it exists' => sub {
    write_conf("site_name: Test\nlayout: default\ntheme: odcc\n");
    my $mirror = "$docroot/lazysite-assets/default/odcc";
    make_path($mirror);

    # Stale mirror: no theme-tokens.css. The block is still emitted, because a
    # site upgraded but not re-mirrored must not lose its theme.
    unlink "$mirror/theme-tokens.css";
    clear_cache();
    my $stale = run_processor( $docroot, '/' );
    like( $stale, qr/<style>\s*\n?:root \{/,
        'a mirror without the file still receives the inline block' )
        or diag( 'Losing this branch does not fail loudly - it silently '
            . 'unstyles every page of every site installed before the '
            . 'change, which is the shape of defect SM365 was.' );

    # Written mirror: the file is linked and NOTHING is inlined.
    open my $tf, '>', "$mirror/theme-tokens.css" or die $!;
    print {$tf} ":root { --theme-colours-primary: #332b82; }\n";
    close $tf;
    clear_cache();
    my $fresh = run_processor( $docroot, '/' );
    like( $fresh, qr{<link rel="stylesheet" href="/lazysite-assets/default/odcc/theme-tokens\.css},
        'a written mirror is linked instead' );
    unlike( $fresh, qr/<style>\s*\n?:root \{/,
        'and no inline style survives - the point of the whole change' );

    unlink "$mirror/theme-tokens.css";
};

# --- 8. Incompatible theme: no theme_css, still renders layout ---
subtest 'incompatible theme renders layout without theme_css' => sub {
    write_conf("site_name: Test\nlayout: default\ntheme: foreign\n");
    clear_cache();
    my $out = run_processor( $docroot, '/' );
    like( $out, qr/<title>Home<\/title>/,
        'layout still renders' );
    unlike( $out, qr/--theme-colours-primary/,
        'no theme_css when theme is incompatible' );
};

# --- 8b. theme_assets falls back to the layout's default_theme mirror ---
subtest 'theme_assets falls back to default_theme mirror when no theme active' => sub {
    my $L = 'fallback-probe';
    make_path("$docroot/lazysite/layouts/$L/themes/dtheme");
    open my $l, '>', "$docroot/lazysite/layouts/$L/layout.tt" or die $!;
    print $l '<html><head><meta name="ta" content="[% theme_assets %]"></head>'
        . '<body>[% content %]</body></html>';
    close $l;
    open my $lj, '>', "$docroot/lazysite/layouts/$L/layout.json" or die $!;
    print $lj encode_json( { default_theme => 'dtheme' } ); close $lj;
    open my $tj, '>', "$docroot/lazysite/layouts/$L/themes/dtheme/theme.json" or die $!;
    print $tj encode_json( { name => 'dtheme', version => '1.0', layouts => [$L], config => {} } );
    close $tj;

    # No active theme AND no mirror yet -> no fallback (theme_assets empty).
    write_conf("site_name: Test\nlayout: $L\n");
    clear_cache();
    my $out1 = run_processor( $docroot, '/' );
    unlike( $out1, qr{content="/lazysite-assets/\Q$L\E/dtheme"},
        'no fallback when the default_theme mirror is not installed' );

    # Install the mirror -> theme_assets falls back to it.
    make_path("$docroot/lazysite-assets/$L/dtheme");
    clear_cache();
    my $out2 = run_processor( $docroot, '/' );
    like( $out2, qr{content="/lazysite-assets/\Q$L\E/dtheme"},
        'theme_assets falls back to the installed default_theme mirror' );
};

# --- 9. No layout configured: embedded fallback renders ---
subtest 'embedded fallback when no layout installed' => sub {
    write_conf("site_name: Test\n");
    clear_cache();
    my $out = run_processor( $docroot, '/' );
    like( $out, qr/Status: 200/, 'still returns 200' );
    like( $out, qr/no layout\.tt found/,
        'fallback footer references layout.tt' );
};

# --- 10. Asset URL uses nested LAYOUT/THEME structure ---
subtest 'theme_assets URL is nested layout/theme' => sub {
    # Write a fresh layout (separate name) that explicitly references
    # [% theme_assets %] so we can observe the URL shape without
    # contending with the TT compile cache for the earlier layouts.
    make_path("$docroot/lazysite/layouts/asset-probe");
    open my $lfh2, '>',
        "$docroot/lazysite/layouts/asset-probe/layout.tt" or die $!;
    print $lfh2 "<link href=\"[% theme_assets %]/main.css\">"
        . "[% content %]";
    close $lfh2;
    # Install the theme under the new layout too (DP-A multi-layout).
    my $td = "$docroot/lazysite/layouts/asset-probe/themes/odcc";
    make_path($td);
    open my $aj, '>', "$td/theme.json" or die $!;
    print $aj encode_json( {
            name    => 'odcc', version => '1.0',
            layouts => [ 'default', 'asset-probe' ],
            config  => { colours => { primary => '#000' } },
    } );
    close $aj;

    write_conf("site_name: Test\nlayout: asset-probe\ntheme: odcc\n");
    clear_cache();
    my $out = run_processor( $docroot, '/' );
    like( $out, qr{/lazysite-assets/asset-probe/odcc/main\.css},
        'nested asset URL follows layout/theme structure' );
};

# --- 11. SM249: the theme variables reach the PAGE BODY, not only the layout ---
# An author writing [% theme_assets %]/hero.jpg in a page used to get an empty
# string and no error, because the layout and theme were resolved in the step
# BETWEEN the body render and the layout render - the variable existed for the
# layout and never for the body. A wrong-looking image path and a missing
# variable are indistinguishable in the output, which is what made it expensive.
subtest 'theme vars resolve in a page body (SM249)' => sub {
    make_path("$docroot/lazysite/layouts/body-probe");
    open my $bl, '>', "$docroot/lazysite/layouts/body-probe/layout.tt" or die $!;
    print $bl "<body>[% content %]</body>";
    close $bl;
    my $bt = "$docroot/lazysite/layouts/body-probe/themes/odcc";
    make_path($bt);
    open my $bj, '>', "$bt/theme.json" or die $!;
    print $bj encode_json(
        { name => 'odcc',
            version => '1.0',
            layouts => [ 'default', 'asset-probe', 'body-probe' ],
            config  => { colours => { primary => '#abcdef' } },
        }
    );
    close $bj;

    # The page BODY references the variables - the layout references none of
    # them, so anything that appears in the output got there through the body.
    open my $pg, '>', "$docroot/index.md" or die $!;
    print $pg "---\ntitle: Home\n---\n"
        . "<img src=\"[% theme_assets %]/hero.jpg\">\n"
        . "<span id=\"ln\">[% layout_name %]</span>\n"
        . "<span id=\"tn\">[% theme_name %]</span>\n";
    close $pg;

    write_conf("site_name: Test\nlayout: body-probe\ntheme: odcc\n");
    clear_cache();
    my $out = run_processor( $docroot, '/' );

    like( $out, qr{<img src="/lazysite-assets/body-probe/odcc/hero\.jpg">},
        'theme_assets resolves in the page body' );
    like( $out, qr{<span id="ln">body-probe</span>},
        'layout_name resolves in the page body' );
    like( $out, qr{<span id="tn">odcc</span>},
        'theme_name resolves in the page body' );
    unlike( $out, qr/\[%\s*theme_assets/,
        'the token is consumed, not emitted literally' );

    # Restore the shared page for any later subtest.
    open my $rp, '>', "$docroot/index.md" or die $!;
    print $rp "---\ntitle: Home\n---\nHome.\n";
    close $rp;
    clear_cache();
};

done_testing();
