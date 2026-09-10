#!/usr/bin/perl
# SM819: the listing row has three parts, and all three manager styles must
# agree on that.
#
# A row is: what describes it, its metadata, and what acts on it. When
# `.mg-row` declared only TWO columns and a page supplied three cells, the third
# did not fall into an implicit column - it wrapped to an implicit ROW at column
# 1, where `.mg-row > :last-child`'s `justify-self: end` right-aligned it inside
# a column whose width was whatever the metadata left over. So the action group
# tracked the length of the text beside it: 297px of drift across four connector
# rows, descending the list diagonally.
#
# `margin-left: auto` had been added for this (SM807) and was inert - it resolves
# to 0 when the grid area has no free space, which is why the field read it as
# unset and suspected a stale stylesheet. It was neither.
#
# WHY A LINT AND NOT JUST A FIX. Two things recur here. MR-68 found this same
# three-parts-in-two-columns defect on the Plugin Manager weeks earlier and fixed
# it locally, so the shared row kept the fault. And there are THREE stylesheets -
# modern, classic and accessible - which a reader edits one at a time, so a
# template that drifts in one style lays rows out differently for whoever selected
# it, and nothing else would say so.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my @sheets = sort glob "$root/starter/lazysite/manager/assets/manager-*.css";
plan skip_all => 'no manager stylesheets' unless @sheets;

my %template;
for my $f (@sheets) {
    ( my $style = $f ) =~ s{.*/manager-}{};
    $style =~ s/\.css$//;
    open my $fh, '<:utf8', $f or die "$f: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    # The `.mg-row` rule's own template, not a neighbour's - match the block.
    my ($block) = $src =~ /^\.mg-row \{(.*?)\}/ms;
    unless ($block) {
        fail("$style: a .mg-row rule was found");
        next;
    }
    my ($cols) = $block =~ /grid-template-columns:\s*([^;]+);/;
    $template{$style} = defined $cols ? _norm($cols) : '(none declared)';
}

sub _norm { my $s = shift; $s =~ s/\s+/ /g; $s =~ s/^ | $//g; return $s }

cmp_ok( scalar keys %template, '>=', 2, 'found the row template in more than one style' );

# --- every style declares the same row -------------------------------------
my %distinct = map { $template{$_} => 1 } keys %template;
is( scalar keys %distinct, 1,
    'every manager style declares the SAME .mg-row template' )
    or diag( join "\n", map { sprintf '  %-12s %s', $_, $template{$_} } sort keys %template );

# --- and it is three columns ------------------------------------------------
# Counted rather than string-matched, so a future edit may re-space or rename the
# functions and still pass, while dropping back to two must argue with SM819.
for my $style ( sort keys %template ) {
    my $t = $template{$style};
    my $n = 0;
    my $rest = $t;
    $n++ while $rest =~ s/^\s*(?:minmax\([^)]*\)|[^\s]+)//;
    cmp_ok( $n, '>=', 3, "$style: the row declares three columns (describes, metadata, acts)" )
        or diag( "template is: $t\n"
            . "With two columns a three-cell row wraps its third cell to an\n"
            . "implicit ROW, and the action group then tracks the width of the\n"
            . "metadata beside it. See SM819 and MR-68." );
}

# --- and the disclosure glyph is a disclosure, in every style ----------------
# SM816: `.mg-chev` rendered a `+`. At its size, beside a "New connector"
# button, that reads as "add another one" - which is how an operator came to
# report that a connector could not be deleted: the only route to Delete was an
# unlabelled plus that looked like the wrong button entirely.
#
# Guarded here rather than in its own file because it is the same shared-idiom
# problem as the row template above: three stylesheets a reader edits one at a
# time, and a glyph that drifts in one style is wrong only for whoever selected
# it. The `+` on `summary.mg-acc-line` is deliberately not covered - that one
# sits beside a text label, so it is not ambiguous.
{
    my %glyph;
    for my $f (@sheets) {
        ( my $style = $f ) =~ s{.*/manager-}{};
        $style =~ s/\.css$//;
        open my $fh, '<:utf8', $f or die "$f: $!";
        my $src = do { local $/; <$fh> };
        close $fh;
        my ($g) = $src =~ /^\.mg-chev::before \{[^}]*content:\s*'([^']*)'/m;
        $glyph{$style} = defined $g ? $g : '(none)';
    }

    my %distinct = map { $glyph{$_} => 1 } keys %glyph;
    is( scalar keys %distinct, 1, 'every style uses the SAME disclosure glyph' )
        or diag( join "\n", map { sprintf '  %-12s %s', $_, $glyph{$_} } sort keys %glyph );

    for my $style ( sort keys %glyph ) {
        isnt( $glyph{$style}, '+',
            "$style: the disclosure glyph is not a plus - a bare + reads as add" );
    }
}

done_testing();
