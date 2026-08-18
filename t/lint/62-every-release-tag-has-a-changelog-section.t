#!/usr/bin/perl
# A release tag whose version has no CHANGELOG.md section.
#
# 0.10.13 was cut, tagged, built and deployed with its entries still sitting
# under `## Unreleased`. Nothing failed. The tarball shipped, the tag resolved,
# the deploy worked - and the release's own record of what it contained named
# no version, so the next release's changelog silently claimed 0.10.13's work
# as its own.
#
# THIS IS THE SAME DEFECT CLASS THE 0.10.13 CONTENT IS FULL OF: a control
# reporting success without having done the work. release.sh has no idea the
# changelog exists, so "cut a release" completed while half of what a release
# IS had not happened.
#
# WHY IT CANNOT BE CHECKED AT RELEASE TIME, and so is checked here instead: the
# heading goes into the release commit and the tag is created after it, so at
# the moment release.sh runs the heading either exists already or never will.
# A check inside release.sh would be asserting on its own input. This asserts
# on HISTORY - every tag that already exists - which is the part that can be
# known.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my $is_repo = system("git -C \Q$root\E rev-parse --git-dir >/dev/null 2>&1") == 0;
plan skip_all => 'not a git checkout - tags cannot be resolved here'
    unless $is_repo;

my $changelog = "$root/CHANGELOG.md";
my $src       = do { open my $fh, '<', $changelog or die $!; local $/; <$fh> };

my %heading;
for my $line ( split /\n/, $src ) {
    next unless $line =~ /^##\s+v?(\d+\.\d+\.\d+)\b/;
    $heading{$1} = 1;
}

my @tags = grep { /\S/ } split /\n/, `git -C \Q$root\E tag --list 'v*.*.*'`;
chomp @tags;
plan skip_all => 'no release tags in this checkout' unless @tags;

# THE FLOOR IS DELIBERATE. The convention predates some of the early tags and
# retrofitting their sections would be inventing a record rather than keeping
# one. Lowering this floor is fine; raising it silently is how a check stops
# checking.
my $FLOOR = '0.10.0';
sub numify { my @p = split /\./, shift; return sprintf '%03d%03d%03d', @p; }

my @missing;
for my $tag ( sort @tags ) {
    my ($v) = $tag =~ /^v(\d+\.\d+\.\d+)$/ or next;
    next if numify($v) lt numify($FLOOR);
    push @missing, $v unless $heading{$v};
}

is( scalar @missing, 0, "every release tag from v$FLOOR has a changelog section" )
    or diag( "No `## VERSION` heading for: @missing\n"
        . "A tagged release whose entries are still under `## Unreleased` has\n"
        . "shipped without a record of what it contained, and the NEXT release\n"
        . "will absorb its entries as though they were new. Add the heading and\n"
        . 'move that release\'s bullets under it.' );

done_testing();
