#!/usr/bin/perl
# SM354: a changelog commit ref must name a commit that exists, on a branch.
#
# This project's changelog convention makes the commit ref load-bearing. From
# the changelog's own preamble:
#
#   An item that SHIPPED in a release begins its own bullet and NAMES THE COMMIT
#   THAT IMPLEMENTED IT ... The commit ref is what marks it as built rather than
#   merely written down.
#
# So a ref that resolves to nothing is not a cosmetic slip - it is the evidence
# for "this shipped" having evaporated, in the one place a reader is told to
# look for it.
#
# WHY IT DRIFTS, and why a person cannot be relied on to prevent it. Work is done
# on a `claude/<feature>` branch and vcs-review lands it onto main BY REBASE,
# which gives every commit a new SHA. A ref written into the changelog while the
# branch is still a branch is therefore stale the moment it lands, and the old
# object survives in the reflog for a while - long enough for a spot check to
# pass and short enough to be gone when it matters.
#
# THIS HAS ALREADY HAPPENED, TWICE, AND THE SECOND TIME WAS PREDICTED BY THE
# FIRST. SM325 records it for TAGS: "0.10.10 was cut twice. The first tag named a
# branch tip; vcs-review then landed that branch onto main with new SHAs, and the
# tag was left pointing at a commit no branch contained." That filing fixed the
# tag half and nobody looked at the changelog, where the same rebase had left
# SEVEN refs in the 0.10.10 entry pointing at objects that no longer exist at
# all. Ten more were on no branch. 17 of 128 when this test was written.
#
# The rule that prevents it is not "be careful": write the ref AFTER the branch
# lands, exactly as SM325 concluded for tags - "tag AFTER the branch lands, not
# before".
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $changelog = "$root/CHANGELOG.md";
ok( -f $changelog, 'CHANGELOG.md is present' );

# A repository is needed to resolve anything. A tarball checkout legitimately
# has none, and skipping is right there - but it must SKIP, loudly, rather than
# pass on having checked nothing.
my $is_repo = system("git -C \Q$root\E rev-parse --git-dir >/dev/null 2>&1") == 0;
unless ($is_repo) {
    plan skip_all => 'not a git checkout - commit refs cannot be resolved here';
}

my $src = do { open my $fh, '<', $changelog or die $!; local $/; <$fh> };

# Refs appear as `- SM238 (37e7c37) ...` and occasionally as a pair,
# `- SM317 / SM319 (2258858, 8e2f1a4) ...`. Anchored on the bullet so a hex
# string in prose is not mistaken for one.
my @refs;
for my $line ( split /\n/, $src ) {
    next unless $line =~ /^\s*-\s/;
    next unless my ($group) = $line =~ /\(([0-9a-f]{7,40}(?:\s*,\s*[0-9a-f]{7,40})*)\)/;
    push @refs, grep { length } split /\s*,\s*/, $group;
}

cmp_ok( scalar @refs, '>', 20, 'the changelog names commits, and they were found' )
    or diag( 'If this drops to nothing the pattern has stopped matching and '
        . 'this test is checking an empty list - which would pass silently.' );

subtest 'every named commit exists' => sub {
    my @gone = grep {
        system("git -C \Q$root\E cat-file -e \Q$_\E 2>/dev/null") != 0
    } @refs;
    is_deeply( \@gone, [],
        'no changelog entry cites a commit that does not exist' )
        or diag( join "\n  ",
        '',
        @gone,
        '',
        'These were almost certainly written while the work was on a branch, '
            . 'and the rebase that landed it gave the commits new SHAs. Write '
            . 'the ref after the branch lands.' );
};

subtest 'every named commit is reachable from main' => sub {
    # ON A BRANCH IS NOT ENOUGH, and this is the gap that let a stale ref
    # through on 2026-08-21.
    #
    # This test's own header states the rule - write the ref AFTER the branch
    # lands, because vcs-review lands BY REBASE and the pre-landing SHA is
    # stale the moment it does. Four entries in the 0.10.22 section were
    # stamped while the work was still on its branch. Every one of those SHAs
    # still existed and every one was still "on a branch" - the pre-landing
    # `claude/*` branches had not been deleted - so both subtests above passed
    # while the section cited four commits that were nowhere in the history a
    # release is built from.
    #
    # It would have gone undetected until somebody deleted those branches, at
    # which point the refs go dangling in a section already published.
    #
    # A SHA-carrying entry claims the work has landed. `(PENDING)` is the
    # spelling for work still on a branch, and this check is what makes the
    # distinction mean something.
    my @unlanded = grep {
        system( "git -C \Q$root\E merge-base --is-ancestor \Q$_\E main"
                . " 2>/dev/null" ) != 0
    } grep {
        system("git -C \Q$root\E cat-file -e \Q$_\E 2>/dev/null") == 0
    } @refs;

    is_deeply( \@unlanded, [],
        'no changelog entry cites a commit that is not on main' )
        or diag( join "\n  ",
        '',
        @unlanded,
        '',
        'These exist and are on SOME branch, which is why the checks above '
            . 'passed. They are not on main. Almost certainly stamped before '
            . 'vcs-review landed the branch - landing rebases, so the ref '
            . 'changes. Use (PENDING) until it lands, then stamp.' );
};

subtest 'every named commit is on a branch' => sub {
    # Existing is not enough. A commit that survives only in the reflog is
    # unreachable from any history a reader can follow, and will be collected.
    # This is SM325's test for tags, applied to the other place a SHA is
    # recorded.
    my @orphan = grep {
        my $out = `git -C \Q$root\E branch --contains \Q$_\E 2>/dev/null`;
        ( $? == 0 && $out =~ /\S/ ) ? 0 : 1;
    } grep {
        system("git -C \Q$root\E cat-file -e \Q$_\E 2>/dev/null") == 0
    } @refs;

    is_deeply( \@orphan, [],
        'no changelog entry cites a commit that no branch contains' )
        or diag( join "\n  ",
        '',
        @orphan,
        '',
        'A ref no branch contains is a release whose provenance cannot be '
            . 'followed from any history, and the object goes away when the '
            . 'reflog expires. SM325 says the same thing about tags.' );
};

done_testing();
