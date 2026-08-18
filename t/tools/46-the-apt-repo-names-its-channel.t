#!/usr/bin/perl
# SM272: the repository that lets a host install what release.sh builds.
#
# The .deb family has existed since 0.6.10 and there has never been anywhere to
# install it FROM, so 17 production sites take a tarball. This is the repository
# half. It deliberately does NOT publish and does NOT hold a key: publication is
# egress and belongs to whoever holds the credential, and where a signing key
# lives, who may use it and how a compromise is recovered are the questions
# SM272 exists to ask. They are not answerable by packaging code.
#
# WHAT IS TESTED IS THE PART THAT CAN GO SILENTLY WRONG. An apt repository that
# is built but empty installs nothing while every command exits 0, and a suite
# chosen by default rather than named is how an edge build reaches a stable
# host.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

# Plans first - an assertion before skip_all is an error, and the first version
# of this file made it.
plan skip_all => 'apt-ftparchive not installed'
    unless `sh -c 'command -v apt-ftparchive 2>/dev/null'` =~ /\S/;
plan skip_all => 'dpkg-deb not installed'
    unless `sh -c 'command -v dpkg-deb 2>/dev/null'` =~ /\S/;

my $root = repo_root();
my $TOOL = "$root/tools/build-apt-repo.sh";
ok( -x $TOOL, 'build-apt-repo.sh is present and executable' );

# A scratch repo with a couple of real packages, so the index has something to
# be wrong about.
my $scratch = tempdir( CLEANUP => 1 );
make_path("$scratch/dist");
make_path("$scratch/tools");
system( 'cp', $TOOL, "$scratch/tools/" ) == 0 or die 'cp tool';
# BUILT HERE rather than taken from dist/. A test that depends on release
# artefacts being present passes or fails on whether somebody cut a release,
# which is not what it is measuring - and dist/ is not carried into a worktree.
for my $pkg (qw(zz-probe-one zz-probe-two)) {
    my $d = "$scratch/build/$pkg/DEBIAN";
    make_path($d);
    open my $ctl, '>', "$d/control" or die $!;
    print {$ctl} "Package: $pkg\nVersion: 1.0-1\nArchitecture: all\n"
        . "Maintainer: t\nDescription: probe package\n";
    close $ctl;
    system( 'dpkg-deb', '--build', '--root-owner-group', "$scratch/build/$pkg",
        "$scratch/dist/${pkg}_1.0-1_all.deb" ) == 0
        or die "dpkg-deb $pkg";
}

sub run {
    my (@args) = @_;
    my $cmd = join ' ', map { quotemeta } 'bash', "$scratch/tools/build-apt-repo.sh", @args;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

subtest 'the channel is required and never inferred' => sub {
    # The failure this guards is an edge build reaching a stable host. A suite
    # chosen by default, by filename, or by whatever was there last is how that
    # happens - so it is named on every invocation or the tool refuses.
    my ( $rc, $out ) = run();
    isnt( $rc, 0, 'no channel is a refusal' );
    like( $out, qr/--channel is required/, 'and says so' );
    like( $out, qr/never inferred/,
        'stating that it is not guessed, which is the point rather than a '
            . 'missing-argument message' );

    ( $rc, $out ) = run( '--channel', 'lts' );
    isnt( $rc, 0, 'an unknown channel is a refusal too' );
};

subtest 'the suite in the Release file is the channel that was asked for' => sub {
    my ( $rc, $out ) = run( '--channel', 'beta' );
    is( $rc, 0, 'it builds' ) or diag $out;

    my $rel = "$scratch/dist/apt/dists/beta/Release";
    ok( -f $rel, 'a Release file exists for that suite' ) or return;
    open my $fh, '<', $rel or die $!;
    my $body = do { local $/; <$fh> };
    close $fh;
    like( $body, qr/^Suite: beta$/m,    'Suite names it' );
    like( $body, qr/^Codename: beta$/m, 'and so does Codename' );
    ok( !-d "$scratch/dist/apt/dists/stable",
        'and nothing was written into a suite nobody asked for' );
};

subtest 'the index names the packages that were pooled' => sub {
    # The silent failure: apt-ftparchive walking the wrong directory exits 0 and
    # writes an EMPTY Packages file. An empty repository installs nothing while
    # every command reports success - which is this register's oldest shape.
    my ( $rc, $out ) = run( '--channel', 'edge' );
    is( $rc, 0, 'it builds' ) or diag $out;

    my $pkgs = "$scratch/dist/apt/dists/edge/main/binary-all/Packages";
    ok( -s $pkgs, 'the index is not empty' ) or return;

    open my $fh, '<', $pkgs or die $!;
    my $n = grep { /^Package: / } <$fh>;
    close $fh;
    is( $n, 2, 'and names both pooled packages' );
    like( $out, qr/Indexed 2 package/, 'which the tool states rather than assumes' );

    ok( -f "$pkgs.gz", 'the gzipped index apt actually fetches is there too' );
};

subtest 'an unsigned repository says it is unsigned' => sub {
    # Not a broken repository - an unfinished one, and the missing half is a
    # decision about key custody rather than a command. apt will refuse it, and
    # an operator should learn that here rather than from apt.
    my ( $rc, $out ) = run( '--channel', 'edge' );
    is( $rc, 0, 'still a success' );
    like( $out, qr/UNSIGNED/,        'it says so plainly' );
    like( $out, qr/apt will refuse/, 'and says what that means' );
    ok( !-f "$scratch/dist/apt/dists/edge/InRelease",
        'and no signature is fabricated' );
};

done_testing();
