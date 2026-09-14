#!/usr/bin/perl
# SM829 item 3: tools/commit-staged.sh reports what landed, and only what landed.
#
# The slips it answers were a commit reported that never happened and a commit
# made over a failed lint - both from reading the last command's output in a
# chain and taking it for the first one's. So the helper's whole job is that its
# word and its exit status are about the commit: COMMITTED with the SHA that is
# now HEAD, or NOT COMMITTED with a non-zero exit that stops anything chained.
#
# Run for real, in a scratch repository with the helper copied in, so a hook can
# refuse and an empty index can be tried without touching this one.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_cmd);

my $repo = site_tempdir( leaf => 'repo' );
make_path("$repo/tools");
copy( repo_root() . '/tools/commit-staged.sh', "$repo/tools/commit-staged.sh" ) or die $!;
chmod 0755, "$repo/tools/commit-staged.sh";

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub git { return run_cmd( 'git', '-C', $repo, @_ ) }

git( 'init',   '-q',         '-b', 'claude/x' );
git( 'config', 'user.email', 't@example.test' );
git( 'config', 'user.name',  'T' );
# SM880: the helper now requires the provenance trailer, so every fixture
# message carries one. This file is about what the helper REPORTS; the trailer
# rules themselves are driven in t/tools/76.
spit( "$repo/msg.txt",
    "the subject line\n\nbody\n\nAssisted-by: Claude:claude-opus-5[1m]\n" );
spit( "$repo/a.txt",   "one\n" );
git( 'add', 'tools/commit-staged.sh', 'a.txt' );

sub helper {
    my $out = run_cmd( 'bash', "$repo/tools/commit-staged.sh", @_ );
    return ( $? >> 8, $out );
}

subtest 'a commit that lands is reported as what landed' => sub {
    my ( $rc, $out ) = helper("$repo/msg.txt");
    is( $rc, 0, 'exit 0' ) or diag $out;
    my $head = git( 'log', '-1', '--format=%h' );
    chomp $head;
    like( $out, qr/^COMMITTED \Q$head\E the subject line on claude\/x$/m,
        'naming the SHA that is now HEAD, its subject and the branch' );
};

subtest 'nothing staged is not a commit' => sub {
    my ( $rc, $out ) = helper("$repo/msg.txt");
    is( $rc, 1, 'a non-zero exit, so nothing chained after it runs' );
    like( $out, qr/NOT COMMITTED on claude\/x: nothing is staged/, 'and it says why' );
    unlike( $out, qr/^COMMITTED/m, 'and never the word that means it did' );
};

subtest 'a hook that refuses is not a commit' => sub {
    spit( "$repo/.git/hooks/pre-commit", "#!/bin/sh\necho 'HOOK: refusing this commit'\nexit 1\n" );
    chmod 0755, "$repo/.git/hooks/pre-commit";
    spit( "$repo/b.txt", "two\n" );
    git( 'add', 'b.txt' );
    my $before = git( 'rev-parse', 'HEAD' );
    my ( $rc, $out ) = helper("$repo/msg.txt");
    is( $rc, 1, 'a non-zero exit' );
    like( $out, qr/HOOK: refusing this commit/, 'the refusal is shown, not swallowed' );
    like( $out, qr/NOT COMMITTED on claude\/x: git commit exited 1 and HEAD is still/, 'and named for what it is' );
    is( git( 'rev-parse', 'HEAD' ), $before, 'and HEAD did not move' );
    unlink "$repo/.git/hooks/pre-commit";
};

subtest 'work left out of the commit is pointed out' => sub {
    spit( "$repo/b.txt", "two, edited after staging\n" );
    my ( $rc, $out ) = helper("$repo/msg.txt");
    is( $rc, 0, 'the staged version commits' ) or diag $out;
    like( $out, qr/unstaged changes remain - they are not in this commit/, 'and the edit that was not staged is named' );
};

subtest 'the message comes from a file' => sub {
    my ( $rc, $out ) = helper('an inline message');
    is( $rc, 2, 'a message that is not a file is a usage error' );
    like( $out, qr/usage: tools\/commit-staged\.sh MESSAGE-FILE/, 'saying so' );
};

done_testing();
