#!/usr/bin/perl
# SM401: field rules for structured data collection, from a real deployment -
# an office team answering ~300 questions of the shape "which production batch
# was on this delivery, and how many", one form page per product.
#
# WHAT WAS ALREADY TRUE, checked before building anything and reported back
# rather than rebuilt: quoted option labels containing SPACES and parentheses
# already worked, and `number` with `min:`/`max:` already rendered numeric
# bounds. The requester had reasonably assumed otherwise.
#
# WHAT WAS ACTUALLY BROKEN
#   a comma INSIDE a quoted option split it into two options - silently, so the
#     form worked and simply offered the wrong answers
#   a repeated field name OVERWROTE, so any multi-select would have kept only
#     the last tick and lost the rest, again silently
#   an unrecognised rule renders a plain text box with no complaint (asserted
#     here as the current behaviour, so a future change to it is deliberate)
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

sub field {
    my ($rules) = @_;
    my $h = main::convert_fenced_form(
        "::: form\n$rules\nsubmit | Send\n:::\n", { form => 'x' } );
    $h =~ s/.*?<div class="form-field">//s;
    $h =~ s{<div class="form-field form-submit">.*}{}s;
    return $h;
}

# --- options, and the comma that broke them ---------------------------
{
    my $h = field(q{b | B | select:"CC1099 (recorded)",CC1007});
    like( $h, qr/<option value="CC1099 \(recorded\)">/,
        'a quoted option keeps its spaces and parentheses' );
    like( $h, qr/<option value="CC1007">/, 'and an unquoted one beside it' );

    my $c = field(q{b | B | select:"Smith, John","Jones"});
    like( $c, qr/<option value="Smith, John">/,
        'a comma INSIDE a quoted option no longer splits it' );
    unlike( $c, qr/<option value="Smith">/, 'so it is not two wrong options' );
    is( scalar( () = $c =~ /<option /g ), 3, 'two options plus the placeholder' );
}

# --- radio ------------------------------------------------------------
{
    my $h = field(q{p | Pick | required radio:A,B,C});
    like( $h, qr/role="radiogroup"/, 'radio renders a group' );
    is( scalar( () = $h =~ /type="radio"/g ), 3, 'one input per option' );
    like( $h, qr/name="p"[^>]*value="A"/, 'options share the field name' );
    like( $h, qr/type="radio"[^>]* required/, 'required applies - the browser reads it as one-of' );
    like( $h, qr/for="p-0"/, 'each input has its own id, so the label is clickable' );
}

# --- checklist --------------------------------------------------------
{
    my $h = field(q{t | Tick | required checklist:A,B});
    is( scalar( () = $h =~ /type="checkbox"/g ), 2, 'one checkbox per option' );
    like( $h, qr/name="t"[^>]*value="A"/, 'sharing the field name' );

    # The load-bearing one. On checkboxes `required` means THIS box, so marking
    # them all required demands every option - the opposite of a multi-select.
    unlike( $h, qr/type="checkbox"[^>]* required/,
        'required is NOT applied to a checkbox group' );
}

# --- checklist-qty ----------------------------------------------------
{
    my $h = field(q{q | Batches | checklist-qty:A,B});
    is( scalar( () = $h =~ /type="checkbox"/g ), 2, 'a checkbox per option' );
    is( scalar( () = $h =~ /type="number"/g ),   2, 'and a quantity beside each' );
    like( $h, qr/name="q~qty~A"/,
        'the quantity carries its option IN THE NAME, so the handler needs no schema' );
    like( $h, qr/aria-label="A quantity"/, 'and is named for a screen reader' );
}

# --- escaping ---------------------------------------------------------
{
    my $h = field(q{e | E | select:"A & B","C<D"});
    like( $h, qr/value="A &amp; B"/, 'an ampersand in an option is escaped' );
    like( $h, qr/&lt;D/,             'and a less-than' );
    unlike( $h, qr/<option value="C<D">/, 'so it cannot break the markup' );
}

# --- what already worked, asserted so it stays working -----------------
{
    my $h = field(q{n | N | number min:1 max:99});
    like( $h, qr/type="number"[^>]*min="1"[^>]*max="99"/,
        'number still takes numeric bounds rather than a maxlength' );
}

# --- the current behaviour of an unknown rule --------------------------
{
    my $h = field(q{u | U | nosuchrule:A,B});
    like( $h, qr/type="text"/,
        'an unrecognised rule silently renders a text box - recorded as it is, '
            . 'so changing it is a decision rather than a surprise' );
}

done_testing();
