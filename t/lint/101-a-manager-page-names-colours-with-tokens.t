#!/usr/bin/perl
# A manager page does not hard-code a colour.
#
# Eighty inline styles across ten pages named a literal - color:#888,
# color:#b00, background:#fff. A literal is THEME-BLIND twice over: it does not
# move when the viewer switches light and dark, and it does not move when the
# operator selects a different manager style. #555 is near-invisible on the
# dark background; #fff text is invisible on the light one.
#
# This is why the manager looked inconsistent in a way no stylesheet change
# could fix: the sheet was never being asked. The tokens already existed.
use strict;
use warnings;
use Test::More;
use FindBin;

my $root = "$FindBin::Bin/../..";
my @found;
for my $f ( sort glob "$root/starter/manager/*.md" ) {
    ( my $name = $f ) =~ s{.*/}{};
    my $src = do { open my $fh, '<', $f or die $!; local $/; <$fh> };
    while ( $src =~ /style="([^"]*)"/g ) {
        my $body = $1;
        while ( $body =~ /([a-z-]+)\s*:\s*(#[0-9a-fA-F]{3,6})/g ) {
            push @found, "$name: $1:$2";
        }
    }
}

is( "@found", '', 'no manager page hard-codes a colour in an inline style' )
    or diag( "Literal colours:\n  " . join( "\n  ", @found )
        . "\n\nUse a token: --mg-text, --mg-text-muted, --mg-text-light for\n"
        . "greys; --mg-danger, --mg-success, --mg-warning for meaning;\n"
        . "--mg-surface / --mg-surface-alt for backgrounds. A literal does not\n"
        . "follow the light/dark choice OR the selected manager style, so it\n"
        . "is wrong in at least one of the six combinations this ships." );

done_testing();
