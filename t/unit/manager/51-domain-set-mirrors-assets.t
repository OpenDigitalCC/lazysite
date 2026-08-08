#!/usr/bin/perl
# SM241: binding a layout/theme to a domain must PUBLISH the theme's assets.
#
# Without it a secondary domain serves a 404 stylesheet - the layout renders its
# header, nav and footer correctly and the page looks chrome-less because nothing
# styles it. The theme source is in the right place; only the public mirror at
# /lazysite-assets/<layout>/<theme>/ is missing.
#
# The mirror was written by theme-activate, theme upload, layout activate/install
# and site_apply, and by nothing in the domain path - so the natural action for a
# secondary domain was the one action that published nothing.
#
# Two things must hold and the second is the one that makes this hard:
#   1. binding publishes the assets, and
#   2. it publishes under THE THEME'S OWN LAYOUT, because the whole failure case
#      is a secondary domain running a layout other than the instance-wide one.
# And the fix must not reintroduce the trap it replaces: the primary site's
# layout:/theme: keys must be untouched.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Domains ();

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/layouts/$_/themes") for qw(base other);
for my $pair ( [ 'base', 'house' ], [ 'other', 'harmony' ] ) {
    my ( $l, $t ) = @$pair;
    make_path("$d/lazysite/layouts/$l/themes/$t/assets");
    open my $c, '>', "$d/lazysite/layouts/$l/themes/$t/assets/main.css" or die $!;
    print {$c} "/* $l-$t */\n";
    close $c;
}

open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} <<'CONF';
site_name: T
layout: base
theme: house
alias_hosts: harmony.example
CONF
close $cf;

$Lazysite::Manager::Domains::DOCROOT = $d;

sub mirror_exists { -f "$d/lazysite-assets/$_[0]/$_[1]/main.css" }
sub conf { open my $f, '<', "$d/lazysite/lazysite.conf" or die $!; local $/; <$f> }

ok( !mirror_exists( 'other', 'harmony' ), 'no mirror before binding' );

# Bind the secondary domain to a layout and theme it does not share with the
# primary - the harmony2050.org shape.
my $r1 = Lazysite::Manager::Domains::domain_set( 'harmony.example', 'layout', 'other' );
ok( $r1->{ok}, 'binding the layout succeeds' );
my $r2 = Lazysite::Manager::Domains::domain_set( 'harmony.example', 'theme', 'harmony' );
ok( $r2->{ok}, 'binding the theme succeeds' );

ok( mirror_exists( 'other', 'harmony' ),
    'the theme assets are published under the domain\'s own layout' );
ok( !mirror_exists( 'base', 'harmony' ),
    'and NOT under the instance-wide active layout (the reported failure mode)' );

# The trap this replaces: re-activating to fix a secondary domain rewrote the
# instance-wide pointer. Binding must never do that.
my $c = conf();
like( $c, qr/^layout: base$/m,  "the primary site's layout is untouched" );
like( $c, qr/^theme: house$/m,  "the primary site's theme is untouched" );
like( $c, qr/^alias\.harmony\.example\.theme: harmony$/m,
    'the binding itself was recorded' );

# A key that is not presentation does no mirroring work.
unlink "$d/lazysite-assets/other/harmony/main.css";
my $r3 = Lazysite::Manager::Domains::domain_set(
    'harmony.example', 'site_name', 'Harmony' );
ok( $r3->{ok}, 'setting a non-presentation key succeeds' );
ok( !mirror_exists( 'other', 'harmony' ),
    'and does not mirror (only layout/theme changes publish)' );

# A theme with no assets/ directory is not an error - many themes are CSS-less
# or inherit everything from the layout.
Lazysite::Manager::Domains::domain_set( 'harmony.example', 'theme', 'nosuch' );
ok( 1, 'binding a theme with no assets directory does not die' );

# Setting only the theme, with the layout inherited from the base site, must
# mirror under the INHERITED layout - the alias case that pins a theme and takes
# the primary's layout.
{
    open my $w, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$w} "site_name: T\nlayout: base\ntheme: house\nalias_hosts: b.example\n";
    close $w;
    my $r = Lazysite::Manager::Domains::domain_set( 'b.example', 'theme', 'house' );
    ok( $r->{ok}, 'binding a theme with an inherited layout succeeds' );
    ok( mirror_exists( 'base', 'house' ),
        'and mirrors under the inherited layout' );
}

done_testing();
