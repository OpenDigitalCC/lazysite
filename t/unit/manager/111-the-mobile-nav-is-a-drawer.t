#!/usr/bin/perl
# SM-DS1: on a narrow screen the sidebar is a drawer, not rows wrapped to the top.
#
# The sheet keys off `data-nav-open` on `.mg-shell` and expects two elements the
# old markup did not have: a burger in the header and a scrim inside the shell.
# CSS cannot add either, so a stylesheet shipped without them leaves a phone with
# no route to the navigation at all - the failure mode is not "it looks wrong",
# it is "there is no menu".
use strict;
use warnings;
use Test::More;
use FindBin;

my $lay = "$FindBin::Bin/../../../starter/lazysite/manager/layout.tt";
my $css = "$FindBin::Bin/../../../starter/lazysite/manager/assets/manager-classic.css";
plan skip_all => "no layout" unless -f $lay;

my $l = do { open my $fh, '<', $lay or die $!; local $/; <$fh> };
my $c = do { open my $fh, '<', $css or die $!; local $/; <$fh> };

subtest 'the markup the sheet needs is present' => sub {
    like( $l, qr/class="mg-nav-burger"/, 'the header carries a burger' );
    like( $l, qr/class="mg-scrim"/,      'the shell carries a scrim' );
    like( $l, qr/<aside class="mg-sidebar" id="mg-sidebar">/,
        'the sidebar has an id, so the burger can point at it' );
};

subtest 'the sheet and the markup agree on the mechanism' => sub {
    like( $c, qr/\.mg-shell\[data-nav-open\]/,
        'the sheet opens the drawer from data-nav-open on the shell' );
    like( $l, qr/setAttribute\('data-nav-open'/,
        'and the script sets exactly that attribute' )
        or diag( 'If these two ever name different attributes the drawer is '
            . 'dead and nothing errors - CSS does not complain about a '
            . 'selector that never matches.' );
};

subtest 'it can be closed without a pointer' => sub {
    like( $l, qr/e\.key === 'Escape'/,
        'Escape closes the drawer' )
        or diag( 'A drawer covering the page that can only be dismissed by '
            . 'finding the scrim is a trap for anyone on a keyboard.' );
    like( $l, qr/aria-expanded="false"/, 'the burger declares its state' );
    like( $l, qr/setAttribute\('aria-expanded'/,
        'and keeps it truthful when the drawer moves' )
        or diag( 'A static aria-expanded is worse than none: it tells a screen '
            . 'reader the opposite of what is on screen half the time.' );
    like( $l, qr/aria-controls="mg-sidebar"/, 'and says what it controls' );
};

done_testing();
