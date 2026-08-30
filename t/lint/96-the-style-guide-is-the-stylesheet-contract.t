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
my $cssf  = "$root/starter/lazysite/manager/assets/manager-classic.css";

# NOT skip_all. Both of these are shipped artefacts: if either is absent the
# manager has no stylesheet or no guide, which is a failure to report and never
# a reason to fall silent. t/lint/95 skipped on exactly this shape, and when
# 0.11.8 renamed manager.css that skip turned a dead check into a passing suite
# for a whole release.
ok( -f $guide, 'the style guide is present' ) or BAIL_OUT("no $guide");
ok( -f $cssf,  'the classic stylesheet is present' ) or BAIL_OUT("no $cssf");

my $g   = do { open my $fh, '<', $guide or die $!; local $/; <$fh> };
my $css = do { open my $fh, '<', $cssf  or die $!; local $/; <$fh> };

# THE THREE SHEETS SHARE ONE VOCABULARY, and that is what makes it legitimate
# for the rest of this test to read `classic` alone. A style is a re-inking of
# the same components, not a different set of them - so a class present in one
# sheet and missing from another is unstyled for whoever selected that style,
# and the guide (which is written once) could not tell you which.
subtest 'every shipped style defines the same vocabulary' => sub {
    my %set;
    for my $f ( sort glob("$root/starter/lazysite/manager/assets/manager-*.css") ) {
        my ($v) = $f =~ m{manager-([a-z]+)\.css\z};
        my $t = do { open my $fh, '<', $f or die $!; local $/; <$fh> };
        $t =~ s{/\*.*?\*/}{}gs;
        my %c; $c{$1} = 1 while $t =~ /\.(mg-[\w-]+)/g;
        $set{$v} = \%c;
    }
    ok( scalar keys %set, 'the sheets were found' ) or return;
    my $base = ( sort keys %set )[0];
    for my $v ( sort keys %set ) {
        next if $v eq $base;
        my @only_base = grep { !$set{$v}{$_} } sort keys %{ $set{$base} };
        my @only_this = grep { !$set{$base}{$_} } sort keys %{ $set{$v} };
        is( "@only_base", '', "$v defines everything $base does" )
            or diag( "Missing from $v: @only_base\n"
                . "An operator on that style sees these unstyled." );
        is( "@only_this", '', "$v defines nothing $base lacks" )
            or diag( "Only in $v: @only_this\n"
                . "The guide is written once, against the shared vocabulary." );
    }
};

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
    mg-sg-family mg-sg-tag mg-sg-count
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

subtest 'an explicit theme choice beats the operating system' => sub {
    # `:root` and `[data-theme="light"]` have the SAME specificity, so an
    # unguarded `@media (prefers-color-scheme: dark)` block declared later in
    # the file wins over the light tokens for a viewer whose OS is dark. The
    # toggle then sets data-theme="light", nothing changes, and the control
    # looks broken - which is how it shipped in 0.11.8.
    #
    # It fails in ONE direction only, on a dark-OS machine, which is why it
    # survived review: light-to-dark works fine and that is what most people
    # try first.
    my @unguarded;
    for my $f ( sort glob("$root/starter/lazysite/manager/assets/manager-*.css") ) {
        my ($v) = $f =~ m{manager-([a-z]+)\.css\z};
        my $t = do { open my $fh, '<', $f or die $!; local $/; <$fh> };
        $t =~ s{/\*.*?\*/}{}gs;
        while ( $t =~ /\@media[^{]*prefers-color-scheme:\s*dark[^{]*\{\s*([^{]*)\{/g ) {
            my $sel = $1;
            $sel =~ s/\s+/ /g; $sel =~ s/^\s+|\s+$//g;
            push @unguarded, "$v: \@media ... { $sel {"
                unless $sel =~ /:not\(\s*\[data-theme=.light.\]\s*\)/;
        }
    }
    is( "@unguarded", '', 'every dark media block excludes an explicit light choice' )
        or diag( "Unguarded:\n  " . join( "\n  ", @unguarded )
            . "\n\nUse :root:not([data-theme=\"light\"]) so a viewer who asks\n"
            . "for light gets light even when their OS is dark." );
};

done_testing();
