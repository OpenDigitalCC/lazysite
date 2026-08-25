#!/usr/bin/perl
# Review D2: perltidy gate, CHANGED-CODE-ONLY. The existing tree keeps its
# hand-formatting; tools/tidy-check.pl flags only lines a change touched (since
# the last release tag) that are not in the .perltidyrc canonical form. Skips
# cleanly when perltidy or git is unavailable (e.g. a release tarball).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $tc   = "$root/tools/tidy-check.pl";

ok( -f $tc, 'tidy-check.pl present' );

my $out = `$^X \Q$tc\E 2>&1`;
my $rc  = $? >> 8;

if ( $out =~ /SKIP/ ) {
    diag($out);
    # SM599: A SKIP IS ONLY ACCEPTABLE WHERE THE TOOL GENUINELY CANNOT RUN -
    # a release tarball with no git, or a host with no perltidy. Where both
    # ARE present the tool must examine something, and for a long time it did
    # not: it tested for a .git DIRECTORY, a linked worktree has a .git FILE,
    # and every gate runs in a worktree. So this lint passed without looking
    # at a line, and the first thing to notice was a release build refusing
    # nine minutes in. A skip that happens where the tool could have run is a
    # failure now, because the alternative is a gate that cannot fail.
    my $have_git  = -e "$root/.git";                          # -e: a worktree's is a FILE
    my $have_tidy = `sh -c 'command -v perltidy' 2>/dev/null`;
    if ( $have_git && length($have_tidy) ) {
        fail("the tidy gate skipped in a tree where it could have run: $out");
    }
    else {
        ok( 1, 'tidy gate skipped (no perltidy/git or no base tag)' );
    }
}
else {
    is( $rc, 0, 'all code changed since the last release is perltidy-clean' )
        or diag($out);
}

done_testing();
