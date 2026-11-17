#!/usr/bin/perl
# SM1475: A STABLE PATCH IS BUILT FROM ITS BRANCH.
#
# Main carries the next release's unreleased work, and `release.sh build` released
# only main's tip. A stable patch is gated on its own branch (gate-main.sh --ref
# BRANCH --final --patch), so `build VERSION --notes FILE --final --ref BRANCH` builds
# it there: the release commit and the stable download/ commit go on the branch's
# tip, the tag on the release commit, the branch ref moves, and local main does not.
# The release material tool is the branch tip's own, the one the gate ran. The build
# ends by printing the merge that brings the release commit to main.
#
# Driven through the REAL release.sh in a scratch repository (t/lib/ReleaseRig.pm).
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);
use ReleaseRig qw(spit slurp git rig_repo rig_release rig_receipt rig_notes rig_tags rig_patch_branch);

plan skip_all => 'setsid missing' unless grep { -x "$_/setsid" } split /:/, $ENV{PATH};

# The receipt a --patch gate of the branch's tip leaves.
sub patch_receipt {
    my ( $d, $tip, %o ) = @_;
    return rig_receipt( $d, sha => $tip, channel => 'stable', suite => 'patch (base v0.1.0, 2 files)', suite_base => 'v0.1.0', %o );
}

subtest 'the release goes on the branch, and main does not move' => sub {
    my $d    = rig_repo();
    my $main = git( $d, 'rev-parse', 'main' );
    # The branch's own release material tool: the gate ran it, so the build must use it.
    my $tool = slurp("$d/tools/release-material.pl") . "\n# the branch's own copy\n";
    my $tip  = rig_patch_branch( $d, 'patch', files => { 'tools/release-material.pl' => $tool } );
    patch_receipt( $d, $tip, material_tool => sha256_hex($tool) );

    my ( $rc, $out ) = rig_release( $d, {}, 'build', '0.1.1', '--notes', rig_notes(), '--final', '--ref', 'patch' );
    is( $rc, 0, 'the build passes' ) or return diag($out);

    my $dl      = git( $d, 'rev-parse', 'patch' );
    my $release = git( $d, 'rev-parse', 'v0.1.1^{commit}' );
    is( git( $d, 'rev-parse', 'patch^' ),  $release, 'the branch is the release commit plus the download commit' );
    is( git( $d, 'rev-parse', 'patch^^' ), $tip,     'on top of the tip the gate ran' );
    is( git( $d, 'rev-parse', 'main' ),    $main,    'local main is not moved' );
    is( git( $d, 'show', 'patch^:VERSION' ), "0.1.1", 'the release commit carries the release material' );
    like( git( $d, 'ls-tree', '--name-only', 'patch', 'download/' ), qr{download/lazysite-0\.1\.1\.tar\.gz}, 'the stable set is on the branch' );
    is( git( $d, 'cat-file', '-t', 'v0.1.1' ), 'tag', 'the tag is annotated' );
    like( git( $d, 'log', '-1', '--format=%s', $release ), qr/^lazysite 0\.1\.1 \(stable\)/, 'its message names the release' );
    like( git( $d, 'log', '-1', '--format=%b', $release ), qr/^patch at \Q${\ substr( $tip, 0, 12 )}\E\./m, 'and the branch it was made on' );

    like( $out, qr/^==> patch is now \Q$dl\E \(was \Q$tip\E\)$/m, 'it says the branch moved' );
    like( $out, qr/^==> v0\.1\.1 is on patch, not on main \(main is still \Q$main\E\)\.$/m, 'and that main has not' );
    like( $out, qr/^    git -C \Q$d\E worktree add -b claude\/land-v0\.1\.1 \Q$d\E\/tmp\/wt-land-v0\.1\.1 \Q$main\E$/m, 'the branch from main, real values' );
    like( $out, qr/^    git -C \Q$d\E\/tmp\/wt-land-v0\.1\.1 merge --no-edit \Q$dl\E$/m, 'merging the branch\'s new tip' );
    unlike( $out, qr/\b(?:BRANCH|SHA|PLACEHOLDER|<[a-z-]+>)\b/, 'no placeholder in what it prints' );
    like( $out, qr/^    tools\/release\.sh publish 0\.1\.1$/m, 'and the publish step after it' );
};

subtest 'a branch checked out elsewhere moves with the build' => sub {
    my $d   = rig_repo();
    my $tip = rig_patch_branch( $d, 'patch' );
    patch_receipt( $d, $tip );
    my $wt = "$d/../wt-patch-" . $$;
    git( $d, 'worktree', 'add', '-q', $wt, 'patch' );
    my ( $rc, $out ) = rig_release( $d, {}, 'build', '0.1.1', '--notes', rig_notes(), '--final', '--ref', 'patch' );
    is( $rc, 0, 'the build passes' ) or return diag($out);
    is( git( $wt, 'rev-parse', 'HEAD' ), git( $d, 'rev-parse', 'patch' ), 'the checkout moved with the branch' );
    is( slurp("$wt/VERSION"), "0.1.1\n", 'and carries the release' );
    git( $d, 'worktree', 'remove', '--force', $wt );
};

subtest 'without --ref the build is main\'s, as it was' => sub {
    my $d = rig_repo();
    rig_receipt($d);
    my ( $rc, $out ) = rig_release( $d, {}, 'build', '0.1.1', '--notes', rig_notes() );
    is( $rc, 0, 'main\'s build passes' ) or return diag($out);
    is( git( $d, 'rev-parse', 'main' ), git( $d, 'rev-parse', 'v0.1.1^{commit}' ), 'main moved to the release commit' );
    like( $out, qr/^==> The release manager's step - pushes main and v0\.1\.1 together:$/m, 'and the next step is publish' );
    unlike( $out, qr/land-v0\.1\.1/, 'with no merge to make' );
};

done_testing();
