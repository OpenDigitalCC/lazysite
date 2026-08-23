#!/usr/bin/perl
# SM494: every manager_caps.<cap> the manager layout gates on is DERIVED.
#
# The menu's capability answers come from a hand-written qw() list in the
# processor. manage_data was in @CAP_KEYS, the groups UI, the layout and the
# guide - and absent from that list, so the menu showed "Data tables"
# padlocked whatever a group granted, and the operator read their own
# successful grant as a failure. The nav tests hand manager_caps to the
# template, proving the layout and never the derivation.
#
# This file closes the class: extract every manager_caps.<cap> the layout
# references, and require each to appear in the derivation list. A capability
# added to the menu without joining the list is a red test, not a field
# report. The reverse is NOT checked - deriving a capability the layout does
# not yet gate on is preparation, not drift.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my $layout = do {
    open my $fh, '<', "$root/starter/lazysite/manager/layout.tt" or die $!;
    local $/; <$fh>;
};
my %gated = map { $_ => 1 } $layout =~ /manager_caps\.([a-z_]+)/g;
ok( %gated, 'the manager layout gates on at least one capability' );

my $proc = do {
    open my $fh, '<', "$root/lazysite-processor.pl" or die $!;
    local $/; <$fh>;
};
# The one derivation site: the qw() list resolved into %manager_caps. Anchored
# on the loop that fills it, so the lint fails loudly if the shape moves.
my ($list) = $proc =~ /for\s+my\s+\$cap\s*\(\s*qw\(([^)]*)\)/s;
ok( defined $list, 'found the manager_caps derivation qw() list' )
    or BAIL_OUT('the derivation moved; re-anchor this lint, do not delete it');
my %derived = map { $_ => 1 } split ' ', $list;

for my $cap ( sort keys %gated ) {
    ok( $derived{$cap},
        "manager_caps.$cap (gated on in the layout) is in the processor's derivation list" )
        or diag( "The menu will answer FALSE for '$cap' for every non-operator, "
            . 'whatever a group grants - the operator reads their own successful '
            . 'grant as a failure (SM494).' );
}

done_testing();
