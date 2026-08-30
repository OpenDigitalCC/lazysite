#!/usr/bin/perl
# A manager page does not bring its own CSS.
#
# The release manager, on seeing three different modals and eight pages that
# looked unrelated: "we shouldnt have so many diffent ways to show things...
# they have many common themes like information with check boxes/selectors.
# there shoudl be one way to do this."
#
# A page-local <style> block is how that happens. It cannot be audited by the
# style guide (SM697), the next page needing the same component copies the
# block rather than reusing a class, and the two copies drift. data.md carried
# a 12-line reimplementation of .mg-sheet, which is why the Rows panel was a
# third modal idiom sitting beside .mg-modal and .mg-sheet.
#
# ONE ENTRY IS OUTSTANDING and named, rather than the rule being softened:
# domains.md carries over a thousand lines. The ceiling is what stops a NEW
# page joining it while that is paid off.
use strict;
use warnings;
use Test::More;
use FindBin;

my $root = "$FindBin::Bin/../..";

# style-guide.md is a page ABOUT styles; its block is the specimen containment
# that keeps overlay classes from escaping their demo box.
#
# edit.md is a DELIBERATE FAILSAFE, not invention, and the distinction is the
# whole point of this test. It inlines the editor's critical layout so the
# panes still work when manager.css is stale or missing - the sheet is copied
# to /manager/assets/ at install time, and a missing copy collapsed the panes
# to zero height: the recorded "page ends at extra, no edit box" symptom. A
# component that must survive its own stylesheet failing is a different thing
# from a page inventing a modal.
my %allowed = ( 'style-guide.md' => 1, 'edit.md' => 1 );

# Known debt, with the size that makes it debt rather than a detail.
my %debt = ( 'domains.md' => 1 );

my ( @new, @paid );
for my $f ( sort glob "$root/starter/manager/*.md" ) {
    ( my $name = $f ) =~ s{.*/}{};
    next if $allowed{$name};
    my $src = do { open my $fh, '<', $f or die $!; local $/; <$fh> };
    my $has = $src =~ /<style>/ ? 1 : 0;
    push @new,  $name if $has  && !$debt{$name};
    push @paid, $name if !$has && $debt{$name};
}

is( "@new", '', 'no manager page carries its own <style> block' )
    or diag( "Page-local CSS in:\n  " . join( "\n  ", @new )
        . "\n\nPut the rule in the stylesheet and name the class in the style\n"
        . "guide, so the next page that needs this component REUSES it. A\n"
        . "block here cannot be audited and is invisible to the guide's\n"
        . "contract - which is how one component became three." );

is( "@paid", '', 'the debt list names only pages that still carry CSS' )
    or diag( "These are clean now and should leave %debt:\n  "
        . join( "\n  ", @paid ) );

cmp_ok( scalar( keys %debt ), '<=', 1, 'the page-local CSS debt has not grown' )
    or diag( 'Adding a page to this list is adding to the debt rather than '
        . 'paying it. Extend an existing component instead - that is what the '
        . 'release manager asked for: "first check to reuse, even if that '
        . 'means extending".' );

done_testing();
