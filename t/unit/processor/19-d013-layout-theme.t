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
         . "</head><body>"
         . "[% content %]"
         . "</body></html>";
close $lfh;

# A theme installed under the default layout.
my $theme_dir = "$docroot/lazysite/layouts/default/themes/odcc";
make_path($theme_dir);
open my $tjf, '>', "$theme_dir/theme.json" or die $!;
print $tjf encode_json({
    name    => 'odcc',
    version => '1.0',
    layouts => ['default'],
    config  => {
        colours => { primary => '#332b82', text => '#2a2a2a' },
        fonts   => { body => 'Open Sans' },
    },
});
close $tjf;

# A theme that does NOT target the 'default' layout (incompatibility).
my $bad_theme_dir = "$docroot/lazysite/layouts/default/themes/foreign";
make_path($bad_theme_dir);
open my $fj, '>', "$bad_theme_dir/theme.json" or die $!;
print $fj encode_json({
    name    => 'foreign',
    version => '1.0',
    layouts => ['some-other-layout'],
    config  => { colours => { primary => '#ff0000' } },
});
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
    is( $info->{theme_name}, 'odcc', 'theme_name' );
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
            fonts   => { body => 'Open Sans' },
        },
    };
    my $css = main::generate_theme_css($theme);
    like( $css, qr/:root \{/,                     'root declaration' );
    like( $css, qr/--theme-colours-primary: #332b82;/, 'colour var' );
    like( $css, qr/--theme-colours-accent: #ff6b35;/,  'accent var' );
    like( $css, qr/--theme-fonts-body: Open Sans;/,    'font var' );
};

# --- 5. generate_theme_css: empty config yields empty string ---
subtest 'generate_theme_css empty config' => sub {
    is( main::generate_theme_css({}),                '', 'no config' );
    is( main::generate_theme_css({ config => {} }),  '', 'empty config' );
    is( main::generate_theme_css(undef),             '', 'undef' );
};

# --- 6. generate_theme_css: strip dangerous chars from values ---
subtest 'generate_theme_css sanitises values' => sub {
    my $css = main::generate_theme_css({
        config => { colours => { primary => '#000;}{evil' } },
    });
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

# --- 9. No layout configured: embedded fallback renders ---
subtest 'embedded fallback when no layout installed' => sub {
    write_conf("site_name: Test\n");
    clear_cache();
    my $out = run_processor( $docroot, '/' );
    like( $out, qr/Status: 200/,                  'still returns 200' );
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
    print $aj encode_json({
        name => 'odcc', version => '1.0',
        layouts => ['default', 'asset-probe'],
        config => { colours => { primary => '#000' } },
    });
    close $aj;

    write_conf("site_name: Test\nlayout: asset-probe\ntheme: odcc\n");
    clear_cache();
    my $out = run_processor( $docroot, '/' );
    like( $out, qr{/lazysite-assets/asset-probe/odcc/main\.css},
        'nested asset URL follows layout/theme structure' );
};

done_testing();
