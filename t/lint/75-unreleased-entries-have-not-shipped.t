#!/usr/bin/perl
# An entry under ## Unreleased whose work has ALREADY shipped.
#
# THE HOLE THIS CLOSES, found on 2026-08-21 while cutting 0.10.22. The
# post-release pass COPIES an entry into the release section and stamps it with
# the commit. Four entries were copied and the originals left behind; six more
# were never copied at all. So `## Unreleased` accumulated ten entries
# describing work that had already shipped in 0.10.20 and 0.10.21 - and the
# 0.10.21 section described four fixes while its tag contained twelve.
#
# NOTHING COULD SEE IT. t/lint/53 ignores (PENDING) by design. t/lint/65 pins
# SHA-carrying entries to the section whose tag contains them, and separately
# refuses a (PENDING) entry INSIDE a released section - but `## Unreleased` is
# not a released section, so a pending entry could sit there through any number
# of releases. The next release to write a heading over that block would have
# claimed a dozen earlier fixes as its own, which is precisely the misreporting
# t/lint/62 was written for, one level deeper than it looks.
#
# TWO CHECKS, because the ten entries failed in two different ways:
#
#   DUPLICATE - the same bold title appears in a released section. The entry
#               was copied and the original left behind.
#   SHIPPED   - the entry names an SM whose work is in a release tag, and no
#               copy exists in any released section. It was never moved.
#
# The second is deliberately conservative: it matches the SM against commit
# SUBJECTS, and a filing can ship in one release while its fix ships in the
# next (SM434 did exactly that), so it only fires when NO entry for that SM
# exists in any released section at all.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
plan skip_all => 'not a git checkout - tags cannot be resolved here'
    unless system("git -C \Q$root\E rev-parse --git-dir >/dev/null 2>&1") == 0;

my @lines = split /\n/,
    do { open my $fh, '<', "$root/CHANGELOG.md" or die $!; local $/; <$fh> };

# Section boundaries. An entry ends at the next '- ' OR the next '## ' -
# whichever comes first. Omitting the second bound makes the LAST entry of a
# section swallow the following heading, which is a boundary fault this
# codebase has met more than once.
my ( $unrel, @heads );
for my $i ( 0 .. $#lines ) {
    next unless $lines[$i] =~ /^## /;
    push @heads, $i;
    $unrel = $i if $lines[$i] =~ /^##\s+Unreleased\s*$/;
}
plan skip_all => 'no ## Unreleased section' unless defined $unrel;
my ($next_head) = grep { $_ > $unrel } @heads;
$next_head //= scalar @lines;

sub entries_in {
    my ( $from, $to ) = @_;
    my @out;
    for my $i ( $from + 1 .. $to - 1 ) {
        next unless $lines[$i] =~ /^- /;
        my $e = $i + 1;
        $e++ while $e < $to && $lines[$e] !~ /^- / && $lines[$e] !~ /^## /;
        my $blob = join ' ', map { my $x = $_; $x =~ s/^\s+|\s+$//g; $x }
            @lines[ $i .. $e - 1 ];
        next unless $blob =~ /^- (SM\d+)\b/;
        my $sm = $1;
        next unless $blob =~ /\*\*(.+?)\*\*/;
        my $title = $1;
        ( my $key = lc $title ) =~ s/\W+//g;
        push @out, { sm => $sm, key => substr( $key, 0, 45 ), title => $title };
    }
    return @out;
}

my ( %released_key, %released_sm );
for my $j ( 0 .. $#heads ) {
    my $h = $heads[$j];
    next if $h <= $unrel;
    my $end = $j + 1 <= $#heads ? $heads[ $j + 1 ] : scalar @lines;
    for my $e ( entries_in( $h, $end ) ) {
        $released_key{ $e->{key} } = $lines[$h] =~ /^##\s+(\S+)/ ? $1 : '?';
        $released_sm{ $e->{sm} }   = 1;
    }
}

# Every SM whose WORK a release tag already contains.
#
# FILINGS DO NOT COUNT, and getting this wrong made the check's first run a
# false positive. A filing commit ("SM446: file - ...") ships in whatever cut
# happens to follow it, months before the fix; it carries no changelog entry
# and is not something a release announces. SM446 was filed in v0.10.21 and
# fixed for 0.10.22, which is the ordinary shape, not a fault.
my %shipped_sm;    # SM => [ tag, hash, hash, ... ] - every tagged commit
for my $tag ( grep { /\S/ } split /\n/, `git -C \Q$root\E tag --list 'v*.*.*'` ) {
    chomp $tag;
    for my $line ( split /\n/, `git -C \Q$root\E log --format='%H %s' \Q$tag\E` ) {
        my ( $h, $s ) = split / /, $line, 2;
        next unless defined $s && $s =~ /^(SM\d+)\b/;
        my $sm = $1;
        next if $s =~ /^SM\d+[^:]*:\s*file\b/i;
        $shipped_sm{$sm} //= [$tag];
        push @{ $shipped_sm{$sm} }, $h;
    }
}

# A commit is WORK when it touches anything outside docs/. SM438's landing
# found the subject convention above too narrow on its own: six investigation
# commits ("SM438: resolved as measured - ...", "SM438: WITHDRAW ...") sat
# under v0.10.27, none of them work a release should announce, and none spelt
# "file" after the colon. A filing or investigation commit is DEFINED by what
# it touches, not by what it says. Checked lazily, only for an SM about to be
# called stranded, so the tag walk above stays one pass.
sub touches_code {
    my (@hashes) = @_;
    for my $h (@hashes) {
        my @touched = grep { /\S/ } split /\n/,
            `git -C \Q$root\E show --name-only --format= \Q$h\E`;
        # CHANGELOG.md IS THE RECORD, NEVER THE WORK. The landing tool rebuilds
        # the changelog and amends it into whatever commit it is landing, so a
        # filing commit that touched one document arrives carrying CHANGELOG.md
        # too - and this then read it as work and called the SM shipped in that
        # release. SM597 was filed as a candidate under v0.10.33 and FIXED for
        # 0.11.0; without this it was refused as work stranded in 0.10.33. A
        # genuine work commit always touches something else as well, so nothing
        # is weakened by ignoring it.
        return 1 if grep { !m{^docs/} && $_ ne 'CHANGELOG.md' } @touched;
    }
    return 0;
}

my ( @dupes, @stranded );
for my $e ( entries_in( $unrel, $next_head ) ) {
    if ( my $sec = $released_key{ $e->{key} } ) {
        push @dupes, "$e->{sm} '$e->{title}' is already in $sec";
    }
    elsif ( $shipped_sm{ $e->{sm} } && !$released_sm{ $e->{sm} } ) {
        my ( $tag, @hashes ) = @{ $shipped_sm{ $e->{sm} } };
        push @stranded,
            "$e->{sm} shipped in $tag and no released section mentions it"
            if touches_code(@hashes);
    }
}

is( scalar @dupes, 0, 'no Unreleased entry duplicates one in a shipped section' )
    or diag( join "\n", @dupes,
    'The post-release pass COPIES rather than moves. The copy is stamped and '
        . 'the original stays behind - so the next release re-announces it.' );

is( scalar @stranded, 0, 'no Unreleased entry describes work already released' )
    or diag( join "\n", @stranded,
    'Its release said nothing about it, and the NEXT release would claim it.' );

done_testing();
