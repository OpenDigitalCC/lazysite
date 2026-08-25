#!/usr/bin/perl
# SM532: renaming the active theme keeps the site styled.
#
# action_theme_delete refuses the active theme and any theme a configured
# domain resolves to. action_theme_rename checked neither: it renamed the
# directory and the mirror, answered ok:1, and left `theme: t` in
# lazysite.conf while themes/t was gone - every page then rendered through
# the layout with no theme mirror (tmp/tl-probe-rename-active.pl).
#
# The filing left open whether to repoint or refuse. This is REFUSE: the two
# verbs that can strand a site now answer alike, and an operator activates
# another theme first, exactly as before a delete.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use Lazysite::Manager::Themes ();

my $root = tempdir( CLEANUP => 1 );
my $doc  = "$root/site";
my $lz   = "$doc/lazysite";
make_path("$lz/auth");
$Lazysite::Manager::Themes::DOCROOT      = $doc;
$Lazysite::Manager::Themes::LAZYSITE_DIR = $lz;

sub _w {
    my ( $p, $c ) = @_;
    open my $f, '>', $p or die "$p: $!";
    print {$f} $c;
    close $f;
    return;
}

sub _theme {
    my ($name) = @_;
    make_path("$lz/layouts/l/themes/$name/assets");
    make_path("$doc/lazysite-assets/l/$name");
    _w( "$lz/layouts/l/themes/$name/theme.json", qq({"name":"$name","layouts":["l"]}) );
    return;
}

make_path("$lz/layouts/l");
_w( "$lz/layouts/l/layout.tt", "[% content %]" );
_theme($_) for qw(t v w);
_w( "$lz/lazysite.conf",
    "layout: l\ntheme: t\nalias_hosts: a.example\nalias.a.example.theme: v\n" );

subtest 'the active theme cannot be renamed out from under the site' => sub {
    my $r = Lazysite::Manager::Themes::action_theme_rename( 't', 'u' );
    is( $r->{ok}, 0, 'refused' ) or diag explain $r;
    like( $r->{error}, qr/active theme/i, 'and the refusal says why' );
    ok( -d "$lz/layouts/l/themes/t",  'themes/t is still there' );
    ok( !-d "$lz/layouts/l/themes/u", 'nothing was renamed' );
    ok( -d "$doc/lazysite-assets/l/t", 'the mirror is untouched' );
    my ( $layout, $theme ) = Lazysite::Manager::Themes::_read_active_layout_and_theme();
    is( $theme, 't', 'lazysite.conf still points at a theme that exists' )
        or diag('The conf pointed at a theme directory that no longer existed.');
    my $list = Lazysite::Manager::Themes::action_theme_list();
    my @flag = grep { $_->{active} } @{ $list->{themes} };
    is( scalar @flag, 1, 'exactly one theme carries the active flag' );
};

subtest 'a theme a domain resolves to cannot be renamed either' => sub {
    my $r = Lazysite::Manager::Themes::action_theme_rename( 'v', 'x' );
    is( $r->{ok}, 0, 'refused' ) or diag explain $r;
    like( $r->{error}, qr/in use by/i, 'the refusal says in use' );
    like( $r->{error}, qr/a\.example/, 'and names the domain' );
    ok( -d "$lz/layouts/l/themes/v", 'themes/v is still there' );
};

subtest 'a free theme still renames, mirror and all' => sub {
    my $r = Lazysite::Manager::Themes::action_theme_rename( 'w', 'y' );
    is( $r->{ok}, 1, 'renamed' ) or diag explain $r;
    is( $r->{old}, 'w', 'old name reported' );
    is( $r->{new}, 'y', 'new name reported' );
    ok( -d "$lz/layouts/l/themes/y",   'the directory moved' );
    ok( !-d "$lz/layouts/l/themes/w",  'and the old one is gone' );
    ok( -d "$doc/lazysite-assets/l/y", 'the mirror followed' );
};

subtest 'the guards are the ones delete applies' => sub {
    my $del = Lazysite::Manager::Themes::action_theme_delete('t');
    my $ren = Lazysite::Manager::Themes::action_theme_rename( 't', 'u' );
    ( my $d = $del->{error} ) =~ s/delete/VERB/;
    ( my $r = $ren->{error} ) =~ s/rename/VERB/;
    is( $r, $d, 'the active-theme refusal is worded alike for both verbs' );
    $del = Lazysite::Manager::Themes::action_theme_delete('v');
    $ren = Lazysite::Manager::Themes::action_theme_rename( 'v', 'x' );
    is( $ren->{error}, $del->{error}, 'and so is the in-use refusal' );
};

done_testing();
