#!/usr/bin/perl
# SM847: every overlay in the manager carries a visible close, in the same place.
#
# Reported by the release manager on 0.13.12: some modals have a close X in the
# header and others do not. Measured: every sheet (.mg-sheet) had one; no dialog
# (.mg-modal - every confirm and prompt, the style preview) did. Escape and a
# Cancel button closed them, but an overlay that is dismissed one way here and
# another way there is the inconsistency the operator saw.
#
# The rule this pins: each dialog panel built on a manager surface carries a
# .mg-modal-close, and each sheet head a .mg-sheet-close - counted per file, so
# the next overlay a page builds by hand cannot arrive without one.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my @files = ( glob("$root/starter/manager/*.md"), "$root/starter/lazysite/manager/layout.tt" );

my ( $dialogs, $sheets ) = ( 0, 0 );
for my $f (@files) {
    open my $fh, '<', $f or next;
    my $t = do { local $/; <$fh> };
    close $fh;
    ( my $rel = $f ) =~ s{\A\Q$root/\E}{};

    # A class list containing the name, in markup or in a string that builds it.
    my $panel  = () = $t =~ /class="(?:[^"]*\s)?mg-modal-in(?:\s[^"]*)?"/g;
    my $mclose = () = $t =~ /class="(?:[^"]*\s)?mg-modal-close(?:\s[^"]*)?"/g;
    my $head   = () = $t =~ /class="(?:[^"]*\s)?mg-sheet-head(?:\s[^"]*)?"/g;
    my $sclose = () = $t =~ /class="(?:[^"]*\s)?mg-sheet-close(?:\s[^"]*)?"/g;
    $dialogs += $panel;
    $sheets  += $head;
    cmp_ok( $mclose, '>=', $panel, "$rel: each of its $panel dialog panel(s) carries a close" ) if $panel;
    cmp_ok( $sclose, '>=', $head, "$rel: each of its $head sheet head(s) carries a close" ) if $head;
}

# The shared dialog is what every confirm and prompt is built from; it is the
# one that matters most, so it is named rather than only counted.
my $layout = do { open my $fh, '<', "$root/starter/lazysite/manager/layout.tt" or die $!; local $/; <$fh> };
like( $layout, qr/querySelector\('\.mg-modal-close'\)\.onclick\s*=/,
    'the shared dialog wires its close, not only draws it' );

cmp_ok( $dialogs, '>=', 3, "the sweep found the dialogs ($dialogs)" );
cmp_ok( $sheets,  '>=', 4, "and the sheets ($sheets)" );

done_testing();
