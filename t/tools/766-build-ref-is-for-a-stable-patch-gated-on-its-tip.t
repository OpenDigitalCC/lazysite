#!/usr/bin/perl
# SM1475: `release.sh build --ref BRANCH` BUILDS ONLY A STABLE PATCH THAT WAS GATED AS IT IS.
#
# It is refused off stable, for main and for a branch that is not there; unless the
# gate receipt for the version is a --patch receipt for the branch's CURRENT tip;
# unless the branch grew from the patch base (the newest release of the line) and its
# download/ holds that base's stable set; and --ref is not a gate option. Every
# refusal leaves the branch, main and the tags as they were.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);
use ReleaseRig qw(spit slurp git commit rig_repo rig_release rig_receipt rig_notes rig_tags rig_patch_branch);

plan skip_all => 'setsid missing' unless grep { -x "$_/setsid" } split /:/, $ENV{PATH};

sub patch_receipt {
    my ( $d, $tip, %o ) = @_;
    return rig_receipt( $d, sha => $tip, channel => 'stable', suite => 'patch (base v0.1.0, 2 files)', suite_base => 'v0.1.0', %o );
}

# Build, and say what it left: the refusal's exit and text, with nothing moved.
sub refused {
    my ( $name, $d, $want_rc, $re, @flags ) = @_;
    my %before = map { $_ => git( $d, 'rev-parse', $_ ) } qw(main patch);
    my ( $rc, $out ) = rig_release( $d, {}, 'build', '0.1.1', '--notes', rig_notes(), @flags );
    is( $rc, $want_rc, "$name: refused" );
    like( $out, $re, "$name: says why" ) or diag($out);
    is( rig_tags($d), '', "$name: nothing is tagged" );
    is( git( $d, 'rev-parse', $_ ), $before{$_}, "$name: $_ is where it was" ) for qw(main patch);
}

subtest 'the options it is refused with' => sub {
    my $d   = rig_repo();
    my $tip = rig_patch_branch( $d, 'patch' );
    patch_receipt( $d, $tip );
    for my $c ( [ 'edge', '--ref', 'patch' ], [ 'beta', '--beta', '--ref', 'patch' ], [ 'certified', '--certified', '--ref', 'patch' ] ) {
        my ( $name, @f ) = @$c;
        refused( $name, $d, 2, qr/^release\.sh: --ref is for a stable patch \(--final\); the \Q$name\E channel is built from main's tip\.$/m, @f );
    }
    refused( 'main', $d, 2, qr/^release\.sh: --ref names the patch branch; main is built without --ref\.$/m, '--final', '--ref', 'main' );
    refused( 'refs/heads/main', $d, 2, qr/--ref names the patch branch/, '--final', '--ref', 'refs/heads/main' );
    refused( 'no such branch', $d, 1, qr/^release\.sh: no local nosuch in \Q$d\E$/m, '--final', '--ref', 'nosuch' );

    my $out = run_cmd( 'bash', "$d/tools/release.sh", 'gate', '0.1.1', '--final', '--ref', 'patch' );
    is( $? >> 8, 2, 'a gate takes --commit, not --ref' );
    like( $out, qr/--ref is a build option/, 'saying so' );
};

subtest 'the receipt must be a patch receipt for the branch\'s tip' => sub {
    my $d   = rig_repo();
    my $tip = rig_patch_branch( $d, 'patch' );

    rig_receipt( $d, sha => $tip, channel => 'stable' );
    refused( 'a full-suite receipt', $d, 1, qr/is not a --patch receipt.*\nrelease\.sh: Gate the branch: tools\/gate-main\.sh --ref patch --version 0\.1\.1 --final --patch$/s, '--final', '--ref', 'patch' );

    patch_receipt( $d, $tip );
    my $later = rig_patch_branch( $d, 'later', from => 'patch' );
    # The receipt names the gated tip; the branch has since moved.
    git( $d, 'branch', '-f', 'patch', $later );
    refused( 'a branch past its gate', $d, 1, qr/the gate receipt is for \Q${\ substr( $tip, 0, 12 )}\E, and patch is at \Q$later\E\./, '--final', '--ref', 'patch' );
    git( $d, 'branch', '-f', 'patch', $tip );

    patch_receipt( $d, git( $d, 'rev-parse', 'main' ) );
    refused( 'a receipt for main\'s tip', $d, 1, qr/the gate receipt is for \Q${\ substr( git( $d, 'rev-parse', 'main' ), 0, 12 )}\E, and patch is at \Q$tip\E\./, '--final', '--ref', 'patch' );

    patch_receipt( $d, $tip, suite_base => 'v0.0.9' );
    refused( 'a patch gate against another base', $d, 1, qr/a patch gate against v0\.0\.9 /, '--final', '--ref', 'patch' );
};

subtest 'the branch must grow from the base release, and carry its stable set' => sub {
    my $d = rig_repo();

    # Not from the base tag: a root commit with main's tree.
    my $root = git( $d, 'commit-tree', 'main^{tree}', '-m', 'unrelated' );
    git( $d, 'branch', 'patch', $root );
    patch_receipt( $d, $root );
    refused( 'a branch not from the base tag', $d, 1, qr/^release\.sh: patch \(\Q$root\E\) does not descend from the patch base v0\.1\.0;$/m, '--final', '--ref', 'patch' );
    git( $d, 'branch', '-D', 'patch' );

    # From the tag, but its download/ is not the base's set (newest stable is another).
    my $tip = rig_patch_branch( $d, 'patch', files => { 'download/lazysite-0.1.0.tar.gz' => undef, 'download/lazysite-0.0.9.tar.gz' => "old\n" } );
    patch_receipt( $d, $tip );
    refused( 'a download/ that is not the base', $d, 1, qr/^release\.sh: v0\.1\.0 is not the newest stable release on patch: its download\/ holds 0\.0\.9\.$/m, '--final', '--ref', 'patch' );
};

done_testing();
