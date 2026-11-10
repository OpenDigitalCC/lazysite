#!/usr/bin/perl
# n812 (Y10 of the 0.16.10 edge run): THE GROUPS PAGE'S "WHAT THIS GRANTS" FOR
# settle_odoo_writes SAYS WHERE THE PANEL IS.
#
# n804 (SM1424) put "its card on Extensions - configure" into the capability's
# `unlocks.ui` and the capability map. The Groups page does not draw `unlocks`: it
# draws the capability's `grants` label, which still read "... Held by the operator
# group by default." and named no page, so a tester reading it did not know where
# to go. One source: the declaration in extensions/odoo.pl; the capability map's
# row is built from it, and the phrase is held equal in all three places.
#
# With the clause removed from `grants` the first two assertions fail.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root mirror_engine);
use Lazysite::Capabilities ();

my $root = repo_root();
sub slurp { my ($p) = @_; open my $fh, '<', $p or die "$p: $!"; local $/; my $t = <$fh>; close $fh; return $t }

my $PHRASE = 'its card on Extensions - configure';

mirror_engine();
my $cap = Lazysite::Capabilities::describe()->{capabilities}{settle_odoo_writes};
ok( $cap, 'the capability is declared' ) or BAIL_OUT('no settle_odoo_writes');
like( $cap->{grants} // '', qr/\Q$PHRASE\E/, 'the "what this grants" label names where the panel is linked' );
like( $cap->{grants} // '', qr/Unknown Odoo writes/, 'and which panel it is' );
like( join( ' ', @{ $cap->{unlocks}{ui} || [] } ), qr/\Q$PHRASE\E/, 'the unlocks say the same' );

my ($row) = grep { /^settle_odoo_writes \|/ } split /\n/, slurp("$root/docs/reference/capability-map.md");
like( $row // '', qr/\Q$PHRASE\E/, 'and so does the capability map' );

Lazysite::Extensions::Declared::unmirror();
done_testing;
