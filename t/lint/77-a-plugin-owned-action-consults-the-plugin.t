#!/usr/bin/perl
# SM469 / ADR 0009: an action gated on a PLUGIN-OWNED capability must consult
# that plugin's enabled state.
#
# THE HOLE THIS CLOSES. The ADR's first clause is "off means off - every
# dispatch path consults the enabled state", and SM409 built the gate. What it
# covers is plugin SCRIPT execution, the `plugin-action` path. The six data
# actions dispatched straight into Lazysite::Manager::Data and never went near
# it, so disabling the data plugin changed nothing about them.
#
# Nothing caught that, and the reason is worth stating: a plugin OWNING
# control-API actions is a new shape. Before the data plugin there was no such
# path for the gate to miss, so no test was looking for one. It was found while
# writing a test brief, not by testing.
#
# So the fix that matters is not the three lines in the manager module - it is
# this, which asserts the property for whatever owns a capability NEXT. Without
# it the second plugin to own actions reintroduces the same gap silently, and
# the symptom is a plugin an operator has turned off that keeps working.
use strict;
use warnings;
use Test::More;
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use Lazysite::ControlApi::Actions ();

my $root    = "$FindBin::Bin/../..";
my $plugins = "$root/plugins";
plan skip_all => 'no plugins directory' unless -d $plugins;

# Which capabilities are plugin-owned, and which module answers for them.
my %owner;
for my $f ( sort glob "$plugins/*.pl" ) {
    my $d = eval { decode_json( `$^X \Q$f\E --describe 2>/dev/null` ) };
    next unless ref $d eq 'HASH' && ref $d->{owns} eq 'HASH';
    $owner{$_} = ( $f =~ s{.*/}{}r ) for @{ $d->{owns}{capabilities} || [] };
}

plan skip_all => 'no plugin declares a capability' unless %owner;

# The actions gated on one of those capabilities.
my %guarded;
my $actions = \%Lazysite::ControlApi::Actions::ACTION;
for my $a ( sort keys %{$actions} ) {
    my $caps = $actions->{$a}{caps};
    next unless ref $caps eq 'ARRAY';
    for my $c ( @{$caps} ) {
        push @{ $guarded{ $owner{$c} } }, $a if $owner{$c};
    }
}

ok( scalar keys %guarded,
    'at least one control-API action is gated on a plugin-owned capability' )
    or diag( 'With none, this test is green and empty - the exact failure '
        . 'mode it exists to catch one layer down.' );

# The dispatch chain, to find which module each action calls into.
my $api = do {
    open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!;
    local $/;
    <$fh>;
};

for my $plugin ( sort keys %guarded ) {
    my @acts = @{ $guarded{$plugin} };

    # Which modules those actions dispatch into. Read from the chain rather
    # than assumed, so a future action routed somewhere else is still checked.
    my %modules;
    for my $a (@acts) {
        my ($branch)
            = $api =~ /\$action\s+eq\s+'\Q$a\E'\s*\)\s*\{(.*?)\n\}/s;
        next unless defined $branch;
        $modules{$1} = 1 while $branch =~ /(Lazysite::[\w:]+)::\w+\s*\(/g;
    }

    ok( scalar keys %modules, "$plugin: its actions dispatch somewhere known" )
        or diag( "could not read the dispatch for: @acts" );

    # Each of those modules must consult the enabled state.
    for my $m ( sort keys %modules ) {
        ( my $path = $m ) =~ s{::}{/}g;
        my $file = "$root/lib/$path.pm";
        next unless -f $file;
        my $src = do { open my $fh, '<', $file or die $!; local $/; <$fh> };
        like( $src, qr/plugin_enabled/,
            "$m consults the enabled state (for $plugin)" )
            or diag( "$m answers for a capability owned by $plugin, and never "
                . "asks whether $plugin is enabled. An operator turning the "
                . 'plugin off would see no change - which is the state SM409 '
                . 'exists to remove.' );
    }
}

# And the owning plugin must have opted INTO the gate, or the gate is not
# watching it: _gate_execution treats a descriptor with no `contract` key as a
# legacy plugin and leaves it ungated. That default is deliberate - existing
# plugins keep running until each migration SM enables them - which is exactly
# why a NEW plugin declaring a capability has to say so.
for my $plugin ( sort values %owner ) {
    my $d = eval { decode_json( `$^X \Q$plugins/$plugin\E --describe 2>/dev/null` ) };
    ok( $d && $d->{contract},
        "$plugin declares `contract`, so the enabled gate applies to it" )
        or diag( 'Without it the gate treats this as a legacy plugin and does '
            . 'not gate it at all - so the module-side check above would be '
            . 'asking a question whose answer is always yes.' );
}

done_testing();
