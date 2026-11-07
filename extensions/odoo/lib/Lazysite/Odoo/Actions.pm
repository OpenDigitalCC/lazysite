package Lazysite::Odoo::Actions;

# SM1369 X2 (H-9): THE ODOO EXTENSION'S CONTROL-API AND MCP ACTIONS, as core
# runs them. The descriptor (extensions/odoo.pl, `hooks.api_actions`) names one
# function here per action; core's loader (Lazysite::Extensions::Hooks::
# call_hook) loads this module from the payload lib, only while the extension
# is on, and calls the function as
#
#     function( \%params, \%ctx )
#
# where %params are the action's declared parameters as the door read them
# (the query string, the JSON body, or the tool's arguments) and %ctx is who is
# asking: user, caps, groups, ip, channel, reach, plus docroot, extension and
# action. Each function hands that to the engine's own action_odoo_* exactly as
# the two doors' hand-written branches did before X2, so the wire is unchanged.
# The engine is told where the site is from the context, not from a global a
# door set.

use strict;
use warnings;

# The engine, told where the site is. Loaded here, not at compile time: the
# descriptor's --describe must not need it, and a door loads this module only
# when it dispatches one of these actions.
sub _engine {
    my ($ctx) = @_;
    require Lazysite::Odoo;
    no warnings 'once';
    $Lazysite::Odoo::DOCROOT = $ctx->{docroot};
    return 'Lazysite::Odoo';
}

# Who is asking, in the engine's shape (SM747 E): the verified account, its
# capabilities and groups, the request address, the door and its reach (E-Q1).
sub _who {
    my ($ctx) = @_;
    return (
        user    => $ctx->{user},
        caps    => ( ref $ctx->{caps} eq 'HASH'    ? $ctx->{caps}   : {} ),
        groups  => ( ref $ctx->{groups} eq 'ARRAY' ? $ctx->{groups} : [] ),
        ip      => $ctx->{ip},
        channel => $ctx->{channel},
        reach   => ( ref $ctx->{reach} eq 'HASH' ? $ctx->{reach} : {} ),
    );
}

# SM747 CU: the connection user. The key is set and cleared, never read.
sub status {
    my ( $p, $ctx ) = @_;
    return _engine($ctx)->can('action_odoo_status')->();
}

sub calls {
    my ( $p, $ctx ) = @_;
    return _engine($ctx)->can('action_odoo_calls')->( binding => $p->{binding}, limit => $p->{limit} );
}

sub secret_set {
    my ( $p, $ctx ) = @_;
    return _engine($ctx)->can('action_odoo_secret_set')
        ->( $p->{secret}, grant => $p->{grant}, login => $p->{login}, scheduled => $p->{scheduled} );
}

sub secret_clear {
    my ( $p, $ctx ) = @_;
    return _engine($ctx)->can('action_odoo_secret_clear')->( grant => $p->{grant}, scheduled => $p->{scheduled} );
}

# SM747 E: a bound operation, run by a signed-in caller. The binding gates it
# (its modes, callers and caps) inside Lazysite::Odoo, as a connector gates
# connector-call; this runs as the connection user, or as the grant's own Odoo
# account over MCP (Q2).
sub bindings {
    my ( $p, $ctx ) = @_;
    return _engine($ctx)->can('action_odoo_bindings')->( _who($ctx) );
}

sub run {
    my ( $p, $ctx ) = @_;
    return _engine($ctx)->can('action_odoo_run')->( $p->{binding}, $p->{params}, _who($ctx) );
}

sub confirm {
    my ( $p, $ctx ) = @_;
    return _engine($ctx)->can('action_odoo_confirm')->( $p->{plan}, _who($ctx) );
}

# SM1278 (rulings 10b, 10c): the runs left unknown, an operator's decision on
# one, and dismissing one. Listing and dismissing are settle_odoo_writes'; a
# resume is gated by the run's binding inside Lazysite::Odoo::resume, as a
# confirm is.
sub unknown_runs {
    my ( $p, $ctx ) = @_;
    return _engine($ctx)->can('action_odoo_unknown_runs')->( _who($ctx) );
}

sub resume {
    my ( $p, $ctx ) = @_;
    return _engine($ctx)->can('action_odoo_resume')
        ->( $p->{run}, $p->{assume_done}, $p->{assume_not_done}, _who($ctx) );
}

sub dismiss {
    my ( $p, $ctx ) = @_;
    return _engine($ctx)->can('action_odoo_dismiss')->( $p->{run}, $p->{reason}, _who($ctx) );
}

1;
