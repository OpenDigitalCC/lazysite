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
#   visitor_scope_args       P15: which domains' traffic a caller asks for, and may
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

our @EXPORT_OK = qw(action_channel_services action_analyse_visitors _service_state action_version
    visitor_scope_args);

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

# P15 (WORK-PLAN-0154, ruled 2026-10-12 "Record host"): WHOSE TRAFFIC. Every
# first-party event carries the host that served it; analyse_visitors filters
# to one domain (`host`) and groups by domain (`by_host`), and a confined
# caller sees only its own domains' traffic - the SM976 rule, asked through
# Lazysite::Manager::Common::caller_may_reach_domain like every other domain
# question. One reading for both surfaces: the control API's analyse_visitors
# and MCP's.
#
# %opt: host, by_host, and the selectors (index, day, month, trails); %who is
# the caller as caller_may_reach_domain takes it (MCP passes its grant's
# scopes; the manager request passes nothing and is asked from its own state).
# Returns ( \@stats_args ) - the --host/--by-host arguments for the stats
# plugin - or ( undef, $refusal ).
#
# CONFINED: no `host` means every domain the caller reaches, and nothing else;
# a `host` it does not reach is refused as domain_reach_refusal refuses; a
# selector (index, day, month, trails) is refused, because the durable rollups
# and trails are the instance's, not split by domain. NOT CONFINED: as before,
# unless a host or by_host is asked for.
sub visitor_scope_args {
    my ( $opt, %who ) = @_;
    require Lazysite::Manager::Domains;
    no warnings 'once';
    local $Lazysite::Manager::Domains::DOCROOT = $DOCROOT if defined $DOCROOT;
    my $list = Lazysite::Manager::Domains::domains_list();
    my @known
        = map { $_->{is_primary} ? '' : lc( $_->{host} // '' ) } @{ ( ref $list eq 'HASH' && $list->{domains} ) || [] };
    @known = ('') unless @known;
    # Confined as caller_may_reach_domain reads it: a grant passed as `scopes`
    # always is; the manager request when its own state says so.
    my $confined = exists $who{scopes} ? 1 : Lazysite::Manager::Common::request_domain_confined();
    my $selector = $opt->{index} || grep { defined $opt->{$_} && length $opt->{$_} } qw(day month trails);

    my @hosts;
    my $host = $opt->{host};
    if ( defined $host && length $host ) {
        $host = lc $host;
        $host = '' if $host eq '(default)';
        return ( undef, { ok => 0, kind => 'not-found',
                error => "'$opt->{host}' is not a domain this instance serves - list_domains names them" } )
            unless grep { $_ eq $host } @known;
        if ( my $r = Lazysite::Manager::Common::domain_reach_refusal( %who, host => $host ) ) {
            return ( undef, $r );
        }
        @hosts = ($host);
    }
    elsif ($confined) {
        @hosts = grep { Lazysite::Manager::Common::caller_may_reach_domain( %who, host => $_ ) } @known;
        return ( undef, { ok => 0, kind => 'forbidden',
                error => 'This account reaches no domain on this instance, so it has no visitor traffic to read.' } )
            unless @hosts;
        # One domain reached on a one-domain instance is the whole instance: the
        # view and every selector are as they were.
        @hosts = () if @hosts == @known;
    }
    if ( @hosts && $selector ) {
        return ( undef, { ok => 0, kind => 'invalid',
                error => 'The index, the day and month rollups and the trails count every domain on this '
                    . 'instance together and are not split by domain'
                    . ( $confined ? ', and this account reaches only some of them' : '' )
                    . ' - ask for a window (window=N), which is counted per domain.' } );
    }
    my @args = map { ( '--host', ( length $_ ? $_ : '(default)' ) ) } @hosts;
    push @args, '--by-host' if $opt->{by_host};
    return ( \@args );
}

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

    # P15: whose traffic - one domain, grouped, and a confined caller's own.
    my ( $scope, $no ) = visitor_scope_args( \%opt );
    return $no unless $scope;

    my ( $out, $in );
    local $SIG{PIPE} = 'IGNORE';    # SM959: a child that exits early must not kill us
    my $pid = eval {
        open2( $out, $in, $^X, $tool, '--export', '--docroot', $DOCROOT, '--window', $window, @sel, @$scope );
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
