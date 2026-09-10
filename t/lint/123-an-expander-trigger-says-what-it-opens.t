#!/usr/bin/perl
# SM816: the row expander's trigger has no text of its own.
#
# `.mg-chev` is an empty element - the glyph comes from the stylesheet
# (`.mg-chev::before { content: '+' }`, becoming U+2212 when open), so the
# element itself contains nothing. That makes it an unnamed control unless the
# page gives it a name, and an unnamed control that is the ONLY route to a
# row's actions is a feature nobody can find.
#
# WHICH IS WHAT HAPPENED. An operator reported there was no way to delete a
# connector. There was: Save and Delete are inside the row's expander, and the
# expander's only trigger was `<a href="#" class="mg-chev" ... ></a>` - no text,
# no aria-label, no title. The capability was never the obstacle; the control
# had nothing to announce itself with, and at the rendered size a `+` beside a
# "New connector" button reads as "add another one".
#
# THE STYLE GUIDE TAUGHT THE OMISSION, which is why this is a lint and not a
# one-line fix. `data.md` and `files.md` both named their triggers; the guide's
# own two exemplars did not, and connectors.md was written from the guide. A
# defect in an exemplar is a defect in everything copied from it, so the check
# covers the guide as well as the pages - it is the file most likely to be
# copied and the least likely to be tested by hand.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $dir  = "$root/starter/manager";
opendir my $dh, $dir or plan skip_all => "no $dir";
my @pages = sort grep { /\.md$/ } readdir $dh;
closedir $dh;
plan skip_all => 'no manager pages' unless @pages;

my @unnamed;
my $checked = 0;

for my $page (@pages) {
    open my $fh, '<:utf8', "$dir/$page" or die "$page: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    # A TRIGGER, not a mention. The pages also name this class in
    # querySelectorAll and classList calls, which are not elements and have
    # nothing to announce - so match only what opens a tag carrying the class.
    #
    # Both spellings: literal HTML in the guide, and the string-concatenated
    # form the pages build in JavaScript. The concatenated form is why this
    # reads to the end of the statement rather than to the closing angle
    # bracket: the attributes are split across several quoted fragments and
    # `>` arrives in a different one from `class`.
    while ( $src =~ /<a\b([^>]*?class\s*=\s*["'][^"']*\bmg-chev\b[^"']*["'].*?)(?:><\/a>|>)/gs ) {
        my $attrs = $1;
        $checked++;
        next if $attrs =~ /aria-label/;
        next if $attrs =~ /\btitle\s*=/;

        # A trigger may also be named by text inside it, which none of these
        # use - but a page that did would be correct, so allow it.
        next if $attrs =~ /aria-labelledby/;

        my $line = 1 + substr( $src, 0, pos($src) ) =~ tr/\n//;
        push @unnamed, "$page:$line";
    }
}

cmp_ok( $checked, '>=', 4, 'found the expander triggers to check' )
    or diag 'no .mg-chev trigger matched - has the idiom changed shape?';

is_deeply( \@unnamed, [],
    'every .mg-chev trigger carries a name (aria-label, title or labelledby)' )
    or diag( "unnamed expander triggers:\n  " . join( "\n  ", @unnamed ) . "\n"
        . "The element has no text of its own - the glyph is the stylesheet's -\n"
        . "so without a name it announces nothing, and it is often the only\n"
        . "route to the row's Save and Delete. Name it, and change the name\n"
        . "with the state: 'Show details for X' / 'Hide details for X'." );

# --- and it carries a WORD, not only a name ---------------------------------
# SM816: an aria-label helps a reader who is already on the control; a visible
# word is what makes somebody look. The operator who reported that a connector
# could not be deleted was not using a screen reader - the route to Delete was a
# shape, and shapes are not searched for.
#
# The label is per-list by design - Configure for a connector, Settings for a
# file, More for a table - so this asserts the SLOT is used, never a fixed word.
{
    my @unlabelled;
    my $checked = 0;
    for my $page (@pages) {
        open my $fh, '<:utf8', "$dir/$page" or die "$page: $!";
        my $src = do { local $/; <$fh> };
        close $fh;

        while ( $src =~ /<a\b([^>]*?class\s*=\s*["'][^"']*\bmg-chev\b[^"']*["'].*?)>(.*?)<\/a>/gs ) {
            my ( $attrs, $text ) = ( $1, $2 );
            $checked++;

            # The concatenated form puts the label in a following fragment, so
            # accept either the modifier class or visible text between the tags.
            next if $attrs =~ /\bmg-chev-label\b/;
            next if $text =~ /\S/;

            my $line = 1 + substr( $src, 0, pos($src) ) =~ tr/\n//;
            push @unlabelled, "$page:$line";
        }
    }

    cmp_ok( $checked, '>=', 4, 'found the triggers to check for a label' );
    is_deeply( \@unlabelled, [],
        'every .mg-chev trigger carries a visible word, not only a name' )
        or diag( "glyph-only triggers:\n  " . join( "\n  ", @unlabelled ) . "\n"
            . "Add .mg-chev-label and put the word inside the element. It is\n"
            . "per-list: Configure for a connector, Settings for a file, More\n"
            . "for a table. One control - never a glyph plus a button." );
}

done_testing();
