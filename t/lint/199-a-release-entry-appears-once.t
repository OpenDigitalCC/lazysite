#!/usr/bin/perl
# One release entry is not named both PENDING and stamped.
#
# WHY THIS EXISTS: the same landing artefact has happened twice, and neither
# t/lint/53 nor t/lint/65 could see it.
#
# The shape both times: a branch is cut, the pre-cut stamping lands on main while
# that branch is open, and the branch's copy of CHANGELOG.md still carries the row
# as `(PENDING)`. On landing, the merge keeps main's stamped FIRST LINE and the
# branch's WHOLE entry, so the file ends up with
#
#   - SM917 step 3 (f6bccc25) **a read that names a store obeys the store rule wherever
#   - SM919 (PENDING) **a row's tick box and its Delete button no longer sit at
#
# an 84-byte orphan whose sentence stops mid-phrase, and the complete 1941-byte
# entry lower down still unstamped. One entry, named twice, and the half carrying
# the reasoning is the half still marked PENDING.
#
# t/lint/53 passed both times: it checks a SHA exists and ignores PENDING.
# t/lint/65 passed both times: it refuses a PENDING entry inside a RELEASED
# section, and a duplicate under `## Unreleased` breaks neither rule.
#
# THE OBVIOUS CHECK IS WRONG, AND WAS TRIED. The first version of this file
# refused any name appearing twice in one section. It failed immediately on
# thirteen historical entries, because a repeated name is ORDINARY PRACTICE here:
# SM447 contributes three entries to 0.10.23, SM857 two to this release, and
# "Tier A", "DP-2" and "Docs" repeat as well. A filing that does several separable
# things in one release gets a row for each, which is the convention working.
#
# So the signature is narrower and it is exact: the same name appearing BOTH
# stamped and PENDING. Two stamped rows are two entries; two PENDING rows are two
# entries not yet landed; one of each is one entry the merge tore in half.
# Verified against the whole file - no historical section mixes the two states for
# one name, so this fires on the artefact and on nothing else.
#
# What it deliberately does NOT check is the orphan itself - a row whose body went
# missing. That was in the first version too and it fired on legitimate one-line
# entries from 0.10.13, which have a bolded lead and no continuation by choice.
# Recognising a truncated sentence needs judgement about prose; the mixed ref
# state is the same defect observed without it.
use strict;
use warnings;
use Test::More;
use FindBin;

my $file = "$FindBin::Bin/../../CHANGELOG.md";
open my $fh, '<', $file or die "CHANGELOG.md: $!";
my @lines = <$fh>;
close $fh;

my ( $section, %state, @torn ) = ('(before any heading)');
for my $i ( 0 .. $#lines ) {
    my $l = $lines[$i];

    if ( $l =~ /^## / ) {
        %state   = ();
        $section = $l;
        $section =~ s/^##\s+|\s+$//g;
        next;
    }

    # `- <name> (REF) **rest` - the name is what a reader uses to find the entry.
    my ( $name, $ref ) = $l =~ /^- (.+?)\s+\((PENDING|[0-9a-f]{7,40})\)/;
    next unless defined $name;
    my $kind = ( $ref eq 'PENDING' ) ? 'PENDING' : 'stamped';

    if ( exists $state{$name}{kind} && $state{$name}{kind} ne $kind ) {
        push @torn, sprintf( '%s: "%s" is %s at line %d and %s at line %d',
            $section, $name, $state{$name}{kind}, $state{$name}{line}, $kind, $i + 1 );
    }
    $state{$name} = { kind => $kind, line => $i + 1 };
}

cmp_ok( scalar @lines, '>', 100, 'the changelog was read' );

is_deeply( \@torn, [], 'no entry is named both PENDING and stamped' )
    or diag( "This is the landing artefact described at the top of this file: main's\n"
        . "stamped first line survived and a branch's whole PENDING copy landed under\n"
        . "it. KEEP THE COMPLETE ENTRY, stamp it, and delete the fragment - the\n"
        . "fragment is the one that lost its body, so check the byte counts rather\n"
        . "than the line order before deleting either.\n"
        . join( "\n", @torn ) );

done_testing();
