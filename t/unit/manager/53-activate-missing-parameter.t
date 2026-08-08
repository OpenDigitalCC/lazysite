#!/usr/bin/perl
# SM247: a missing parameter must never be read as a destructive instruction.
#
# The control API defaults `path` to '/'. action_theme_activate sanitises its
# name with s/[^a-zA-Z0-9_-]//g, which reduces '/' to '' - and '' used to mean
# DEACTIVATE. So calling theme-activate with the name in the wrong parameter
# (theme= rather than path=) stripped the site's theme and returned ok:1. A site
# agent did exactly that to a live site and caught it only by checking theme-list
# straight afterwards; an agent trusting ok:1 walks away leaving a site unstyled.
#
# The property under test is not "empty means error" but the stronger one: the
# destructive branch is reachable ONLY by asking for it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Themes ();
use Lazysite::Manager::Files  ();

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/layouts/base/themes/house", "$d/lazysite/manager/locks" );
open my $tj, '>', "$d/lazysite/layouts/base/themes/house/theme.json" or die $!;
print {$tj} '{"name":"house","version":"1.0.0","layouts":["base"],"config":{}}';
close $tj;

$Lazysite::Manager::Themes::DOCROOT      = $d;
$Lazysite::Manager::Themes::LAZYSITE_DIR = "$d/lazysite";
# action_theme_activate takes an artifact lock, so the lock store must exist.
$Lazysite::Manager::Files::DOCROOT  = $d;
$Lazysite::Manager::Files::LOCK_DIR = "$d/lazysite/manager/locks";

sub write_conf { open my $f, '>', "$d/lazysite/lazysite.conf" or die $!; print {$f} $_[0]; close $f }
sub conf       { open my $f, '<', "$d/lazysite/lazysite.conf" or die $!; local $/; <$f> }

write_conf("site_name: T\nlayout: base\ntheme: house\n");

# --- the reported call: name in the wrong parameter --------------------------
{
    # This is what `?action=theme-activate&theme=house` produces: path defaults
    # to '/', which sanitises to ''.
    my $r = Lazysite::Manager::Themes::action_theme_activate( '/', {} );
    ok( !$r->{ok}, 'an empty theme name is an ERROR, not a silent deactivation' );
    is( $r->{kind}, 'missing-parameter', 'reported as a missing parameter' );
    like( $r->{error}, qr/\bpath\b/, 'the message names the right parameter' );
    like( $r->{error}, qr/deactivate=1/, 'and names how to deactivate on purpose' );
    like( conf(), qr/^theme: house$/m,
        'and the site theme is UNTOUCHED - the whole point' );
}

# An entirely absent name behaves the same way.
{
    my $r = Lazysite::Manager::Themes::action_theme_activate( '', {} );
    ok( !$r->{ok}, 'an empty string is refused too' );
    like( conf(), qr/^theme: house$/m, 'theme still untouched' );
}

# --- deliberate deactivation still works -------------------------------------
{
    my $r = Lazysite::Manager::Themes::action_theme_activate( '', { deactivate => 1 } );
    ok( $r->{ok}, 'deactivate=1 deactivates' );
    unlike( conf(), qr/^theme: /m, 'and the theme pointer is cleared' );
}

# --- a real activation is unaffected -----------------------------------------
{
    write_conf("site_name: T\nlayout: base\n");
    my $r = Lazysite::Manager::Themes::action_theme_activate( 'house', {} );
    ok( $r->{ok}, 'activating a real theme still works' ) or diag( $r->{error} // '' );
    like( conf(), qr/^theme: house$/m, 'and sets the pointer' );
}

# --- the sibling already refuses, and must keep doing so ---------------------
# layout-activate shares the same $path default but has always required a name.
# Pinned here so the two stay consistent if either is touched.
{
    my $r = Lazysite::Manager::Themes::action_layout_activate( '/', {} );
    ok( !$r->{ok}, 'layout-activate refuses an empty name' );
    like( $r->{error}, qr/required/i, 'with a "required" message' );
}

done_testing();
