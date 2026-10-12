#!/usr/bin/perl
# mirror.pl [SITE] - publish the local site's theme assets to /lazysite-assets/.
#
# SM887, from the release manager's real-session run (2026-10-12): with the
# editor's layout and theme pulled into the local tree, every page linked
# /lazysite-assets/<layout>/<theme>/main.css - correctly - and that URL 404'd,
# because on a real site the directory is written when a theme is ACTIVATED, a
# layout installed or a package applied, and the local tree had none of those.
# The HTML was right and the page rendered unstyled.
#
# THIS IS THE ENGINE'S OWN STEP, not a copy of it. It loads the installed
# engine's Lazysite::Manager::Themes and calls _mirror_layout_themes - the
# function activation, layout install and package apply all call - so the
# mirror is built exactly as the site's was: assets/ copied, the theme-tokens
# stylesheet written beside them, the fingerprint the layout keys its cache on.
# A hand-rolled `cp -r assets` would have got the first and silently missed the
# other two.
#
# Every theme the active layout carries is mirrored, not only the active one,
# for the engine's reason (SM820): a page with its own `theme:` links that
# theme's mirror.
#
# Reads layout and theme from SITE/lazysite/lazysite.conf (site-context.md has
# the agent write them there). Exit 0 when the active theme's mirror has files,
# 1 when it has none (with the engine's own reason), 2 for a usage problem.
# Writes only under SITE - never beside itself, so a read-only skill mount is
# no obstacle.
use strict;
use warnings;

my $site = shift @ARGV // $ENV{LAZYSITE_SITE} // ( $ENV{LAZYSITE_HOME} // '/root/lazysite-local' ) . '/site';
$site =~ s{/+\z}{};
my $lib = $ENV{LAZYSITE_LIB} // '/usr/share/lazysite/lib';

sub usage_fail {
    print STDERR "mirror.pl: $_[0]\n";
    exit 2;
}

usage_fail("no site at $site - run setup.sh first") unless -d $site;
usage_fail("no engine library at $lib - run setup.sh first") unless -d "$lib/Lazysite";
unshift @INC, $lib;

my $conf = "$site/lazysite/lazysite.conf";
my %want;
if ( open my $fh, '<', $conf ) {
    while ( my $l = <$fh> ) {
        next unless $l =~ /^(layout|theme)\s*:\s*(\S+)\s*$/;
        $want{$1} //= $2;
    }
    close $fh;
}
my ( $layout, $theme ) = @want{qw(layout theme)};
usage_fail("$conf names no layout: - write the reconstructed conf first (reference/site-context.md)")
    unless defined $layout && length $layout;

require Lazysite::Paths;
require Lazysite::Manager::Themes;
{
    no warnings 'once';
    $Lazysite::Manager::Themes::DOCROOT      = $site;
    $Lazysite::Manager::Themes::LAZYSITE_DIR = Lazysite::Paths::lazysite_dir($site);
    $Lazysite::Manager::Themes::action       = 'skill-mirror';
}

my $all = Lazysite::Manager::Themes::_mirror_layout_themes($layout);
my $res = $all->{results} // {};

if ( !$all->{themes} ) {
    print "mirror.pl: layout '$layout' carries no themes"
        . ( $all->{reason} ? " ($all->{reason})" : '' ) . "\n";
    exit 1;
}

for my $t ( sort keys %$res ) {
    my $r = $res->{$t};
    if ( ( $r->{mirrored} // 0 ) > 0 ) {
        print "mirrored $layout/$t: $r->{mirrored} file(s) -> /lazysite-assets/$layout/$t/\n";
    }
    else {
        print "NOT mirrored $layout/$t: " . ( $r->{reason} // 'unknown' ) . "\n";
    }
}

# The verdict is the ACTIVE theme's: that is the one every page without its own
# `theme:` links. No theme named means the layout's default, which is one of the
# above - say so rather than guess which.
if ( defined $theme && length $theme ) {
    my $r = $res->{$theme};
    unless ( $r && ( $r->{mirrored} // 0 ) > 0 ) {
        print "FAIL: the active theme '$theme' has no mirror - its pages will link a stylesheet that 404s\n";
        exit 1;
    }
}
exit 0;
