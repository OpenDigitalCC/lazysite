#!/usr/bin/perl
# tools/confirm-register.pl - the release manager's one confirmation of a drafted
# security-register entry (SM1454 R4).
#
#   tools/release.sh confirm-register SMNNNN --ruling N [--date YYYY-MM-DD]
#   perl tools/confirm-register.pl [--repo DIR] SMNNNN --ruling N [--date YYYY-MM-DD]
#
# A patch carries its fix, its docs/SECURITY.md register entry and its compliance
# stamps on ONE branch. The developer agent drafts the entry and says so, in the
# words the compliance check looks for:
#
#   Assessment drafted by the developer agent (nNNN); awaiting the release manager's confirmation.
#   verdict : accepted, awaiting the release manager's confirmation. ...
#
# The compliance check passes such an entry (advisory below certified, ADR 0010,
# where it blocks) and names it. The release manager lands the branch and runs this
# once, on main: every entry whose heading names SMNNNN has each "awaiting the
# release manager's confirmation" rewritten to "confirmed by the release manager on
# D Mon YYYY (ruling N)" - the wording every confirmed entry has - and the one file
# is committed. There is no second branch round.
#
# Refuses, changing nothing, when: no entry names the SM number; none of its
# entries is awaiting confirmation (already confirmed, or never drafted); the
# checkout is not on main; docs/SECURITY.md has uncommitted changes.
use strict;
use warnings;
use File::Basename qw(dirname);
use FindBin;
use File::Temp qw(tempfile);
use POSIX      qw(strftime);

# Every refusal is a die; one clean exit status (1) for the release manager's shell.
BEGIN { $SIG{__DIE__} = sub { return if $^S; print STDERR @_; exit 1 } }

my $MARK = "awaiting the release manager's confirmation";
my @MON  = qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);

my ( $repo, $sm, $ruling, $date ) = ( dirname($FindBin::Bin) );
while (@ARGV) {
    my $a = shift @ARGV;
    if    ( $a eq '--repo' )                  { $repo   = shift @ARGV }
    elsif ( $a eq '--ruling' )                { $ruling = shift @ARGV }
    elsif ( $a eq '--date' )                  { $date   = shift @ARGV }
    elsif ( $a =~ /^SM\d+$/ && !defined $sm ) { $sm     = $a }
    else { die "confirm-register: unknown argument '$a'\nusage: confirm-register SMNNNN --ruling N [--date YYYY-MM-DD]\n" }
}
die "confirm-register: say which entry: SMNNNN\n" unless defined $sm;
die "confirm-register: --ruling N is needed - the confirmation is recorded with its ruling\n"
    unless defined $ruling && $ruling =~ /^\d+$/;
$date //= strftime( '%Y-%m-%d', gmtime );
my ( $y, $m, $d ) = $date =~ /^(\d{4})-(\d\d)-(\d\d)$/ or die "confirm-register: --date wants YYYY-MM-DD, not '$date'\n";
die "confirm-register: --date '$date' is not a month\n" unless $m >= 1 && $m <= 12;
my $said = sprintf 'confirmed by the release manager on %d %s %d (ruling %d)', $d, $MON[ $m - 1 ], $y, $ruling;

sub git {
    my @cmd = ( 'git', '-C', $repo, @_ );
    open my $p, '-|', @cmd or die "confirm-register: cannot run git: $!\n";
    local $/;
    my $out = <$p>;
    close $p or die "confirm-register: git @_ failed\n";
    $out //= '';
    $out =~ s/\n\z//;
    return $out;
}

my $branch = eval { git( 'symbolic-ref', '--short', 'HEAD' ) } // '';
die "confirm-register: run it on main - $repo is on '" . ( length $branch ? $branch : 'a detached HEAD' ) . "'\n"
    unless $branch eq 'main';
my $file = "$repo/docs/SECURITY.md";
die "confirm-register: $file is missing\n" unless -f $file;
die "confirm-register: docs/SECURITY.md has uncommitted changes; commit or move them first\n"
    if length git( 'status', '--porcelain', '--', 'docs/SECURITY.md' );

open my $in, '<', $file or die "confirm-register: $file: $!\n";
local $/;
my $text = <$in>;
close $in;

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

open my $out, '>', $file or die "confirm-register: $file: $!\n";
print {$out} join '', @parts;
close $out or die "confirm-register: $file: $!\n";

my ( $mf, $msg ) = tempfile( 'confirm-register-XXXXXX', TMPDIR => 1, UNLINK => 1 );
print {$mf} "$sm: register entry confirmed by the release manager (ruling $ruling)\n\n"
    . "docs/SECURITY.md: $changed marker" . ( $changed == 1 ? '' : 's' ) . " in " . scalar(@heads) . " entr"
    . ( @heads == 1 ? 'y' : 'ies' ) . " rewritten to \"$said\".\n";
close $mf or die "confirm-register: $msg: $!\n";
my $rc = system( 'git', '-C', $repo, 'commit', '-q', '-F', $msg, '--', 'docs/SECURITY.md' );
die "confirm-register: git commit failed; docs/SECURITY.md is changed in the working tree\n" if $rc;
print "confirm-register: $sm - $changed marker" . ( $changed == 1 ? '' : 's' ) . " confirmed ($said), committed "
    . substr( git( 'rev-parse', 'HEAD' ), 0, 12 ) . "\n";
print "confirm-register:   $_\n" for @heads;
exit 0;
