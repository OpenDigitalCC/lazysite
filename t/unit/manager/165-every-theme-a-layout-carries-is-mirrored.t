#!/usr/bin/perl
# SM820: a per-page `theme:` naming a theme that was never ACTIVATED linked
# stylesheets that did not exist, and the page rendered completely unstyled.
#
# `theme_assets` resolves to /lazysite-assets/<layout>/<theme>/, and that mirror
# was written only for the theme being activated. A theme present in the tree,
# declaring the layout, and simply never activated had no mirror - so
# `resolve_theme` reported it usable and the page linked 404s. Measured on edge:
# background rgba(0,0,0,0), font Times New Roman.
#
# The asymmetry is what made it a defect: a MISSPELT name already fell back
# safely, while a correct-but-unmirrored one failed silently to no styling. The
# safer outcome went to the more obviously wrong input.
#
# The fix mirrors EVERY theme a layout carries. Not on reference - that puts a
# file write on a render path an anonymous visitor can trigger - and not by
# serving the theme SOURCE, which would make lazysite/layouts/ web-reachable and
# needs a carve-out in the SM795 exclusion. This is the same idempotent per-theme
# function, called for more themes, at the moments it is already called.
#
# Tested at the mirroring function rather than through a render, deliberately: a
# render-based test written for this same filing earlier passed whether the fix
# was present or absent.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

require Lazysite::Manager::Themes;

my $docroot = site_tempdir();
my $lazy    = "$docroot/lazysite";

# Three themes on one layout. Each carries an assets/ dir with a stylesheet,
# which is what _mirror_theme_assets copies.
my @themes = qw(active spare backup-20260818T211110Z);
for my $t (@themes) {
    make_path("$lazy/layouts/base/themes/$t/assets");
    open my $css, '>', "$lazy/layouts/base/themes/$t/assets/main.css" or die $!;
    print $css "/* $t */\n";
    close $css;
}
# A file that is not a theme directory, to be sure the sweep enumerates dirs.
open my $stray, '>', "$lazy/layouts/base/themes/README.txt" or die $!;
print $stray "not a theme\n";
close $stray;

{
    no warnings 'once';
    $Lazysite::Manager::Themes::LAZYSITE_DIR = $lazy;
    $Lazysite::Manager::Themes::DOCROOT      = $docroot;
}

my $res = Lazysite::Manager::Themes::_mirror_layout_themes('base');

is( $res->{themes}, 3, 'the sweep found three themes and ignored the stray file' );
is( $res->{mirrored}, 3, 'and mirrored all three' );

for my $t (@themes) {
    ok( -f "$docroot/lazysite-assets/base/$t/main.css",
        "$t has a mirror, whether or not it is the activated theme" );
}

# --- the case the field hit ---------------------------------------------------
# Before this, only the activated theme was mirrored, so this assertion is the
# whole filing: a theme nobody has activated still resolves to something served.
ok( -d "$docroot/lazysite-assets/base/backup-20260818T211110Z",
    'a backup theme that has never been activated has a mirror' );

# --- and it is idempotent, because it runs on every activation ----------------
my $again = Lazysite::Manager::Themes::_mirror_layout_themes('base');
is( $again->{mirrored}, 3, 'running it a second time mirrors the same three' );

# --- a layout with no themes directory is not an error ------------------------
make_path("$lazy/layouts/bare");
my $bare = Lazysite::Manager::Themes::_mirror_layout_themes('bare');
is( $bare->{themes}, 0, 'a layout with no themes/ dir reports zero' );
is( $bare->{mirrored}, 0, 'and mirrors nothing' );
like( $bare->{reason} // '', qr/no themes directory/,
    'and says why, rather than looking like a layout whose themes all failed' );

# --- an unnamed layout is refused rather than guessed at ----------------------
my $none = Lazysite::Manager::Themes::_mirror_layout_themes('');
is( $none->{themes}, 0, 'an empty layout name mirrors nothing' );

done_testing();
