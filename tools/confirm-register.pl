#!/usr/bin/perl
# tools/confirm-register.pl - one confirmation of a drafted security-register entry,
# made on a branch (SM1454 R4, R6 d).
#
#   tools/release.sh confirm-register SMNNNN --ruling N [--date YYYY-MM-DD] [--trailer TEXT]...
#   perl tools/confirm-register.pl [--repo DIR] SMNNNN --ruling N [--date YYYY-MM-DD] [--trailer TEXT]...
#
# A patch carries its fix, its docs/SECURITY.md register entry and its compliance
# stamps on ONE branch. The developer agent drafts the entry and says so, in the
# words the compliance check looks for:
#
#   Assessment drafted by the developer agent (nNNN); awaiting the release manager's confirmation.
#   verdict : accepted, awaiting the release manager's confirmation. ...
#
# The compliance check passes such an entry (advisory below certified, ADR 0010,
# where it blocks) and names it. When the release manager has ruled, the DEVELOPER
# AGENT runs this once, with the ruling's number: every entry in main's
# docs/SECURITY.md whose heading names SMNNNN has each "awaiting the release
# manager's confirmation" rewritten to "confirmed by the release manager on
# D Mon YYYY (ruling N)" - the wording every confirmed entry has - and that one file
# is committed on a NEW BRANCH, claude/confirm-SMNNNN, cut from main and held for
# vcs-review (refs/vcs-review/hold/claude/confirm-SMNNNN). The branch is printed:
# that is what lands. An agent cannot commit on main, and nobody has to.
#
# THE BRANCH IS MADE IN A WORKTREE under tmp/, not in the checkout. The checkout is
# the shared tree: often on another branch, sometimes holding uncommitted work, and
# switching it to cut a branch would move all of that. The worktree is made from
# main, committed in and removed; the branch stays.
#
# Refuses, changing nothing, when: there is no main; no entry names the SM number;
# none of its entries is awaiting confirmation (already confirmed, or never
# drafted); the branch or its worktree path already exists.
use strict;
use warnings;
use File::Basename qw(dirname);
use FindBin;
use File::Temp qw(tempfile);
use POSIX      qw(strftime);

# Every refusal is a die; one clean exit status (1) for the caller's shell.
BEGIN { $SIG{__DIE__} = sub { return if $^S; print STDERR @_; exit 1 } }

my $MARK = "awaiting the release manager's confirmation";
my @MON  = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

my ( $repo, $sm, $ruling, $date, @trailer ) = ( dirname($FindBin::Bin) );
while (@ARGV) {
    my $a = shift @ARGV;
    if    ( $a eq '--repo' )                  { $repo   = shift @ARGV }
    elsif ( $a eq '--ruling' )                { $ruling = shift @ARGV }
    elsif ( $a eq '--date' )                  { $date   = shift @ARGV }
    elsif ( $a eq '--trailer' )               { push @trailer, shift @ARGV }
    elsif ( $a =~ /^SM\d+$/ && !defined $sm ) { $sm = $a }
    else {
        die "confirm-register: unknown argument '$a'\n"
            . "usage: confirm-register SMNNNN --ruling N [--date YYYY-MM-DD] [--trailer TEXT]...\n";
    }
}
die "confirm-register: say which entry: SMNNNN\n" unless defined $sm;
die "confirm-register: --ruling N is needed - the confirmation is recorded with its ruling\n"
    unless defined $ruling && $ruling =~ /^\d+$/;
$date //= strftime( '%Y-%m-%d', gmtime );
my ( $y, $m, $d ) = $date =~ /^(\d{4})-(\d\d)-(\d\d)$/ or die "confirm-register: --date wants YYYY-MM-DD, not '$date'\n";
die "confirm-register: --date '$date' is not a month\n" unless $m >= 1 && $m <= 12;
my $said = sprintf 'confirmed by the release manager on %d %s %d (ruling %d)', $d, $MON[ $m - 1 ], $y, $ruling;

sub git_raw {
    my @cmd = ( 'git', '-C', $repo, @_ );
    open my $p, '-|', @cmd or die "confirm-register: cannot run git: $!\n";
    local $/;
    my $out = <$p>;
    close $p or die "confirm-register: git @_ failed\n";
    return $out // '';
}

sub git {
    my $out = git_raw(@_);
    $out =~ s/\n\z//;
    return $out;
}

# main's committed register, whatever the checkout is on or holds.
die "confirm-register: $repo has no branch main to cut the confirmation from\n"
    unless eval { git( 'rev-parse', '--verify', '--quiet', 'refs/heads/main' ) };
my $branch = "claude/confirm-$sm";
die "confirm-register: branch $branch already exists - land it, or delete it if it was abandoned\n"
    if eval { git( 'rev-parse', '--verify', '--quiet', "refs/heads/$branch" ) };
my $wt = "$repo/tmp/wt-confirm-$sm";
die "confirm-register: $wt already exists - remove that worktree (git worktree remove) and run it again\n"
    if -e $wt;

my $text  = git_raw( 'show', 'main:docs/SECURITY.md' );
my @parts = split /(?=^### )/m, $text;
my ( $named, $changed, @heads ) = ( 0, 0 );
for my $part (@parts) {
    my ($head) = $part =~ /\A(### [^\n]*)/ or next;
    next unless $head =~ /\b\Q$sm\E\b/;
    $named++;
    my $n = ( $part =~ s/\Q$MARK\E/$said/g );
    next unless $n;
    $changed += $n;
    push @heads, $head;
}
die "confirm-register: no entry in docs/SECURITY.md names $sm\n" unless $named;
die "confirm-register: the $named entr" . ( $named == 1 ? 'y' : 'ies' ) . " naming $sm has nothing \"$MARK\" - already confirmed, or never drafted\n"
    unless $changed;

# Nothing has been changed so far. From here a failure names what it left behind.
my $rc = system( 'git', '-C', $repo, 'worktree', 'add', '-q', '-b', $branch, $wt, 'main' );
die "confirm-register: git worktree add $wt failed\n" if $rc;
my $file = "$wt/docs/SECURITY.md";
open my $out, '>', $file or die "confirm-register: $file: $!; $wt and branch $branch are left as they are\n";
print {$out} join '', @parts;
close $out or die "confirm-register: $file: $!; $wt and branch $branch are left as they are\n";

my ( $mf, $msg ) = tempfile( 'confirm-register-XXXXXX', TMPDIR => 1, UNLINK => 1 );
print {$mf} "$sm: register entry confirmed by the release manager (ruling $ruling)\n\n"
    . "docs/SECURITY.md: $changed marker" . ( $changed == 1 ? '' : 's' ) . " in " . scalar(@heads) . " entr"
    . ( @heads == 1 ? 'y' : 'ies' ) . " rewritten to \"$said\".\n"
    . ( @trailer    ? "\n" . join( "\n", @trailer ) . "\n" : '' );
close $mf or die "confirm-register: $msg: $!\n";
$rc = system( 'git', '-C', $wt, 'commit', '-q', '-F', $msg, '--', 'docs/SECURITY.md' );
die "confirm-register: git commit failed; $wt and branch $branch are left as they are\n" if $rc;
my $tip = git( 'rev-parse', "refs/heads/$branch" );

# Held for vcs-review, as every branch a developer hands over is.
$rc = system( 'git', '-C', $repo, 'update-ref', "refs/vcs-review/hold/$branch", $tip );
die "confirm-register: git update-ref refs/vcs-review/hold/$branch failed; branch $branch is committed at $tip\n" if $rc;
$rc = system( 'git', '-C', $repo, 'worktree', 'remove', $wt );
die "confirm-register: branch $branch is committed and held; git worktree remove $wt failed\n" if $rc;

print "confirm-register: $sm - $changed marker" . ( $changed == 1 ? '' : 's' ) . " confirmed ($said)\n";
print "confirm-register:   $_\n" for @heads;
print "confirm-register: branch $branch at " . substr( $tip, 0, 12 ) . ", held for vcs-review - land it\n";
exit 0;
