#!/usr/bin/perl
# SM686: the "what does this grant" marker is a control, not punctuation.
#
# The capability grid attaches a hover marker to every capability that carries a
# sentence explaining what it grants. It shipped as a bare `?` against a class
# with NO CSS RULE AT ALL, so it rendered as an unstyled character sitting in
# the label text: the grid read "Manage forms ?", which looks like the page
# asking a question rather than offering somewhere to look. Every capability has
# a sentence, so every row had one.
#
# The two halves are tested together on purpose. A marker glyph with no rule to
# style it is the defect; so is a rule with no element to attach to. Either half
# alone would let this come back.
use strict;
use warnings;
use Test::More;
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $page = "$root/starter/manager/groups.md";
my $css  = "$root/starter/lazysite/manager/assets/manager-classic.css";

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

my $P = slurp($page);
my $C = slurp($css);

# ---- the marker is not a bare question mark ------------------------------
unlike( $P, qr/class="mg-cap-what"[^>]*>\?</,
    'the capability hint is not a bare question mark' )
    or diag( 'A `?` in the label text reads as part of the sentence. The '
        . "release manager's instruction was to say the label and put the "
        . 'detail behind an info button or a tooltip.' );

like( $P, qr/class="mg-cap-what"/, 'the hint marker is still rendered' );
like( $P, qr/mg-cap-what[^>]*>i</,
    '...as an information marker' );

# ---- it is STYLED, which is the half that was missing --------------------
# The class existed and the stylesheet had no rule for it. That is why it
# looked like stray text rather than a control.
like( $C, qr/^\.mg-cap-what\s*\{/m,
    'the stylesheet has a rule for the marker' )
    or diag( 'Without a rule the glyph renders inline as plain text, which is '
        . 'exactly how the bare `?` came to look like punctuation.' );
like( $C, qr/\.mg-cap-what\s*\{[^}]*border-radius:\s*50%/s,
    '...that makes it a badge rather than a character' );
like( $C, qr/\.mg-cap-what\s*\{[^}]*cursor:\s*help/s,
    '...and says it can be hovered' );

# ---- the sentence is reachable without a pointer -------------------------
# A title attribute alone is mouse-only. The marker takes focus so the sentence
# is available to somebody on a keyboard.
like( $P, qr/mg-cap-what[^>]*tabindex="0"/, 'the marker can be focused' );
like( $P, qr/mg-cap-what[^>]*aria-label=/,  'and names itself to a screen reader' );
# Matched with flexible whitespace: the property is that focus shares the
# hover rule, not that the two selectors sit on separate lines. A test pinned
# to formatting fails on a reflow that changes nothing (SM684's lesson, in the
# loud direction rather than the silent one).
like( $C, qr/\.mg-cap-what:hover,\s*\.mg-cap-what:focus/s,
    'and it shows the same state on focus as on hover' );

# ---- the sentence itself still comes from one source ---------------------
# The grid, describe_capabilities and the generated map must say the same
# words, which is why the text is read from Capabilities.pm rather than typed
# into this page.
like( $P, qr/CAP_GRANTS\s*&&\s*CAP_GRANTS\[/,
    'the sentence is still read from the capability declarations' );

done_testing();
