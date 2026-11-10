#!/usr/bin/perl
# SM1424 (n804): THE WORDS NAME THE PAGE THAT HAS THE CARD.
#
# An extension's panel is linked from its card (SM1369 H-8), and the cards are on
# "Extensions - configure" (/manager/extension-config), not on the enable/disable
# page /manager/extensions. The Odoo capability's `unlocks.ui` and the capability
# map generated from it said "its card on Extensions", and a tester looked for the
# link on the page that has no cards.
#
# With the change reverted both assertions fail.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
sub slurp { my ($p) = @_; open my $fh, '<', $p or die "$p: $!"; local $/; my $t = <$fh>; close $fh; return $t }

my $odoo = slurp("$root/extensions/odoo.pl");
like( $odoo, qr{linked from its card on Extensions - configure, /manager/extension-config\)},
    'the descriptor names the page that has the card' );

my ($row) = grep { /^settle_odoo_writes \|/ } split /\n/, slurp("$root/docs/reference/capability-map.md");
like( $row // '', qr{linked from its card on Extensions - configure, /manager/extension-config\)},
    'and so does the generated capability map' );

done_testing;
