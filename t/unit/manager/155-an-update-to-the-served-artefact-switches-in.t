#!/usr/bin/perl
# SM756: an update to the theme or layout being served installs beside it and
# switches in. Nothing writes into an active artefact, on any surface.
#
# The release manager's ruling, after SM749 closed the file writes: "nothing
# works on an active theme or layout, they load new and switch in. it should be
# atomic, and common on all surfaces." Before this, a theme upload with update
# and a layout install with force `cp -r`'d over the directory being rendered -
# a sequence of file replacements, so a request between two of them rendered
# half of each - and the asset mirror the browsers fetch from was written the
# same way by activation itself.
#
# What a unit test can hold about atomicity: the served directory's identity
# (its inode) changes EXACTLY ONCE across an update, its contents are the new
# version in full, at no point did the old directory contain new files, and
# the old directory survives under the snapshot name when it was edited and is
# gone when it was pristine. Both install paths route every surface (upload,
# layout-install, layouts-install, install_layout) through the two functions
# tested here.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                 qw(repo_root);
use Lazysite::Manager::Themes  ();
use Lazysite::Manager::Layouts ();

my $t = tempdir( CLEANUP => 1 );
mkdir "$t/site";
my $docroot = "$t/site/public_html";
make_path("$docroot/lazysite/layouts/base/themes");
$Lazysite::Manager::Themes::DOCROOT       = $docroot;
$Lazysite::Manager::Themes::LAZYSITE_DIR  = "$docroot/lazysite";
$Lazysite::Manager::Layouts::DOCROOT      = $docroot;
$Lazysite::Manager::Layouts::LAZYSITE_DIR = "$docroot/lazysite";

sub put { my ( $p, $c ) = @_; make_path( ( $p =~ m{(.*)/} )[0] ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh }
sub slurp { open my $fh, '<', $_[0] or return undef; local $/; my $s = <$fh>; close $fh; return $s }
sub ino { return ( stat $_[0] )[1] }
sub dirs { my ($d) = @_; opendir my $dh, $d or return (); my @e = sort grep { !/^\./ } readdir $dh; closedir $dh; return @e }

put( "$docroot/lazysite/lazysite.conf", "site_name: t\nlayout: base\ntheme: lumen\n" );
put( "$docroot/lazysite/layouts/base/layout.tt", "V1 [% content %]\n" );

sub theme_release {
    my ($marker) = @_;
    my $d = tempdir( CLEANUP => 1 );
    put( "$d/theme.json", '{"name":"lumen","version":"1.0.0","layouts":["base"],"config":{"colours":{"primary":"#000"}}}' );
    put( "$d/assets/main.css", "/* $marker */\nbody{}\n" );
    return $d;
}

my $THEME = "$docroot/lazysite/layouts/base/themes/lumen";
my $MIRR  = "$docroot/lazysite-assets/base/lumen";

subtest 'a fresh theme install and its mirror' => sub {
    my $r = Lazysite::Manager::Themes::_install_theme_from_dir( theme_release('ORIGINAL'), 'test', 'op' );
    ok( $r->{ok},  'installed' ) or diag $r->{error};
    ok( -d $THEME, 'the theme directory exists' );
    my $m = Lazysite::Manager::Themes::_mirror_theme_assets( 'base', 'lumen' );
    ok( $m->{mirrored}, 'the mirror is built' ) or diag explain $m;
    like( slurp("$MIRR/main.css"), qr/ORIGINAL/, 'and carries the css' );
    ok( -f "$MIRR/theme-tokens.css", 'and the tokens file, switched in with it' );
    is_deeply( [ grep { /installing/ } dirs("$docroot/lazysite-assets/base") ], [], 'no staging directory is left behind' );
};

subtest 'an update to the PRISTINE served theme: switched in, old removed, no snapshot' => sub {
    my $ino_before = ino($THEME);
    my $r = Lazysite::Manager::Themes::_install_theme_from_dir( theme_release('UPGRADED'), 'layout-install', 'op', 1 );
    ok( $r->{ok}, 'the update reports success' ) or diag $r->{error};
    isnt( ino($THEME), $ino_before, 'the served directory is a NEW directory (switched in), not the old one written into' );
    like( slurp("$THEME/assets/main.css"), qr/UPGRADED/, 'with the new css' );
    is_deeply( [ dirs("$docroot/lazysite/layouts/base/themes") ], ['lumen'],
        'a pristine old version is removed, not snapshotted (SM176), and no staging is left' );
    like( slurp("$MIRR/main.css"), qr/UPGRADED/, 'the mirror was switched too' );
    is_deeply( [ grep { /installing|swap-out/ } dirs("$docroot/lazysite-assets/base") ], [], 'no staging or swap-out mirror left behind' );
};

subtest 'an update to an EDITED served theme: the old directory becomes the snapshot' => sub {
    put( "$THEME/assets/main.css", "/* EDITED BY SYSOP */\nbody{color:red}\n" );
    my $ino_old = ino($THEME);
    my $r = Lazysite::Manager::Themes::_install_theme_from_dir( theme_release('V3'), 'theme-upload', 'op', 1 );
    ok( $r->{ok}, 'the update reports success' ) or diag $r->{error};
    like( slurp("$THEME/assets/main.css"), qr/V3/, 'the served theme is the new version' );
    my @snap = grep { /^lumen-backup-/ } dirs("$docroot/lazysite/layouts/base/themes");
    is( scalar @snap, 1, 'exactly one snapshot exists' ) or diag explain [ dirs("$docroot/lazysite/layouts/base/themes") ];
    is( ino("$docroot/lazysite/layouts/base/themes/$snap[0]"), $ino_old,
        'and the snapshot IS the old directory, renamed - not a copy taken before an overwrite' );
    like( slurp("$docroot/lazysite/layouts/base/themes/$snap[0]/assets/main.css"), qr/EDITED BY SYSOP/,
        'holding the sysop\'s edit, which is the rollback' );
};

subtest 'the swap never leaves a mixture: the old directory is untouched until it steps aside' => sub {
    # Instrument: watch the served directory across the update. cp into the
    # served directory would show new bytes under the OLD inode; a switch shows
    # old bytes under the old inode until the inode changes.
    my $ino_old = ino($THEME);
    my $css_old = slurp("$THEME/assets/main.css");
    no warnings 'redefine';
    my $orig = \&Lazysite::Manager::Themes::_swap_in;
    my $seen_before_swap;
    local *Lazysite::Manager::Themes::_swap_in = sub {
        # at this moment the staging directory is complete and the served one untouched
        $seen_before_swap = { ino => ino($THEME), css => slurp("$THEME/assets/main.css") }
            if $_[1] eq $THEME;
        return $orig->(@_);
    };
    my $r = Lazysite::Manager::Themes::_install_theme_from_dir( theme_release('V4'), 'theme-upload', 'op', 1 );
    ok( $r->{ok},          'updated' ) or diag $r->{error};
    ok( $seen_before_swap, 'the switch was used for the served theme' ) or return;
    is( $seen_before_swap->{ino}, $ino_old, 'immediately before the switch the served directory was still the old one' );
    is( $seen_before_swap->{css}, $css_old, 'with the old bytes - nothing was written into it' );
    isnt( ino($THEME), $ino_old, 'and after the switch it is the new one' );
};

subtest 'a layout update: staged with its themes, switched in, layout.tt new' => sub {
    my $rel = tempdir( CLEANUP => 1 );
    put( "$rel/layout.tt", "V2 [% content %]\n" );
    my $L       = "$docroot/lazysite/layouts/base";
    my $ino_old = ino($L);
    my @themes  = dirs("$L/themes");

    my $refuse = Lazysite::Manager::Layouts::_install_layout_from_dir( $rel, 'base', 'layout-install', 'op', 0 );
    ok( !$refuse->{ok}, 'without force a differing install is refused' );
    is( slurp("$L/layout.tt"), "V1 [% content %]\n", 'and nothing changed' );

    my $r = Lazysite::Manager::Layouts::_install_layout_from_dir( $rel, 'base', 'layout-install', 'op', 1 );
    ok( $r->{ok} && $r->{action} eq 'updated', 'with force: updated' ) or diag explain $r;
    isnt( ino($L), $ino_old, 'the served layout directory is a new directory' );
    is( slurp("$L/layout.tt"), "V2 [% content %]\n", 'carrying the new template' );
    is_deeply( [ dirs("$L/themes") ], \@themes, 'and every installed theme, unchanged' );
    like( slurp("$L/themes/lumen/assets/main.css"), qr/V4/, 'including the served theme\'s current content' );
    is_deeply( [ grep { /installing|swap-out/ } dirs("$docroot/lazysite/layouts") ], [], 'no staging left behind' );
    ok( ( grep { /^base-backup-/ } dirs("$docroot/lazysite/layouts") ), 'the old layout (edited: it had no pristine record) is the snapshot' );
};

subtest 'every surface routes through the two functions' => sub {
    my $root = repo_root();
    my $s = do { local ( @ARGV, $/ ) = ( "$root/lib/Lazysite/Manager/Themes.pm", "$root/lib/Lazysite/Manager/Layouts.pm" ); <> };
    my @cp_over = grep { /system\(\s*['"]cp['"],\s*['"]-r['"],\s*"\$extract_dir\/\."\s*,\s*\$dest\s*\)/ } split /\n/, $s;
    is( scalar @cp_over, 0, 'no `cp -r extract/. dest` into an existing theme directory remains' );
    like( $s, qr/sub _swap_in/, 'the switch exists' );
    my $themes = do { local ( @ARGV, $/ ) = "$root/lib/Lazysite/Manager/Themes.pm"; <> };
    my ($mirror) = $themes =~ /(sub _mirror_theme_assets \{.*?\n\})/s;
    like( $mirror, qr/_swap_in\(/, 'the mirror builder switches in' );
    unlike( $mirror, qr/system\( 'cp', '-r', "\$src\/\.", \$dest \)/, 'and no longer copies over the served mirror' );
};

done_testing();
