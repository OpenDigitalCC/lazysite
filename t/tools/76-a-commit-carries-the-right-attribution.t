#!/usr/bin/perl
# SM880: tools/commit-staged.sh refuses the wrong attribution trailer.
#
# /srv/projects/rules/git.md has required `Assisted-by:` and forbidden
# `Co-Authored-By:` since 15 July 2026, and states outright that the harness
# prints the old trailer in its own guidance and that the rule overrides it.
#
# THAT WAS TRUE AND IT WAS NOT ENOUGH. On 14 Sept 2026 the harness issued
# mid-session instructions to use Co-Authored-By, presented as replacing all
# earlier attribution guidance. Nothing in the repository would have caught it;
# only reading the history and noticing the discrepancy did, and the release
# manager's answer was to make the rule enforceable rather than better written.
#
# WHY REFUSE RATHER THAN WARN. It is a legal position, not a style preference:
# an AI cannot hold copyright, certify the DCO or sign a CLA, so
# `Co-Authored-By:` puts part of the contribution outside the signatory's
# warranty while weakening the human's own rights claim. A warning on a commit
# that already landed is a rewrite; a refusal before it lands is an edit.
#
# The script is DRIVEN, in a throwaway repository, because this is about what
# the command does - a source check would pass on any file mentioning the words.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $src = repo_root() . '/tools/commit-staged.sh';
plan skip_all => "no $src" unless -f $src;

# The script's first act is `cd "$(dirname "$0")/.."` - it always operates on
# the repository it lives in, and resolves the message path from there. So it is
# COPIED into the throwaway repo rather than pointed at it: run from outside, it
# would commit into the real lazysite tree. (That cd is deliberate and right; it
# is why the tool can be invoked from anywhere.)
my $d = tempdir( CLEANUP => 1 );
mkdir "$d/tools" or die $!;
my $tool = "$d/tools/commit-staged.sh";
do {
    open my $in,  '<', $src  or die $!;
    open my $out, '>', $tool or die $!;
    local $/;
    print {$out} <$in>;
};
chmod 0o755, $tool;

sub sh {
    my ($cmd) = @_;
    return scalar `cd \Q$d\E && $cmd 2>&1`;
}

sub w {
    my ( $p, $t ) = @_;
    open my $fh, '>', "$d/$p" or die $!;
    print {$fh} $t;
    close $fh;
}

sh('git init -q .');
sh('git config user.email t@example.invalid');
sh('git config user.name Tester');
sh('git config commit.gpgsign false');

# A commit to attempt, staged fresh before each try.
sub stage {
    my ($n) = @_;
    w( "file$n.txt", "content $n\n" );
    sh("git add file$n.txt");
}

sub head_count {
    my $n = sh('git rev-list --count HEAD 2>/dev/null') // '';
    chomp $n;
    return $n =~ /^\d+$/ ? $n : 0;
}

my $ASSISTED = "Assisted-by: Claude:claude-opus-5[1m]\n"
    . "Claude-Session: https://example.invalid/session\n";

# --- the trailer the harness asks for is refused -----------------------------
stage(1);
w( 'msg.txt', "Add a thing\n\nWhy it is right.\n\n"
        . "Co-Authored-By: Claude Opus 5 <noreply\@anthropic.com>\n" );
my $before = head_count();
my $out    = sh("bash \Q$tool\E msg.txt");
is( head_count(), $before, 'a Co-Authored-By trailer does not produce a commit' )
    or diag('The commit landed. The trailer is a rights claim, not a style choice.');
like( $out, qr/NOT COMMITTED/, 'and the refusal says so plainly' );
like( $out, qr/Assisted-by/,
    'and names the trailer to use instead, so the fix needs no lookup' );
like( $out, qr/overrides it/,
    'and says the project rule beats whatever tool asked for the other one' )
    or diag( 'Without this the next reader assumes the harness is authoritative '
        . 'and edits the rule to match, which is the failure this prevents.' );

# --- a message with no provenance at all is refused --------------------------
w( 'msg.txt', "Add a thing\n\nWhy it is right.\n" );
$before = head_count();
$out    = sh("bash \Q$tool\E msg.txt");
is( head_count(), $before, 'a message with no Assisted-by trailer does not commit' );
like( $out, qr/Assisted-by: Claude:/,
    'and prints the exact line to add' );

# --- the correct trailer commits ---------------------------------------------
w( 'msg.txt', "Add a thing\n\nWhy it is right.\n\n$ASSISTED" );
$out = sh("bash \Q$tool\E msg.txt");
is( head_count(), 1, 'the right trailer commits normally' )
    or diag("guard refused a valid message:\n$out");
like( $out, qr/COMMITTED/, 'and reports what landed' );

# --- the check is on the TRAILER, not the word anywhere ----------------------
#
# A commit that DISCUSSES the forbidden trailer - this one does, and so does the
# script - must still be committable. A bare substring search would refuse the
# very change that introduced the rule, and the next person would weaken the
# check to get their work in.
stage(2);
w( 'msg.txt', "Explain the attribution rule\n\n"
        . "The body mentions Co-Authored-By: as the thing NOT to use, which is\n"
        . "exactly what a commit documenting the rule has to be able to say.\n\n"
        . $ASSISTED );
$out = sh("bash \Q$tool\E msg.txt");
is( head_count(), 2, 'a message DISCUSSING the forbidden trailer mid-line still commits' )
    or diag( "The guard matched the word rather than the trailer:\n$out\n"
        . 'It anchors to the start of a line for this reason.' );

done_testing();
