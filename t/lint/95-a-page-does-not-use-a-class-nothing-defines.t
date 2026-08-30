#!/usr/bin/perl
# SM697: a manager page may not emit a class the stylesheet does not define.
#
# TWICE NOW. SM686: the capability grid's hint marker carried `mg-cap-what`,
# which had NO rule at all, so a `?` sat in the label text reading as
# punctuation rather than as a control. SM697: the Plugin Config page emitted
# EIGHT such classes, so a list of forms ran together as a paragraph and a
# submissions table had no table styling.
#
# The defect survives review because nothing is wrong with the code. The class
# is spelled correctly, the markup is well formed, no error is raised, and the
# page LOOKS written. Only the rendered page says otherwise, and that is not
# what a reviewer or a test was looking at.
#
# Scope: classes the page's own script EMITS in markup, in the `mg-` namespace
# this project owns. A class that comes from somewhere else is somebody else's
# to define.
use strict;
use warnings;
use Test::More;
use FindBin;

my $root = "$FindBin::Bin/../..";

# EVERY SHIPPED SHEET, and it is a FAILURE to find none.
#
# This test read `manager.css` and skipped when it was absent. 0.11.8 renamed
# that file to manager-classic.css and split two more beside it - so from that
# release the suite reported `1..0 # SKIP` and ran no assertions at all, while
# counting as a passing suite in every gate. A guard that disables itself when
# its subject moves is worse than no guard: it reports the same green tick
# either way, which is the defect class this project keeps closing. The skip
# is now a failure, so the next rename fails loudly instead of going quiet.
#
# All three sheets, because a class defined only in `classic` is unstyled for
# an operator who selected `modern` - the fault this test exists to catch,
# arriving through the style selector rather than through a missing rule.
my @sheets = sort glob("$root/starter/lazysite/manager/assets/manager-*.css");
ok( scalar @sheets,
    'the shipped manager stylesheets were found' )
    or BAIL_OUT( 'No manager-*.css under starter/lazysite/manager/assets. '
        . 'If the sheets moved again, point this test at them - do not let it '
        . 'skip, which is how it went silent for a whole release.' );

my %css;
for my $f (@sheets) {
    my ($variant) = $f =~ m{manager-([a-z]+)\.css\z};
    $css{$variant} = do { open my $fh, '<', $f or die $!; local $/; <$fh> };
}

# Classes that exist for scripting or state, not appearance. A class used only
# as a querySelector handle is legitimately undefined in CSS, so this list is
# the deliberate exception - keep it short and say why each one is here.
# Each of these is read back with querySelector/closest and never styled - a
# handle, not an appearance. Verified individually; a class that is merely
# UNSTYLED does not belong here, only one that is not meant to be styled.
my %scripting_only = map { $_ => 1 } qw(
    mg-sub-cb
    mg-acl-body
    mg-perm-owner
    mg-git-panel
    mg-git-view
    mg-sec-read
);

# PAID. SM697 measured fourteen classes with no rule; eight were fixed in
# 0.11.8 and the design sheets that landed in the same release defined the
# remaining twelve, in all three variants. The list is empty and the ceiling
# below is zero, so a new undefined class fails immediately rather than joining
# a waiver list that reads like permission.
my %known_debt = ();

my @pages = sort glob("$root/starter/manager/*.md");
plan skip_all => 'no manager pages' unless @pages;

my @undefined;
for my $page (@pages) {
    my $name = $page;
    $name =~ s{.*/}{};
    my $src = do { open my $fh, '<', $page or next; local $/; <$fh> };
    my ($js) = $src =~ /<script>(.*)<\/script>/s;
    next unless defined $js;

    my %seen;
    # Only literal class attributes - a value built by concatenation is not
    # something this can read, and guessing would produce false alarms.
    while ( $js =~ /class="([^"{}+]+)"/g ) {
        for my $c ( split ' ', $1 ) {
            next unless $c =~ /\Amg-[\w-]+\z/;
            next if $scripting_only{$c};
            next if $known_debt{$c};
            next if $seen{$c}++;
            my @missing = grep { index( $css{$_}, ".$c" ) < 0 } sort keys %css;
            next unless @missing;
            push @undefined, "$name: .$c (undefined in: @missing)";
        }
    }
}

is( "@undefined", '',
    'every mg- class a manager page emits has a rule in EVERY shipped style' )
    or diag( "Emitted with no stylesheet rule:\n  "
        . join( "\n  ", @undefined )
        . "\n\nAn element carrying a class nothing defines renders as unstyled\n"
        . "inline content. Nothing errors and the source looks correct, which\n"
        . "is how SM686 and SM697 both reached an operator. Either add the rule\n"
        . "or, if the class is only a querySelector handle, add it to\n"
        . "%scripting_only in this test with a reason." );

# The debt list only shrinks. An entry that no longer needs to be there is a
# waiver protecting nothing, and the next person to add a class would find a
# list that looks like permission.
my @stale = grep {
    my $c = $_; !grep { index( $css{$_}, ".$c" ) < 0 } keys %css
} sort keys %known_debt;
is( "@stale", '',
    'no entry in the known-debt list has quietly been fixed without being removed' )
    or diag( "These now HAVE a rule and should leave the list:\n  "
        . join( "\n  ", map {".$_"} @stale ) );

cmp_ok( scalar( keys %known_debt ), '<=', 0,
    'the known-debt list has not grown' )
    or diag( 'SM697 measured twelve distinct classes and the design sheets '
        . 'defined all twelve, so the list is empty and the ceiling is zero. '
        . 'If this fails somebody has added to the debt rather than paying '
        . 'it - add the rule instead, in all three sheets.' );

done_testing();
