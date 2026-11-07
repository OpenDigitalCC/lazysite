package Lazysite::Extensions::Declared;

# SM1369 X2 (H-7, H-9): THE FULL SCOPE OF THE MIRROR, THE CROSS-CHECKS, AND THE
# ONE RUNNER FOR A DECLARED ACTION.
#
# Lazysite::Extensions::Hooks validates a declaration's kinds and mirrors the
# LIGHT scope of the index (the capability names and the refusal statuses),
# which is all a grant resolver or a page endpoint needs - and all the
# processor's pooled workers may carry (t/lint/269). This module is the rest:
# the capability map (Lazysite::Capabilities) and the gate and action tables
# (Lazysite::ControlApi::Actions) filled from the same index, the checks that
# read core's names at the index build, and run_action, which the two doors
# dispatch a declared row through. The doors, the users tool, the docs
# generator and the lints load this; nothing the processor loads names it.
#
# The order is the security model: a declaration is VALIDATED (Hooks) and
# CROSS-CHECKED (check_declared, here) at the build, before anything is
# indexed; the mirror refuses a core name a second time (the declare functions
# of each table); run_action requires the extension on NOW, its hooks indexed,
# and runs the handler through X1's loader, which checks the module is the
# extension's own.

use strict;
use warnings;
use Exporter 'import';
use Lazysite::Paths             ();
use Lazysite::Extensions::Hooks ();

our @EXPORT_OK = qw(check_declared mirror mirror_index unmirror run_action);

sub _err {
    my ( $id, $key, $why ) = @_;
    return { extension => $id, key => $key, error => $why };
}

sub _plain {
    my ($v) = @_;
    return defined $v && !ref $v ? 1 : 0;
}

# THE CROSS-CHECKS, once the kinds validate on their own: every capability the
# extension owns is described and every description names an owned capability;
# a section is one the grids know; nothing declared shadows a core name (a
# capability, an action, a tool, a refusal kind); a gate names capabilities
# that exist (core's or the extension's own). Returns problems in Owns' shape.
# Run at the index build and by the lints.
sub check_declared {
    my ( $id, $owns ) = @_;
    return () unless ref $owns eq 'HASH';
    my $hooks = ref $owns->{hooks} eq 'HASH' ? $owns->{hooks} : {};
    my @bad;
    my @caps = ref $owns->{capabilities} eq 'ARRAY' ? grep { _plain($_) } @{ $owns->{capabilities} } : ();
    my $info  = ref $hooks->{capability_info} eq 'HASH' ? $hooks->{capability_info} : {};
    my $rows  = ref $hooks->{api_actions} eq 'ARRAY'    ? $hooks->{api_actions}     : [];
    my $kinds = ref $hooks->{refusal_kinds} eq 'HASH'   ? $hooks->{refusal_kinds}   : {};
    return () unless @caps || %$info || @$rows || %$kinds;

    my %own = map { $_ => 1 } @caps;
    if ( %$info || @$rows ) {
        push @bad, _err( $id, 'capabilities', "'$_' is owned and not described in hooks.capability_info" )
            for grep { !exists $info->{$_} } @caps;
    }
    push @bad, _err( $id, 'hooks.capability_info', "'$_' is described and not in owns.capabilities" )
        for grep { !$own{$_} } sort keys %$info;

    require Lazysite::Auth::Settings;
    require Lazysite::Capabilities;
    my %core_cap = map { $_ => 1 } Lazysite::Auth::Settings::core_capability_keys();
    push @bad, _err( $id, 'capabilities', "'$_' is a core capability, which an extension can never own or shadow" )
        for grep { $core_cap{$_} } @caps;
    for my $cap ( sort keys %$info ) {
        my $m = ref $info->{$cap} eq 'HASH' ? $info->{$cap} : {};
        push @bad, _err( $id, 'hooks.capability_info', "$cap: section '$m->{section}' is not one of "
                . join( ', ', @Lazysite::Capabilities::SECTIONS ) )
            if _plain( $m->{section} ) && !grep { $_ eq $m->{section} } @Lazysite::Capabilities::SECTIONS;
        push @bad, _err( $id, 'hooks.capability_info', "$cap: top_up_from names '$_', which is no capability" )
            for grep { !$core_cap{$_} && !$own{$_} } @{ ref $m->{top_up_from} eq 'ARRAY' ? $m->{top_up_from} : [] };
    }

    require Lazysite::ControlApi::Actions;
    for my $r ( grep { ref $_ eq 'HASH' } @$rows ) {
        my $name = _plain( $r->{name} ) ? $r->{name} : next;
        push @bad, _err( $id, 'hooks.api_actions', "'$name' is a core action, which an extension can never shadow" )
            if Lazysite::ControlApi::Actions::is_core_action($name);
        push @bad, _err( $id, 'hooks.api_actions', "'$r->{mcp}' is a core tool, which an extension can never shadow" )
            if _plain( $r->{mcp} ) && Lazysite::ControlApi::Actions::is_core_tool( $r->{mcp} );
        if ( ref $r->{gate} eq 'ARRAY' ) {
            push @bad, _err( $id, 'hooks.api_actions', "'$name' is gated on '$_', which is no capability of core's or this extension's" )
                for grep { _plain($_) && !$core_cap{$_} && !$own{$_} } @{ $r->{gate} };
        }
    }

    if (%$kinds) {
        require Lazysite::Manager::Common;
        no warnings 'once';
        push @bad, _err( $id, 'hooks.refusal_kinds', "'$_' is a core refusal kind, which an extension can never redefine" )
            for grep { exists $Lazysite::Manager::Common::REFUSAL_STATUS{$_} } sort keys %$kinds;
    }
    return @bad;
}

# The api and mcp halves of a capability's `unlocks`, derived from the rows
# whose gate names it (the gate is what decides, so the map cannot over- or
# under-claim - lint 90's two directions, by construction).
sub _unlocks_of {
    my ( $cap, $info, $rows ) = @_;
    my ( @api, @mcp );
    for my $r ( grep { ref $_ eq 'HASH' && ref $_->{gate} eq 'ARRAY' } @$rows ) {
        next unless grep { $_ eq $cap } @{ $r->{gate} };
        push @api, $r->{name};
        push @mcp, $r->{mcp} if defined $r->{mcp};
    }
    my %u  = ( api => \@api, mcp => \@mcp );
    my $ui = ref $info->{unlocks} eq 'HASH' ? $info->{unlocks}{ui} : undef;
    $u{ui} = [@$ui] if ref $ui eq 'ARRAY' && @$ui;
    return \%u;
}

# Fill every table from an index: the light scope first (Hooks), then the
# capability map and the gate and action tables. Replaces what an earlier
# mirror put there, so a rebuilt index is read whole. A declaration the build
# let through that a table refuses (a core name, from a hand-edited index) is
# skipped with a WARN. Returns the ids mirrored.
sub mirror_index {
    my ( $index, $sig ) = @_;
    unmirror();
    my @ids = Lazysite::Extensions::Hooks::mirror_index( $index, $sig );
    my $decl = ref $index eq 'HASH' && ref $index->{declared} eq 'HASH' ? $index->{declared} : {};
    require Lazysite::Capabilities;
    require Lazysite::ControlApi::Actions;
    for my $id (@ids) {
        my $e    = $decl->{$id};
        my $info = ref $e->{capability_info} eq 'HASH' ? $e->{capability_info} : {};
        my $rows = ref $e->{api_actions} eq 'ARRAY'    ? $e->{api_actions}     : [];
        my @why;
        for my $cap ( grep { ref $info->{$_} eq 'HASH' } sort keys %$info ) {
            push @why, Lazysite::Capabilities::declare_capability( $id, $cap,
                { %{ $info->{$cap} }, unlocks => _unlocks_of( $cap, $info->{$cap}, $rows ) } );
        }
        push @why, Lazysite::ControlApi::Actions::declare_action( $id, $_ ) for grep { ref $_ eq 'HASH' } @$rows;
        if (@why) {
            require Lazysite::Util;
            Lazysite::Util::log_event( 'WARN', 'extension-hook', 'a declaration in the index was not mirrored',
                extension => $id, why => join( '; ', @why ) );
        }
    }
    Lazysite::Extensions::Hooks::mirror_state()->{scope} = 'full';
    return @ids;
}

sub unmirror {
    require Lazysite::Capabilities;
    require Lazysite::ControlApi::Actions;
    Lazysite::Capabilities::undeclare_capabilities();
    Lazysite::ControlApi::Actions::undeclare_actions();
    Lazysite::Extensions::Hooks::unmirror();
    return;
}

# Mirror a site's index into this process, full scope, once per index: a
# second call with the same file is a stat, and a light mirror of the same
# index is widened. Returns 1 when the tables changed.
sub mirror {
    my ($lz) = @_;
    return 0 unless defined $lz && length $lz;
    my $index = Lazysite::Extensions::Hooks::read_index($lz);
    my $sig   = Lazysite::Extensions::Hooks::index_signature($lz);
    my $state = Lazysite::Extensions::Hooks::mirror_state();
    return 0 if defined $state->{sig} && $state->{sig} eq $sig && ( $state->{scope} // '' ) eq 'full';
    mirror_index( $index, $sig );
    return 1;
}

# RUN ONE DECLARED ACTION, from either door. $name is the control-API action
# (the twin's row is the same row); \%params are its declared parameters as the
# door read them; \%ctx is who is asking (user, caps, groups, ip, channel,
# reach), to which the docroot, the extension and the action are added. The
# extension must be on NOW and its hooks indexed; call_hook checks the rest.
# Answers a result hash in the doors' shape, always.
sub run_action {
    my ( $docroot, $name, $params, $ctx ) = @_;
    require Lazysite::ControlApi::Actions;
    no warnings 'once';
    my $spec = $Lazysite::ControlApi::Actions::ACTION{ $name // '' };
    my $id   = ref $spec eq 'HASH' ? $spec->{extension} : undef;
    return { ok => 0, kind => 'not-found', error => 'Unknown action: ' . ( $name // '' ) } unless defined $id;
    my $lz    = Lazysite::Paths::lazysite_dir($docroot);
    my $index = Lazysite::Extensions::Hooks::read_index($lz);
    my $decl  = ref $index->{declared} eq 'HASH' ? $index->{declared}{$id}     : undef;
    my $key   = ref $decl eq 'HASH'              ? $decl->{key}                : undef;
    my $label = ref $decl eq 'HASH' && _plain( $decl->{name} ) ? $decl->{name} : $id;
    unless ( defined $key && Lazysite::Extensions::Hooks::enabled_keys($lz)->{$key} ) {
        return { ok => 0, kind => 'disabled',
            error => "This extension ($label) is off, so $name cannot run - a sysop can enable it on the Extensions page." };
    }
    my ( $ok, @out ) = Lazysite::Extensions::Hooks::call_hook( $docroot, $id, $spec->{handler}, $params // {},
        { %{ $ctx || {} }, docroot => $docroot, extension => $id, action => $name } );
    unless ($ok) {
        return { ok => 0, kind => 'cannot-tell',
            error => "$name cannot run now: $out[0]. Enabling, saving or upgrading the extension rebuilds its index." };
    }
    return $out[0] if ref $out[0] eq 'HASH';
    return { ok => 0, kind => 'internal', error => "$name answered nothing this door can send" };
}

1;
