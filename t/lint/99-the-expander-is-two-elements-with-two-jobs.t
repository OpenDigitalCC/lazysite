#!/usr/bin/perl
# The expander's outer and inner elements keep different class names.
#
# WHAT THE OPERATOR SAW on 0.11.8: "files expander just shows a thin line",
# then the same on Data. The panel opened to a strip with an accent edge and
# nothing inside it.
#
# WHY. The 0.11.8 class collapse merged `mg-perms-row` (the element JavaScript
# TOGGLES, and finds with querySelectorAll to close the others) and
# `mg-perms-card` (the card INSIDE it that carries the padding) into one name,
# `mg-expand`. They are not synonyms - they are a parent and a child with
# different jobs - so `closest('.mg-expand')` from inside the card returned the
# CARD instead of the row, and `querySelectorAll('.mg-expand')` matched both.
#
# The lesson is narrower than "do not rename things": two classes that always
# appear together are not therefore the same class. Nesting is the tell.
use strict;
use warnings;
use Test::More;
use FindBin;

my $root = "$FindBin::Bin/../..";
my @pages = glob "$root/starter/manager/*.md";
ok( scalar @pages, 'manager pages were found' ) or BAIL_OUT('no pages');

my ( @nested, @ambiguous );
for my $f (@pages) {
    ( my $name = $f ) =~ s{.*/}{};
    next if $name eq 'style-guide.md';    # demonstrates the nesting on purpose
    my $src = do { open my $fh, '<', $f or die $!; local $/; <$fh> };

    # The outer emitted directly inside the outer - the shape that broke it.
    push @nested, $name
        if $src =~ /class="mg-expand"[^>]*>\s*'?\s*\+?\s*'?<div class="mg-expand"/;

    # A selector that means the CARD must name the card. `closest('.mg-expand')`
    # walks up and stops at the first match, which from inside the card is the
    # card itself only when the two share a name - so this is the bug spelled
    # out rather than its symptom.
    while ( $src =~ /closest\('\.mg-expand'\)/g ) {
        push @ambiguous, "$name: closest('.mg-expand') - name the body if the "
            . 'card is what is wanted';
    }
}

is( "@nested", '', 'no page nests .mg-expand directly inside .mg-expand' )
    or diag( "Nested in: @nested\n"
        . "The outer is toggled and enumerated; the inner is styled. One name\n"
        . "for both makes closest() and querySelectorAll() ambiguous." );

is( "@ambiguous", '', 'a selector that wants the card names .mg-expand-body' )
    or diag( join( "\n  ", @ambiguous ) );

# Both names must actually be defined, in every shipped style - a role with no
# rule is the SM697 defect arriving by a different route.
for my $v (qw(classic modern accessible)) {
    my $p = "$root/starter/lazysite/manager/assets/manager-$v.css";
    next unless -f $p;
    my $css = do { open my $fh, '<', $p or die $!; local $/; <$fh> };
    like( $css, qr/\.mg-expand\b/,      "$v defines .mg-expand" );
    like( $css, qr/\.mg-expand-body\b/, "$v defines .mg-expand-body" );
}

done_testing();
