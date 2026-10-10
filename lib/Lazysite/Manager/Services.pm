package Lazysite::Manager::Services;

# The instance's services, its version and the visitor stats: which channels are
# switched on and what each capability hands over (channel-services, and
# _service_state for whoami), the installed version (version), and the stats
# plugin's export (analyse_visitors). Moved unchanged out of
# lazysite-manager-api.pl by SM944 S26.
#
# Index
#   action_channel_services  channel-services: killswitches, sentences, owners
#   _stats_tool_path         the stats plugin (LAZYSITE_STATS_TOOL wins)
#   action_analyse_visitors  analyse_visitors: the stats export, for an account
#   _service_state           which transports are on (whoami reads it)
#   action_version           version: the install state's version
#
# The request context ($auth_user) is read from Lazysite::Manager::Common, which
# lazysite-manager-api.pl sets and nothing here assigns (t/lint/217). Loaded
# where no request set it, analyse_visitors refuses and runs no tool; the site
# facts answer (t/unit/manager/205). $DOCROOT and $LAZYSITE_DIR are set by the
# dispatcher, as for every manager module.

use strict;
use warnings;
use Exporter 'import';
use IPC::Open2;
use JSON::PP                   qw(decode_json);
use Lazysite::Util             ();
use Lazysite::Capabilities     qw(channel_service);
use Lazysite::Manager::Plugins qw(action_plugin_list);
use Lazysite::Manager::Common  qw($auth_user _tool_path);

our @EXPORT_OK = qw(action_channel_services action_analyse_visitors _service_state action_version);

our $DOCROOT;         # set by the script
our $LAZYSITE_DIR;    # set by the script

# SM180: the per-channel service state for the Groups/Users capability grids.
# A CHANNEL capability is DORMANT - granted but inert - when its site service is
# switched off. Returns { channel => 0|1 } for ui/webdav/api/mcp, read from the
# killswitches named by Lazysite::Capabilities::channel_service (the single
# source of truth). A cheap read of non-sensitive on/off booleans; the grids
# cross-reference it to show a "granted but the service is off" hint.
sub action_channel_services {
    my $map = channel_service();
    my %svc;
    for my $ch ( keys %$map ) {
        $svc{$ch} = Lazysite::Util::service_enabled( $DOCROOT, $map->{$ch} ) ? 1 : 0;
    }
    # SM277: the map itself, keyed by the lazysite.conf setting, so the Services
    # page can say which capability each switch governs without a second copy of
    # the mapping in JavaScript. Lazysite::Capabilities stays the one source.
    my %by_key = reverse %$map;

    # SM427: the plain-sentence statement of what each capability hands over,
    # served rather than restated. SM277 set this precedent in this same
    # function and for the same reason - the Groups page must not carry a
    # second copy of capability metadata in JavaScript, and here the copy at
    # risk is the SENTENCES, which are the part that has to be right.
    my $desc   = Lazysite::Capabilities::describe()->{capabilities} || {};
    my %grants = map { $_ => ( $desc->{$_}{grants} // '' ) }
        grep { length( $desc->{$_}{grants} // '' ) } keys %$desc;

    # SM675: which capabilities are owned by a PLUGIN, and whether that plugin
    # is on. `manage_data` grants nothing while the data plugin is disabled;
    # `manage_briefs` grants nothing while briefs is - every brief action
    # returns "the briefs plugin is disabled" before it looks at capabilities at
    # all. The Groups grid offered both as ordinary checkboxes, so an operator
    # granted one, the grid showed it on, whoami reported it held, and the
    # surface refused.
    #
    # DERIVED FROM THE PLUGIN'S OWN DECLARATION (`owns.capabilities`, ADR 0009),
    # not from a list here. A hand-kept map would be another copy of a fact the
    # plugins already state, and wrong the first time one changed.
    #
    # Served alongside the channel services for the same reason SM277 and SM427
    # put their maps here: the Groups page must not carry a second copy of
    # capability metadata in JavaScript.
    my %cap_plugin;
    for my $p ( @{ ( action_plugin_list() || {} )->{plugins} || [] } ) {
        my $owns = ( ref $p->{owns} eq 'HASH' && ref $p->{owns}{capabilities} eq 'ARRAY' )
            ? $p->{owns}{capabilities}
            : [];
        for my $c ( @{$owns} ) {
            $cap_plugin{$c} = {
                plugin  => $p->{id},
                name    => ( $p->{name} // $p->{id} ),
                enabled => ( $p->{_enabled} ? JSON::PP::true : JSON::PP::false ),
            };
        }
    }

    return { ok => 1, services => \%svc, channel_for_key => \%by_key,
        grants => \%grants, capability_plugin => \%cap_plugin,
        # SM758: the categories the Actions grid is drawn by, from the registry.
        sections => Lazysite::Capabilities::sections() };
}

# The visitor-stats plugin. LAZYSITE_STATS_TOOL wins.
sub _stats_tool_path { return _tool_path( 'LAZYSITE_STATS_TOOL', 'plugins/stats.pl' ) }

# SM095: visitor-log analysis over the control API (gated on `analytics`, like the
# MCP analyse_visitors tool). Returns the stats plugin's sanitised, cached export -
# aggregates + a capped event stream; never the raw log, a path, or a visitor IP.
sub action_analyse_visitors {
    my (%opt) = @_;
    # SM944 S26 (c), ruled 2026-10-10: THE STATS ARE READ FOR AN ACCOUNT. Inside
    # a request the dispatcher has refused an empty $auth_user (and required
    # `analytics`) before this runs, so it is never empty here; reached outside
    # one (the request context's reset leaves nobody) it ran the stats plugin and
    # returned its export with nobody asking (tmp/sm944-s26-refusal-probe.out).
    return { ok => 0, kind => 'forbidden',
        error => 'Visitor analysis is read for a signed-in account, and no account is asking.' }
        unless length $auth_user;
    my $tool = _stats_tool_path()
        or return { ok => 0, error => 'Visitor stats plugin not found' };
    my $window = ( defined $opt{window} && $opt{window} =~ /^\d+$/ ) ? $opt{window} : 30;

    # SM213: durable-store selectors. Validated to strict shapes and passed as exec
    # args (open2 list form - no shell), so they cannot inject.
    my @sel;
    if    ( $opt{index} ) { @sel = ('--index') }
    elsif ( defined $opt{day} && $opt{day} =~ /^\d{4}-\d{2}-\d{2}$/ ) {
        @sel = ( '--day', $opt{day} );
    }
    elsif ( defined $opt{month} && $opt{month} =~ /^\d{4}-\d{2}$/ ) {
        @sel = ( '--month', $opt{month} );
    }

    # SM394: one day's recorded trails. Same strict shape and same exec-arg
    # handling as the selectors above - the value never reaches a shell.
    elsif ( defined $opt{trails} && $opt{trails} =~ /^\d{4}-\d{2}-\d{2}$/ ) {
        @sel = ( '--trails', $opt{trails} );
    }

    my ( $out, $in );
    local $SIG{PIPE} = 'IGNORE';    # SM959: a child that exits early must not kill us
    my $pid = eval {
        open2( $out, $in, $^X, $tool, '--export', '--docroot', $DOCROOT, '--window', $window, @sel );
    } or return { ok => 0, error => 'Cannot run the stats plugin' };
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return eval { decode_json( $resp // '{}' ) } || { ok => 0, error => 'No stats output' };
}

# SM072: the running version, read from the install state .install-state.json.
# SM612: which transports the INSTANCE has switched on. Read through
# service_enabled, the same predicate the request gate uses, so "is this
# channel on" has one answer wherever it is asked.
sub _service_state {
    my %map = (
        api    => 'control_api_enabled',
        mcp    => 'mcp_enabled',
        webdav => 'webdav_enabled',
        oauth  => 'oauth_enabled',
    );
    my %on;
    for my $ch ( sort keys %map ) {
        $on{$ch} = Lazysite::Util::service_enabled( $DOCROOT, $map{$ch} )
            ? JSON::PP::true
            : JSON::PP::false;
    }
    return \%on;
}

sub action_version {
    my $path = "$LAZYSITE_DIR/.install-state.json";
    # SM907: the guard that stood here made an unreadable install state
    # indistinguishable from a site installed before the state file existed, and
    # both answered `version: null`. The answer shape is unchanged - a client
    # cannot act on it either way - but the host now says which it was.
    open my $fh, '<', $path or do {
        Lazysite::Util::cannot_read( '.install-state.json', $path ) unless $!{ENOENT};
        return { ok => 1, version => undef };
    };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { decode_json($raw) } || {};
    return { ok => 1, version => $d->{version}, installed_at => $d->{installed_at} };
}

1;
