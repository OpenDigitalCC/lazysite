#!/usr/bin/perl
# SM217: the Domains list marks an alias, and does NOT say what a column already
# says.
#
# THIS PAGE ALREADY REMOVED AN ALIAS CHIP, with its reason recorded in the source:
# it meant "no content folder of its own", the Content folder column one place to
# the right already read "default site", and - being a chip - it looked like a
# button, so it was pressed and nothing happened. Two ways of saying one thing,
# and the removal was right.
#
# So the marker SM217 adds has to earn its place. What no column says is that two
# domains pointing at the SAME NAMED FOLDER are one site: both cells read
# `sites/acme` and nothing connects them. What every column already says is that a
# domain with no folder of its own serves the default site - which is exactly the
# `alias_of: (default)` case, and exactly the chip that was removed.
#
# The narrowing is therefore the whole of the design, and it is one `!==` that a
# later tidy would not think twice about deleting. Hence a guard, and hence one
# that names the earlier decision rather than just the condition.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
open my $fh, '<:utf8', "$root/starter/manager/domains.md" or die $!;
my $src = do { local $/; <$fh> };
close $fh;

like( $src, qr/row\.alias_of/,
    'the list reads alias_of, which domains-list derives' );

# THE NARROWING, asserted as the condition rather than as prose about it.
like( $src, qr/row\.alias_of\s*&&\s*row\.alias_of\s*!==\s*'\(default\)'/,
    'and shows the marker only when the shared root is a NAMED folder' )
    or diag( 'Without the (default) exclusion this is the chip the page already '
        . 'removed: a second way of saying what the Content folder column says, '
        . 'on every rootless domain.' );

# AND THE REASON TRAVELS WITH IT. A condition whose purpose is not written down
# beside it is the one a tidy deletes.
like( $src, qr/SM217.{0,400}deliberately NOT shown/s,
    'with the earlier decision named where the condition lives' );

# The marker is a TAG, in the page's own vocabulary - not a new class, which
# lint 100 would refuse anyway, and not a button: the removed chip's third
# failing was that it looked pressable and did nothing.
like( $src, qr/class="mg-tag"[^>]*>alias of /,
    'rendered as an mg-tag, like the language-set marker beside it' );
unlike( $src, qr/<button[^>]*>alias of/,
    'and never as a button - there is nothing to press' );

done_testing();
