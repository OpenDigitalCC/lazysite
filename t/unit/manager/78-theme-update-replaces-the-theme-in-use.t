#!/usr/bin/perl
# A layout UPDATE reports themes_installed and leaves the site on the old theme.
#
# FROM THE FIELD, 2026-08-17. The layouts agent and the site agent both measured
# it on edge after upgrading lumen to catalogue 1.1.0: the template was the new
# one, and `/lazysite-assets/lumen/lumen/main.css` was byte-identical to a copy
# taken that morning, with 0 `.nav-toggle` rules where the repo CSS has 2. Below
# 900px the stale CSS hid the nav with no rule to reveal the toggle, and the
# declared favicon 404'd. Every surface reported success.
#
# THE MECHANISM, which is an asymmetry rather than a missing call.
# _install_layout_from_dir takes an update flag and writes to layouts/<name>,
# so a layout updates in place. _install_theme_from_dir has no update flag at
# all, and on finding the destination already there it installs under a
# DATE-PREFIXED name instead:
#
#     20260817-lumen        <- the new theme, which nothing points at
#     lumen                 <- what the site still serves
#
# So the theme is installed, `themes_installed` names it truthfully, the mirror
# runs - for the copy nobody uses. The report is true of the engine and false
# about the world, which is this register's most-repeated finding.
#
# THE RENAME IS RIGHT WHEN IT IS NOT AN UPDATE. A theme arriving with the same
# name as one the operator has edited must not clobber it. That case is kept and
# asserted below; what changes is that an explicit update stops being treated as
# a collision.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                qw(repo_root);
use Lazysite::Manager::Themes ();

my $docroot = tempdir( CLEANUP => 1 );
$Lazysite::Manager::Themes::DOCROOT      = $docroot;
$Lazysite::Manager::Themes::LAZYSITE_DIR = "$docroot/lazysite";

# A layout for the theme to declare, since the installer rejects a theme whose
# declared layouts are not installed.
make_path("$docroot/lazysite/layouts/base");
open my $lt, '>', "$docroot/lazysite/layouts/base/layout.tt" or die $!;
print {$lt} "[% content %]\n";
close $lt;

# A theme package on disk, with the marker in its stylesheet so a stale mirror
# is visible rather than inferred.
sub theme_dir {
    my ($marker) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/assets");
    open my $j, '>', "$d/theme.json" or die $!;
    print {$j} '{"name":"lumen","version":"1.0.0","layouts":["base"],"config":{}}';
    close $j;
    open my $c, '>', "$d/assets/main.css" or die $!;
    print {$c} "/* $marker */\nbody { color: #111 }\n";
    close $c;
    return $d;
}

sub mirrored_css {
    my $p = "$docroot/lazysite-assets/base/lumen/main.css";
    return '(absent)' unless -f $p;
    open my $fh, '<', $p or return '(unreadable)';
    local $/;
    return <$fh>;
}

sub installed_theme_dirs {
    opendir my $dh, "$docroot/lazysite/layouts/base/themes" or return ();
    my @d = sort grep { !/^\./ } readdir $dh;
    closedir $dh;
    return @d;
}

# --- 1. first install ---------------------------------------------------------
subtest 'a first install lands under its own name' => sub {
    my $r = Lazysite::Manager::Themes::_install_theme_from_dir(
        theme_dir('ORIGINAL'), 'test', 'operator' );
    ok( $r->{ok}, 'installed' ) or diag $r->{error};
    is_deeply( [ installed_theme_dirs() ], ['lumen'], 'as lumen' );
    Lazysite::Manager::Themes::_mirror_theme_assets( 'base', 'lumen' );
    like( mirrored_css(), qr/ORIGINAL/, 'and the mirror carries it' );
};

# --- 2. THE DEFECT ------------------------------------------------------------
subtest 'an UPDATE replaces the theme the site is using' => sub {
    my $r = Lazysite::Manager::Themes::_install_theme_from_dir(
        theme_dir('UPGRADED'), 'layout-install', 'operator', 1 );
    ok( $r->{ok}, 'the update reports success' ) or diag $r->{error};

    is_deeply( [ installed_theme_dirs() ], ['lumen'],
        'and there is still ONE lumen, not a dated sibling beside it' )
        or diag( 'A date-prefixed copy is the defect: the new theme installs '
            . 'where nothing points at it, themes_installed names it '
            . 'truthfully, and the site keeps serving the old one.' );

    Lazysite::Manager::Themes::_mirror_theme_assets( 'base', 'lumen' );
    like( mirrored_css(), qr/UPGRADED/,
        'the mirrored stylesheet is the new one' )
        or diag( 'This is the field measurement: the template updated and '
            . 'main.css was byte-identical to the pre-upgrade copy.' );
    unlike( mirrored_css(), qr/ORIGINAL/, 'and not the old one' );
};

# --- 3. what must NOT change --------------------------------------------------
subtest 'a same-named theme that is NOT an update still steps aside' => sub {
    # The rename exists so a theme arriving with a name an operator already
    # uses cannot clobber their work. Only an EXPLICIT update is exempt.
    my $r = Lazysite::Manager::Themes::_install_theme_from_dir(
        theme_dir('THIRD-PARTY'), 'theme-upload', 'operator' );
    ok( $r->{ok}, 'installed' ) or diag $r->{error};

    my @dirs = installed_theme_dirs();
    is( scalar @dirs, 2, 'it landed beside the existing theme, not on it' );
    ok( ( grep { /^\d{8}-lumen$/ } @dirs ),
        'under a dated name' ) or diag "dirs: @dirs";

    Lazysite::Manager::Themes::_mirror_theme_assets( 'base', 'lumen' );
    like( mirrored_css(), qr/UPGRADED/,
        "and the theme in use is untouched by it" );
};

done_testing();
