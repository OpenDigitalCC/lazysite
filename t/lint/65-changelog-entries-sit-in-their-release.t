#!/usr/bin/perl
# The changelog's structure is load-bearing, and merge=union quietly breaks it.
#
# CHANGELOG.md merges with the union driver so parallel branch landings never
# conflict - but each branch brings its own copy of the "## Unreleased"
# heading, and by 0.10.16 the file had accumulated NINE of them. Two entries
# (SM383, SM384) shipped in 0.10.15 yet sat above the live Unreleased heading
# through two releases: misfiled reads as shipped-and-recorded while being
# neither, which is worse than absent - absent gets noticed. A partner agent
# reading the deployed changelog found the missing 0.10.16 heading; cleaning
# that up surfaced the strays; this lint keeps both from coming back.
#
# Two properties:
#   1. Exactly ONE "## Unreleased" heading.
#   2. Every entry bearing a commit SHA sits in the section whose TAG contains
#      it: an ancestor of that release's tag and not of the previous release's.
#      Entries under Unreleased must not be inside any release tag that has a
#      section. (Ancestry is the same test the 0.10.16 repair used - position
#      between headings is exactly what the strays made unreliable.)
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
# -e not -d: a git WORKTREE has a .git file, and this lint must run there too
# (the first version used -d and silently skipped in every worktree).
plan skip_all => 'needs a git checkout with tags'
    unless -e "$root/.git" && `git -C \Q$root\E tag -l 'v*'` =~ /\S/;

my $log = do { open my $fh, '<', "$root/CHANGELOG.md" or die $!; local $/; <$fh> };

# --- 1. one Unreleased heading ------------------------------------------------
my @unreleased = ( $log =~ /^(## Unreleased)\s*$/mg );
is( scalar @unreleased, 1,
    'exactly one "## Unreleased" heading - union-merge strays get removed at '
        . 'release prep, not accumulated' );

# --- 2. every SHA'd entry is in the right section -----------------------------
# Parse (section, sha) pairs. A section is Unreleased or a version heading.
my @pairs;
my $section = '';
for my $line ( split /\n/, $log ) {
    if    ( $line =~ /^## Unreleased\s*$/ )   { $section = 'unreleased' }
    elsif ( $line =~ /^## (\d+\.\d+\.\d+) / ) { $section = $1 }
    elsif ( $line =~ /^## / )                 { $section = '' }
    elsif ( length $section && $line =~ /^- \S.*?\(([0-9a-f]{7,40})[,)]/ ) {
        push @pairs, [ $section, $1 ];
    }
}
ok( @pairs > 10, 'found SHA-carrying entries to check (sanity)' );

my %tag_exists = map { $_ => 1 } split /\n/, `git -C \Q$root\E tag -l 'v*'`;

sub in_tag {
    my ( $sha, $tag ) = @_;
    return 0 unless $tag_exists{$tag};
    return system("git -C \Q$root\E merge-base --is-ancestor $sha $tag 2>/dev/null") == 0;
}

# Version list in file order (newest first), for previous-tag lookups.
my @versions = ( $log =~ /^## (\d+\.\d+\.\d+) /mg );

my @wrong;
for my $p (@pairs) {
    my ( $sec, $sha ) = @$p;

    # A SHA the repo does not have (squashed history, other remote) is
    # t/lint/53's business, not this lint's - skip, never fail.
    next if system("git -C \Q$root\E cat-file -e $sha^{commit} 2>/dev/null") != 0;

    if ( $sec eq 'unreleased' ) {
        # Must not be inside the NEWEST tag that has a section.
        my ($newest) = @versions;
        push @wrong, "$sha listed Unreleased but ships in v$newest"
            if defined $newest && in_tag( $sha, "v$newest" );
    }
    else {
        push @wrong, "$sha listed under $sec but is not in v$sec"
            if $tag_exists{"v$sec"} && !in_tag( $sha, "v$sec" );
        # And not in the PREVIOUS release either (else it belongs there).
        my ($i) = grep { $versions[$_] eq $sec } 0 .. $#versions;
        my $prev = defined $i ? $versions[ $i + 1 ] : undef;
        push @wrong, "$sha listed under $sec but already shipped in v$prev"
            if defined $prev && in_tag( $sha, "v$prev" );
    }
}
is( scalar @wrong, 0, 'every SHA-carrying entry sits in the section whose tag contains it' )
    or diag join "\n", @wrong;

# --- 3. a (PENDING) entry belongs under Unreleased ---------------------------
#
# SM423 found the gap this closes, in a lint written for exactly this class:
# check 2 above pins entries that carry a SHA and says NOTHING about the ones
# that do not. t/lint/53 also ignores (PENDING) by design. So a PENDING entry
# misfiled into a released section was invisible to both - and "misfiled reads
# as shipped-and-recorded while being neither" is the whole reason this file
# exists.
#
# It happened: ADR 0010's bullet landed after v0.10.17 was tagged and sat
# inside that release's section, describing work the release does not contain.
my @pending_misfiled;
$section = '';
for my $line ( split /\n/, $log ) {
    if    ( $line =~ /^## Unreleased\s*$/ )   { $section = 'unreleased' }
    elsif ( $line =~ /^## (\d+\.\d+\.\d+) / ) { $section = $1 }
    elsif ( $line =~ /^## / )                 { $section = '' }
    elsif ( length $section
        && $section ne 'unreleased'
        && $line =~ /^- \S.*\(PENDING/ )
    {
        ( my $what = $line ) =~ s/^- //;
        $what =~ s/\s+.*$//;
        push @pending_misfiled, "$what in $section";
    }
}
is( scalar @pending_misfiled, 0,
    'no (PENDING) entry sits inside a released section' )
    or diag( join( "\n  ", '', @pending_misfiled )
        . "\n\nA (PENDING) entry describes work that has not shipped. Inside a"
        . " released section it claims the release contains it, and neither"
        . " this lint's SHA check nor t/lint/53 can see it." );

done_testing();
