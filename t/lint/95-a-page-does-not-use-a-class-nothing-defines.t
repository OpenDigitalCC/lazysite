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
my $cssf = "$root/starter/lazysite/manager/assets/manager.css";
plan skip_all => "no $cssf" unless -f $cssf;

my $css = do { open my $fh, '<', $cssf or die $!; local $/; <$fh> };

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

# KNOWN AND NOT YET FIXED (SM697, measured 2026-08-29). Fourteen classes across
# seven pages that are PURELY VISUAL - not selector handles - and have no rule.
# They are listed rather than waived so this lint can guard the boundary today
# while they are worked through: a NEW one fails immediately, and this list only
# ever shrinks.
#
# Do not add to it. If a page needs a class, the stylesheet needs the rule; the
# entries below are a debt, not a pattern.
my %known_debt = map { $_ => 1 } qw(
    mg-apply-panel
    mg-config-preset
    mg-readonly-value
    mg-field-note
    mg-dom-tools
    mg-dom-chip
    mg-dom-open
    mg-recent-dot
    mg-protect-lock
    mg-file-select
    mg-split-bar
    mg-onb-warn
);

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
            next if index( $css, ".$c" ) >= 0;
            push @undefined, "$name: .$c";
        }
    }
}

is( "@undefined", '',
    'every mg- class a manager page emits has a rule in manager.css' )
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
my @stale = grep { index( $css, ".$_" ) >= 0 } sort keys %known_debt;
is( "@stale", '',
    'no entry in the known-debt list has quietly been fixed without being removed' )
    or diag( "These now HAVE a rule and should leave the list:\n  "
        . join( "\n  ", map {".$_"} @stale ) );

cmp_ok( scalar( keys %known_debt ), '<=', 12,
    'the known-debt list has not grown' )
    or diag( 'SM697 measured twelve distinct classes. If this fails somebody '
        . 'has added to the debt rather than paying it.' );

done_testing();
