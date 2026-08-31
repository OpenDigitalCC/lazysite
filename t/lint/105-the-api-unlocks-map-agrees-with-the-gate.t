#!/usr/bin/perl
# SM654, the control-API half: `unlocks.api` says what a capability opens, and
# the gate decides it. They must agree.
#
# WHY THIS COULD NOT BE WRITTEN BEFORE. SM654 recorded the reason plainly: the
# MCP half was pinned by t/lint/90, and the API half was not, because %need
# held PREDICATES - sub { $_[0]->{manage_content} } - and nothing can extract
# the capability from one without executing it. Restructuring a
# security-critical gate table is not a lint's business to force, so the half
# was recorded and left.
#
# SM662 restructured it. The gate DECLARES its capabilities now, so the answer
# is data, and this is the lint that was waiting for it.
#
# BOTH DIRECTIONS, because they fail differently:
#
#   OVER-CLAIMING  the map names an action the gate does not admit with this
#                  capability. An operator grants it expecting that action and
#                  is refused - visible, annoying, and self-correcting.
#   SILENCE        the gate admits an action the map does not mention. Nothing
#                  ever tells the operator, and the grant is quietly wider than
#                  the page they read before making it. This is the half that
#                  matters and the half nobody notices.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root gate_caps);

my $root = repo_root();
my $api  = do {
    open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
    local $/; <$fh>;
};

my %need = gate_caps($api);
cmp_ok( scalar keys %need, '>=', 60, 'the gate table was read' )
    or BAIL_OUT('no gate table - nothing to compare the map against');

require Lazysite::Capabilities;
# Through describe(), which is what the control API actually publishes - so
# this compares the gate with what an OPERATOR is shown, not with an internal
# structure that might differ from it.
my $CAPS = Lazysite::Capabilities::describe()->{capabilities};
ok( ref $CAPS eq 'HASH' && keys %{$CAPS}, 'the capability map was read' )
    or BAIL_OUT('no capability map');

# What the GATE says each capability opens: every action whose declared list
# names it. An action needing no capability belongs to nobody in particular and
# is not a claim any capability should make.
my %gate_opens;
for my $action ( keys %need ) {
    for my $cap ( keys %{ $need{$action} } ) {
        $gate_opens{$cap}{$action} = 1;
    }
}

# A CAPABILITY THAT GUARDS KEYS RATHER THAN ACTIONS.
#
# manage_services (SM633) is not a gate on config-set. The ACTION is gated on
# manage_config; manage_services is checked separately, against the particular
# KEYS that decide whether the remote surfaces answer at all - so a caller
# needs both, and holding manage_services alone opens nothing.
#
# The map naming config-set is therefore over-claiming by this test's
# definition and right by an operator's: it is what the capability governs. So
# it is an exemption WITH ITS REASON rather than a rule bent, and the same
# discipline as %API_ONLY in lint 23 - a second one has to be written down,
# which is the point.
my %map_exempt = (
    'manage_services' => { 'config-set' => 'guards KEYS within config-set '
        . '(the service killswitches), not the action - which is gated on '
        . 'manage_config. Holding manage_services alone opens nothing.' },
);

my ( @over, @silent );
for my $cap ( sort keys %{$CAPS} ) {
    my $claimed = $CAPS->{$cap}{unlocks}{api};
    next unless ref $claimed eq 'ARRAY';
    my %claims = map { $_ => 1 } @{$claimed};
    my $opens  = $gate_opens{$cap} || {};

    for my $a ( sort keys %claims ) {
        next if $map_exempt{$cap} && $map_exempt{$cap}{$a};
        push @over, "$cap claims '$a', which its gate does not admit"
            unless $opens->{$a};
    }
    for my $a ( sort keys %{$opens} ) {
        push @silent, "$cap admits '$a', and the map does not say so"
            unless $claims{$a};
    }
}

is( "@over", '', 'the map claims nothing the gate refuses' )
    or diag( join( "\n  ", '', @over )
        . "\n\nAn operator grants the capability for that action and is\n"
        . "refused. Visible and self-correcting, but it makes the page they\n"
        . "read before granting untrue." );

is( "@silent", '', 'the map names everything the gate admits' )
    or diag( join( "\n  ", '', @silent )
        . "\n\nThis is the half nobody notices: the grant is WIDER than the\n"
        . "page the operator read before making it, and nothing ever says so.\n"
        . "SM664 hit exactly this - git-history-summary is reachable with two\n"
        . "capabilities and was listed under one." );

done_testing();
