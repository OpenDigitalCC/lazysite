#!/usr/bin/perl
# SM829: releasing the branch is part of saying READY, not a step afterwards.
#
# handoff.sh printed READY and left the branch checked out, and a human was then
# meant to remember two more things: return the worktree to main, and offer the
# branch. The gap between them is real enough that the REVIEW side defends
# against it - "checked out at /srv/projects/lazysite (in use): not offered" -
# and it was walked into by the author of the sentence describing the sequence,
# in the session that wrote it.
#
# Asserted by reading the script rather than by running it: a real run is the
# whole test suite plus coverage, and the property here is about what the script
# DOES on success, which is legible without paying for that.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
for my $f (qw(tools/handoff.sh tools/where.sh)) {
    ok( -x "$root/$f", "$f is executable" );
}

open my $fh, '<:utf8', "$root/tools/handoff.sh" or die $!;
my $src = do { local $/; <$fh> };
close $fh;

# --- READY and released are one act -----------------------------------------
like( $src, qr/git checkout "\$BASE"/,
    'a passing handoff returns the worktree to the base branch itself' );

# The checkout must sit INSIDE the success path - releasing a branch that failed
# its gates would be worse than not releasing one that passed.
my ($success) = $src =~ /if \[ "\$RC" -eq 0 \]; then(.*?)^else/ms;
ok( $success, 'found the success path' );
like( $success, qr/git checkout/, '...and the release happens inside it' );

# --- a branch that cannot be released is NOT ready --------------------------
# Saying READY about a branch still held by this worktree would be the same
# class of false report the gate exists to prevent.
like( $success, qr/RC=1/,
    'if the worktree cannot return to the base, the run reports NOT READY' );
like( $success, qr/still held/,
    '...and says why, rather than failing silently' );

# --- and it does not try to check out the base when already on it -----------
like( $success, qr/\[ "\$BRANCH" != "\$BASE" \]/,
    'a handoff run from the base branch does not check itself out' );

# --- where.sh reads and never writes ----------------------------------------
# Its whole value is being safe to run at any moment, including mid-release.
open my $wh, '<:utf8', "$root/tools/where.sh" or die $!;
my $where = do { local $/; <$wh> };
close $wh;

# Checked line by line, and only where a command is INVOKED. An earlier version
# of this matched the string "git checkout -b claude/<feature>" inside a printf
# that suggests it to the reader, and matched `2>/dev/null` as a file write - so
# it failed a script that was correct. The assertion has to know the difference
# between running a command and printing one.
my @writes;
my @redirects;
for my $line ( split /\n/, $where ) {
    next if $line =~ /^\s*#/;
    next if $line =~ /^\s*(?:printf|echo|say)\b/;    # printing a suggestion
    push @writes, $line
        if $line =~ /(?:^|[;&|(]|\$\()\s*git\s+(?:checkout|commit|rebase|reset|merge|push|rm|branch\s+-[dDmM])\b/;
    my $stripped = $line;
    $stripped =~ s{[12]?>>?\s*/dev/null}{}g;         # discarding output is not a write
    push @redirects, $line if $stripped =~ />>?\s*\S/;
}
is_deeply( \@writes, [], 'where.sh runs no git command that changes state' )
    or diag( join "\n", @writes );
is_deeply( \@redirects, [], 'and writes to no file' )
    or diag( join "\n", @redirects );

# It has to report the thing that was never looked at: MY OTHER unlanded work.
like( $where, qr/claude\/\*? ?branches ahead|other claude/,
    'where.sh reports other claude/* branches ahead of the base' );

done_testing();
