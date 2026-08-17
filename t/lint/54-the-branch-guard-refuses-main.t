#!/usr/bin/perl
# SM357: a hook that refuses a commit on an integration branch.
#
# THE CONTRACT EXISTED AND WAS NOT FOLLOWED. Work is supposed to happen on a
# `claude/<feature>` branch that vcs-review lands onto main, so the release
# manager reads a change before it is tagged. In one session roughly thirty
# commits went straight onto main and the first anyone saw of them was a
# release - including two defects (SM343, and the basis-stamp asymmetry) that
# were discoverable from a diff and instead cost a release cycle each.
#
# The failure is the absence of a moment rather than carelessness. Nothing about
# committing to main asks anything of you: it is the same command, and the
# branch you are on is a fact you have to go and look at.
#
# WHAT THIS TEST IS FOR. The hook is bypassable on purpose - a hook that cannot
# be bypassed in an emergency gets uninstalled instead - so what must be
# guaranteed is narrower than "main is protected": the refusal must actually
# fire, the escape hatch must actually work, and NEITHER may break the workflow
# the hook exists to protect. A guard that blocked vcs-review's own rebase would
# be removed within the hour and the contract would be back to being a habit.
#
# Driven by running the hook, not by reading it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $hook = repo_root() . '/githooks/pre-commit';
ok( -f $hook, 'the hook is present' );
ok( -x $hook, 'and executable' );

my $installer = repo_root() . '/scripts/install-hooks.sh';
ok( -f $installer, 'the installer that enables it is present' );

# Run the hook inside a throwaway repository on a named branch, optionally with
# an in-progress operation marker or the override set. Returns the exit status.
sub hook_says {
    my (%o) = @_;
    my $dir = File::Temp::tempdir( CLEANUP => 1 );
    system("git -C \Q$dir\E init -q 2>/dev/null") == 0 or return -1;
    system("git -C \Q$dir\E symbolic-ref HEAD refs/heads/\Q$o{branch}\E") == 0
        or return -1;

    if ( $o{marker} ) {
        my $gd = "$dir/.git";
        if   ( $o{marker} =~ /^rebase/ ) { mkdir "$gd/$o{marker}" }
        else                             { open my $fh, '>', "$gd/$o{marker}"; close $fh }
    }

    local $ENV{LAZYSITE_ALLOW_COMMIT_ON_MAIN} = $o{override} ? 1 : '';
    delete $ENV{LAZYSITE_ALLOW_COMMIT_ON_MAIN} unless $o{override};

    my $rc = system("cd \Q$dir\E && \Q$hook\E >/dev/null 2>&1");
    return $rc >> 8;
}

require File::Temp;

subtest 'the branch is resolved on a repo with no commits' => sub {
    # This is how the fail-open path was found. The guard used
    # `rev-parse --abbrev-ref HEAD`, which resolves HEAD as a REVISION and so
    # fails on a branch with no commits - the branch came back empty, matched
    # nothing, and the commit was allowed. A fresh repository is the case where
    # a guard against committing to main matters least and the bug showed most.
    isnt( hook_says( branch => 'main' ), 0,
        'an unborn main is still main' )
        or diag( 'symbolic-ref reads the ref HEAD points at without resolving '
            . 'it, which answers on an unborn branch. rev-parse does not.' );
};

subtest 'it refuses the branches a release is cut from' => sub {
    for my $b (qw(main master integration)) {
        isnt( hook_says( branch => $b ), 0, "a commit on '$b' is refused" )
            or diag( 'The whole point is that the wrong path is loud at the '
                . 'moment it is taken, not at review.' );
    }
};

subtest 'and allows everything else' => sub {
    for my $b (qw(claude/sm357-branch-guard claude/anything feature/x mainline)) {
        is( hook_says( branch => $b ), 0, "a commit on '$b' is allowed" )
            or diag( "'mainline' is in this list on purpose: a prefix match "
                . 'would refuse it, and refusing a branch nobody asked to '
                . 'protect is how a guard gets uninstalled.' );
    }
};

subtest 'it does not break the workflow it exists to protect' => sub {
    # vcs-review lands a branch onto main BY REBASE, which commits onto main by
    # definition. A guard that refused that would block the only sanctioned
    # route onto main - protecting the branch from the process that is allowed
    # to change it.
    for my $marker (qw(rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD BISECT_LOG)) {
        is( hook_says( branch => 'main', marker => $marker ), 0,
            "an in-progress $marker commits onto main without complaint" )
            or diag( 'A rebase, merge, cherry-pick or bisect legitimately '
                . 'replays commits onto the branch it is replaying.' );
    }
};

subtest 'the escape hatch works, and is explicit' => sub {
    # Deliberately bypassable. The control that actually holds is that main only
    # advances through review; this makes the wrong path loud rather than
    # impossible, and a hook that cannot be bypassed gets deleted instead.
    is( hook_says( branch => 'main', override => 1 ), 0,
        'the override lets a deliberate commit through' );

    my $src = do { open my $fh, '<', $hook or die $!; local $/; <$fh> };
    like( $src, qr/LAZYSITE_ALLOW_COMMIT_ON_MAIN/,
        'and it is named in the refusal message, so it is discoverable' );
    like( $src, qr/git switch -c/,
        'the refusal says how to move the work rather than only that it is wrong' )
        or diag( 'A refusal that does not say what to do next gets bypassed on '
            . 'reflex, which trains the reflex.' );
    like( $src, qr/nothing has been committed/,
        'and says the work is not lost - the first fear a refusal creates' );
};

done_testing();
