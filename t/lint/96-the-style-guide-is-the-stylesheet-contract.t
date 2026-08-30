#!/usr/bin/perl
# The manager style guide is the contract between the pages and the stylesheet.
#
# The practice this follows is the one the site guidance already states, applied
# to the manager itself:
#
#   Every component the pages emit is registered in the style guide, in each of
#   its states, with test content. The theme's job is to deliver everything the
#   guide names - a component present in the guide but missing from the theme is
#   a gap in delivery, not a licence to hand-style a page.
#
# WHY THE MANAGER NEEDED IT. Three defects in three days were each a page that
# was correct in SOURCE and wrong in the BROWSER: SM686 (a hint marker whose
# class had no rule, so a `?` read as punctuation), SM689 (markup discarded
# between the source and the browser), SM697 (eight classes on one page with no
# rule, and fourteen more across seven others). Nothing errored in any of them.
# A reviewer reading a diff cannot see any of it; a rendered guide can.
#
# The rule runs BOTH WAYS, and each direction catches a different mistake:
#   - a class the guide names with no rule  -> the stylesheet owes a rule
#   - a class the stylesheet defines that is absent from the guide -> either the
#     component is undocumented, or the rule is dead and should go
use strict;
use warnings;
use Test::More;
use FindBin;

my $root  = "$FindBin::Bin/../..";
my $guide = "$root/starter/manager/style-guide.md";
my $cssf  = "$root/starter/lazysite/manager/assets/manager.css";

plan skip_all => "no $guide" unless -f $guide;
plan skip_all => "no $cssf"  unless -f $cssf;

my $g   = do { open my $fh, '<', $guide or die $!; local $/; <$fh> };
my $css = do { open my $fh, '<', $cssf  or die $!; local $/; <$fh> };

# Classes the guide DEMONSTRATES: those in a class attribute, plus those it
# names in a `.mg-x` code label. Both count as registering a component.
my %in_guide;
while ( $g =~ /class="([^"{}]+)"/g ) {
    $in_guide{$_} = 1 for grep {/\Amg-[\w-]+\z/} split ' ', $1;
}
$in_guide{$1} = 1 while $g =~ /<code[^>]*>\.(mg-[\w-]+)</g;

# Classes the stylesheet DEFINES. Comments are stripped first: this file
# explains itself, and prose naming `.mg-dom-*` is not a rule. Reading a comment
# as a definition would have the guide document something that does not exist.
( my $css_rules = $css ) =~ s{/\*.*?\*/}{}gs;
my %in_css = map { $_ => 1 } $css_rules =~ /\.(mg-[\w-]+)/g;

# The guide's own furniture, which is deliberately styled inside the guide so it
# cannot lean on a rule it exists to audit.
my %guide_furniture = map { $_ => 1 } qw(
    mg-sg-h mg-sg-note mg-sg-demo mg-sg-fam mg-sg-grid mg-sg-item mg-sg-name
);

cmp_ok( scalar( keys %in_guide ), '>', 200,
    'the guide demonstrates the manager vocabulary, not a sample of it' );

# --- direction one: the stylesheet owes a rule for everything named ---------
my @unstyled = sort grep { !$in_css{$_} && !$guide_furniture{$_} } keys %in_guide;
is( "@unstyled", '',
    'every class the guide names has a rule in manager.css' )
    or diag( "Named in the guide, no rule in the stylesheet:\n  "
        . join( "\n  ", map {".$_"} @unstyled )
        . "\n\nThese render as unstyled inline content. That is SM697 - and it\n"
        . "is a gap in the stylesheet, not a reason to style the page instead." );

# --- direction two: nothing the stylesheet defines is undocumented ----------
my @undocumented = sort grep { !$in_guide{$_} } keys %in_css;
is( "@undocumented", '',
    'every class manager.css defines appears in the guide' )
    or diag( "Defined in the stylesheet, absent from the guide:\n  "
        . join( "\n  ", map {".$_"} @undocumented )
        . "\n\nEither the component is undocumented - so the next person to need\n"
        . "one invents a second class for the same thing, which is how the\n"
        . "manager ended up with two expander idioms - or the rule is dead and\n"
        . "should be removed. Both are answered by editing the guide." );

done_testing();
