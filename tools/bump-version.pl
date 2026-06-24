#!/usr/bin/perl
# tools/bump-version.pl - post-release version roll. Promotes NEXT_VERSION into
# VERSION (the just-released version) and advances NEXT_VERSION, so VERSION
# never drifts behind the last release - the 2026 seven-dimension review found
# it stuck at 0.2.18 while releases were at 0.3.x. The release process should
# call this AFTER a tag is cut; it always advances, so call once per release.
#
#   perl tools/bump-version.pl            # advance NEXT_VERSION patch
#   perl tools/bump-version.pl --minor    # minor bump (patch -> 0)
#   perl tools/bump-version.pl --major    # major bump (minor, patch -> 0)
use strict;
use warnings;

my $level = 'patch';
$level = 'minor' if grep { $_ eq '--minor' } @ARGV;
$level = 'major' if grep { $_ eq '--major' } @ARGV;

sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!\n"; chomp( my $v = <$fh> ); close $fh; return $v }
sub spit  { open my $fh, '>', $_[0] or die "$_[0]: $!\n"; print $fh "$_[1]\n"; close $fh }

my $next = slurp('NEXT_VERSION');
die "NEXT_VERSION '$next' is not X.Y.Z\n" unless $next =~ /^(\d+)\.(\d+)\.(\d+)$/;
my ( $maj, $min, $pat ) = ( $1, $2, $3 );

spit( 'VERSION', $next );   # VERSION = the version just released

if    ( $level eq 'major' ) { $maj++; $min = 0; $pat = 0 }
elsif ( $level eq 'minor' ) { $min++; $pat = 0 }
else                        { $pat++ }
my $new_next = "$maj.$min.$pat";
spit( 'NEXT_VERSION', $new_next );

print "VERSION -> $next ; NEXT_VERSION -> $new_next\n";
