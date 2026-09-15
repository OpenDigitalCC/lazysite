#!/usr/bin/perl
# SM888 S3 / K6: every headline number on the stats page says what it is a
# count OF.
#
# THE SHAPE OF THE DEFECT, which is why this is a rule and not two fixes.
# N141B-F found "Unique visitors" showing 48 where the same field name meant
# 153 on another surface: the value was deliberate - human class only, to pair
# with Page views - and the LABEL claimed all visitors. It built
# `tile(label, value, note)` for exactly this and applied it to the one tile it
# had been asked about. Page views, Images and files and Data served were left
# bare, so the page still answered "48 of what?" for three of its five tiles.
#
# AND ONE OF THEM COUNTS A DIFFERENT POPULATION. `bytes` is accumulated for
# EVERY caller, before the human filter the other three sit behind - so three
# tiles in one row count people and the fourth counts scanners too. Whichever
# way that is resolved, the tile has to say which it is, because a sysop
# dividing Data served by Page views is otherwise dividing by the wrong number.
#
# WHAT THIS CHECKS, and what it deliberately does not: that a tile showing a
# COUNT carries a note. It does not check the wording - that would pin prose
# and break on an improvement - and it does not require a note on a tile whose
# value is self-describing (`Window`, "30 days").
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $page = repo_root() . '/starter/manager/stats.md';
open my $fh, '<', $page or BAIL_OUT("no stats page at $page: $!");
my $src = do { local $/; <$fh> };
close $fh;

# CHUNKED, not paren-matched. The first draft of this file matched a call up to
# its closing paren and a line break, and found two of the four counting tiles:
# the calls are laid out differently from each other and a comment sits between
# two of them. A check that silently examines half of what it names is the
# thing this file exists to prevent, so the split is on the call keyword and
# each chunk runs to the next one.
my @chunks = split /\btile\(/, ( $src =~ /mg-stat-tiles(.*?)<\/div>';/s )[0] // '';
shift @chunks;    # whatever preceded the first call
cmp_ok( scalar @chunks, '>=', 5, 'the tile calls were found' )
    or diag( 'If this drops, the extraction stopped matching and every '
        . 'assertion below would pass by examining nothing.' );

# A tile whose value is a formatted NUMBER is a count. fmtNum and fmtBytes are
# the page's own formatters, so this asks the page rather than guessing from a
# label.
my %SELF_DESCRIBING = ( 'Window' => 'the value carries its own unit - "30 days"' );

my $checked = 0;
for my $chunk (@chunks) {
    my ($plain) = $chunk =~ /\A\s*'([^']*)'/;
    next unless defined $plain;

    next unless $chunk =~ /fmtNum\(|fmtBytes\(/;
    next if $SELF_DESCRIBING{$plain};
    $checked++;

    # The note is the argument AFTER the value: a comma following the
    # formatter's closing paren.
    ok( $chunk =~ /fmt(?:Num|Bytes)\([^()]*(?:\([^()]*\))?[^()]*\)\s*,/s,
        "the '$plain' tile says what it counts" )
        or diag( "tile('$plain', ...) shows a number and no note.\n"
            . 'A headline figure with no denominator is one a sysop quotes, '
            . 'and the tiles beside it do not all count the same population.' );
}

cmp_ok( $checked, '>=', 4, 'counting tiles were found to check' );

# The Devices block, where the numbers are page views and the label is a device
# name - "mobile: 412" with no denominator invites "visitors" or "sessions".
# Stated in the block rather than a tooltip, because an opened block is being
# read rather than glanced at.
my ($dev) = $src =~ /(if \(d\.devices.*?block\( 'devices'.*?\);)/s;
ok( $dev, 'the devices block was located' );

# COMMENTS STRIPPED FIRST, and a sabotage is why. The first version matched
# /page views/ against the raw window, and the explanatory COMMENT above the
# block says "They are PAGE VIEWS, human only" - so removing the line the
# reader actually sees left the check passing on the comment that explains it.
# A check satisfied by its own rationale is worse than no check.
( my $dev_emitted = $dev // '' ) =~ s{^\s*//.*$}{}mg;
like( $dev_emitted, qr/page views/i,
    'the devices block names what its numbers count, in what it EMITS' )
    or diag( 'Device counts are human PAGE VIEWS with assets excluded '
        . '(SM336 item 6), which is not what a reader assumes.' );

done_testing();
