#!/usr/bin/perl
# VERSION must not sit behind the newest release tag.
#
# IT HAS DONE THIS TWICE. tools/bump-version.pl was written the first time - its
# header records a 2026 review finding VERSION "stuck at 0.2.18 while releases
# were at 0.3.x" - and it says plainly that "the release process should call
# this AFTER a tag is cut". Nothing called it. VERSION then sat at 0.10.9 while
# 0.10.10, .11, .12, .13 and .14 were released.
#
# So the fix for the defect was written, committed, and never wired in. That is
# the failure mode this test exists for: not the drift, which is easy to correct,
# but a REMEDY THAT DEPENDS ON SOMEBODY REMEMBERING TO INVOKE IT. This project's
# standing answer is to replace a person remembering with a build failing.
#
# WHAT IT COST, so the next reader knows this is not cosmetic: lazysite-compliance
# reads VERSION and compares compliance records against it, so the release gate
# spent five releases asking whether records were current as of 0.10.9.
# build-manifest.pl and manifest-to-sbom.pl DEFAULT to it, and were correct only
# because release.sh passes --version explicitly - and the file ships inside the
# tarball, where nothing passes them anything.
#
# THE WINDOW IS DELIBERATE. Between cutting vX and bumping VERSION to X, this
# test fails on main. That is the forcing function, not a flaw: release.sh
# stamps the ARTEFACT correctly on its own, so a red main here costs nothing but
# a one-line commit, and it is the only thing that makes that commit happen.
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

my $vf = "$root/VERSION";
ok( -f $vf, 'VERSION is present' ) or do { done_testing(); exit };

open my $fh, '<', $vf or die $!;
chomp( my $version = <$fh> );
close $fh;
$version =~ s/^\s+|\s+$//g;

like( $version, qr/^\d+\.\d+\.\d+$/, "VERSION is a semver ($version)" )
    or do { done_testing(); exit };

my @tags = grep { /\S/ } split /\n/, `git -C \Q$root\E tag --list 'v*.*.*'`;
chomp @tags;
plan skip_all => 'no release tags in this checkout' unless @tags;

sub numify {
    my @p = split /\./, shift;
    return sprintf '%05d%05d%05d', @p;
}

my ($newest) = sort { numify($b) <=> numify($a) }
    map { /^v(\d+\.\d+\.\d+)$/ ? $1 : () } @tags;

ok( numify($version) >= numify($newest),
    "VERSION ($version) is not behind the newest tag ($newest)" )
    or diag( "Run: perl tools/bump-version.pl\n"
        . "That promotes NEXT_VERSION into VERSION and advances NEXT_VERSION.\n"
        . 'It exists for exactly this and has never been wired into a release, '
        . 'which is how VERSION reached five releases behind.' );

# NEXT_VERSION is the other half of the same pair, and a NEXT_VERSION at or
# below VERSION means the next release would propose a version already cut -
# and burned versions are never reused (SM064).
my $nf = "$root/NEXT_VERSION";
if ( -f $nf ) {
    open my $nh, '<', $nf or die $!;
    chomp( my $next = <$nh> );
    close $nh;
    $next =~ s/^\s+|\s+$//g;
    like( $next, qr/^\d+\.\d+\.\d+$/, "NEXT_VERSION is a semver ($next)" );
    ok( numify($next) > numify($version),
        "NEXT_VERSION ($next) is ahead of VERSION ($version)" );
}

done_testing();
