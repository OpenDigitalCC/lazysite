#!/usr/bin/perl
# SM834: on a narrow screen the Files trigger stays on the screen, in all three
# manager styles.
#
# Measured in the field (1311E-04): below ~465px the Files table's last column -
# the trigger SM816 gave a visible word - went past the viewport edge, 33 of 33
# rows at 420px. Nowrap on Access, Modified AND the trigger pinned the table's
# minimum at ~477px.
#
# THE FIX WAS MEASURED, NOT ASSUMED, in a real narrow viewport (Chromium, the
# fixture in an iframe so media queries evaluate at the iframe's width): at 420px
# the trigger went from 108px past the wrapper's edge to 0, and every column at
# 1000px was identical to before. Letting a table cell wrap only changes anything
# when the table cannot fit.
#
# THIS FILE PINS THE TRAP THAT MEASURING FOUND. The first version fixed modern
# and classic and left accessible 54px off the screen, because accessible
# declares its own generous cell padding LATER in the file and won by source
# order. Only measuring each stylesheet on its own showed it. So the assertion
# is about ORDER: in every style, the narrow override has to be the last word on
# a table cell's horizontal padding.
#
# Asserted from the source because a browser is not a dependency of this suite.
# The rig that measured it is described in SM834.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $dir = repo_root() . '/starter/lazysite/manager/assets';

for my $style (qw(modern classic accessible)) {
    my $f = "$dir/manager-$style.css";
    open my $fh, '<:utf8', $f or die "$f: $!";
    my $css = do { local $/; <$fh> };
    close $fh;
    ( my $bare = $css ) =~ s{/\*.*?\*/}{}gs;    # comments are not rules

    # the trigger is a control and must not wrap
    like( $bare, qr/\.mg-col-exp\s*\{\s*white-space:\s*nowrap;/,
        "$style: the trigger column does not wrap" );

    # Access and Modified may: the old combined nowrap rule is what pinned it
    unlike( $bare, qr/\.mg-col-access,\s*\.mg-col-mod,\s*\.mg-col-exp\s*\{[^}]*white-space:\s*nowrap/,
        "$style: Access and Modified are no longer held to one line" );

    # THE ORDER. Every declaration setting a table cell's padding, in the order
    # the browser applies them; the last must be the narrow override.
    my @rules;
    while ( $bare =~ /(\.mg-table th,\s*\.mg-table td\s*\{([^}]*)\})/g ) {
        my ( $whole, $body ) = ( $1, $2 );
        push @rules, $body if $body =~ /padding/;
    }
    ok( scalar @rules, "$style: found the table cell padding rules" );
    like( $rules[-1] // '', qr/padding-left:\s*6px;\s*padding-right:\s*6px/,
        "$style: the narrow override is the LAST word on cell padding" )
        or diag "$style: a later rule wins by source order, which is how "
        . 'accessible stayed 54px off a 420px screen while the others fitted';

    # and it only narrows the SIDES - accessible's vertical padding is its
    # target size, which is the point of that style
    unlike( $rules[-1] // '', qr/padding:\s*\d/,
        "$style: the override narrows the sides only, never the height" );
}

done_testing();
