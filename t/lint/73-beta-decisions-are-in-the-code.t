#!/usr/bin/perl
# Two release-manager decisions, asserted where they live.
#
# SM462: adding a principal grants BOTH rights. It defaulted to read on,
# write off - and an empty write list means NO RESTRICTION, so the ordinary
# way of restricting a file produced a rule that locked reads and left writes
# open. An operator was shown "rw", the stored rule was read-only, and they
# found they could SAVE a file they could not PREVIEW.
#
# Read+write fails SAFE: too few people able to write is a nuisance, too many
# is the thing the feature exists to prevent. The per-chip toggles are
# untouched, so narrowing it back is one visible click.
#
# SM461: the all-files History OVERVIEW is hidden for this release - it fails
# with a JSON parse error while its data is fine, and diagnosing it needs a
# browser. The per-file History panel is NOT hidden: that one is a file
# operation, it works, and hiding it would remove something useful to fix
# something else.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $page = repo_root() . '/starter/manager/files.md';
# SM664: the all-files overview moved to the Plugin Config page, so the decision
# recorded below is now held across two files - one that must NOT carry it, and
# one that must.
my $ppage = repo_root() . '/starter/manager/plugin-config.md';
plan skip_all => 'manager pages missing' unless -f $page && -f $ppage;
my $src  = do { open my $fh, '<', $page  or die $!; local $/; <$fh> };
my $plug = do { open my $fh, '<', $ppage or die $!; local $/; <$fh> };

subtest 'SM462: a new principal gets read AND write' => sub {
    my ($fn) = $src =~ /function addPrincipal\(sel\)\s*\{(.*?)\n\}/s;
    ok( defined $fn, 'addPrincipal is present' ) or BAIL_OUT('cannot find it');
    like( $fn, qr/chipHtml\(name, 1, 1\)/,
        'both rights are on by default' )
        or diag( 'read-on/write-off stores an EMPTY write list, and an empty '
            . 'list means no restriction - so the file ends up readable by '
            . 'fewer people than can write it.' );
    unlike( $fn, qr/chipHtml\(name, 1, 0\)/, 'and not read-only' );
};

subtest 'SM461/SM664: the overview was hidden, then shown, and has now moved' => sub {
    # THIS ASSERTION USED TO SAY THE OPPOSITE, and the reversal is the point of
    # keeping it rather than deleting it.
    #
    # For 0.10.22 the overview was hidden unconditionally: it reported a JSON
    # parse error against data that was fine, and a panel that blames the data
    # teaches an operator to distrust it. That was a decision to hold a symptom
    # still, not a fix, and this test held it in place so it could not drift
    # back by accident.
    #
    # The cause is now fixed - the page read any non-JSON body as malformed
    # data - so the decision has been SUPERSEDED rather than abandoned.
    #
    # AND SUPERSEDED AGAIN, by SM664 on 2026-08-28: the overview is no longer on
    # this page at all. It moved to the content-history plugin's own row, which
    # is where SM461's placement half argued it belonged before that half was
    # declined. So this assertion flips a THIRD time - hidden, then shown, now
    # moved - and what it guards is that the move was complete: the Files page
    # keeps no copy, and the control is offered where the plugin lives.
    #
    # The enabled-check that used to matter here is now structural rather than
    # conditional: the Plugin Config page renders a row only for an ENABLED
    # plugin, so there is no state in which the button appears and can only
    # answer "not enabled".
    unlike( $src, qr/hist-overview/,
        'the Files page keeps no copy of the overview' )
        or diag( 'Two copies drift, and only one of them gets fixed.' );
    like( $plug, qr/openHistoryOverview\(\)/,
        'and the Plugin Config page offers it' );
    like( $plug, qr/plugin\.id === 'content-history'/,
        'on the content-history row, which renders only when enabled' );

    # The per-file panel must survive, as it had to before. Hiding it would
    # remove something that works to fix something that did not.
    like( $src, qr/toggleHistory\(this\)/,
        'the per-file History control is still offered' )
        or diag( 'That one IS a file operation and belongs beside the file.' );
};

done_testing();
