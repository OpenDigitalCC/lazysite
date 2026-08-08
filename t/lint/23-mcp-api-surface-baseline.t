#!/usr/bin/perl
# SM239 (first cut): a BASELINE guard on the remote-surface shape.
#
# The two remote channels drifted apart one action at a time, with nothing
# recording whether a gap was deliberate - SM238 found the whole domain CRUD on
# the control API and absent from MCP, under the same manage_domains capability,
# which nobody had decided. Deciding every gap is the expensive half of SM239 and
# is deliberately NOT done here. This does the cheap half that stops the bleeding:
# it records today's shape and fails when it CHANGES, so the next divergence is a
# decision someone makes rather than a thing that happens.
#
# KNOWN LIMITATION, recorded so it is not mistaken for coverage: this compares
# capability-level shape, not action-level pairing. manage_domains reads as
# "paired" below - it has entries on both channels - while the domain CRUD SM238
# reported is entirely missing from MCP. Action-level pairing needs a name map
# between differently-spelled twins (read_form_submissions <-> form-submissions)
# and is the work SM239 still describes. This guard would not have caught SM238;
# it will catch the next capability whose surface changes shape.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use Lazysite::Capabilities qw(describe action_keys);

# The recorded shape: capability => "api=<n> mcp=<n> ui=<n> dav=<n>".
# Counts come from each capability's `unlocks` block, which t/unit/lib/05
# already pins to the live %TOOLS and %need maps - so a count here cannot drift
# from reality without that test failing too.
my %BASELINE = (
    analytics                  => 'api=1 mcp=1 ui=0 dav=0',
    audit                      => 'api=1 mcp=0 ui=0 dav=0',
    create_sub_users           => 'api=0 mcp=0 ui=1 dav=0',
    delegate_sub_user_creation => 'api=0 mcp=0 ui=1 dav=0',
    feedback                   => 'api=0 mcp=1 ui=0 dav=0',
    manage_config              => 'api=3 mcp=0 ui=0 dav=2',
    # SM240 added upload_file (26 -> 27): a binary write, deliberately MCP-only.
    # The control API has no twin and does not need one - a script or an agent on
    # the API channel already has WebDAV, which is the right tool for bulk bytes.
    manage_content             => 'api=6 mcp=27 ui=0 dav=1',
    manage_domains             => 'api=10 mcp=2 ui=0 dav=0',
    manage_forms               => 'api=0 mcp=2 ui=0 dav=1',
    manage_layouts             => 'api=5 mcp=4 ui=0 dav=1',
    manage_nav                 => 'api=3 mcp=1 ui=0 dav=1',
    manage_themes              => 'api=4 mcp=4 ui=0 dav=1',
    manage_users               => 'api=0 mcp=0 ui=1 dav=0',
    notifications              => 'api=0 mcp=0 ui=1 dav=0',
    read_submissions           => 'api=2 mcp=2 ui=0 dav=0',
);

# Divergences present today, each with why it is tolerated. "undecided" is an
# honest answer and the point of recording it: SM239's audit turns these into
# decisions. A capability may only appear here if it is genuinely one-sided.
my %ACCEPTED_DIVERGENCE = (
    audit         => 'API-only. Undecided (SM239) - an agent cannot read the audit trail over MCP.',
    manage_config => 'API-only. Undecided (SM239) - config-read/config-set/git-init have no MCP twin.',
    feedback      => 'MCP-only. Deliberate: submit_feedback is an agent-to-operator channel.',
    manage_forms  => 'MCP-only in `unlocks`. Undecided (SM239) - and the map itself looks incomplete, '
        . 'since form-targets-read/save exist as control-API actions. Verify before deciding.',
);

my $map   = describe();
my @acts  = action_keys();       # NOT `sort action_keys()` - that parses as
my @sorted = sort @acts;         # sort SUBNAME LIST and silently returns nothing.

is( scalar @sorted, scalar keys %BASELINE,
    'every capability is in the baseline (a new one must be recorded)' );

for my $a (@sorted) {
    my $u = $map->{capabilities}{$a}{unlocks} || {};
    my ( $api, $mcp, $ui, $dav ) =
        map { scalar @{ $u->{$_} || [] } } qw(api mcp ui webdav);
    my $shape = "api=$api mcp=$mcp ui=$ui dav=$dav";

    is( $shape, $BASELINE{$a} // '(not recorded)', "$a: remote surface shape unchanged" )
        or diag( "\n  '$a' changed shape: was '"
            . ( $BASELINE{$a} // 'not recorded' )
            . "', now '$shape'.\n"
            . "  If you added an action to ONE channel, decide whether the other needs\n"
            . "  the twin (SM239). Then update \%BASELINE here to the new shape.\n" );

    # A one-sided remote surface must carry a recorded reason.
    next if $api && $mcp;              # paired
    next if !$api && !$mcp;            # no remote surface at all (ui/webdav only)
    ok( $ACCEPTED_DIVERGENCE{$a},
        "$a: a one-sided remote surface has a recorded reason" );
}

# Nothing may sit in the divergence list once it is paired - a stale entry would
# read as a live decision.
for my $a ( sort keys %ACCEPTED_DIVERGENCE ) {
    my $u = $map->{capabilities}{$a}{unlocks} || {};
    my ( $api, $mcp ) = map { scalar @{ $u->{$_} || [] } } qw(api mcp);
    ok( !( $api && $mcp ),
        "$a: still one-sided, so its divergence entry is not stale" );
}

done_testing();
