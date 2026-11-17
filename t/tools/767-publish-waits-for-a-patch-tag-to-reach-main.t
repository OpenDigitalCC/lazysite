#!/usr/bin/perl
# SM1475: A STABLE PATCH TAG REACHES ORIGIN ONLY ONCE ITS COMMIT IS ON MAIN.
#
# `build --ref BRANCH` leaves the release commit and the tag on the patch branch.
# `publish` pushes main and the tag together and refuses while the tag's commit is not
# reachable from local main, so a stable tag never sits on origin ahead of main. After
# the merge build printed has landed (a branch from main merging the patch branch's new
# tip, landed by fast-forward), one publish pushes both; the patch branch is not pushed.
use strict;
use warnings;
use Test::More;
use File::Temp ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);
use ReleaseRig qw(spit slurp git rig_repo rig_release rig_receipt rig_notes rig_patch_branch);

plan skip_all => 'setsid missing' unless grep { -x "$_/setsid" } split /:/, $ENV{PATH};

sub remote_ref { my ( $r, $ref ) = @_; my $o = run_cmd( 'git', '-C', $r, 'rev-parse', '--verify', '--quiet', $ref ); chomp $o; $? ? '' : $o }

# A scratch repository with a bare origin that holds main, and a patch branch built on
# main's tip (its commits are already main's, as the 0.17.2 ones are) with the release on it.
my $d    = rig_repo();
my $r    = File::Temp::tempdir( CLEANUP => 1 );
git( $r, 'init', '-q', '--bare', '-b', 'main' );
git( $d, 'remote', 'add', 'origin', $r );
git( $d, 'push', '-q', 'origin', 'main:refs/heads/main' );    # the fixture, not the subject
my $origin_main = git( $d, 'rev-parse', 'main' );
my $tip = rig_patch_branch( $d, 'patch', from => 'main' );
rig_receipt( $d, sha => $tip, channel => 'stable', suite => 'patch (base v0.1.0, 2 files)', suite_base => 'v0.1.0' );
my ( $brc, $bout ) = rig_release( $d, {}, 'build', '0.1.1', '--notes', rig_notes(), '--final', '--ref', 'patch' );
is( $brc, 0, 'the patch is built on its branch' ) or BAIL_OUT($bout);
my $new_tip = git( $d, 'rev-parse', 'patch' );

sub publish { my $out = run_cmd( 'bash', "$d/tools/release.sh", 'publish', '0.1.1' ); return ( $? >> 8, $out ) }

subtest 'publish refuses while the tag is not reachable from main' => sub {
    my ( $rc, $out ) = publish();
    is( $rc, 1, 'refused' );
    like( $out, qr/v0\.1\.1 \(\w+\) is not on local main\./, 'saying so' );
    like( $out, qr/until the merge\nrelease\.sh: build printed has landed on main \(SM1475\); publish after that\./, 'and what to do' );
    is( remote_ref( $r, 'refs/tags/v0.1.1' ),  '',           'no tag on origin' );
    is( remote_ref( $r, 'refs/heads/main' ), $origin_main, 'main on origin is where it was' );
    is( remote_ref( $r, 'refs/heads/patch' ), '',           'the patch branch was not pushed either' );
};

subtest 'after the printed merge has landed, publish pushes main and the tag' => sub {
    my ( $branch, $path ) = $bout =~ m{worktree add -b (claude/land-v0\.1\.1) (\S+) };
    ok( $branch && $path, 'build printed the branch and the path' ) or return;
    git( $d, 'worktree', 'add', '-q', '-b', $branch, $path, $origin_main );
    git( $path, 'merge', '--no-edit', '-q', $new_tip );
    git( $d, 'merge', '--ff-only', '-q', $branch );    # the release manager's landing
    is( git( $d, 'rev-parse', 'main' ), git( $path, 'rev-parse', 'HEAD' ), 'main took the merge by fast-forward' );

    my ( $rc, $out ) = publish();
    is( $rc, 0, 'published' ) or return diag($out);
    my $tag = git( $d, 'rev-parse', 'v0.1.1^{commit}' );
    is( remote_ref( $r, 'refs/heads/main' ),        git( $d, 'rev-parse', 'main' ), 'origin\'s main is local main' );
    is( remote_ref( $r, 'refs/tags/v0.1.1^{commit}' ), $tag, 'and the tag is there' );
    run_cmd( 'git', '-C', $r, 'merge-base', '--is-ancestor', $tag, 'main' );
    is( $? >> 8, 0, 'on a commit reachable from origin\'s main' );
    is( remote_ref( $r, 'refs/heads/patch' ), '', 'the patch branch is not pushed' );
};

done_testing();
