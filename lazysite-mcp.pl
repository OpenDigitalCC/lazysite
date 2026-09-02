#!/usr/bin/perl
# lazysite-mcp.pl - SM076: a remote MCP server exposing lazysite SITE
# MAINTENANCE as tools an AI client (Claude.ai custom connector, Claude
# Desktop/Code) can call. Streamable-HTTP JSON-RPC over a single endpoint
# (POST = client->server request + JSON response; GET = 405 in v1, no SSE).
#
# Auth (v1): a static bearer token presented as `Authorization: Bearer
# <partner-id>:<lzs_ token>` - the same credential the control API verifies, so
# capabilities + per-file ACLs apply identically. (OAuth 2.1 is a documented
# v2; Claude.ai connectors accept a static bearer today.) A token client is
# never a manager operator, so per-file ACLs bind it exactly as over WebDAV.
#
# The tools are thin wrappers over the shared Lazysite::* action handlers; this
# script owns only the transport, the bearer auth, and the per-tool capability
# gate. It deliberately exposes maintenance verbs (files, theming, permissions),
# not the manager-only operations (user admin, secrets).
use strict;
use warnings;
use JSON::PP       qw(encode_json decode_json);
use File::Basename qw(dirname);
use IPC::Open2;

BEGIN {
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}
use Lazysite::Util           qw(log_event);
use Lazysite::Paths          ();
use Lazysite::Audit          qw(audit_log);
use Lazysite::Capabilities   qw(describe);
use Lazysite::Auth::OAuth    ();
use Lazysite::Manager::Files qw(action_list action_read action_save action_delete
    action_save_binary
    action_move action_acl_get action_acl_set action_acl_remove
    action_git_history action_git_history_summary action_git_show action_git_restore);
use Lazysite::Manager::Themes qw(action_theme_activate action_layout_activate
    action_cache_invalidate _read_active_layout_and_theme action_themes_list_all
    action_theme_tokens action_create_theme theme_config_issues
    _layout_declared_tokens _theme_config_tokens _token_mismatch
    _token_warning_list);
use Lazysite::Manager::Nav     qw(action_nav_read action_nav_save);
use Lazysite::Manager::Layouts qw(action_layouts_manifest action_layout_install
    action_layout_delete action_layouts_available);
use Lazysite::Manager::Domains     ();
use Lazysite::Manager::Data        ();
use Lazysite::Manager::SitePackage qw(package_create apply_and_configure);
use Lazysite::Manager::Plugins     qw(action_form_submissions action_form_list);
use Lazysite::Lang                 qw(set_members);

our $VERSION = '0.1';
my $PROTOCOL = '2025-11-25';
# Cap a single read_file response so a huge file can't produce a slow/oversized
# reply that trips the client's per-call timeout. Normal pages are a few KB.
my $MAX_READ_BYTES = 512 * 1024;

# SM556: resolved once, here, as the control API does - one spelling of the
# tree for every module's confinement check.
my $DOCROOT      = Lazysite::Paths::canonical_docroot( $ENV{DOCUMENT_ROOT} // '' );
my $LAZYSITE_DIR = Lazysite::Paths::lazysite_dir($DOCROOT);                        # SM293
my $LOCK_DIR     = "$LAZYSITE_DIR/manager/locks";
$Lazysite::Auth::OAuth::LAZYSITE_DIR = $LAZYSITE_DIR;
# Set early so verify_bearer (which runs before setup_context) can audit a connect.
$Lazysite::Audit::LAZYSITE_DIR = $LAZYSITE_DIR;

# How the current request authenticated, for whoami to surface the real session
# lifetime (an OAuth access token expires ~hourly even when the partner's static
# token_expires_at is null).
my %AUTH_INFO = ( method => 'none', expires_at => undef );

# --- output helpers -------------------------------------------------------

sub send_json {
    my ($obj) = @_;
    my $body = encode_json($obj);
    # encode_json already emits UTF-8 bytes; print them raw. A :utf8 layer here
    # would re-encode them (so a literal +/- becomes mojibake on read/preview).
    binmode STDOUT;
    print "Status: 200 OK\r\n";
    print "Content-Type: application/json\r\n";
    print "MCP-Protocol-Version: $PROTOCOL\r\n";
    print "\r\n";
    print $body;
    exit 0;
}

sub send_status {    # for notifications (no id) and bad methods on GET
    my ( $code, $text ) = @_;
    print "Status: $code $text\r\n\r\n";
    exit 0;
}

sub rpc_result { send_json( { jsonrpc => '2.0', id => $_[0], result => $_[1] } ) }

# SM278: enforce the inputSchema we publish. Every tool declares its properties
# and "additionalProperties": false, and until now that declaration was sent to
# the client at tools/list and never checked at tools/call - so an argument the
# tool does not support was silently dropped and the call reported ok. A site
# agent found this the expensive way: set_permissions with "draft": true
# returned ok:1 and stored an ACL without it, which reads as a security setting
# that succeeded and did nothing.
#
# Refusing is the honest answer for an ARGUMENT (the caller asked for something
# we do not do). Note the asymmetry with the capability model, where refusing
# loudly is also the rule - silence is what both exist to avoid.
sub validate_args {
    my ( $name, $tool, $args ) = @_;
    my $schema = $tool->{inputSchema} or return;
    my $props  = $schema->{properties} || {};

    my @unknown = sort grep { !exists $props->{$_} } keys %$args;
    if (@unknown) {
        my $known = join ', ', sort keys %$props;
        return
            "Unknown argument"
            . ( @unknown > 1 ? 's' : '' ) . ' '
            . join( ', ', map { "'$_'" } @unknown )
            . " for $name. This tool accepts: "
            . ( length $known ? $known : '(no arguments)' )
            . ". Do not retry with the same argument - it is not supported, and "
            . "passing it would have no effect.";
    }

    my @missing = sort grep { !defined $args->{$_} } @{ $schema->{required} || [] };
    return "Missing required argument"
        . ( @missing > 1 ? 's' : '' ) . ' '
        . join( ', ', map { "'$_'" } @missing )
        . " for $name."
        if @missing;

    # SM291: the declared TYPE, for booleans.
    #
    # SM278 made this validator enforce the argument NAME and `required`, and a
    # site agent measured what it still did not enforce: a value the schema
    # declares invalid was neither refused nor treated as omitted. For
    # set_permissions.draft it fell through to CLEAR - so `draft: "yes-please"`
    # published a folder that had been returning 404, and answered ok:1.
    #
    # The inversion is what makes it worth refusing rather than coercing:
    # OMITTING draft is safe and documented as safe, while a MALFORMED draft was
    # destructive. A typo is normally the safer of the two mistakes.
    #
    # Booleans only. They have a small closed set of sane spellings, so refusing
    # the rest cannot surprise a caller that was already right. Strings and
    # numbers are left alone deliberately - agents rely on existing coercion
    # there, and tightening it needs its own measurement rather than a guess.
    for my $k ( sort keys %$args ) {
        my $spec = $props->{$k} or next;
        next unless ref $spec eq 'HASH';
        next unless ( $spec->{type} // '' ) eq 'boolean';
        my $v = $args->{$k};
        next unless defined $v;    # null reads as omitted
        next if ref $v eq 'JSON::PP::Boolean';
        next if !ref $v && $v =~ /\A(?:1|0|true|false|yes|no|on|off|)\z/i;
        return
            "Argument '$k' for $name must be true or false. "
            . "It was neither, so it was REFUSED rather than guessed at: "
            . "on this tool an unrecognised value used to mean 'false', which "
            . "is the destructive direction. Send true or false, or omit '$k' "
            . "to leave the current setting alone.";
    }

    return;
}

sub rpc_error {
    my ( $id, $code, $msg ) = @_;
    send_json( { jsonrpc => '2.0', id => $id,
            error => { code => $code, message => $msg } } );
}

# SM076 OAuth: a tool call without valid auth returns HTTP 401 with a
# WWW-Authenticate challenge pointing at the protected-resource metadata, so an
# OAuth client (Claude.ai web) discovers the authorization server and starts the
# flow. (initialize / tools/list stay open for discovery.)
sub send_401 {
    my ($id) = @_;
    my $host = $ENV{HTTP_HOST} // $ENV{SERVER_NAME} // '';
    my $meta = "https://$host/.well-known/oauth-protected-resource";
    # SM200: a DISTINCT reason per failure so an agent (and the operator reading
    # the audit) goes straight to the cause instead of one opaque
    # sign-in-incomplete. sign-in-incomplete (no bearer at all - authorise / paste
    # the connect code) | credential-invalid (a static user:token bearer that did
    # not verify) | token-expired (a known OAuth token past its expiry - reconnect
    # or refresh) | token-invalid (an OAuth token we do not recognise - revoked, or
    # the site secret was rotated).
    my $hdr = $ENV{HTTP_AUTHORIZATION} || $ENV{REDIRECT_HTTP_AUTHORIZATION} || '';
    my ($tok) = $hdr =~ /^Bearer\s+(\S+)/;
    my ( $reason, $msg );
    if ( !defined $tok ) {
        $reason = 'sign-in-incomplete';
        $msg    = 'Connector sign-in incomplete - finish authorising the connector '
            . "(paste the operator's one-time connect code at the sign-in prompt) before "
            . 'calling tools. This is not a missing header you can fix in the prompt.';
    }
    elsif ( index( $tok, ':' ) >= 0 ) { # static user:token bearer (Code / Desktop / a script)
        $reason = 'credential-invalid';
        $msg = 'Credential did not verify (expired or revoked) - reissue the token / reconnect.';
    }
    elsif ( Lazysite::Auth::OAuth::token_status($tok) eq 'expired' ) {
        $reason = 'token-expired';
        $msg    = 'The connector access token has EXPIRED - reconnect, or let the client '
            . 'refresh it (the OAuth session is short-lived).';
    }
    else {
        $reason = 'token-invalid';
        $msg = 'The connector access token is not recognised (revoked, or the site auth '
            . 'secret was rotated, invalidating existing tokens) - reconnect the connector.';
    }
    binmode STDOUT;    # encode_json emits UTF-8 bytes; do not re-encode
    print "Status: 401 Unauthorized\r\n";
    print "WWW-Authenticate: Bearer resource_metadata=\"$meta\"\r\n";
    print "Content-Type: application/json\r\n";
    print "MCP-Protocol-Version: $PROTOCOL\r\n\r\n";
    print encode_json( { jsonrpc => '2.0', id => $id,
            error => { code => -32001, message => $msg, data => { reason => $reason } } } );
    exit 0;
}

# --- token auth (reuses the control-API credential verification) ----------

# MC-4: the three sibling-tool probes were the same loop written three times.
# Only the CANDIDATE LIST differs - an optional environment override, the script
# beside this one, the same one level up, and the one under the docroot's parent
# - so that is what each caller passes.
sub _sibling_tool {
    for my $c (@_) {
        return $c if defined $c && -f $c;
    }
    return undef;
}

# Run a sibling tool and hand back what it printed. Returns ( $ran, $output ):
# $ran is false ONLY when the tool could not be STARTED, which each caller
# reports in its own words - a tool that ran and printed nothing is a different
# failure from one that never ran, and merging the two would lose that.
sub _run_json_tool {
    my ( $argv, $stdin ) = @_;
    my ( $out, $in );
    my $pid = eval { open2( $out, $in, $^X, @$argv ) } or return ( 0, undef );
    print {$in} $stdin if defined $stdin;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return ( 1, $resp );
}

sub _users_tool {
    my $bin = dirname( Cwd::abs_path(__FILE__) );
    return _sibling_tool( $ENV{LAZYSITE_USERS_TOOL},
        "$bin/tools/lazysite-users.pl",
        "$bin/../tools/lazysite-users.pl",
        "$DOCROOT/../tools/lazysite-users.pl" );
}

sub _users_api {
    my ($payload) = @_;
    my $tool = _users_tool() or return undef;
    my ( $ran, $resp ) = _run_json_tool(
        [ $tool, '--api', '--docroot', $DOCROOT ], encode_json($payload) );
    return undef unless $ran;
    return eval { decode_json( $resp // '{}' ) };
}

sub _stats_tool {
    my $bin = dirname( Cwd::abs_path(__FILE__) );
    return _sibling_tool( $ENV{LAZYSITE_STATS_TOOL},
        "$bin/plugins/stats.pl",
        "$bin/../plugins/stats.pl",
        "$DOCROOT/../plugins/stats.pl" );
}

# Run the visitor-stats AI export (cached, incremental). Returns the SANITISED
# JSON the agent reasons over - aggregates + a capped event stream, never the raw
# log, log path, filesystem path, or visitor IP.
sub _stats_export {
    my ($opt) = @_;
    my $tool = _stats_tool()
        or return { ok => 0, error => 'stats plugin not found' };
    my $window = ( defined $opt->{window} && $opt->{window} =~ /^\d+$/ ) ? $opt->{window} : 30;

    # SM213: durable-store selectors, validated + passed as exec args (no shell).
    my @sel;
    if    ( $opt->{index} ) { @sel = ('--index') }
    elsif ( defined $opt->{day} && $opt->{day} =~ /^\d{4}-\d{2}-\d{2}$/ ) {
        @sel = ( '--day', $opt->{day} );
    }
    elsif ( defined $opt->{month} && $opt->{month} =~ /^\d{4}-\d{2}$/ ) {
        @sel = ( '--month', $opt->{month} );
    }

    # SM394: one day's recorded trails, same strict shape and same exec-arg
    # handling - the value never reaches a shell.
    elsif ( defined $opt->{trails} && $opt->{trails} =~ /^\d{4}-\d{2}-\d{2}$/ ) {
        @sel = ( '--trails', $opt->{trails} );
    }

    my ( $ran, $resp ) = _run_json_tool(
        [ $tool, '--export', '--docroot', $DOCROOT, '--window', $window, @sel ] );
    return { ok => 0, error => 'could not run the stats plugin' } unless $ran;
    return eval { decode_json( $resp // '{}' ) }
        || { ok => 0, error => 'stats export produced no JSON' };
}

# Resolve the Authorization bearer to ($partner, \%caps), or () on failure.
# Two shapes: the static "<partner>:<lzs_ token>" (Claude Code / Desktop), or an
# opaque OAuth access token (Claude.ai web, SM076). Some Apache setups expose
# the forwarded header as REDIRECT_HTTP_AUTHORIZATION.
sub verify_bearer {
    my $hdr = $ENV{HTTP_AUTHORIZATION} || $ENV{REDIRECT_HTTP_AUTHORIZATION} || '';
    return () unless $hdr =~ /^Bearer\s+(\S.*)$/;
    my $cred = $1;

    my ( $user, $secret ) = split /:/, $cred, 2;
    if ( defined $user && defined $secret && $secret =~ /^lzs_/ ) {
        my $v = _users_api( { action => 'verify-credential',
                username => $user, secret => $secret, touch => 1 } );
        return () unless $v && $v->{ok};
        # Audit the connector's first authentication with this credential (the
        # static-bearer "connected" moment - Claude Code / Desktop / a script).
        # Once per issuance, so it does not flood on every tool call.
        audit_log( $user, 'connect', 'bearer', $ENV{REMOTE_ADDR} // '', 'ok', 'mcp' )
            if $v->{first_use};
        %AUTH_INFO = ( method => 'bearer',
            expires_at => ( $v->{settings} ? $v->{settings}{token_expires_at} : undef ) );
        return ( $user, $v->{settings} || {} );
    }

    # Opaque OAuth access token: resolve to its partner, then its capabilities
    # (partner-caps also stamps first use for the connector-setup detection).
    my $partner = Lazysite::Auth::OAuth::validate_token($cred);
    return () unless defined $partner;
    my $r = _users_api( { action => 'partner-caps', username => $partner } );
    return () unless $r && $r->{ok};
    %AUTH_INFO = ( method => 'oauth',
        expires_at => Lazysite::Auth::OAuth::token_expiry($cred) );
    return ( $partner, $r->{settings} || {} );
}

# Set the per-request module context once the caller is known.
# SM612: the installed build, from the install state the installer writes -
# not from a rendered page, which reports whatever built that page.
sub _engine_version {
    my $path = "$LAZYSITE_DIR/.install-state.json";
    return undef unless -f $path;
    open my $fh, '<', $path or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { decode_json($raw) } || {};
    return $d->{version};
}

sub setup_context {
    my ($user) = @_;
    $Lazysite::Manager::Files::DOCROOT       = $DOCROOT;
    $Lazysite::Manager::Files::LOCK_DIR      = $LOCK_DIR;
    $Lazysite::Manager::Files::auth_user     = $user;
    $Lazysite::Manager::Files::action        = 'mcp';
    $Lazysite::Manager::Themes::DOCROOT      = $DOCROOT;
    $Lazysite::Manager::Themes::LAZYSITE_DIR = $LAZYSITE_DIR;
    $Lazysite::Manager::Themes::auth_user    = $user;
    $Lazysite::Manager::Themes::action       = 'mcp';
    # SM318: the shared nav implementation, same context as every other module.
    $Lazysite::Manager::Nav::DOCROOT           = $DOCROOT;
    $Lazysite::Manager::Nav::LAZYSITE_DIR      = $LAZYSITE_DIR;
    $Lazysite::Manager::Nav::auth_user         = $user;
    $Lazysite::Manager::Layouts::DOCROOT       = $DOCROOT;
    $Lazysite::Manager::Layouts::LAZYSITE_DIR  = $LAZYSITE_DIR;
    $Lazysite::Manager::Layouts::auth_user     = $user;
    $Lazysite::Manager::Layouts::action        = 'mcp';
    $Lazysite::Manager::Common::DOCROOT        = $DOCROOT;
    $Lazysite::Manager::Domains::DOCROOT       = $DOCROOT;
    $Lazysite::Manager::SitePackage::DOCROOT   = $DOCROOT;
    $Lazysite::Manager::Plugins::DOCROOT       = $DOCROOT;
    $Lazysite::Manager::Data::DOCROOT          = $DOCROOT;
    $Lazysite::Manager::Data::auth_user        = $user;    # SM468: schema-history actor
    $Lazysite::Manager::Common::action         = 'mcp';
    $Lazysite::Manager::Artifact::LAZYSITE_DIR = $LAZYSITE_DIR;
    $Lazysite::Auth::Acl::DOCROOT              = $DOCROOT;
    $Lazysite::Auth::Acl::auth_user            = $user;
    $Lazysite::Auth::Acl::token_auth           = 1;               # never an operator
        # SM288: the account's REAL groups, so an @group ACL entry matches a partner
        # here exactly as it already did over WebDAV. This line used to be `= ()`
        # with the comment "token carries no groups - the safe default". It was not
        # a safe default, it was a THIRD answer: the same account in the same group
        # was allowed over WebDAV and refused here. Being a sysop is still
        # refused above - that is a capability question, and this is not.
    @Lazysite::Auth::Acl::user_groups = Lazysite::Auth::Acl::groups_for_user($user);
    return;
}

# MC-2: the four brief tools each required the module and then set the same two
# globals, two of them setting before requiring. The store is the same store for
# all four, so the context is established once, here, in the order that reads
# correctly: load the module, then tell it who is asking and where the site is.
sub _briefs {
    my ($user) = @_;
    require Lazysite::Manager::Briefs;
    no warnings 'once';    # the package is required at run time, not compiled in
    $Lazysite::Manager::Briefs::DOCROOT   = $DOCROOT;
    $Lazysite::Manager::Briefs::auth_user = $user;
    return;
}

# --- shared site-tool helpers ---------------------------------------------
# site_backup and site_apply both resolve a configured domain and then test its
# content root against the caller's scope union. The two blocks were verbatim
# copies; only the refusal WORDING differs, so that stays at each call site.
sub _domain_row {
    my ($host) = @_;
    my ($row)  = grep { lc( $_->{host} // '' ) eq $host }
        @{ Lazysite::Manager::Domains::domains_list()->{domains} || [] };
    return $row;
}

# True when the caller may NOT reach content rooted at $croot.
#
# SM578: an unscoped caller used to be "not outside" - the same reading the
# control API carried, and wrong for the same reason. There, a cookie session
# is the operator and is exempt; HERE THERE IS NO COOKIE SESSION. Every MCP
# caller is a token or OAuth partner, so an empty dav_scopes means nobody set
# one, never "this is the operator". The operator's ruling was explicit that an
# empty scope stops meaning unconfined for a token OR MCP partner, so an
# unscoped MCP grant reaches no domain's content rather than every domain's.
sub _croot_outside_scope {
    my ( $caps, $croot ) = @_;
    my $scopes = $caps->{dav_scopes};
    return 1 unless ref $scopes eq 'ARRAY' && @$scopes;
    return 1 unless length $croot;
    return Lazysite::Manager::Common::outside_all_scopes( $scopes, $croot ) ? 1 : 0;
}

# --- tool registry --------------------------------------------------------
# Each tool: description, inputSchema (JSON Schema), cap (required capability
# or undef = any authenticated), run (coderef: \%args, $user -> result hash).

my %TOOLS = (
    whoami => {
        description => 'Report the calling partner identity, capabilities, and the active layout/theme.',
        cap => undef,
        inputSchema => { type => 'object', properties => {}, additionalProperties => JSON::PP::false },
        run => sub {
            my ( $args, $user, $caps ) = @_;
            my ( $layout, $theme ) = _read_active_layout_and_theme();
            # Echo the tool list so an agent sees every tool it may call in one
            # call (the connector loads tools a few at a time, which can hide
            # some). SM525: filtered to this session's grant, as tools/list is.
            return { ok => 1, user => $user, capabilities => $caps,
                # SM612: THE BUILD THIS INSTANCE IS RUNNING. An agent asked to
                # re-check a previous release's finding is in the one case
                # where the build IS the question, and no token-readable
                # signal reported it: `version` is refused to token clients,
                # and the generator meta names the build that rendered a PAGE,
                # which on a cached page can be arbitrarily stale. A field
                # correction was withdrawn on the strength of that gap.
                engine_version => _engine_version(),
                # SM491: the same reachability block the API whoami carries,
                # from the same derivation - so the two surfaces cannot
                # disagree about which door is open (SM288).
                reachable => Lazysite::Capabilities::reachability($caps),
                # SM612: the twin of the API whoami's block - which transports
                # this INSTANCE has switched on, beside what the grant holds.
                services => {
                    map {
                        $_->[0] => (
                            Lazysite::Util::service_enabled( $DOCROOT, $_->[1] )
                            ? JSON::PP::true
                            : JSON::PP::false )
                    } ( [ api => 'control_api_enabled' ], [ mcp => 'mcp_enabled' ],
                        [ webdav => 'webdav_enabled' ], [ oauth => 'oauth_enabled' ] )
                },
                active_layout => $layout, active_theme => $theme,
                tools         => _tool_names($caps),
                # SM653/SM525: the same list, split by where it can be CALLED.
                # `tools` stays the whole set so no existing reader changes.
                tools_by_reach => do {
                    my ( $anywhere, $path_only ) = _tool_classes($caps);
                    { anywhere => $anywhere,
                        path_only => $path_only,
                        note      => @{$path_only}
                        ? 'The path_only tools are callable on theme and layout '
                            . 'paths only, through the path-aware override. On any '
                            . 'other path they are refused - hold the capability '
                            . 'each names to call it anywhere.'
                        : 'Every tool offered is callable on any path this grant '
                            . 'reaches.',
                    };
                },
                # How this session authenticated + when the credential expires
                # (OAuth tokens expire ~hourly and refresh transparently; a
                # static/operator credential may be permanent = null).
                auth => { method => $AUTH_INFO{method}, expires_at => $AUTH_INFO{expires_at} } };
        },
    },
    describe_capabilities => {
        description => 'Return the full capability map: the four channels (all '
            . 'enforced), every capability and what it unlocks (which MCP tools, '
            . 'control-API actions and WebDAV paths), task recipes for common jobs, '
            . 'the engine-owned paths you must not write, under "docs" an index of '
            . 'the documentation this site publishes, and - under "holds" - what '
            . 'THIS account currently has. Call this first to learn what you may do, '
            . 'then READ THE BRIEFINGS listed under docs.briefings before designing '
            . 'anything: "capabilities" is what lazysite offers and "holds" is only '
            . 'what you were granted, so a capability you lack is a grant to ask the '
            . 'sysop for, never a feature that is missing.',
        cap => undef,    # introspection: exempt from the mcp channel gate
        inputSchema => { type => 'object', properties => {}, additionalProperties => JSON::PP::false },
        run => sub {
            my ( $args, $user, $caps ) = @_;

            # SM353: `groups` too. The API's map held it and MCP's did not, so
            # the same account asking what it may do got a different answer
            # depending on how it asked - and this is the document a caller
            # reads to reason about its own grant.
            #
            # The resolution was already decided in this file. SM288 replaced
            # `user_groups = ()` here with the account's REAL groups, because a
            # token carrying no groups was not a safe default but a THIRD
            # answer: the same account in the same group was allowed over WebDAV
            # and refused over MCP. Omitting them from the capability map was
            # the same defect one layer up, so it takes the same fix.
            my $map = describe( caps => $caps, account => $user,
                groups  => [@Lazysite::Auth::Acl::user_groups],
                docroot => $DOCROOT );    # SM225: include the documentation index
            $map->{ok} = JSON::PP::true;
            return $map;
        },
    },
    list_files => {
        description => 'List files and folders under a site-relative directory path (default "/").',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => { path => { type => 'string', description => 'Directory path, e.g. /content' } },
            additionalProperties => JSON::PP::false },
        run => sub { action_list( $_[0]->{path} // '/' ) },
    },
    read_file => {
        description => 'Read the contents of a text file by site-relative path.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => { path => { type => 'string' } },
            required   => ['path'], additionalProperties => JSON::PP::false },
        run => sub {
            my $out = action_read( $_[0]->{path}, $_[1] );
            # Guard against an oversized response (slow transfer / client
            # timeout). Refuse rather than truncate - a truncated read that gets
            # written back would destroy content.
            if ( ref $out eq 'HASH' && $out->{ok} && defined $out->{content}
                && length( $out->{content} ) > $MAX_READ_BYTES ) {
                return { ok => 0, too_large => 1, kind => 'too-large', path => $_[0]->{path},
                    error => 'File too large to read through the connector ('
                        . length( $out->{content} ) . ' bytes); edit it over WebDAV instead.' };
            }
            return $out;
        },
    },
    upload_file => {
        description => 'Upload a BINARY file (base64-encoded): a webfont, an image, a favicon.ico, a PDF, a JavaScript library. Use this whenever the bytes are not text - write_file is text-only and will corrupt them. This is how you SELF-HOST assets instead of linking a CDN or hotlinking a remote image, which the site briefings require: upload the woff2 and reference it from the theme CSS, upload the photograph and reference it from the page. Same permissions as write_file (manage_content, or manage_themes/manage_layouts for a path under a layout or theme) and the same refusals - engine-owned paths, executable extensions and your scope confinement all apply unchanged. Give `content_base64` as standard base64; the size cap is the site\'s upload limit and is named in the refusal if you exceed it.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => {
                path => { type => 'string',
                    description => 'Site-relative destination, e.g. assets/fonts/inter.woff2 or favicon.ico' },
                content_base64 => { type => 'string',
                    description => 'The file bytes, base64-encoded' },
            },
            required             => [ 'path', 'content_base64' ],
            additionalProperties => JSON::PP::false },
        run => sub { _upload_file( $_[0], $_[1] ) },
    },
    write_file => {
        description => 'Create or overwrite a text file with the given content. FOR A FORM: never hand-write <form>/<input> HTML or point at a third-party form service (Formspree, Google Forms) - that has no sysop-vetted handler and routes visitor data off-instance. Use create_form, or a native :::form block + bind_form.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => { path => { type => 'string' }, content => { type => 'string' } },
            required => [ 'path', 'content' ], additionalProperties => JSON::PP::false },
        run => sub {
            my ( $a, $user ) = @_;
            if ( my $refusal = _page_parse_refusal( $a->{path}, $a->{content} ) ) {
                return $refusal;
            }
            my $r = action_save( $a->{path}, $user, $a->{content}, undef );
            # Validate-on-write: surface front-matter / form / public-data issues
            # in the write result so the agent sees them without a second call.
            if ( ref $r eq 'HASH' && $r->{ok} ) {
                # SM205: a theme.json written this way is validated EAGERLY too
                # (mirroring the page validator), so an agent editing a theme.json
                # sees name/value/coverage warnings without needing to re-activate.
                if ( ( $a->{path} // '' ) =~ m{(?:^|/)theme\.json$}
                    && ( $a->{path} // '' ) =~ m{lazysite/layouts/} ) {
                    my $tw = _validate_theme_json( $a->{path}, $a->{content} );
                    $r->{warnings} = $tw if @{$tw};
                }
                else {
                    my $v = _validate_page( undef, $a->{content}, $user );
                    if ( ref $v eq 'HASH' ) {
                        $r->{warnings} = $v->{warnings} if $v->{warnings} && @{ $v->{warnings} };
                        $r->{issues} = $v->{issues} if $v->{issues} && @{ $v->{issues} };
                    }
                }
            }
            return $r;
        },
    },
    # SM447: the data tables. An agent populating a table is the PRIMARY use
    # of the data plugin, which is why these exist rather than leaving agents
    # to drive the control API - and why the API-only gap was recorded in
    # t/lint/23 as a schedule rather than a decision.
    #
    # THEY ALL ROUTE THROUGH Lazysite::Manager::Data, the same module the
    # control API calls, which in turn calls Lazysite::Data::Tables. Three
    # surfaces, one implementation - because two surfaces each assembling the
    # data layer for themselves is how they come to disagree about the same
    # question, and t/lint/57 exists because that has happened.
    #
    # The plugin's enabled gate lives in that module (SM469), so these refuse
    # when it is disabled without each tool having to remember to ask.
    list_data_tables => {
        description => 'List the data tables this site declares - each with its title, and whether its descriptor is valid. A table is declared by a YAML file at lazysite/db/tables/<name>.yaml and holds SITE data: a product list, an events calendar, a directory. Call this FIRST on any task that mentions stored records, so you learn what exists rather than guessing a name. A table whose descriptor is broken is reported WITH its error rather than omitted, because a silently shorter list is the least useful thing this could do. Read-only.',
        cap         => 'manage_data',
        inputSchema => { type => 'object', properties => {},
            additionalProperties => JSON::PP::false },
        run => sub {
            return Lazysite::Manager::Data::action_data_tables();
        },
    },
    describe_data_table => {
        description => 'The declared shape of one data table: its fields, their types, which are required, and which field is the key. Call this BEFORE writing a row - the write is refused if a value does not fit its declared type, and this is how you find out what fits. Types are text, integer, decimal, boolean, date, datetime and enum; a decimal declares how many digits and decimal places it holds, and an enum declares its permitted values. Read-only.',
        cap         => 'manage_data',
        inputSchema => { type => 'object',
            properties => {
                table => { type => 'string', description => 'The table name, as list_data_tables reports it' },
            },
            required => ['table'], additionalProperties => JSON::PP::false },
        run => sub {
            return Lazysite::Manager::Data::action_data_table( $_[0]->{table} );
        },
    },
    read_data_table_source => {
        description => 'The descriptor of one data table as the TEXT that was written - comments, key order and spacing intact. describe_data_table returns the parsed shape, which is right for reading; this is for a read-modify-write, where the descriptor goes back through save_data_table as the same text with one change. Read-only.',
        cap         => 'manage_data',
        inputSchema => { type => 'object',
            properties => {
                table => { type => 'string', description => 'The table name, as list_data_tables reports it' },
            },
            required => ['table'], additionalProperties => JSON::PP::false },
        run => sub {
            return Lazysite::Manager::Data::action_data_table_source( $_[0]->{table} );
        },
    },
    read_data_rows => {
        description => 'Read rows from a data table. Ordering takes a DECLARED FIELD NAME, not an expression, and a field the table does not declare is refused with a reason rather than failing at the database. The row count is always capped, so this cannot return an unbounded listing. If the table is declared but has never been migrated, this succeeds with no rows and says pending_schema - which means run migrate_data_table, not that the table is empty. Read-only.',
        cap         => 'manage_data',
        inputSchema => { type => 'object',
            properties => {
                table => { type => 'string', description => 'The table name' },
                order_by => { type => 'string', description => 'A declared field name to sort by' },
                order => { type => 'string', description => 'asc (default) or desc' },
                limit => { type => 'integer', description => 'Rows to return; defaults to 200 and is capped at 1000' },
                offset => { type => 'integer', description => 'Rows to skip, for paging through a large table' },
            },
            required => ['table'], additionalProperties => JSON::PP::false },
        run => sub {
            my $a = $_[0];
            return Lazysite::Manager::Data::action_data_rows(
                $a->{table},
                order_by => $a->{order_by},
                order    => $a->{order},
                limit    => $a->{limit},
                offset   => $a->{offset},
            );
        },
    },
    save_data_table => {
        description => 'Create or replace a table DESCRIPTOR - the YAML that declares a table\'s fields and their types. This is the only way to declare a table: the descriptor lives under lazysite/, which is a protected area no general file-writing tool can reach, so it is written here where it can be CHECKED first. A descriptor that does not load is refused with the reason - the field, the rule, the value - rather than stored and failing later at first use. Writing a descriptor does NOT change the stored table: call migrate_data_table afterwards, which applies what is safe and reports what it refuses.',
        cap         => 'manage_data',
        inputSchema => { type => 'object',
            properties => {
                table => { type => 'string', description => 'The table name - lower-case letters, digits and underscores. This becomes the filename.' },
                descriptor => { type => 'string', description => 'The descriptor as YAML text. Keys: public, title, key, default_order, timestamps, indexes, writable_by, and fields (a mapping of name to {type, required, default, ...}). Types: text, integer, decimal, boolean, date, datetime, enum. A decimal declares digits and places; an enum declares values; a text field may set max and widget (input or textarea). Any field may set unique: true to say no two rows share its value - empty values are exempt, and adding it to a field that already has duplicates is reported rather than attempted. default_order names the field the table is ordered by when a binding does not say, with a leading - for descending. public defaults to FALSE: until it is true, an anonymous visitor cannot read the table through a page binding or the data endpoint, and it answers as though it does not exist.' },
            },
            required => [ 'table', 'descriptor' ], additionalProperties => JSON::PP::false },
        run => sub {
            my $a = $_[0];
            return Lazysite::Manager::Data::action_data_table_save( $a->{table},
                $a->{descriptor} );
        },
    },
    migrate_data_table => {
        description => 'Bring the stored table into line with its descriptor, as far as is SAFE. Adding a field is applied, and a field with a default is filled in on the rows that predate it. Changing a field\'s type, tightening it to required, or removing it are REPORTED AND REFUSED, not performed - each of those rewrites the table and a sysop decides it. Returns both what was applied and what was blocked, and the blocked list is the half that explains why a column is not there yet. Safe to run repeatedly: a table already in line is a no-op.',
        cap         => 'manage_data',
        inputSchema => { type => 'object',
            properties => {
                table => { type => 'string', description => 'The table name' },
            },
            required => ['table'], additionalProperties => JSON::PP::false },
        run => sub {
            return Lazysite::Manager::Data::action_data_migrate( $_[0]->{table} );
        },
    },
    plan_data_migration => {
        description => 'What migrate_data_table WOULD do, with nothing done - the safety step before a migration. Returns the additive changes it would apply and the changes it would refuse (a type change, a field tightened to required, a removal), each naming the field, and when something is blocked, the rebuild pre-flight too: which columns a rebuild would lose and which rows could not satisfy the new shape. Call this after changing a descriptor and BEFORE migrate_data_table, so a refused change is read about rather than discovered. Read-only.',
        cap         => 'manage_data',
        inputSchema => { type => 'object',
            properties => {
                table => { type => 'string', description => 'The table name' },
            },
            required => ['table'], additionalProperties => JSON::PP::false },
        run => sub {
            return Lazysite::Manager::Data::action_data_migrate_plan( $_[0]->{table} );
        },
    },
    rebuild_data_table => {
        description => 'Perform a schema change that migrate_data_table REFUSES - changing a field\'s type, tightening it to required, or removing it. All three are the same operation underneath: the table is rebuilt, which is why they are not done because a descriptor changed. CONFIRM BY NAMING EACH COLUMN whose data will be lost, in confirm_lost: call without it first to be told which those are, then call again naming them. A list rather than a yes/no on purpose - agreeing to lose one column you read about must not agree to a second you did not notice. A safety export of every row is written before anything is dropped, and its path is returned. A reply with kind "blocked" is different from one with kind "needs_confirmation": it means existing ROWS cannot satisfy the new shape - a required field some rows leave empty, a value that will not convert to the new type - and NO confirmation can clear it. Fix the rows it names, then rebuild again.',
        cap         => 'manage_data',
        inputSchema => { type => 'object',
            properties => {
                table        => { type => 'string', description => 'The table name' },
                confirm_lost => { type => 'array', items => { type => 'string' },
                    description => 'Every column whose data you accept losing. Omit to be told which they are without changing anything.' },
            },
            required => ['table'], additionalProperties => JSON::PP::false },
        run => sub {
            my $a = $_[0];
            return Lazysite::Manager::Data::action_data_rebuild( $a->{table},
                $a->{confirm_lost} );
        },
    },
    read_brief => {
        description => 'Read the authoring brief for a content path - the "why" record SM073 invented, held out of band in the engine-owned brief store since SM245 (no .brief sidecar exists any more; migrated sites moved theirs into the store). Answers exists:false with an empty brief for a path nobody has briefed.',
        cap         => 'manage_briefs',
        cap_also    => 'manage_content',
        inputSchema => { type => 'object',
            properties => { path => { type => 'string', description => 'The content path the brief is about' } },
            required => ['path'], additionalProperties => JSON::PP::false },
        run => sub {
            my $a = $_[0];
            _briefs( $_[1] );
            return Lazysite::Manager::Briefs::action_brief_read( $a->{path} );
        },
    },
    append_brief => {
        description => 'Append one entry to a content path\'s authoring brief (append-only, like the sidecar it replaced): what changed and why, in your words. The store stamps the date and your identity. Use this when you make a substantive change to a page you maintain.',
        cap         => 'manage_briefs',
        inputSchema => { type => 'object',
            properties => {
                path => { type => 'string', description => 'The content path the brief is about' },
                entry => { type => 'string', description => 'The entry text (one log line; 64KB cap)' },
            },
            required => [ 'path', 'entry' ], additionalProperties => JSON::PP::false },
        run => sub {
            my $a = $_[0];
            _briefs( $_[1] );
            return Lazysite::Manager::Briefs::action_brief_append( $a->{path}, $a->{entry} );
        },
    },
    list_briefs => {
        description => 'List every brief in the store: path, size, mtime, and whether it is an ORPHAN (no content answers its key - the brief was written for a path that never existed, or its page predates the engine carrying briefs through renames and deletes). The discovery half of the lifecycle: read_brief needs a path you already know; this answers WHICH paths have one.',
        cap      => 'manage_briefs',
        cap_also => 'manage_content',
        inputSchema => { type => 'object', properties => {}, additionalProperties => JSON::PP::false },
        run => sub {
            _briefs( $_[1] );
            return Lazysite::Manager::Briefs::action_briefs_list();
        },
    },
    delete_brief => {
        description => 'Delete one brief store entry by its content path (as list_briefs reports it). The cleanup half of the lifecycle: an orphan surfaced by list_briefs is removed with this. Deleting a live page\'s brief discards its record of intent - prefer appending a correction with append_brief. Audited as brief-delete.',
        cap         => 'purge',    # SM591: the lateral grant
        inputSchema => {
            type     => 'object',
            required => ['path'],
            properties => { path => { type => 'string', description => 'The store entry to remove' } },
            additionalProperties => JSON::PP::false,
        },
        run => sub {
            _briefs( $_[1] );
            return Lazysite::Manager::Briefs::action_brief_delete( $_[0]->{path} );
        },
    },
    drop_data_table => {
        description => 'Remove a table entirely - its descriptor, its stored rows, and every value in them. THIS EXISTS BECAUSE THERE WAS NO WAY BACK: declaring a table was reachable from three surfaces and removing one from none, and the descriptor lives under lazysite/ where every write channel refuses, so a table made by mistake or for a single test was permanent. CONFIRM BY NAMING THE TABLE EXACTLY in confirm: call without it first to be told what will be lost. A safety export of every row is written before anything is dropped and its path is returned, so a mistake is recoverable even though the table is not.',
        cap         => 'housekeeping',       # SM591: the lateral grant
        inputSchema => { type => 'object',
            properties => {
                table   => { type => 'string', description => 'The table name' },
                confirm => { type => 'string',
                    description => 'The table name again, exactly. Omit to be told what dropping it would remove, without changing anything.' },
            },
            required => ['table'], additionalProperties => JSON::PP::false },
        run => sub {
            my $a = $_[0];
            return Lazysite::Manager::Data::action_data_table_drop( $a->{table},
                $a->{confirm} );
        },
    },
    list_data_safety_exports => {
        description => 'List the safety exports that drop_data_table and rebuild_data_table wrote under lazysite/db/rebuilds/: file, table, kind (dropped or rebuild), stamp, size, mtime. A read. These accumulate - one per drop or rebuild - and this is how you see them; delete_data_safety_export clears one you no longer need.',
        cap => 'manage_data',
        inputSchema => { type => 'object', properties => {}, additionalProperties => JSON::PP::false },
        run => sub {
            return Lazysite::Manager::Data::action_data_safety_exports();
        },
    },
    delete_data_safety_export => {
        description => 'Delete one safety export by its file name as list_data_safety_exports reports it. Permanent: the export is the only copy of the rows a drop or a lossy rebuild removed, so read it (or confirm it is a throwaway) before clearing it. Audited as data-safety-export-delete.',
        cap         => 'purge',              # SM591: the lateral grant
        inputSchema => { type => 'object',
            properties => { file => { type => 'string', description => 'The export file name, exactly as listed' } },
            required => ['file'], additionalProperties => JSON::PP::false },
        run => sub {
            return Lazysite::Manager::Data::action_data_safety_export_delete( $_[0]->{file} );
        },
    },
    read_data_safety_export => {
        description => 'Read one safety export - the rows a drop or a lossy rebuild removed - by its file name as list_data_safety_exports reports it: table, key, fields and rows. This is how you JUDGE an export before clearing it, or before offering it back with restore_data_safety_export. A read.',
        cap         => 'manage_data',
        inputSchema => { type => 'object',
            properties => { file => { type => 'string', description => 'The export file name, exactly as listed' } },
            required => ['file'], additionalProperties => JSON::PP::false },
        run => sub {
            return Lazysite::Manager::Data::action_data_safety_export_read( $_[0]->{file} );
        },
    },
    restore_data_safety_export => {
        description => 'Offer a safety export\'s rows back to the table they came from. Without apply it is a PLAN (how many rows would be inserted or updated by key, and which columns can be restored); with apply:true it writes, through the same coercion as a live write. Columns the table no longer has are reported as not_restored_columns rather than refused - a lossy rebuild export is lossy by definition; to recover those columns, re-declare them and restore again. A drop export needs its table re-declared (and migrated) first; the refusal says so. Audited as data-safety-export-restore.',
        cap         => 'manage_data',
        inputSchema => { type => 'object',
            properties => {
                file => { type => 'string', description => 'The export file name, exactly as listed' },
                apply => { type => 'boolean', description => 'Write the rows. Omit or false to see the plan.' },
            },
            required => ['file'], additionalProperties => JSON::PP::false },
        run => sub {
            return Lazysite::Manager::Data::action_data_safety_export_restore( $_[0]->{file},
                $_[0]->{apply} ? 1 : 0 );
        },
    },
    save_data_row => {
        description => 'Insert a row, or update one by its key. WITHOUT `key` this inserts; WITH `key` it updates that row and touches only the fields you send, leaving the rest alone. Every value is checked against the descriptor and a value that does not fit is REFUSED with the field named - a decimal with too many places is refused rather than rounded, because a store that quietly rounds money is worse than one that will not take it. An unknown field name is refused rather than ignored, so a typo cannot look like a successful write.',
        cap         => 'manage_data',
        inputSchema => { type => 'object',
            properties => {
                table => { type => 'string', description => 'The table name' },
                key => { type => 'string', description => 'The key of the row to UPDATE. Omit to insert a new row.' },
                row => { type => 'object', description => 'The field values, as an object. Send values as strings for decimal fields so no precision is lost on the way here.' },
            },
            required => [ 'table', 'row' ], additionalProperties => JSON::PP::false },
        run => sub {
            my $a = $_[0];
            return { ok => 0, error => 'row must be an object' }
                unless ref $a->{row} eq 'HASH';
            return Lazysite::Manager::Data::action_data_row_save( $a->{table},
                $a->{key}, $a->{row} );
        },
    },
    delete_data_row => {
        description => 'Delete one row by its key. Deleting a row that is not there is REFUSED rather than reported as success, so a mistaken key does not read as a completed deletion. There is no bulk delete and no delete-by-filter: removing many rows is a decision a sysop makes, not one an agent reaches by accident.',
        cap         => 'manage_data',
        inputSchema => { type => 'object',
            properties => {
                table => { type => 'string', description => 'The table name' },
                key => { type => 'string', description => 'The key of the row to delete' },
            },
            required => [ 'table', 'key' ], additionalProperties => JSON::PP::false },
        run => sub {
            my $a = $_[0];
            return Lazysite::Manager::Data::action_data_row_delete( $a->{table},
                $a->{key} );
        },
    },
    list_domains => {
        description => 'List the domains this instance serves - the primary site plus every configured domain, each with its content_root, layout, theme, nav and language settings, and which of those it INHERITS from the primary rather than setting itself. Call this FIRST on any task that mentions a domain, or before activate_theme / activate_layout on an instance that may serve more than one site: those are instance-wide without a host, and this is how you find out whether that matters. Read-only.',
        cap         => 'manage_domains',
        inputSchema => { type => 'object', properties => {},
            additionalProperties => JSON::PP::false },
        run => sub {
            return Lazysite::Manager::Domains::domains_list();
        },
    },
    domain_set => {
        description => 'Set ONE presentation or routing key on ONE configured domain: theme, layout, site_name, site_url, nav_file, search_default, lang or lang_group. This is how a secondary domain gets its own look - binding a theme or layout here publishes that theme\'s assets and leaves every other domain, including the primary, untouched. To bind both a layout and a theme, call twice (layout first). Does NOT create or remove domains.',
        cap         => 'manage_domains',
        inputSchema => { type => 'object',
            properties => {
                host => { type => 'string', description => 'The configured domain, e.g. clienta.example' },
                key => { type => 'string', description => 'theme | layout | site_name | site_url | nav_file | search_default | lang | lang_group' },
                value => { type => 'string', description => 'The value; an empty string clears the override so the domain inherits the primary again' },
            },
            required => [ 'host', 'key' ], additionalProperties => JSON::PP::false },
        run => sub {
            my $a = $_[0];
            # content_root is deliberately not settable here: repointing a live
            # domain's content is a migration, not a presentation tweak, and it
            # belongs with site_apply where a safety snapshot is taken.
            return { ok => 0, kind => 'refused',
                error => 'content_root cannot be set through this tool - repointing '
                    . 'a domain\'s content is a migration. Use site_apply, which '
                    . 'takes a snapshot first.' }
                if ( $a->{key} // '' ) eq 'content_root';
            return _domain_presentation_set( $a->{host}, $a->{key}, $a->{value} // '' );
        },
    },
    # SM466 / SM456: the field agent could not confirm what a VISITOR receives.
    #
    # Every tool it held answered a different question - preview_page renders
    # through the manager, read_page returns source, page_status reports
    # metadata. Per-Host routing is what makes those different questions rather
    # than three views of one: the layout is chosen from the Host, so a
    # docroot-shaped tool cannot report it.
    #
    # Fetching the page directly does work and is not the answer: it is egress
    # outside the grant model, and a result obtained that way cannot be
    # attributed to any capability the partner holds. A grant cannot attribute
    # its own access.
    #
    # This is the existing preview-public action - which already renders as an
    # anonymous visitor under the owning domain's Host - given an MCP door and
    # taught to report the layout and theme the visitor actually got.
    preview_public_page => {
        description => 'Render ONE page exactly as an anonymous visitor would receive it - no session, no token, under the Host that owns the path - and report whether it is publicly visible, which layout and theme were actually used, and an excerpt. Use this to CONFIRM a change rather than assuming it: what a page should look like is a question about configuration, and what a visitor got is a question about the response, and they come apart. A page that renders through the built-in fallback reports no layout, which is itself the answer to "why does this look wrong". Read-only: nothing is published and no cache is written.',
        cap         => 'manage_content',
        inputSchema => { type => 'object',
            properties => {
                path => { type => 'string', description => 'The page path, e.g. /about or /clients/index. Omitted means the home page, "/" - the same default the control API applies, so the two surfaces answer identically.' },
            },
            additionalProperties => JSON::PP::false },
        run => sub {
            return Lazysite::Manager::Domains::preview_public( $_[0]->{path} );
        },
    },
    preview_domain => {
        description => 'Render a configured domain\'s home page exactly as an anonymous visitor would see it under that Host - its own content root, layout, theme and nav - and return the HTML. Works before DNS or TLS point at the domain, because the render is server-side, so use it to CHECK a domain you have just configured rather than guessing. Read-only: nothing is published and no cache is written.',
        cap         => 'manage_domains',
        inputSchema => { type => 'object',
            properties => { host => { type => 'string', description => 'The configured domain to render' } },
            required => ['host'], additionalProperties => JSON::PP::false },
        run => sub {
            return Lazysite::Manager::Domains::domain_preview( $_[0]->{host} );
        },
    },
    site_backup => {
        description => 'Package one configured domain\'s SITE - its content, nav, referenced theme + layout, and presentation settings - into a portable .tar.gz stored alongside the backups (download it with the backup tooling). Excludes plugins, instance settings and secrets, so it is safe to hand to a client\'s own instance. Requires manage_domains and access to that domain.',
        cap         => 'manage_domains',
        inputSchema => {
            type       => 'object',
            properties => { host => {
                    type        => 'string',
                    description => 'The configured domain to package, e.g. shop.clienta.com',
            } },
            required             => ['host'],
            additionalProperties => JSON::PP::false,
        },
        run => sub {
            my ( $a, $user, $caps ) = @_;
            my $host = lc( $a->{host} // '' );
            return { ok => 0, error => 'A host is required' } unless length $host;
            my $row = _domain_row($host);
            return { ok => 0, error => "Not a configured domain: $host" } unless $row;
            my $croot = $row->{content_root} // '';
            if ( _croot_outside_scope( $caps, $croot ) ) {
                return { ok => 0, error => "You do not have access to the content of $host." };
            }
            local $Lazysite::Manager::SitePackage::auth_user = $user;
            return package_create($host);
        },
    },
    site_apply => {
        description => 'Apply a previously created/uploaded site package (a lazysite-site-*.tar.gz already in the backups area) onto a target domain on this instance: copies its content into the domain content root, installs the bundled theme/layout if missing, places the nav, and sets the domain presentation. Omit host to apply to the default site. Requires manage_domains + access to the target. A safety snapshot of the docroot IS taken before anything is written, and its name is returned as `safety`, so an apply is always reversible - tell the sysop that name if they need to roll back. If the snapshot cannot be taken the apply is refused rather than proceeding without one.',
        cap         => 'manage_domains',
        inputSchema => {
            type       => 'object',
            properties => {
                name => { type => 'string', description => 'The package file name in the backups area (lazysite-site-*.tar.gz)' },
                host => { type => 'string', description => 'Target configured domain; omit for the default site' },
                clean => { type => 'boolean', description => 'Remove existing content under the target root first' },
                # SM263: opt IN to taking the package's identity. The default -
                # keeping the TARGET's site_url and site_name - is right for
                # migrating a package onto a new domain, which is the common
                # case; adopting the source's is right when cloning a site as-is
                # to hand over. The control API has had this since SM193 and MCP
                # had no way to ask for it at all.
                adopt_identity => { type => 'boolean',
                    description => "Take the PACKAGE's site_url and site_name instead of keeping the target domain's own. Default false: the target keeps its identity, so a clone never advertises the source's address. Set true only when the package IS the site being moved." },
            },
            required             => ['name'],
            additionalProperties => JSON::PP::false,
        },
        run => sub { _site_apply( $_[0], $_[1], $_[2] ) },
    },
    replace_text => {
        description => 'Edit a file by replacing exact text - safer than rewriting the whole file for a small change to a page with HTML / front matter / scripts. Replaces every occurrence of "old" with "new"; errors if "old" is not present. read_file first to copy the exact text (including whitespace).',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => {
                path => { type => 'string' },
                old => { type => 'string', description => 'exact text to find (must match including whitespace)' },
                new => { type => 'string', description => 'replacement text' },
            },
            required => [ 'path', 'old', 'new' ], additionalProperties => JSON::PP::false },
        run => sub {
            my ( $a, $user ) = @_;
            my $old = $a->{old};
            return { ok => 0, error => 'old text must not be empty' } unless defined $old && length $old;
            my $r = action_read( $a->{path}, $user );
            return $r unless ref $r eq 'HASH' && $r->{ok};
            my @parts = split /\Q$old\E/, $r->{content}, -1;
            my $count = @parts - 1;
            return { ok => 0, error => 'text not found in ' . ( $a->{path} // '' ) } unless $count;
            my $content = join( ( defined $a->{new} ? $a->{new} : '' ), @parts );
            if ( my $refusal = _page_parse_refusal( $a->{path}, $content ) ) {
                return $refusal;
            }
            my $s = action_save( $a->{path}, $user, $content, undef );
            $s->{replacements} = $count if ref $s eq 'HASH' && $s->{ok};
            return $s;
        },
    },
    copy_file => {
        description => 'Copy a text file to a new path - templating a new page from an existing one. The destination starts with a fresh ACL.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => { from => { type => 'string' }, to => { type => 'string' } },
            required   => [ 'from', 'to' ], additionalProperties => JSON::PP::false },
        run => sub {
            my ( $a, $user ) = @_;
            my $r = action_read( $a->{from}, $user );
            return $r unless ref $r eq 'HASH' && $r->{ok};
            return action_save( $a->{to}, $user, $r->{content}, undef );
        },
    },
    get_permissions => {
        description => 'Read the access-control list for a path (owner + per-user / @group read & write grants). Call this before set_permissions to see the current state.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => { path => { type => 'string' } },
            required   => ['path'], additionalProperties => JSON::PP::false },
        run => sub { action_acl_get( $_[0]->{path}, $_[1] ) },
    },
    move_file => {
        description => 'Rename or move a file: re-keys its ACL and PRESERVES its content history across the move. Always use this (or rename_page for a page) to relocate a file - never write a new file at the destination and delete the old one, which starts a fresh history and loses the past.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => { from => { type => 'string' }, to => { type => 'string' } },
            required   => [ 'from', 'to' ], additionalProperties => JSON::PP::false },
        run => sub { action_move( $_[0]->{from}, $_[0]->{to}, $_[1] ) },
    },
    delete_file => {
        description => 'Delete a file by site-relative path. A delete ends the file\'s content history thread (a later file at the same path starts clean). To RELOCATE a file, use move_file, not delete-then-recreate, so its history follows.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => { path => { type => 'string' } },
            required   => ['path'], additionalProperties => JSON::PP::false },
        run => sub { action_delete( $_[0]->{path}, $_[1] ) },
    },
    set_permissions => {
        description => 'Set the ACL for a file OR a folder prefix: owner, read/write lists (users or @groups), and the draft flag. A folder prefix (a path ending in /) gates or hides every page and asset beneath it. PARTIAL UPDATE: fields you omit keep their current value - so setting a read list on a DRAFT section leaves it draft (still a 404). The API equivalent of the Publish button is {"draft": false} alongside your grants.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => {
                path => { type => 'string' },
                read => { type => 'string', description => 'comma-separated users / @groups' },
                write => { type => 'string' },
                draft => { type => 'boolean',
                    description => 'Hide this path outright: 404 to the public and absent from the sitemap, feeds and every listing, previewable by a signed-in editor. Omit to leave the current setting alone; false clears it and publishes.' },
            },
            required => ['path'], additionalProperties => JSON::PP::false },
        run => sub {
            action_acl_set( $_[0]->{path}, $_[1], $_[0]->{read}, $_[0]->{write},
                undef, $_[0]->{draft} );
        },
    },
    list_themes => {
        description => 'List the themes installed across all layouts (with which is active), so you can discover what is available without activating each in turn.',
        cap => 'manage_themes',
        inputSchema => { type => 'object', properties => {}, additionalProperties => JSON::PP::false },
        run => sub { action_themes_list_all() },
    },
    theme_tokens => {
        description => 'Discover a layout or theme\'s design-token vocabulary WITHOUT activating anything: give theme for that theme\'s parsed config (group->key->value); give layout for its declared token block (if any) plus its default theme\'s config as exemplar values (derived:true when nothing is declared); give neither for the active layout+theme.',
        cap         => 'manage_themes',
        inputSchema => { type => 'object',
            properties => {
                theme => { type => 'string', description => 'theme name (resolved under its layout, or the active one)' },
                layout => { type => 'string', description => 'layout name; without theme, returns its token vocabulary + exemplar values' },
            },
            additionalProperties => JSON::PP::false },
        run => sub {
            my $a = $_[0];
            my %p;
            $p{theme}  = $a->{theme}  if defined $a->{theme};
            $p{layout} = $a->{layout} if defined $a->{layout};
            action_theme_tokens( \%p );
        },
    },
    activate_theme => {
        description => 'Activate a theme. WITHOUT `host` this is INSTANCE-WIDE: it changes the theme of the whole site, every domain that inherits it included - on a multi-domain instance that is almost never what you want. WITH `host` it binds the theme to that one configured domain and publishes its assets, leaving every other domain untouched. Call list_domains first if you are not certain the instance serves only one site. Clears the HTML cache.',
        cap         => 'manage_themes',
        inputSchema => { type => 'object',
            properties => {
                theme => { type => 'string' },
                host  => { type => 'string',
                    description => 'A configured domain to bind this theme to. Omit ONLY when you mean the whole instance.' },
            },
            required => ['theme'], additionalProperties => JSON::PP::false },
        run => sub {
            my $a = $_[0];
            # SM238: with a host, this is a per-domain BINDING, not an instance
            # activation - so it routes through domain_set, which mirrors the
            # theme's assets under that domain's own layout (SM241) and never
            # touches the site-wide theme: key. Without a host the old
            # instance-wide behaviour is unchanged.
            return _domain_presentation_set( $a->{host}, 'theme', $a->{theme} )
                if defined $a->{host} && length $a->{host};
            return action_theme_activate( $a->{theme}, {} );
        },
    },
    create_theme => {
        description => 'Scaffold a validated theme under a layout in ONE step (instead of the five-step create-dirs / write theme.json / remember assets/ / write CSS / activate sequence). Give layout + name + a config (group->key->value of design tokens). Omit css to copy the layout default theme\'s main.css as the starting point (the config restyles it via the var(--theme-*) fallback chain). Validates the name and config values EAGERLY (rejects with kind:"validation" before writing anything). If the layout declares a token vocabulary (SM203), returns coverage warnings (never rejects). activate:true makes it live (mirror build + cache clear), same as activate_theme. Returns created paths, warnings, and a preview URL.',
        cap         => 'manage_themes',
        inputSchema => {
            type       => 'object',
            properties => {
                layout => { type => 'string', description => 'the installed layout to create the theme under' },
                name => { type => 'string', description => 'theme name ([A-Za-z0-9_-]+)' },
                config => { type => 'object',
                    description => 'design tokens as group->key->value, e.g. {"colours":{"primary":"#0044CC"}}' },
                css => { type => 'string', description => 'optional main.css; omit to copy the layout default theme CSS' },
                activate => { type => 'boolean', description => 'activate the theme after creating it (default false)' },
                description => { type => 'string' },
                tags        => { type => 'array', items => { type => 'string' } },
            },
            required             => [ 'layout', 'name' ],
            additionalProperties => JSON::PP::false,
        },
        run => sub {
            my $a = $_[0];
            my %p = ( layout => $a->{layout}, name => $a->{name} );
            $p{config}      = $a->{config}      if defined $a->{config};
            $p{css}         = $a->{css}         if defined $a->{css};
            $p{activate}    = $a->{activate}    if defined $a->{activate};
            $p{description} = $a->{description} if defined $a->{description};
            $p{tags}        = $a->{tags}        if defined $a->{tags};
            action_create_theme( \%p );
        },
    },
    activate_layout => {
        description => 'Activate a layout (optionally naming a compatible theme). WITHOUT `host` this is INSTANCE-WIDE and changes the whole site. WITH `host` it binds the layout to that one configured domain and leaves the others alone. Call list_domains first if the instance may serve more than one site.',
        cap         => 'manage_layouts',
        inputSchema => { type => 'object',
            properties => {
                layout => { type => 'string' },
                theme  => { type => 'string' },
                host   => { type => 'string',
                    description => 'A configured domain to bind this layout to. Omit ONLY when you mean the whole instance.' },
            },
            required => ['layout'], additionalProperties => JSON::PP::false },
        run => sub {
            my $a = $_[0];
            if ( defined $a->{host} && length $a->{host} ) {
                # SM238: bind the layout, then the theme if one was named, so a
                # single call leaves the domain in a consistent, servable state
                # rather than a layout with the previous layout's theme.
                my $r = _domain_presentation_set( $a->{host}, 'layout', $a->{layout} );
                return $r unless $r->{ok};
                return $r unless defined $a->{theme} && length $a->{theme};
                return _domain_presentation_set( $a->{host}, 'theme', $a->{theme} );
            }
            my $p = {};
            $p->{theme} = $a->{theme} if defined $a->{theme};
            return action_layout_activate( $a->{layout}, $p );
        },
    },
    list_layout_catalogue => {
        description => 'List the layouts available in the configured layouts repo (its manifest.json): each layout, its version, default theme, and its themes - annotated with what is already installed. Discover what install_layout can pull, without downloading anything.',
        cap => 'manage_layouts',
        inputSchema => { type => 'object', properties => {}, additionalProperties => JSON::PP::false },
        run => sub { action_layouts_manifest() },
    },
    install_layout => {
        description => 'Install a layout and its theme(s) from the repo on demand. Installing does NOT activate: the layout is placed on the site and nothing visitors see changes until you call activate_layout (SM176 - activating is the part that changes the live site, so it is always asked for explicitly). By default installs the layout default_theme; pass theme for a specific one, or all:true for every theme. Mirrors assets and clears the cache. Use list_layout_catalogue first to see names. To SWITCH the site to a different layout: install_layout, then activate_layout, then delete the old one if it is no longer wanted - deleting the ACTIVE layout is always refused, so never delete first.',
        cap         => 'manage_layouts',
        inputSchema => { type => 'object',
            properties => {
                layout => { type => 'string', description => 'layout name from list_layout_catalogue' },
                theme => { type => 'string', description => 'optional specific theme; default is the layout default_theme' },
                all => { type => 'boolean', description => 'install every theme for the layout' },
                update => { type => 'boolean', description => 'overwrite an already-installed layout (e.g. to push a layout fix); the old one is snapshotted, its themes/ kept' },
                activate => { type => 'boolean', description => 'activate after install (default false)' },
            },
            required => ['layout'], additionalProperties => JSON::PP::false },
        run => sub {
            my $a   = $_[0];
            my %req = ( layout => $a->{layout} );
            $req{theme}    = $a->{theme}    if defined $a->{theme};
            $req{all}      = $a->{all}      if defined $a->{all};
            $req{update}   = $a->{update}   if defined $a->{update};
            $req{activate} = $a->{activate} if defined $a->{activate};
            action_layout_install( encode_json( \%req ) );
        },
    },
    delete_layout => {
        description => 'Delete an installed layout AND its themes. Refuses the ACTIVE layout - when switching layouts, install the replacement with install_layout, activate it with activate_layout, and only then delete the old one. A recovery snapshot is kept and the web asset mirror is cleared.',
        cap         => 'manage_layouts',
        inputSchema => { type => 'object',
            properties => { layout => { type => 'string' } },
            required   => ['layout'], additionalProperties => JSON::PP::false },
        run => sub { action_layout_delete( $_[0]->{layout} ) },
    },
    delete_theme => {
        description => 'Delete a theme YOU created with create_theme. You cannot remove a theme created by anyone else, or one that predates this account - that stays an operator action from the manager. Refuses the ACTIVE theme, and any theme a configured domain is using, naming the domains. Use this to clear an experiment rather than leaving it behind: a theme you abandon stays in the site\'s theme list until someone removes it.',
        cap         => 'manage_themes',
        inputSchema => { type => 'object',
            properties => { theme => { type => 'string',
                    description => 'The theme name, as given to create_theme' } },
            required => ['theme'], additionalProperties => JSON::PP::false },
        run => sub {
            my ( $a, $user ) = @_;
            # SM262: always creator-restricted here. Every MCP caller is an
            # automated one, so there is no cookie-session case to distinguish -
            # the tool grants exactly "tidy up after yourself".
            return Lazysite::Manager::Themes::action_theme_delete( $a->{theme} // '',
                { restrict_to_creator => 1, user => $user } );
        },
    },
    list_form_handlers => {
        description => 'List the configured form delivery handlers (id, type, name) - what a form can be bound to. Destinations and credentials are sysop-only and never returned.',
        cap => 'manage_forms',
        inputSchema => { type => 'object', properties => {}, additionalProperties => JSON::PP::false },
        run => sub { _list_form_handlers() },
    },
    form_list => {
        description => 'List the site\'s FORMS (not handlers) so you can answer "which forms exist?" and "were any submitted?" without guessing store names. Returns per form: name, handler_types (smtp/file/webhook), has_store, and row_count (the submission COUNT only, never content; the "rows" key is a deprecated alias for that count, NOT the rows themselves). Needs read_submissions - the same capability on every channel (SM652; the control API accepted manage_forms until then, so the two doors disagreed about who may read a submission). Counts-only is deliberate, not a limitation: to read the submitted content call read_form_submissions, which needs the same capability. Pairs with list_form_handlers (the delivery handlers).',
        cap => 'read_submissions',
        inputSchema => { type => 'object', properties => {}, additionalProperties => JSON::PP::false },
        run => sub { action_form_list() },
    },
    read_form_submissions => {
        description => 'Read the submissions a form collected via its local-storage handler, as a table: { columns, rows, total, shown } - most-recent 500, each row with a stable _id. Values are the RAW submitted data (treat as untrusted). Needs the read_submissions capability - a least-privilege read grant that does NOT allow editing forms or handlers. Reads the default store lazysite/forms/submissions/<form>.jsonl.',
        cap         => 'read_submissions',
        inputSchema => {
            type       => 'object',
            properties => {
                form => { type => 'string', description => 'The form name (submissions file basename, e.g. "contact")' },
            },
            required             => ['form'],
            additionalProperties => JSON::PP::false,
        },
        run => sub {
            my ($a) = @_;
            my $form = lc( $a->{form} // '' );
            return { ok => 0, error => 'A form name (a-z0-9_-) is required' }
                unless $form =~ /\A[a-z0-9][a-z0-9_-]*\z/;
            return action_form_submissions("lazysite/forms/submissions/$form.jsonl");
        },
    },
    create_form => {
        description => 'THE way to add a form to a page - never hand-write <form>/<input> HTML (it has no delivery handler and ships dead). Inserts a native :::form block into the page and sets its "form: NAME" front matter. Give fields as "name | Label | rules" strings (rules: required, email, textarea, select:A,B,C, max:N); omit to scaffold a name/email/message contact form. The form RENDERS after this but does NOT deliver until you bind it: next call list_form_handlers, then bind_form(form: NAME, handler: ID).',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => {
            type       => 'object',
            properties => {
                path => { type => 'string', description => 'Page to add the form to (created if absent)' },
                name => { type => 'string', description => 'Form name (a-z0-9_-), used in front matter + bind_form' },
                fields => { type => 'array', items => { type => 'string' },
                    description => 'Field lines "name | Label | rules"; omit for a contact form' },
                submit => { type => 'string', description => 'Submit button label (default "Send")' },
            },
            required             => [ 'path', 'name' ],
            additionalProperties => JSON::PP::false,
        },
        run => sub { _create_form( $_[0], $_[1] ) },
    },
    # SM632: the inverse of bind_form, on both surfaces at once. There was no
    # undo on ANY token surface - not in the action registry, and delete_file
    # refuses lazysite/ because it is internal (correctly) - so a tool an agent
    # holds created a registration nothing it holds could remove, and they
    # accumulated. A field agent left one behind on edge and had to ask the
    # operator to rm it.
    delete_form => {
        description => 'Remove a form REGISTRATION (lazysite/forms/<form>.conf) - '
            . 'the inverse of bind_form. Use it to clean up a form you created, or '
            . 'one whose page has gone. REFUSED while the form has stored '
            . 'submissions: those are personal data, and removing the registration '
            . 'would leave them on disk and out of every listing. Deleting '
            . 'submissions is a manager-UI operation on purpose. Confirm by passing '
            . 'confirm equal to the form name. Does NOT edit the page: remove the '
            . ':::form block and the "form:" front matter separately if the page '
            . 'still exists.',
        cap         => 'manage_forms',
        destructive => 1,
        inputSchema => { type => 'object',
            properties => {
                form => { type => 'string', description => 'the registered form name' },
                confirm => { type => 'string', description => 'the form name again, to confirm' },
            },
            required => [ 'form', 'confirm' ],
        },
        run => sub {
            require Lazysite::Manager::Plugins;
            return Lazysite::Manager::Plugins::action_form_delete(
                $_[0]->{form}, $_[0]->{confirm} );
        },
    },
    bind_form => {
        description => 'Wire a form to delivery. FULL FLOW to build a working form natively (do not just copy an existing page): (1) in the page Markdown add front matter "form: NAME" and a :::form block - each field is a "field_name | Label | rules" line; rules include required, email, textarea, select:A,B,C, max:N; end with "submit | Button label". Example: ":::form\\nname | Your name | required max:200\\nemail | Email | required email\\nmessage | Message | required textarea\\nsubmit | Send\\n:::". See /docs/forms for the full reference. (2) call list_form_handlers to see the sysop-vetted delivery handlers. (3) call bind_form(form: NAME, handler: ID). A :::form renders but does NOT deliver until bound. PREFER A HANDLER: it is sysop-vetted and holds any credentials. If your grant needs to deliver somewhere the sysop has not pre-defined, pass `target` instead - {type: webhook|api, url: https://...} or {type: file, path: relative/dir} - which writes the delivery target directly into the form config. That is the same thing this capability can already do over WebDAV and the control API; it is offered here so the three surfaces agree rather than one being quietly weaker. NOT AN INLINE TARGET TYPE: delivery into a declared DATA TABLE is handler-only, and deliberately so. The inline route exists to reach somewhere the sysop has not pre-defined; a form writing rows into a declared table is precisely what the sysop should vet, and an inline table target would let any declared table be named as a destination without them wiring it. Ask the sysop for a handler. Writes lazysite/forms/<form>.conf.',
        cap         => 'manage_forms',
        inputSchema => { type => 'object',
            properties => {
                form => { type => 'string', description => 'the form name (the _form / front-matter form key)' },
                handler => { type => 'string', description => 'an existing handler id from list_form_handlers (preferred)' },
                target => { type => 'object',
                    description => 'an inline delivery target, INSTEAD of handler: {type: webhook|api, url} or {type: file, path}. No credentials - those live in sysop-defined handlers.',
                    properties => {
                        type   => { type => 'string' },
                        url    => { type => 'string' },
                        path   => { type => 'string' },
                        format => { type => 'string' },
                    },
                    additionalProperties => JSON::PP::false },
            },
            required => ['form'], additionalProperties => JSON::PP::false },
        run => sub { _bind_form( $_[0]->{form}, $_[0]->{handler}, $_[0]->{target} ) },
    },
    audit_site => {
        description => 'Audit the whole site: broken internal links, orphan pages (nothing links to them), pages missing a title, stale generated HTML (no source), duplicate content blocks (the same paragraph on multiple pages), broken forms (hand-authored form HTML with no handler, or a :::form never bound to a handler), raw HTML pages (a raw:/api: page declaring an HTML content type, which is served as plain text), and STARTER pages - the shipped demo content, still published and possibly still advertised in the sitemap, which is worth checking before a site goes public. Returns lists per category, plus starter_in_sitemap as a count. On a site whose auth_default is required or optional it also returns unprotected_static_files: files with no page source, which the web server hands to anyone who knows the path REGARDLESS of the site-wide auth setting - so a site that looks closed can still be publishing private assets. It also returns acl_keys_matching_nothing: per-path ACL entries whose key matches no file or folder, which is what a URL-shaped key looks like on a content-rooted domain - ACL keys are relative to the docroot, not to a domain\'s URLs, and an inert rule looks exactly like a protecting one until somebody tries the URL.',
        cap => 'manage_content',
        inputSchema => { type => 'object', properties => {}, additionalProperties => JSON::PP::false },
        run => sub { _audit_site() },
    },
    analyse_visitors => {
        description => 'Visitor-log analysis for trend reporting (read-only). Returns a SANITISED JSON: per-day and per-month totals, a people/AI-assistant/bot/noise/scanner traffic breakdown (scanner = a visitor that probed a non-existent path, so its whole session - including a spoofed referrer - is excluded from people), top pages, referrers, status codes, a not_found split (plausible missing pages vs a junk scanner-chorus count), auth_refused (paths a visitor was TURNED AWAY from rather than paths that were missing - a file here that should be public means an access rule is refusing it, which is how a mis-scoped ACL surfaces), a device breakdown, and - ONLY where the sysop has switched it on - the top internal SEARCH TERMS visitors typed, which are people\'s own words rather than facts about a page and are held to terms used by at least three separate visits, and a bounded recent event SAMPLE - never the raw log, any filesystem path, or a visitor IP (IPs are anonymised; events carry only a network-level visitor token). The aggregates are complete over data_from..window.to and durably stored one file per day (SM213); "events"/"sample" is a recent sample, not the dataset - use data_from and the sample.{from,to,count} fields to tell them apart. Selectors: index (the days+months index, plus trail_days - which days have trails), day=YYYY-MM-DD (one day\'s rollup), month=YYYY-MM (one month\'s rollup), trails=YYYY-MM-DD (one day\'s recorded visit trails - the ORDERED page sequence per visit, which the aggregates above cannot answer); otherwise a windowed view. Read /docs/ai-briefing-stats to interpret the fields, then answer the sysop\'s question (trends, month-on-month, rising/falling pages, AI-crawler share). Heuristic and not authenticated.',
        cap         => 'analytics',
        inputSchema => { type => 'object',
            properties => {
                window => { type => 'integer', description => 'Days for the windowed view (1-365, default 30).' },
                index => { type => 'boolean', description => 'Return the days + months index instead of a window.' },
                day => { type => 'string', description => 'A specific day (YYYY-MM-DD) - returns that day\'s durable rollup.' },
                month => { type => 'string', description => 'A specific month (YYYY-MM) - returns that month\'s durable rollup.' },
                trails => { type => 'string', description => 'A specific day (YYYY-MM-DD) - returns that day\'s recorded VISIT TRAILS: the ordered page sequence per visit, with entry, exit, distinct-page depth, the gap after each step and the visitor class at the time. Use index to see which days have trails; they expire (30 days by default) where the rollups do not.' },
            },
            additionalProperties => JSON::PP::false },
        run => sub { _stats_export( $_[0] ) },
    },
    validate_page => {
        description => 'Check page content before saving: malformed/unterminated front matter, missing title, invalid form-field rules, and a PUBLIC-DATA warning (Wi-Fi passwords, postcodes/addresses, phone numbers) so private operational details are not published by accident. Pass content to check a draft, or path to check a saved file.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => {
                path => { type => 'string', description => 'page to validate' },
                content => { type => 'string', description => 'draft content to validate instead of a saved file' },
            },
            additionalProperties => JSON::PP::false },
        run => sub { _validate_page( $_[0]->{path}, $_[0]->{content}, $_[1] ) },
    },
    read_nav => {
        description => 'Read a site navigation as a structured list (top-level items with optional children), plus which nav_file it came from and whether that is INHERITED from the primary site. WITHOUT `host` this reads the primary site. WITH `host` it reads that one configured domain. Call list_domains first if the instance may serve more than one site. Read this before set_nav to modify it.',
        # SM421 (parity map F1): manage_nav, not manage_content. This was
        # path_aware, but its run passes only `host` and no path - so the
        # dispatcher's carve-out pass had nothing to inspect and never demanded
        # the capability that owns nav.conf. WebDAV GET of nav.conf and the
        # API's token nav-read both require manage_nav, and set_nav (the write)
        # already did; only the MCP READ undershot. Low sensitivity - nav is
        # public - but the engine's own rule about who owns nav.conf was not
        # upheld on one surface out of three.
        cap         => 'manage_nav',
        inputSchema => { type => 'object',
            properties => {
                host => { type => 'string', description => 'configured domain to read; omit for the primary site' },
            },
            additionalProperties => JSON::PP::false },
        run => sub { action_nav_read( $_[0]->{host} ) },
    },
    set_nav => {
        description => 'Replace a site navigation. items is an ordered list of { label, url } (a child list under "children" becomes an indented sub-menu; an item with no url is a section header). WITHOUT `host` this writes the PRIMARY site nav. WITH `host` it writes that one configured domain and leaves the others alone - call list_domains first if the instance may serve more than one site. Writes the domain nav_file and clears the render cache, reporting how many pages were refreshed: the nav is baked into every page, so a nav change is invisible until they re-render.',
        cap         => 'manage_nav',
        inputSchema => { type => 'object',
            properties => {
                items => { type => 'array', items => { type => 'object' } },
                host => { type => 'string', description => 'configured domain to write; omit for the primary site' },
            },
            required => ['items'], additionalProperties => JSON::PP::false },
        run => sub { action_nav_save( $_[0]->{items}, $_[0]->{host} ) },
    },
    submit_feedback => {
        description => 'Submit a brief feedback report on your experience building this site through the connector - what worked, what got in the way, anything confusing or missing. You are encouraged to use this whenever something helps or hinders: it is how the operators improve the tools. Provide the content; your identity and context are recorded automatically. Returns the saved report id.',
        inputSchema => { type => 'object',
            properties => {
                summary => { type => 'string', description => 'one-line summary (required)' },
                good => { type => 'string', description => 'what worked well' },
                bad => { type => 'string', description => 'what got in the way or was missing' },
                rating => { type => 'integer', description => 'optional overall rating, 1 (poor) to 5 (great)' },
                context => { type => 'string', description => 'what you were doing when this applied' },
            },
            required => ['summary'], additionalProperties => JSON::PP::false },
        # Opt-in: feedback is OFF by default (no capability), so an agent cannot
        # write to lazysite/feedback/ or ping the sysop until the sysop
        # grants the `feedback` capability to the agent's group - transparency +
        # operator control, rather than default-on-and-invisible. The write path
        # itself is safe (server-generated .json filename, JSON-encoded content -
        # no traversal, no code execution); the capability bounds who may spend
        # the operator's disk + notifications.
        cap => 'feedback',
        run => sub { _submit_feedback( $_[0], $_[1], $_[2] ) },
    },
    create_page => {
        description => 'Create a new page from front-matter fields (title, subtitle, register list) + Markdown body. Errors if the page already exists (use write_file to overwrite). Higher-level than assembling front matter by hand. FOR A FORM: never hand-write <form>/<input> HTML (it ships with no delivery handler - a dead form). Use the create_form tool, or put a native :::form block in the body (fields as "name | Label | rules" lines) plus "form: NAME" front matter, then wire delivery with bind_form.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => {
                slug => { type => 'string', description => 'page path, e.g. things-to-do' },
                title    => { type => 'string' },
                subtitle => { type => 'string' },
                body     => { type => 'string', description => 'Markdown body' },
                register => { type => 'array', items => { type => 'string' }, description => 'registries by output name, e.g. ["sitemap.xml","llms.txt"] (a bare stem like "sitemap" is resolved to its template output name)' },
            },
            required => ['slug'], additionalProperties => JSON::PP::false },
        run => sub { _create_page( $_[0], $_[1] ) },
    },
    delete_page => {
        description => 'Delete a page by slug or by path (either works) - its brief store entry goes with it - and report where its slug is still referenced (nav, other pages) so you can clean up. Generated indexes (sitemap/llms/feeds) refresh automatically. A delete ends the page content history thread; to RELOCATE a page use rename_page (not delete-then-recreate) so its history follows.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => {
                slug => { type => 'string', description => 'The page slug (about, or docs/install)' },
                path => { type => 'string', description => 'Or the page path as read_page spells it (/about.md) - either identifier works' },
            },
            additionalProperties => JSON::PP::false },
        run => sub { _delete_page( $_[0], $_[1] ) },
    },
    rename_page => {
        description => 'Rename / move a page: carries its brief store entry + ACL and PRESERVES its content history across the rename. Always use this to relocate a page - never write a new page at the new path and delete the old one, which loses the history. With update_links:true, rewrites internal links to the old path across pages (best-effort - verify with preview_page; nav.conf is not rewritten). The result always reports alias_suggested - the old URL, which should be added to the new page so the retired URL keeps working; pass add_alias:true to have it written for you. A published URL that starts 404ing is the most common avoidable cost of a rename.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => {
                old          => { type => 'string' }, new => { type => 'string' },
                update_links => { type => 'boolean' },
                add_alias    => { type => 'boolean',
                    description => 'Add the old URL to the new page\'s aliases: so the retired URL keeps working. Creates the front-matter block if the page has none. The result reports alias_added (it was written), or alias_present (it was already there), so you can tell the two apart.' },
            },
            required => [ 'old', 'new' ], additionalProperties => JSON::PP::false },
        run => sub { _rename_page( $_[0], $_[1] ) },
    },
    list_pages => {
        description => 'List the site pages with their title, public URL, and which registries (sitemap/llms/feed) each is in. A page-level view rather than a raw file list.',
        cap => 'manage_content',
        inputSchema => { type => 'object', properties => {}, additionalProperties => JSON::PP::false },
        run => sub { _list_pages() },
    },
    read_page => {
        description => 'Read a page as structured data: parsed front matter, the Markdown body, whether it has an authoring brief, and its public URL. Higher-level than read_file for editing a page.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => { path => { type => 'string', description => 'page path, e.g. /enquire.md' } },
            required => ['path'], additionalProperties => JSON::PP::false },
        run => sub { _read_page( $_[0]->{path}, $_[1] ) },
    },
    preview_page => {
        description => 'Render a page server-side (fresh, bypassing the cache) and return its HTML, so you can verify layout / nav / form output in-channel - no web fetch needed. Renders the public view; a protected page shows the auth gate.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => { path => { type => 'string', description => 'page path, e.g. /enquire' } },
            required => ['path'], additionalProperties => JSON::PP::false },
        run => sub { _preview_page( $_[0]->{path} ) },
    },
    page_status => {
        description => 'Publish status for a page: whether the source exists, when it was last modified, whether the public HTML render is pending (cache dropped after an edit - it re-renders on the next visit), and the public URL. Use after an edit to confirm it will reach visitors.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => { path => { type => 'string', description => 'page path, e.g. /enquire.md' } },
            required => ['path'], additionalProperties => JSON::PP::false },
        run => sub { _page_status( $_[0]->{path} ) },
    },
    search_files => {
        description => 'Search the site text files for a string (case-insensitive). Returns matching files with line numbers and snippets - use to find pages mentioning a term, links to a path, or duplicated text. Excludes the lazysite/ infrastructure and binary/asset files. "count" is how many matches this response CARRIES, never how many exist; no total is available, because the search stops early by design and counting them all would mean reading every file. When "truncated" is true, "truncated_reason" says what stopped it: "match_limit" - there are more matches, so page on with "offset" or narrow the query; "file_budget" - the tree was too large to finish, so narrow "path" instead. Paging re-walks the tree each call, so a result set that changes underneath you can skip or repeat an entry.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => {
                query => { type => 'string', description => 'text to search for' },
                path => { type => 'string', description => 'directory to search under (default /)' },
                limit => { type => 'integer',
                    description => 'maximum matches to return (default 200, maximum 500)' },
                offset => { type => 'integer',
                    description => 'matches to skip, for paging past a truncated result (default 0)' },
            },
            required => ['query'], additionalProperties => JSON::PP::false },
        run => sub {
            _mcp_search( $_[0]->{query}, $_[0]->{path}, $_[0]->{limit}, $_[0]->{offset} );
        },
    },
    regenerate_registries => {
        description => 'Clear the generated registries - sitemap.xml, llms.txt, robots.txt and the feeds - so they rebuild from current content on the next request. Use after deleting or renaming a page when you want to VERIFY the result: a delete removes the page immediately but the registries are rebuilt asynchronously, so checking the sitemap straight afterwards can still show the old URL. Clears every content root, so a multi-domain instance is handled in one call. Fetch the registry afterwards to force the rebuild.',
        cap         => 'manage_content',
        inputSchema => { type => 'object', properties => {},
            additionalProperties => JSON::PP::false },
        run => sub {
            # SM264: the operator's preferred remedy for SM251's reported
            # confusion - an agent deletes a page, checks the sitemap, still sees
            # the URL and reasonably concludes the delete failed. On one site
            # that led to hand-editing a generated registry. Waiting is not a
            # workflow; this makes "delete then verify" complete.
            #
            # SM442: route through the SHARED action rather than rebuilding
            # the response here. This copy called the invalidator and then
            # composed its own answer, so it reported cleared_roots with no
            # cleared_files - and, worse, no shadowed_by_files at all. SM433
            # added that warning to the control API only, so an MCP caller
            # regenerating against a shadowed registry was told the clear
            # succeeded and given nothing to explain why the site did not
            # change. Two implementations of one operation drift, and the
            # drift is silent because each surface is individually consistent
            # - the reasoning SM301 and SM318 already settled for other pairs.
            return Lazysite::Manager::Files::action_regenerate_registries();
        },
    },
    invalidate_cache => {
        description => 'Drop the cached HTML for a page so it re-renders on the next request. A normal write already clears the saved page; use this to force a refresh or to rebuild pages that embed another (pass "*" to clear every page).',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => { path => { type => 'string', description => 'Page path (e.g. /enquire), or "*" for all pages' } },
            required => ['path'], additionalProperties => JSON::PP::false },
        run => sub { action_cache_invalidate( $_[0]->{path} ) },
    },
    # SM085 over MCP: the content-history surface the control API already has
    # (git-history / git-show / git-restore), so a connector agent can inspect
    # and undo content changes. Available when the site's Content history
    # plugin is enabled; list_versions says so honestly when it is not.
    list_versions => {
        description => 'List a file\'s recorded versions (content history): newest first, each with a version id, author, date and message. Works when the site\'s Content history plugin is enabled - if the result says enabled:false, versions are not being recorded and there is nothing to restore (ask the sysop to enable the plugin).',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => {
                path => { type => 'string' },
                limit => { type => 'integer', description => 'maximum entries to return (default 50)' },
            },
            required => ['path'], additionalProperties => JSON::PP::false },
        run => sub { action_git_history( $_[0]->{path}, $_[1], $_[0]->{limit} ) },
    },
    # SM199: the file-list / table-of-contents over the whole history - every
    # path under version control with per-file statistics (revision count, first
    # + latest date, last author) and a site-level summary (total files, total
    # revisions). The report/overview complement of list_versions (per file):
    # an agent can see at a glance which content is churning and which is stable.
    # Works when Content history is enabled; enabled:false means nothing recorded.
    list_content_history => {
        description => 'List every file under content history with per-file statistics: '
            . 'number of recorded versions, date of the first and latest version, and the '
            . 'last author - plus a site-level summary (total files, total revisions). This '
            . 'is the overview complement of list_versions (which lists one file\'s versions): '
            . 'use it to see where change is happening across the site. Works when the site\'s '
            . 'Content history plugin is enabled - if enabled:false, nothing is being recorded.',
        cap         => 'manage_content',
        inputSchema => { type => 'object', properties => {},
            additionalProperties => JSON::PP::false },
        # SM419: the partner's resolved scope union, as the path_aware tools
        # get via the dispatcher - this tool carries no path for that block to
        # filter, so it takes the scopes directly.
        run => sub { action_git_history_summary( $_[2] ? $_[2]->{dav_scopes} : undef ) },
    },
    view_version => {
        description => 'View one recorded version of a file: its full content at that version plus a unified diff against the current file. Get the version id from list_versions first.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => {
                path => { type => 'string' },
                version => { type => 'string', description => 'version id from list_versions' },
            },
            required => [ 'path', 'version' ], additionalProperties => JSON::PP::false },
        run => sub { action_git_show( $_[0]->{path}, $_[1], $_[0]->{version} ) },
    },
    restore_version => {
        description => 'Restore a file to one of its recorded versions. The historic content is written back through the normal save path (page cache refreshed), and the restore itself becomes the newest recorded version - nothing is ever lost by restoring. Use list_versions / view_version first to pick the version.',
        cap         => 'manage_content', path_aware => 1,
        inputSchema => { type => 'object',
            properties => {
                path => { type => 'string' },
                version => { type => 'string', description => 'version id from list_versions' },
            },
            required => [ 'path', 'version' ], additionalProperties => JSON::PP::false },
        run => sub { action_git_restore( $_[0]->{path}, $_[1], $_[0]->{version} ) },
    },
);

# Content search (grep) over site text files. Excludes the lazysite/ infra and
# binary/asset files; bounded by file + match caps so a big site can't produce a
# runaway response.
#
# SM359: WHAT IS ACTUALLY BEING PAGED, because it decided the design. This is a
# depth-first walk of the site's own content tree reading a few hundred small
# text files - 181 on lazysite.io, 442 on dito.tech - against a 2,000-file
# budget and a 200-match cap. So the FILE budget essentially never fires on a
# real site; it is there to stop a runaway tree. The MATCH cap fires constantly,
# because searching a site for a common word reaches 200 hits in the first few
# pages.
#
# That inverts the filing's priority. A caller who hits truncation here almost
# always has too broad a QUERY rather than too small a page, and the response
# could not tell them so: both limits set the same bare boolean. Naming which
# one stopped the walk is the smaller change and the more useful one.
#
# NO TOTAL, deliberately. "200 of 1,431" would be the honest thing to report and
# the scan stops AT 200, so producing that number means walking the whole tree
# and reading every file - exactly the cost the cap exists to avoid. Promising a
# figure the design cannot afford would make the response slower to be more
# impressive.
#
# NO CURSOR, also deliberately. Offset paging re-walks from the start each time
# and can skip or repeat if the tree changes underneath, which is the honest
# weakness of it. On a few hundred files the re-walk is milliseconds, and a
# cursor would mean inventing a stable index this traversal does not have - the
# stack is a LIFO, so it is deterministic for an unchanged tree and is an order,
# not an index. Said plainly in the schema rather than papered over.
our $SEARCH_FILE_BUDGET = 2000;
our $SEARCH_LIMIT_MAX   = 500;
our $SEARCH_LIMIT_DEF   = 200;
my %SEARCH_EXT = map { $_ => 1 } qw(md txt html htm xml json js css svg atom rss);

sub _mcp_search {
    my ( $query, $base, $limit, $offset ) = @_;

    $limit  = $SEARCH_LIMIT_DEF unless defined $limit  && $limit =~ /^\d+$/ && $limit > 0;
    $offset = 0                 unless defined $offset && $offset =~ /^\d+$/;
    $limit  = $SEARCH_LIMIT_MAX if $limit > $SEARCH_LIMIT_MAX;
    return { ok => 0, error => 'query must not be empty' } unless defined $query && length $query;
    $base = '/' unless defined $base && length $base;
    $base =~ s{^/+}{}; $base =~ s{/+$}{}; $base =~ s{\.\.}{}g;

    # SM268 04-F4: the lazysite/ exclusion below only applies while DESCENDING,
    # so naming a base INSIDE the tree skipped it entirely - and the blocklist
    # was never consulted at all. `search_files` with base lazysite/auth printed
    # user-settings.json a line at a time, a file read_file refuses outright:
    # the full capability and scope roster, to any partner holding
    # manage_content, scoped or not, as an unlimited-query oracle. The
    # searchable extension set also covers acls.json (per-file owner and
    # reader/writer lists), oauth.json and revoked.json.
    return { ok => 0,
        error => 'search does not enter the lazysite/ tree - it holds the auth '
            . 'store, ACLs and engine state, none of which is site content' }
        if Lazysite::Manager::Common::path_is_reserved($base);

    my $root = $DOCROOT . ( length $base ? "/$base" : '' );
    my $qre  = qr/\Q$query\E/i;
    my ( @matches, $files, $truncated, $reason, $seen );
    my @stack = ($root);
    while (@stack) {
        my $dir = pop @stack;
        opendir my $dh, $dir or next;
        for my $e ( sort readdir $dh ) {
            next if $e =~ /^\./;
            my $full = "$dir/$e";
            if ( -d $full ) {
                push @stack, $full unless $e eq 'lazysite' || $e eq 'lazysite-assets';
                next;
            }
            next unless -f $full;
            my ($ext) = $e =~ /\.([^.]+)$/;
            next unless $ext && $SEARCH_EXT{ lc $ext };
            # SM268 04-F4: and the blocklist per candidate, as defence in depth -
            # the base check above is a string test, this one asks the same
            # question the read path asks about the file actually being opened.
            ( my $key = $full ) =~ s{^\Q$DOCROOT\E/?}{};
            next if Lazysite::Manager::Common::is_blocked_path($key);
            if ( ++$files > $SEARCH_FILE_BUDGET ) {
                $truncated = 1;
                $reason    = 'file_budget';
                last;
            }
            open my $fh, '<:utf8', $full or next;
            my $ln = 0;
            while ( my $line = <$fh> ) {
                $ln++;
                next unless $line =~ $qre;

                # SM359: count every match, return only this page's worth. The
                # walk continues one match PAST the limit so `truncated` means
                # "there is more after this page" rather than "the page is
                # full" - the two differ on the last page, which is the one a
                # caller stops on.
                $seen++;
                next if $seen <= $offset;
                if ( @matches >= $limit ) {
                    $truncated = 1;
                    $reason    = 'match_limit';
                    last;
                }
                ( my $rel = $full ) =~ s{^\Q$DOCROOT\E/?}{/};
                chomp $line;
                $line = substr( $line =~ s/^\s+//r, 0, 200 );
                push @matches, { path => $rel, line => $ln, text => $line };
            }
            close $fh;
            last if $truncated;
        }
        closedir $dh;
        last if $truncated;
    }
    return {
        ok        => 1,
        query     => $query,
        count     => scalar @matches,    # SM359: matches RETURNED, never a total
        limit     => $limit,
        offset    => $offset,
        matches   => \@matches,
        truncated => ( $truncated ? JSON::PP::true : JSON::PP::false ),

        # Present only when something stopped the walk, so its absence is not a
        # third state to interpret. `match_limit` means ask for the next page or
        # narrow the query; `file_budget` means narrow the base - the two want
        # opposite responses and used to be indistinguishable.
        ( $truncated ? ( truncated_reason => $reason ) : () ),
    };
}

# Publish status for a page: is the source there, has the rendered HTML cache
# been dropped (so a visitor re-renders it fresh), and where is it public.
# SM347: ONE PATH VOCABULARY.
#
# A page created as `create_page {"slug":"zz/probe"}` is stored at
# `/zz/probe.md` and served at `/zz/probe`. Four tools accepted either form and
# two - read_page and validate_page - accepted only the stored one, so the
# natural sequence failed: create a page, read it back at the path it serves
# from, and get not-found with `retryable:false` for a page answering 200.
#
# page_status was in the accepting column for a weaker reason: it returned
# `ok:1` with `exists:false`, which is the call succeeding rather than the page
# being found. That is the worse half - a tool that says ok about a page it did
# not locate.
#
# Conservative on purpose. An exact path that exists is returned unchanged, so
# nothing addressing a file directly changes behaviour; `.md` is tried only when
# the path as given is not there. A path that resolves to nothing comes back as
# it was asked for, so the error names what the caller said rather than
# something the engine invented.
# Turn a caller's page path into the relative slug the docroot is keyed on.
# The callers deliberately differ in HOW FAR they go - only the page verbs strip
# a `.md` suffix, and only create/rename strip a trailing slash - so the extra
# steps are named options rather than folded into one chain.
sub _norm_slug {
    my ( $path, %opt ) = @_;
    my $slug = defined $path ? $path : '';
    $slug =~ s{^/+}{};
    $slug =~ s{\.\.}{}g  if $opt{dots};
    $slug =~ s{\.md\z}{} if $opt{md};
    $slug =~ s{/+\z}{}   if $opt{trail};
    return $slug;
}

sub _resolve_page_path {
    my ($path) = @_;
    return $path unless defined $path && length $path;
    my $rel = _norm_slug( $path, dots => 1 );
    return $path      if -f "$DOCROOT/$rel";
    return "/$rel.md" if $rel !~ /\.md\z/ && -f "$DOCROOT/$rel.md";
    return $path;
}

sub _page_status {
    my ($path) = @_;
    return { ok => 0, error => 'path required' } unless defined $path && length $path;
    $path = _resolve_page_path($path);    # SM347
    my $rel    = _norm_slug( $path, dots => 1 );
    my $full   = "$DOCROOT/$rel";
    my $exists = -f $full;
    my %out    = ( ok => 1, path => "/$rel",
        exists => ( $exists ? JSON::PP::true : JSON::PP::false ) );
    $out{modified} = ( stat $full )[9] if $exists;
    if ( $rel =~ /\.md$/ ) {
        ( my $html = $full ) =~ s/\.md$/.html/;
        my $cached = -f $html;
        # render_pending: the public HTML is missing or older than the source, so
        # the next visit re-renders it (a normal state right after an edit).
        $out{render_pending} =
            ( !$cached || ( $exists && ( stat $html )[9] < ( stat $full )[9] ) )
            ? JSON::PP::true : JSON::PP::false;
        $out{public_url} = _public_url($rel);
    }
    return \%out;
}

# --- SM087: authenticated in-channel preview (server-side render) ----------
# MC-12 / MCO-3: lazysite.conf was opened three times in a request that audits a
# site - twice by the audit itself and once for the language note. It is not
# written during a request, so one read serves them all and the answer cannot
# change between them.
#
# Two layers, deliberately. The two scanners read DECODED text; set_members()
# parses the bytes the language-set writer wrote. Folding those into a single
# read would change what a non-ASCII value means to one of them, which is a
# behaviour change wearing a cleanup's clothes.
{
    my %CONF_TEXT;

    sub _read_conf_text {
        my ($layer) = @_;
        $layer = ':utf8' unless defined $layer;
        return $CONF_TEXT{$layer} if exists $CONF_TEXT{$layer};
        my $text = '';
        if ( open my $fh, "<$layer", "$LAZYSITE_DIR/lazysite.conf" ) {
            local $/;
            $text = <$fh>;
            close $fh;
        }
        $CONF_TEXT{$layer} = defined $text ? $text : '';
        return $CONF_TEXT{$layer};
    }
}

sub _processor_tool {
    my $bin = dirname( Cwd::abs_path(__FILE__) );
    return _sibling_tool( "$bin/lazysite-processor.pl",
        "$DOCROOT/../cgi-bin/lazysite-processor.pl" );
}

sub _preview_page {
    my ($path) = @_;
    return { ok => 0, error => 'path required' } unless defined $path && length $path;
    ( my $slug = $path ) =~ s{^/+}{}; $slug =~ s{\.\.}{}g; $slug =~ s{\.md$}{}; $slug =~ s{/+$}{};
    my $proc = _processor_tool()
        or return { ok => 0, kind => 'not-found', error => 'processor not available' };

    # Render fresh (no cache, no cache write), as a public visitor.
    local %ENV = ( %ENV,
        DOCUMENT_ROOT    => $DOCROOT,
        REDIRECT_URL     => "/$slug",
        REQUEST_URI      => "/$slug",
        REQUEST_METHOD   => 'GET',
        CONTENT_LENGTH   => '0',
        LAZYSITE_NOCACHE => '1',
    );
    delete $ENV{HTTP_AUTHORIZATION};
    delete $ENV{REDIRECT_HTTP_AUTHORIZATION};

    my $out = '';
    # Decode the rendered HTML so the JSON layer encodes it once (raw bytes here
    # would be re-encoded into mojibake).
    if ( open my $ph, '-|', $^X, $proc ) { binmode $ph, ':utf8'; local $/; $out = <$ph> // ''; close $ph }
    else { return { ok => 0, error => 'could not run the processor' } }

    my ( $head, $body ) = split /\r?\n\r?\n/, $out, 2;
    $body = '' unless defined $body;
    my ($status) = ( ( $head // '' ) =~ /Status:\s*(\d+)/i );
    $status ||= 200;
    my $truncated = 0;
    if ( length $body > $MAX_READ_BYTES ) { $body = substr( $body, 0, $MAX_READ_BYTES ); $truncated = 1 }
    return { ok => 1, path => "/$slug", status => $status, bytes => length $body, html => $body,
        truncated => ( $truncated ? JSON::PP::true : JSON::PP::false ),
        note => 'rendered fresh as a public visitor; a protected page shows the auth gate' };
}

# --- SM087 Tier 2: page-aware helpers -------------------------------------
sub _split_front_matter {
    my ($c) = @_;
    return ( $1, $2 ) if $c =~ /\A---[ \t]*\n(.*?)\n?---[ \t]*\n?(.*)\z/s;
    return ( '', $c );
}

sub _parse_fm {
    my ($fm) = @_;
    my %h;
    for my $line ( split /\n/, $fm ) {
        next unless $line =~ /^([A-Za-z0-9_-]+)\s*:\s*(.*)$/;
        my ( $k, $v ) = ( $1, $2 );
        $v =~ s/\s+$//;
        if ( $v =~ /^\[(.*)\]$/ ) { $h{$k} = [ grep { length } map { s/^\s+|\s+$|["']//gr } split /,/, $1 ]; }
        else                      { $v =~ s/^["']|["']$//g; $h{$k} = $v; }
    }
    return \%h;
}

sub _public_url {
    my ($rel) = @_;
    ( my $slug = $rel ) =~ s/\.md$//;
    my $host = $ENV{HTTP_HOST} // $ENV{SERVER_NAME} // '';
    return length $host ? "https://$host/$slug" : "/$slug";
}

sub _read_page {
    my ( $path, $user ) = @_;
    $path = _resolve_page_path($path);    # SM347
    my $r = action_read( $path, $user );
    return $r unless ref $r eq 'HASH' && $r->{ok};
    my ( $fm, $body ) = _split_front_matter( $r->{content} );
    ( my $rel = $path ) =~ s{^/+}{};
    return { ok => 1, path => "/$rel",
        front_matter => _parse_fm($fm), body => $body,
        # SM245 retired the .brief sidecar; the engine-owned store is the
        # only place a brief lives, as read_brief's own description says.
        has_brief => ( -f "$LAZYSITE_DIR/briefs/$rel" ? JSON::PP::true : JSON::PP::false ),
        public_url => _public_url($rel), modified => $r->{mtime} };
}

# Walk every .md page under the docroot, skipping only ENGINE territory: the
# reserved roots Manager::Common knows (lazysite/), the generated asset tree
# and the manager UI. SM538: this used to skip img, quotes and docs as well -
# the first site's folder names, carried since SM087 - so every documentation
# page under docs/ was invisible to list_pages, audit_site and rename_page.
my %ENGINE_DIRS = map { $_ => 1 } qw(lazysite-assets manager);

sub _each_page {
    my ($cb)  = @_;
    my @stack = ($DOCROOT);
    my $n     = 0;
    while (@stack) {
        my $dir = pop @stack;
        opendir my $dh, $dir or next;
        for my $e ( sort readdir $dh ) {
            next if $e =~ /^\./;
            my $full = "$dir/$e";
            if ( -d $full ) {
                ( my $drel = $full ) =~ s{^\Q$DOCROOT\E/+}{};
                push @stack, $full
                    unless $ENGINE_DIRS{$drel}
                    || Lazysite::Manager::Common::path_is_reserved($drel);
                next;
            }
            next unless -f $full && $e =~ /\.md$/;
            ( my $rel = $full ) =~ s{^\Q$DOCROOT\E/+}{};
            return if ++$n > 1000;
            $cb->( $rel, $full );
        }
        closedir $dh;
    }
    return;
}

sub _list_pages {
    my @pages;
    _each_page( sub {
            my ( $rel, $full ) = @_;
            open my $fh, '<:utf8', $full or return;
            local $/; my $c = <$fh>; close $fh;
            my ($fm) = _split_front_matter($c);
            my $h = _parse_fm($fm);
            push @pages, { path => "/$rel", title => ( $h->{title} // '' ),
                registers => ( ref $h->{register} eq 'ARRAY' ? $h->{register} : ( $h->{register} ? [ $h->{register} ] : [] ) ),
                public_url => _public_url($rel) };
    } );
    @pages = sort { $a->{path} cmp $b->{path} } @pages;
    return { ok => 1, count => scalar @pages, pages => \@pages };
}

# --- SM087 Tier 2: validate a page (incl. public-data warnings) ------------
my %FORM_FLAGS = map { $_ => 1 }
    qw(required optional email tel date time number url password textarea);
# SM205: eager validation of a theme.json written via write_file. Mirrors how
# _validate_page runs for page writes: parse the JSON, apply the shared
# name/value rules (theme_config_issues) and the SM203 declared-token coverage
# check, and return a flat list of warning strings. Warn-only - never rejects
# (the write already happened; this surfaces issues so a fix does not need a
# re-activation cycle).
sub _validate_theme_json {
    my ( $path, $content ) = @_;
    my @w;
    my $data = eval { decode_json($content) };
    if ( ref $data ne 'HASH' ) {
        return ['theme.json does not parse as a JSON object'];
    }
    my $name   = $data->{name};
    my $config = ( ref $data->{config} eq 'HASH' ) ? $data->{config} : {};
    push @w, theme_config_issues( $config, $name );

    # Coverage against the layout declared tokens, derived from the path
    # (lazysite/layouts/<layout>/themes/<theme>/theme.json).
    if ( $path =~ m{lazysite/layouts/([A-Za-z0-9_-]+)/themes/} ) {
        my $layout   = $1;
        my $declared = _layout_declared_tokens($layout);
        my $supplied = _theme_config_tokens( { config => $config } );
        my $tw       = _token_mismatch( $declared, $supplied );
        push @w, @{ _token_warning_list($tw) } if $tw;
    }
    return \@w;
}

# SM488: a warning's line number counts from the top of the FILE, so a scan
# over the BODY (which _split_front_matter returns without its --- fences) has
# to start at the front matter's line count plus the two fences. Written twice
# with two spellings before SM516.
sub _fm_line_offset {
    my ($fm) = @_;
    return 0 unless length $fm;
    return ( ( () = $fm =~ /\n/g ) + 1 ) + 2;
}

# MC-10: _validate_page was 285 lines of seven unrelated checks sharing two
# arrays. Each check is now its own named sub, called in the ORDER IT WAS
# WRITTEN IN - the issue and warning lists are ordered and an agent reads them
# top-down, so the order is part of the answer, not an accident of layout.
# Every body below is the original text; only the two arrays became the
# references each check is handed.

sub _check_front_matter {
    my ( $issues, $warnings, $content, $h ) = @_;
    # Front matter: opened-but-unterminated, and missing title.
    if ( $content =~ /\A---\s*\n/ && $content !~ /\A---\s*\n.*?\n---\s*\n/s ) {
        push @$issues, { kind => 'front-matter-unterminated',
            message => 'front matter opened with --- but never closed' };
    }
    push @$warnings, { kind => 'no-title', message => 'page has no title in front matter' }
        unless length( $h->{title} // '' );

    # SM228: a raw/api page declaring a script-capable content_type is refused at
    # write time and downgraded to text/plain at serve time (ADR 0006). Pages
    # written before that refusal existed are still on disk, still serving as
    # plain text, and nothing told their author why. Report them here with the
    # same remedy the write path gives, so an existing page can be found without
    # loading each one.
    if ( my $raw = Lazysite::Manager::Common::raw_html_page_refusal($content) ) {
        push @$issues, { kind => 'raw-html-page', message => $raw };
    }
    return;
}

sub _check_fences {
    my ( $warnings, $fm, $body ) = @_;
    # GS11 (SM492): AN OPENING FENCE THAT IS NEVER CLOSED SAYS SO, HERE.
    #
    # The processor leaves an unbalanced `::: name` in the page as literal text
    # and logs a WARN the author cannot read over MCP. The symptom on the page
    # is three colons and a word where a hero should be. Reported at the line
    # counted from the top of the FILE (SM488), naming the fence, so the
    # reader's cursor lands on the fence that was opened and never closed.
    #
    # Lines inside ``` code blocks are skipped: a page that DOCUMENTS fences
    # would otherwise trip the check that exists to make fences safe.
    {
        my $off = _fm_line_offset($fm);
        my ( @open, $in_code );
        my $n = 0;
        for my $line ( split /\n/, ( $body // '' ) ) {
            $n++;
            if ( $line =~ /^[ \t]{0,3}(?:```|~~~)/ ) { $in_code = !$in_code; next }
            next if $in_code;
            if    ( $line =~ /^:::[ \t]+([\w-]+)/ ) { push @open, [ $1, $n + $off ] }
            elsif ( $line =~ /^:::[ \t]*$/ ) {
                if (@open) { pop @open }
                else {
                    push @$warnings, { kind => 'fence-close-unmatched', line => $n + $off,
                        message => 'a closing ::: with no open fence above it. It renders '
                            . 'as literal text; remove it or find the opening line it '
                            . 'was meant to close' };
                }
            }
        }
        for my $o (@open) {
            push @$warnings, { kind => 'component-fence-unmatched', line => $o->[1],
                fence   => $o->[0],
                message => "the '::: $o->[0]' fence opened here is never closed. The "
                    . 'processor leaves it in the page as literal text and the block '
                    . 'is not rendered as a component or a div; add the closing ::: '
                    . '(count them when you nest)' };
        }
    }
    return;
}

# SM708: A PAGE WHOSE TEMPLATE BODY CANNOT BE PARSED IS REFUSED HERE, because
# the alternative is that it renders wrong forever and says so only in a log.
#
# WHAT GOES WRONG AT RENDER. Page bodies are TT-processed. A literal `[%` that
# is not a valid directive fails the parse, and lazysite-processor.pl's fallback
# is WHOLE-BODY: it emits the raw body, so EVERY `[% %]` on the page comes out
# un-substituted, not just the span that failed. The page still renders. The
# only signal is one ERROR log line. Reported from familyhq, where a JavaScript
# guard written to detect an un-interpolated template - `/\[%/.test(u)` -
# contained the literal `[%` that broke the parse, and then blanked the very
# variable it was protecting.
#
# WHY IT IS CHECKED HERE AND NOT AT RENDER. At render there is nothing useful to
# do: refusing to serve would take a live page down over an authoring mistake.
# At write time the author is present and can fix it, which is the whole value.
#
# TWO THINGS THIS DELIBERATELY DOES NOT DO.
#
# It does not refuse on a NON-PARSE error. `[% INCLUDE missing.tt %]` fails
# here with a file error but may resolve at render, where INCLUDE_PATH is set.
# Only /parse error/ is refused - which is exactly the failure this filing is
# about, and nothing wider.
#
# It does not look inside code blocks. The processor lifts <pre><code> and
# <code> out before TT runs, so a literal `[%` in a code block is already safe -
# which is why this never bit a documentation page. Both FENCED and
# FOUR-SPACE-INDENTED blocks are stripped here: starter/docs/ai-briefing-layouts
# documents `[% INCLUDE ... %]` in an INDENTED block, and a checker that handled
# only fences would refuse a page we ship. The stripping is deliberately
# over-eager - any line indented four spaces goes - because over-stripping means
# checking less, while under-stripping means refusing a page that renders fine.
# SM708: THE REFUSAL, as distinct from the report.
#
# _validate_page's issues are ADVISORY on the write path: write_file calls
# action_save FIRST and attaches the issues to the result, so a page with an
# issue is already on disk by the time the caller reads about it. That is a
# reasonable contract for most issue kinds - an un-titled page is worth saving
# and worth mentioning - but it is the wrong one here, because a page whose
# template does not parse renders EVERY variable on it literally, and the author
# who could fix it in one edit is present at exactly this moment.
#
# So this refuses BEFORE the write, and only for this one issue kind. Widening
# it to refuse on any issue would change the contract for every other check on
# the same path, which is not this filing's business.
#
# Applied at the three points where a caller supplies page body text:
# write_file, replace_text and _create_page. Deliberately NOT applied to
# _create_form (the body is generated from structured fields, not authored),
# nor to copy_file or rename (the content already passed this gate when it was
# written, and refusing a MOVE because of it would strand the page).
sub _page_parse_refusal {
    return Lazysite::Manager::Common::page_parse_refusal(@_);
}

sub _check_db_bindings {
    my ( $issues, $warnings, $fm ) = @_;
    # SM481: A `db:` BINDING THAT WILL RENDER NOTHING SAYS SO, HERE.
    #
    # The engine already logs the reason - "it may not be published (set
    # public: true) or this visitor may not be allowed to read it" - and it
    # logs it to STDERR, which on a real install is the web server's error log.
    # An agent working over MCP cannot read that, and a site agent lost an
    # afternoon to a page rendering zero rows while the API returned three from
    # the same table at the same moment. They said it exactly right: nothing in
    # the empty result said "this table is not published".
    #
    # A diagnostic the person who needs it cannot reach is not a diagnostic. So
    # it is answered where they are already looking, and STATICALLY - the
    # descriptor says whether a visitor would see anything, without rendering.
    #
    # Read from the front-matter TEXT rather than the parsed hash: tt_page_var
    # is nested, _parse_fm is deliberately flat, and a checker that silently saw
    # no bindings would be a check that always passes.
    my $have_tables;
    for my $line ( split /\n/, ( $fm // '' ) ) {
        next unless $line =~ /:\s*db:([a-z][a-z0-9_]*)/;
        my $table = $1;
        # MCO-2: `require` is a no-op after the first load, but the eval and
        # the lookup are not free and the answer cannot change between two
        # bindings on the same page. Asked on the first binding, not on each
        # - and still not at all on a page that binds nothing, which is why
        # it is lazy here rather than hoisted to the top of the sub.
        $have_tables //= eval { require Lazysite::Data::Tables; 1 } ? 1 : 0;
        my $d = $have_tables
            ? eval { Lazysite::Data::Tables::load_table( $DOCROOT, $table ) }
            : undef;
        unless ( ref $d eq 'HASH' ) {
            push @$warnings, { kind => 'db-binding-unchecked',
                message => "could not check the table '$table' - the data "
                    . 'modules are not available here' };
            next;
        }

        unless ( $d->{ok} ) {
            push @$issues, { kind => 'db-table-missing',
                message => "this page binds db:$table, and $d->{error}. The "
                    . 'binding will render nothing.' };
            next;
        }

        # THE ONE THAT COST THE AFTERNOON. An unpublished table answers a
        # visitor exactly as a table that was never declared does - which is
        # deliberate, and is why nothing on the page could say which it was.
        unless ( $d->{public} ) {
            push @$issues, { kind => 'db-table-not-published',
                message => "this page binds db:$table, which is NOT PUBLISHED. "
                    . 'An anonymous visitor sees no rows and no sign the table '
                    . 'exists, while the API and the manager still read it - so '
                    . 'the page looks broken and the data looks fine. Add '
                    . "public: true to the $table descriptor." };
        }
    }
    return;
}

sub _check_form_rules {
    my ( $issues, $content ) = @_;
    # Form-field rules (catch typos/unsupported rules before publish).
    if ( $content =~ /:::\s*form\b(.*?):::/s ) {
        for my $line ( split /\n/, $1 ) {
            $line =~ s/^\s+|\s+$//g;
            next unless length $line;
            my ( $name, undef, $rules ) = split /\s*\|\s*/, $line, 3;
            next if !defined $name || $name eq 'submit' || !defined $rules;
            # select: takes the rest of the line (its options are not rules and may
            # contain spaces) - drop it before checking the remaining rule tokens.
            ( my $check = $rules ) =~ s/\bselect:.*$//s;
            for my $tok ( split /\s+/, $check ) {
                next if $FORM_FLAGS{$tok} || $tok =~ /^[a-z]+:/; # known flag or key:value
                next if $tok                      !~ /^[a-z]+$/; # only flag plain words
                push @$issues, { kind => 'invalid-form-rule',
                    message => "unknown form rule '$tok' on field '$name'" };
            }
        }
    }
    return;
}

sub _check_html_in_page {
    my ( $warnings, $body, $h ) = @_;
    # SM243: warn at the moment of writing, not only in a briefing the agent read
    # once. The site briefings already say all of this; the problem is that an
    # agent reads them at the start and then works through a tool surface that
    # cheerfully accepts the thing the briefing warned against. write_file and
    # create_page already surface these warnings from here, so a check added here
    # reaches the write path for free.
    #
    # WARN, never refuse. A hand-written HTML page is occasionally the right
    # answer and the platform should not pretend otherwise - the complaint is
    # silence, not permissiveness. (SM228's REFUSAL is different in kind: it
    # catches a page that would be served as plain text, which is always broken.)
    if ( $body =~ /<!DOCTYPE\b/i || $body =~ /<html\b/i || $body =~ /<head\b/i ) {
        push @$warnings, { kind => 'document-in-page',
            message => 'this page body contains a whole HTML document. The layout '
                . 'is then bypassed, the processor mangles the block tags, and the '
                . 'page cannot be maintained as content. Author the body as Markdown '
                . 'and let the layout and theme supply the structure and styling; if '
                . 'you genuinely need a self-contained HTML file served unchanged, '
                . 'publish it as a STATIC FILE (a .html with no .md source is served '
                . 'byte-for-byte).' };
    }
    if ( $body =~ /<style[\s>]/i ) {
        push @$warnings, { kind => 'style-block-in-page',
            message => 'a <style> block in page content styles one page and leaves '
                . 'the rest of the site inconsistent. Put the rules in the theme, '
                . 'where every page gets them and a restyle is one change.' };
    }
    # A raw/api page carrying a document is the shape SM228 refuses only when it
    # also declares an HTML content type; without that it is merely wrong, so it
    # warns here.
    if ( ( $h->{api} // '' ) =~ /^true$/i
        && ( $body =~ /<!DOCTYPE\b/i || $body =~ /<html\b/i ) )
    {
        push @$warnings, { kind => 'api-page-is-a-document',
            message => 'api: true marks this page as a DATA artifact, but the body '
                . 'is an HTML document. api: is for JSON/CSV/text endpoints; a page '
                . 'for people belongs in the layout, and a self-contained HTML file '
                . 'belongs in a static file.' };
    }
    # Page-baked chrome plus a theme that hides the layout's is how a site ends up
    # with unreachable navigation: the operator sets nav items that never appear.
    if ( $body =~ m{<nav[\s>]}i || $body =~ m{<footer[\s>]}i ) {
        push @$warnings, { kind => 'chrome-in-page',
            message => 'this page carries its own <nav> or <footer>. Those are the '
                . 'layout\'s job - a page that bakes its own chrome duplicates the '
                . 'layout\'s, and hiding one with CSS is what makes site navigation '
                . 'unreachable while looking fine.' };
    }

    # SM249: there was a warning here telling authors that theme_assets,
    # theme_css, theme_name and theme are LAYOUT scope and resolve to nothing in
    # a page body. That was true, and it is not any more - the engine now
    # resolves the layout and the active theme BEFORE rendering the body, so the
    # pattern the warning forbade is the pattern that works.
    #
    # The warning is gone rather than softened. A warning that describes a
    # constraint the engine no longer has is worse than none: it teaches an
    # author to write the literal path, which then goes stale when the site's
    # theme changes, in order to avoid a failure that cannot happen.
    #
    # t/unit/mcp/15 now asserts the ABSENCE of that warning, so reintroducing it
    # fails, and t/unit/processor/19 asserts the variables actually resolve in a
    # body - the fact the warning existed to work around.
    return;
}

sub _check_form_delivery {
    my ( $warnings, $content, $body, $h, $path ) = @_;
    # SM161: forms must be native (a :::form block bound to a sysop-vetted
    # handler), never hand-written HTML or a third-party form service.
    my $has_fenced_form = $content =~ /^:::[ \t]*form\b/m;
    if ( $body =~ /<form\b/i || $body =~ /<input\b/i || $body =~ /<textarea\b/i ) {
        push @$warnings, { kind => 'hand-authored-form',
            message => 'hand-written <form>/<input> HTML detected - it has no delivery '
                . 'handler and ships DEAD. Use a native :::form block (fields as '
                . '"name | Label | rules" lines) and wire delivery with bind_form.' };
    }
    if ( $body =~ /action\s*=\s*["']\s*mailto:/i ) {
        push @$warnings, { kind => 'form-mailto',
            message => 'a mailto: form action exposes an address and routes visitor '
                . 'data around the sysop-vetted handlers - use a :::form + bind_form.' };
    }
    if ( $body =~ m{
            action \s* = \s* ["'] \s* https?://
            (?:[\w.-]*\.)?
            (?: formspree\.io | docs\.google\.com | forms\.gle | jotform\.
              | typeform\. | wufoo\. | getform\. | form\.io )
        }ix )
    {
        push @$warnings, { kind => 'form-third-party',
            message => 'a third-party form endpoint routes visitor data OFF this '
                . 'instance, around the operator-vetted handlers (a data-governance '
                . 'leak, not a style choice) - use a :::form + bind_form instead.' };
    }
    # A native :::form that renders but was never bound to a handler does not
    # deliver. It is bound by front matter "form: NAME" + a lazysite/forms/NAME.conf
    # (written by bind_form); warn when the block is present but unbound.
    if ($has_fenced_form) {
        my $fname = $h->{form};
        if ( !defined $fname || !length $fname ) {
            push @$warnings, { kind => 'form-unnamed',
                message => 'a :::form block has no "form: NAME" in the front matter, so '
                    . 'it cannot be bound to a handler and will not deliver - add it, then bind_form.' };
        }
        elsif ( defined $path && length $path ) {
            my $conf = "$LAZYSITE_DIR/forms/$fname.conf";
            push @$warnings, { kind => 'form-unbound',
                message => "the form '$fname' is not bound to a delivery handler yet "
                    . '(it renders but does not deliver) - call bind_form(form, handler).' }
                unless -f $conf;
        }
    }
    return;
}

sub _check_public_data {
    my ( $warnings, $fm, $body ) = @_;
    # Public-data warnings - private/operational details that should not be
    # published accidentally (guest-instruction uploads carry these).
    # SM488: LINE NUMBERS ARE REPORTED AGAINST THE WHOLE PAGE, not the body.
    # The scan runs over $body, which _split_front_matter returns WITHOUT its
    # fences, so a counter starting at zero here named every line short by
    # the front matter plus two. The field agent measured it exactly: reported
    # 15/58/59, actual 24/67/68, delta 9 - seven lines of front matter and two
    # fences. A warning that points at the wrong line is worse than none: the
    # reader opens line 15, finds a canonical link, and concludes the tool is
    # broken - which is nearly right and completely useless.
    my $ln = _fm_line_offset($fm);
    for my $line ( split /\n/, $body ) {
        $ln++;
        push @$warnings, { kind => 'public-credential', line => $ln,
            message => 'possible Wi-Fi / password value - confirm this should be public' }
            if $line =~ /\b(?:wi-?fi|password|passphrase|wpa2?|psk)\b\s*[:=]/i;
        push @$warnings, { kind => 'public-postcode', line => $ln,
            message => 'looks like a UK postcode - confirm the full address should be public' }
            if $line =~ /\b[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}\b/;
        # SM488: AN ISO DATE IS NOT A PHONE NUMBER. /\d[\d\s().-]{8,}\d/ matched
        # 2026-08-22 - ten characters of digits and hyphens - so a page with
        # three dates produced three phone warnings, two of them the filenames
        # of this project's own inbox filings. Dates are stripped from the line
        # before the phone pattern runs; a real number beside a date still
        # fires, because only the date is removed, not the line.
        ( my $undated = $line ) =~ s/\b\d{4}-\d{2}-\d{2}(?:[T ]\d{2}:\d{2}(?::\d{2})?)?\b//g;
        push @$warnings, { kind => 'public-phone', line => $ln,
            message => 'contains a phone number - fine for a contact CTA, not for a private number' }
            if $undated =~ /\+?\d[\d\s().-]{8,}\d/ && $undated =~ /\d{3}/;
    }
    return;
}

sub _validate_page {
    my ( $path, $content, $user ) = @_;
    if ( !defined $content ) {
        return { ok => 0, error => 'path or content required' }
            unless defined $path && length $path;
        $path = _resolve_page_path($path);    # SM347
        my $r = action_read( $path, $user );
        return $r unless ref $r eq 'HASH' && $r->{ok};
        $content = $r->{content};
    }
    my ( @issues, @warnings );

    my ( $fm, $body ) = _split_front_matter($content);
    my $h = _parse_fm($fm);

    _check_front_matter( \@issues, \@warnings, $content, $h );
    _check_fences( \@warnings, $fm, $body );
    push @issues, Lazysite::Manager::Common::page_parse_issues($body);
    _check_db_bindings( \@issues, \@warnings, $fm );
    _check_form_rules( \@issues, $content );
    _check_html_in_page( \@warnings, $body, $h );
    _check_form_delivery( \@warnings, $content, $body, $h, $path );
    _check_public_data( \@warnings, $fm, $body );

    return { ok => 1, valid => ( @issues ? JSON::PP::false : JSON::PP::true ),
        issues => \@issues, warnings => \@warnings };
}

# --- SM238: one presentation key on one configured domain -----------------
# SM238: bind one presentation key on one configured domain. The MCP surface had
# NO domain tools at all beyond site_backup/site_apply, while the control API
# carried the whole domain family under the same manage_domains capability - so an
# agent asked to style a secondary domain could reach only the INSTANCE-WIDE
# activate_theme/activate_layout, which would restyle every other site on the
# instance. It correctly refused to act and reported the gap instead. The safe
# scoped operation was the missing one.
#
# Routes through Domains::domain_set, so it inherits the SM241 asset mirroring
# and cannot touch the site-wide layout:/theme: keys.
sub _domain_presentation_set {
    my ( $host, $key, $value ) = @_;
    my $r = Lazysite::Manager::Domains::domain_set( $host, $key, $value );
    return $r unless ref $r eq 'HASH' && $r->{ok};
    return { %$r, scope => "domain:$host" };
}

# MC-11: the audit was 419 lines in one sub - a page walk, then five passes
# over what it collected, each with its own long rationale comment. The passes
# were already separate in everything but name (one is a bare block), so they
# are named now and the walk hands each what it needs instead of every pass
# reaching into the same nine lexicals. Same passes, same order, same bytes
# out: the ORDER is part of the answer, since a reader works down the report.

sub _audit_collect {
    my ( %exists, %para, @info, @links, @forms, @rawpages, @starter );
    my %class_used;        # SM358: class name -> the first page that uses it
    my %component_used;    # SM358 follow-up: component name -> a page invoking it
    _each_page( sub {
            my ( $rel, $full ) = @_;
            ( my $slug = "/$rel" ) =~ s/\.md$//;
            $exists{$slug} = 1;
            open my $fh, '<:utf8', $full or return;
            local $/; my $c = <$fh>; close $fh;
            my ( $fm, $body ) = _split_front_matter($c);
            my $h = _parse_fm($fm);
            push @info, { slug => $slug, title => ( $h->{title} // '' ) };

            # SM358: which classes this page actually puts on the page, so the
            # reveal check below can name a page rather than a stylesheet. The
            # three ways content carries one: a fenced div, a Markdown attribute
            # block, and raw HTML. First page wins - the finding needs an
            # example, not a census.
            for my $cls ( $body =~ /^:::+\s*([A-Za-z][\w-]*)/mg,
                $body =~ /\{[^}]*\.([A-Za-z][\w-]*)[^}]*\}/g,
                $body =~ /class\s*=\s*["']([^"']+)["']/g )
            {
                $class_used{$_} //= $slug for split /\s+/, $cls;
            }

            # SM358 follow-up: which COMPONENTS this page invokes.
            #
            # The check was reporting a component that APPLIES a hiding class
            # whether or not any page rendered it - so on the field instance it
            # fired with 0 of 26 pages carrying the class, naming a component
            # nothing used. That is the mechanism-versus-use distinction this
            # whole filing is about, reproduced one layer down by the fix for it.
            #
            # A page invokes a component two ways, both visible in the source
            # the walk is already reading: a `::: name` fence matching
            # components/name.tt, and a `sections:` block in front matter (D035
            # phase 3, data-driven pages). No new read, no render, no guessing -
            # which is why this is the audit becoming correct rather than a
            # second warning surface bolted beside it.
            $component_used{$_} //= $slug for $body =~ /^:::+\s*([A-Za-z][\w-]*)/mg;
            if ( $fm =~ /^sections\s*:[ \t]*\n((?:[ \t]+\S[^\n]*\n?|[ \t]*\n)*)/m ) {
                my $block = $1;
                $component_used{$_} //= $slug
                    for $block =~ /^\s*-?\s*(?:component|type)\s*:\s*([A-Za-z][\w-]*)/mg;
            }

            # SM244: starter pages carry `provenance: lazysite-starter` in their
            # front matter and NOTHING has ever read it. On a live fund's domain
            # 28 of 31 sitemap URLs were starter scaffolding, and one of them was
            # publishing demo credentials. Registration is the sharp end: a demo
            # page nobody links to is untidy, a demo page advertised to search
            # engines from a client's domain is a different matter.
            if ( ( $h->{provenance} // '' ) eq 'lazysite-starter' ) {
                my @regs = ref $h->{register} eq 'ARRAY' ? @{ $h->{register} }
                    : ( $h->{register} ? ( $h->{register} ) : () );
                push @starter, { page => $slug, registered => \@regs,
                    message => @regs
                    ? 'starter demo page, still advertised in '
                        . join( ', ', @regs )
                        . ' - remove it or unregister it before this domain is public'
                    : 'starter demo page still published (not registered)' };
            }

            # SM161: forms that ship broken - a hand-authored <form>/<input>
            # (no delivery handler), or a native :::form that was never bound to
            # a handler (renders but does not deliver).
            if ( $body =~ /<form\b/i || $body =~ /<input\b/i ) {
                push @forms, { page => $slug, kind => 'hand-authored',
                    message => 'hand-written form HTML with no handler - use a :::form + bind_form' };
            }
            # SM228: a raw/api page with a script-capable content_type serves as
            # plain text and always will. Surfacing it in the site audit is how an
            # sysop finds the ones written before the write-time refusal, and
            # how they find them all at once rather than a page at a time.
            if ( Lazysite::Manager::Common::raw_html_page_refusal($c) ) {
                push @rawpages, { page => $slug,
                    message => 'raw/api page declares an HTML content type - it is '
                        . 'served as plain text (ADR 0006). Publish it as a static '
                        . '.html file to serve it unchanged, or author it as Markdown.' };
            }
            if ( $c =~ /^:::[ \t]*form\b/m ) {
                my $fname = $h->{form};
                if ( !defined $fname || !length $fname ) {
                    push @forms, { page => $slug, kind => 'unnamed',
                        message => ':::form block with no "form: NAME" - cannot be bound' };
                }
                elsif ( !-f "$LAZYSITE_DIR/forms/$fname.conf" ) {
                    push @forms, { page => $slug, kind => 'unbound', form => $fname,
                        message => "form '$fname' is not bound to a handler - it will not deliver" };
                }
            }
            while ( $body =~ /\]\(([^)\s]+)\)/g )     { push @links, [ $slug, $1 ] }
            while ( $body =~ /href=["']([^"'#?]+)/g ) { push @links, [ $slug, $1 ] }
            for my $p ( split /\n\s*\n/, $body ) {
                $p =~ s/\s+/ /g; $p =~ s/^\s+|\s+$//g;
                push @{ $para{$p} }, $slug if length $p >= 60;
            }
    } );
    return { exists => \%exists, para => \%para, info => \@info,
        links      => \@links,      forms          => \@forms,
        rawpages   => \@rawpages,   starter        => \@starter,
        class_used => \%class_used, component_used => \%component_used };
}

sub _audit_links {
    my ( $exists, $info, $links ) = @_;
    my %inbound;
    my @broken;
    for my $l (@$links) {
        my ( $from, $to ) = @$l;
        next unless $to =~ m{^/};
        next if $to     =~ m{^/(?:cgi-bin|manager|lazysite|img|lazysite-assets)/};
        ( my $t = $to ) =~ s/[#?].*$//; $t =~ s{/$}{};
        next unless length $t;
        if ( $exists->{$t} || -e "$DOCROOT$t" || -f "$DOCROOT$t.md" || -f "$DOCROOT$t.html" ) {
            $inbound{$t}++;
        }
        else { push @broken, { from => $from, to => $to }; last if @broken >= 200 }
    }

    my @orphans = map { $_->{slug} } grep { $_->{slug} ne '/index' && !$inbound{ $_->{slug} } } @$info;
    my @no_title = map { $_->{slug} } grep { !length $_->{title} } @$info;
    return ( \@broken, \@orphans, \@no_title );
}

sub _audit_hidden_by_script {
    my ( $class_used, $component_used ) = @_;
    # SM250: a theme whose CSS hides content by default and reveals it with a
    # script. Content at opacity:0 until JavaScript runs is invisible to a
    # visitor with JS blocked, to most crawlers, and to anything extracting
    # text - so it degrades badly on its own terms, before anyone breaks it.
    #
    # It is worth a MECHANICAL check because the failure is silent, total below
    # the fold, and survives the obvious verification: an agent removed the page
    # script while moving chrome into a layout and left every section of a live
    # site permanently invisible. The hero sat outside the pattern, so four
    # successive visual checks looked fine.
    #
    # Detection is deliberately rough. The pattern is distinctive, and a false
    # positive costs a sysop ten seconds while a false negative costs a live
    # site its content. A rule inside prefers-reduced-motion does NOT count as a
    # fallback - it reaches only visitors who asked for reduced motion, and
    # reading it as a neutraliser is exactly what caused the incident.
    my @hidden_by_script;
    my $ldir = "$LAZYSITE_DIR/layouts";
    my @css;
    if ( opendir my $lh, $ldir ) {
        for my $layout ( grep { !/^\./ } readdir $lh ) {
            my $tdir = "$ldir/$layout/themes";
            next unless -d $tdir;
            opendir my $th, $tdir or next;
            for my $theme ( grep { !/^\./ } readdir $th ) {
                next unless -d "$tdir/$theme";
                for my $f ( glob "$tdir/$theme/*.css $tdir/$theme/assets/*.css" ) {
                    push @css, [ "$layout/$theme", $f, $layout ];
                }
            }
            closedir $th;
        }
        closedir $lh;
    }
    my %layout_markup;    # SM358: a layout's templates, read once
    for my $c (@css) {
        my ( $name, $file, $layout ) = @$c;
        open my $fh, '<:utf8', $file or next;
        my $text = do { local $/; <$fh> };
        close $fh;
        next unless $text =~ m{ (?:opacity \s*:\s* 0 (?![.\d]) | visibility \s*:\s* hidden ) }xi;

        # A non-script path back to visible: anything inside <noscript>'s
        # stylesheet counterpart, or a plain rule restoring it outside a
        # reduced-motion block. Strip reduced-motion blocks first - they are
        # the trap, not the remedy.
        # NB: '#' delimiters, not braces. The pattern needs a literal
        # unmatched '{' in a character class, and s{...}{...} then mis-pairs
        # and swallows the rest of the sub.
        ( my $outside = $text ) =~ s#\@media[^{]*prefers-reduced-motion.*?\}\s*\}##gs;
        my $has_fallback = $outside =~ m{ \.no-js | html:not\(\.js\) | noscript }xi ? 1 : 0;
        next if $has_fallback;

        # SM358: A MECHANISM IS NOT A FINDING. Up to here the check has
        # established that a stylesheet CAN hide content behind a script. It
        # used to report that, which put an item a sysop cannot clear on
        # a list they are expected to clear: the theme is shipped, so editing
        # it is overwritten on upgrade, and on the reporting instance no page
        # used the class at all. "Learn to ignore the audit" was the only
        # available response, and an audit people learn to ignore is worse
        # than no audit.
        #
        # So the finding now requires a USE. Which classes do the hiding, and
        # does anything on this site put one on the page - a layout template,
        # or a page's own content? Both, because the SM250 incident was a
        # LAYOUT emitting the class on every section: checking content alone
        # would have missed the case this check exists for.
        #
        # WHAT DID NOT CHANGE, and the filing asked for it: a rule inside
        # prefers-reduced-motion still does not count as a fallback. The
        # filing proposed crediting it, or reporting it as mitigating. It
        # reaches only visitors who asked for reduced motion, and reading it
        # as a neutraliser is precisely what caused the incident - it is the
        # trap, not the remedy. Narrowing the finding to real uses makes it
        # actionable without weakening the test that exists because a live
        # site lost every section below the fold.
        my %hide_class;
        while ( $outside =~ /([^{}]+)\{([^{}]*)\}/g ) {
            my ( $sel, $decl ) = ( $1, $2 );
            next unless $decl =~ m{ opacity \s*:\s* 0 (?![.\d])
                | visibility \s*:\s* hidden }xi;
            $hide_class{$_} = 1 for $sel =~ /\.([A-Za-z][\w-]*)/g;
        }
        next unless %hide_class;

        # SM358 follow-up: keep each template SEPARATE, so the finding can
        # name the file that applies the class rather than the layout that
        # contains it.
        #
        # The first version concatenated them and reported `layout:lumen`.
        # On the reporting instance that was true and unhelpful: both
        # `reveal` references in layout.tt are JavaScript, four of the six
        # COMPONENTS apply the class in markup, and two are innocent. An
        # operator told "layout:lumen" has six files to read; told
        # "component:features" they have one.
        $layout_markup{$layout} //= do {
            my %by_file;
            for my $tt ( glob "$ldir/$layout/*.tt $ldir/$layout/**/*.tt" ) {
                open my $th, '<:utf8', $tt or next;
                local $/;
                my $body = <$th>;
                close $th;
                ( my $label = $tt ) =~ s{^\Q$ldir/$layout/\E}{};
                $label =~ s{\.tt\z}{};
                $by_file{ $label eq 'layout' ? "layout:$layout" : $label }
                    = $body;
            }
            \%by_file;
        };

        my ( @classes, %seen_use, @used_by );
        for my $cls ( sort keys %hide_class ) {
            my @where;
            for my $file ( sort keys %{ $layout_markup{$layout} } ) {
                next unless $layout_markup{$layout}{$file}
                    =~ /\bclass\s*=\s*["'][^"']*\b\Q$cls\E\b/;

                # A COMPONENT COUNTS ONLY IF A PAGE INVOKES IT. The layout's
                # own template renders on every page and needs no such test;
                # a component nothing renders hides nothing, and reporting
                # it put an item on the findings list that no site owner
                # could ever clear - the components ship inside the layout
                # and an edit is overwritten on reinstall.
                #
                # This is the loaded-gun case answered rather than dropped:
                # the finding now appears the moment a page starts using the
                # component, which is the moment a sysop can act on it.
                if ( my ($comp) = $file =~ m{\Acomponents/([A-Za-z][\w-]*)\z} ) {
                    next unless defined $component_used->{$comp};
                    push @where, "$layout/$file (used by $component_used->{$comp})";
                    next;
                }
                push @where, ( $file =~ /^layout:/ ? $file : "$layout/$file" );
            }
            push @where, $class_used->{$cls} if defined $class_used->{$cls};
            next unless @where;
            push @classes, $cls;
            push @used_by, grep { !$seen_use{$_}++ } @where;
        }

        # Nothing on this site puts the class on a page, so nothing is
        # hidden. Reporting it anyway is what made the finding unclearable.
        next unless @classes;

        ( my $rel = $file ) =~ s{^\Q$DOCROOT\E/+}{/};
        push @hidden_by_script, {
            theme   => $name,
            file    => $rel,
            classes => \@classes,
            used_by => [ @used_by[ 0 .. ( $#used_by > 4 ? 4 : $#used_by ) ] ],
        };
        last if @hidden_by_script >= 50;
    }
    return \@hidden_by_script;
}

sub _audit_static_exposure {
    # Stale generated HTML: a rendered .html with no .md source.
    #
    # SM260: this was `my ( @stale, @stack ) = ( (), $DOCROOT );`, which does not
    # do what it reads like. The FIRST array in a list assignment slurps every
    # remaining value, so @stale started as ($DOCROOT) and @stack empty - the
    # scan below never ran even once, and the docroot the walk was supposed to
    # START from was reported to the caller as a finding. Two defects in one
    # line: an audit that has never worked, and the server's absolute filesystem
    # path (including the hosting account name) handed to every token and MCP
    # partner. Declared separately so the shape cannot mislead again.
    my @stale;
    my @stack = ($DOCROOT);

    # SM223: a site whose auth_default is protective still serves STATIC files to
    # anyone who knows the path. A file with no .md source is never evaluated
    # against auth_default - on Apache the [L] rewrite means the processor never
    # runs at all, and on the engine's own path check_auth sits inside a
    # source-file test - so a sysop can set auth_default: required, watch
    # every page bounce to the login form, reasonably conclude the site is
    # closed, and be publishing private assets to the open internet. Nothing in
    # the manager, the config or the logs contradicts them.
    #
    # Closing that gap is a behavioural change on upgrade and carries four open
    # decisions (SM223). The DETECTOR does not: it needs no reload, breaks
    # nothing, and is what tells a sysop their configuration and their
    # content disagree. Detect before enforce.
    my $auth_default = '';
    for my $l ( split /\n/, _read_conf_text() ) {
        if ( $l =~ /^auth_default\s*:\s*(\S+)/ ) { $auth_default = lc $1; last }
    }
    my $site_protected = ( $auth_default eq 'required' || $auth_default eq 'optional' ) ? 1 : 0;

    # Anything the web server will hand to an anonymous visitor. Deliberately
    # broad: the reported case was single-file browser applications and the
    # private material they produce, which are .html, but a PDF or an image
    # inside a private brief is the same exposure.
    my $SERVABLE = qr/\.(?:html?|pdf|docx?|xlsx?|pptx?|csv|txt|json|js|css|
        png|jpe?g|gif|webp|svg|avif|mp4|webm|mp3|zip)$/xi;

    my @unprotected;
    while (@stack) {
        my $dir = pop @stack;
        opendir my $dh, $dir or next;
        for my $e ( readdir $dh ) {
            next if $e =~ /^\./;
            my $full = "$dir/$e";
            if ( -d $full ) { push @stack, $full unless $e =~ /^(?:lazysite|lazysite-assets)$/; next }

            ( my $rel = $full ) =~ s{^\Q$DOCROOT\E/+}{/};

            if ( $e =~ /\.html$/ ) {
                ( my $src = $full ) =~ s/\.html$/.md/;
                unless ( -f $src ) { push @stale, $rel if @stale < 200 }
            }

            # A source-less servable file on a protected site. One WITH a .md
            # source is a rendered page and is gated normally, so it is not a
            # finding.
            next unless $site_protected && @unprotected < 200;
            next unless $e =~ $SERVABLE;
            ( my $md = $full ) =~ s/\.[^.]+$/.md/;
            push @unprotected, $rel unless -f $md;
        }
        closedir $dh;
    }
    return ( \@stale, \@unprotected, $auth_default );
}

sub _audit_acl_keys {
    # SM268 01-M3: an ACL key that matches nothing on disk.
    #
    # ACL keys are DOCROOT-relative; a content-rooted domain's URLs are relative
    # to its content_root. So on such a domain the intuitive key - the URL
    # segment, which is exactly what SM181's example rule uses - is inert, and
    # inert looks identical to protected until somebody tries the URL. The
    # manager and MCP write docroot-relative keys and are consistent; the
    # exposure is confined to the hand-written folder rules SM181 asks for.
    #
    # A key matching no existing path is the classic symptom, and it is cheap to
    # check. Where a content root would make it match, say so - that is the
    # actual repair, and a sysop who has just read "protects nothing" needs
    # to be told what to write instead.
    my @acl_unmatched;
    if ( open my $afh, '<:raw', "$LAZYSITE_DIR/auth/acls.json" ) {
        my $raw = do { local $/; <$afh> };
        close $afh;
        my $map = eval { JSON::PP::decode_json( $raw // '{}' ) };
        if ( ref $map eq 'HASH' ) {
            my @croots;
            for my $l ( split /\n/, _read_conf_text() ) {
                next unless $l =~ /^alias\.\S+\.content_root\s*:\s*(\S+)/;
                my $c = $1;
                $c =~ s{^/+|/+$}{}g;
                push @croots, $c if length $c;
            }
            for my $k ( sort keys %$map ) {
                ( my $rel = $k ) =~ s{^/+|/+$}{}g;
                next unless length $rel;
                next if -e "$DOCROOT/$rel";
                my @would = grep { -e "$DOCROOT/$_/$rel" } @croots;
                push @acl_unmatched, {
                    key     => $k,
                    message => @would
                    ? "matches nothing at the docroot, so it protects nothing. On "
                        . "a content-rooted domain the key must include the content "
                        . "root: try '$would[0]/$rel'."
                    : 'matches no file or folder in this site, so it protects '
                        . 'nothing. ACL keys are relative to the docroot, not to a '
                        . "domain's URLs.",
                };
                last if @acl_unmatched >= 50;
            }
        }
    }
    return \@acl_unmatched;
}

sub _audit_duplicates {
    my ($para) = @_;
    my @dups;
    for my $p ( sort keys %$para ) {
        my %u = map { $_ => 1 } @{ $para->{$p} };
        next unless keys %u > 1;
        push @dups, { text => substr( $p, 0, 120 ), pages => [ sort keys %u ] };
        last if @dups >= 50;
    }
    return \@dups;
}

sub _audit_site {
    my $c = _audit_collect();
    my ( $broken, $orphans, $no_title )
        = _audit_links( $c->{exists}, $c->{info}, $c->{links} );
    my $hidden = _audit_hidden_by_script( $c->{class_used}, $c->{component_used} );
    my ( $stale, $unprotected, $auth_default ) = _audit_static_exposure();
    my $acl_unmatched = _audit_acl_keys();
    my $dups          = _audit_duplicates( $c->{para} );

    return { ok => 1, pages => scalar @{ $c->{info} },
        broken_links  => $broken,     orphan_pages   => $orphans,
        missing_title => $no_title,   stale_html     => $stale, duplicate_blocks => $dups,
        broken_forms  => $c->{forms}, raw_html_pages => $c->{rawpages},
        starter_pages => $c->{starter},
        # The ratio is what makes the problem obvious - no single page does.
        starter_in_sitemap => scalar( grep { grep { $_ eq 'sitemap.xml' } @{ $_->{registered} } } @{ $c->{starter} } ),

        # SM223: static files a protected site is serving to anyone. Reported
        # only when auth_default is protective, because on an open site these are
        # simply the site's assets and listing them would be noise - and a
        # finding that fires on every site trains its reader to ignore it.
        # SM250: themes whose content is invisible until a script runs.
        hidden_by_script         => $hidden,
        site_auth_default        => $auth_default,
        unprotected_static_files => $unprotected,

        # SM268 01-M3: ACL keys that match nothing, which is what a URL-shaped
        # key looks like on a content-rooted domain.
        acl_keys_matching_nothing => $acl_unmatched,
    };
}


# --- SM088: bind a form to a sysop-vetted delivery handler ------------
# Handlers (with their destinations + credentials) live in handlers.conf and
# are sysop-only. The connector may only REFERENCE an existing handler by id;
# it never sees or sets a destination or secret.
sub _list_form_handlers {
    my $f = "$LAZYSITE_DIR/forms/handlers.conf";
    return { ok => 1, handlers => [] } unless -f $f;
    open my $fh, '<:utf8', $f or return { ok => 0, error => 'cannot read handlers.conf' };
    local $/; my $c = <$fh>; close $fh;
    my @h;
    while ( $c =~ /^[ \t]*-[ \t]+id:[ \t]*(\S+)(.*?)(?=^[ \t]*-[ \t]+id:|\z)/gms ) {
        my ( $id, $block ) = ( $1, $2 );
        my %x = ( id => $id, type => 'unknown' );
        $x{type}    = $1 if $block =~ /^[ \t]*type:[ \t]*(\S+)/m;
        $x{name}    = $1 if $block =~ /^[ \t]*name:[ \t]*(.+?)[ \t]*$/m;
        $x{enabled} = ( $block =~ /^[ \t]*enabled:[ \t]*(?:true|yes|1)[ \t]*$/mi )
            ? JSON::PP::true : JSON::PP::false;
        push @h, \%x;
    }
    return { ok => 1, handlers => \@h };
}

# SM421: THE SURFACES AGREE, because the capability is the control.
#
# manage_forms could already write an inline delivery target over WebDAV (a raw
# lazysite/forms/<name>.conf) and through the control API's form-targets-save,
# which explicitly preserves and accepts inline targets. Only bind_form was
# handler-only - so the SAME capability was strictly weaker on one surface, and
# an agent delegated form-building through MCP had to ask an operator for
# something the same grant could do elsewhere.
#
# The release manager's ruling: permission decides whether this is available;
# where it is granted, the surface delivers it in full. So the fix is to add
# the ability here rather than remove it there.
#
# A handler stays PREFERRED and the description says so - it is sysop-vetted
# and holds credentials. An inline target carries no credential (the legacy
# parser reads only type/url/format/path), so this cannot exfiltrate an SMTP
# password; what it can do is name a destination, which is exactly what
# manage_forms means.
sub _bind_form {
    my ( $form, $handler, $target ) = @_;
    $form    = '' unless defined $form;
    $handler = '' unless defined $handler;
    return { ok => 0, error => 'form is required' } unless length $form;
    return { ok => 0, error => "invalid name '$form'", kind => 'invalid-path' }
        unless $form =~ /\A[A-Za-z0-9_-]+\z/;

    return { ok => 0, error => 'give either handler or target, not both' }
        if length $handler && ref $target eq 'HASH';

    if ( ref $target eq 'HASH' ) {
        my $t = _inline_target_block($target);
        return $t unless ref $t eq 'HASH' && $t->{ok};
        return _write_form_conf( $form, $t->{block},
            { form => $form, target => $target->{type} } );
    }

    return { ok => 0, error => 'form and handler are required' }
        unless length $handler;
    return { ok => 0, error => "invalid name '$handler'", kind => 'invalid-path' }
        unless $handler =~ /\A[A-Za-z0-9_-]+\z/;
    my $hl = _list_form_handlers();
    return $hl unless $hl->{ok};
    unless ( grep { $_->{id} eq $handler } @{ $hl->{handlers} } ) {
        return { ok => 0, kind => 'not-found',
            error => "no handler '$handler' - call list_form_handlers to see the configured ones" };
    }
    return _write_form_conf( $form, "  - handler: $handler\n",
        { form => $form, handler => $handler } );
}

# Validate an inline target and render its config block. Returns {ok=>1,block}
# or an error hash. Deliberately strict about the SHAPE while saying nothing
# about the destination: which URL a form may deliver to is the sysop's
# decision, expressed by whether they granted manage_forms.
sub _inline_target_block {
    my ($t) = @_;
    my $type = lc( $t->{type} // '' );

    # smtp is absent on purpose: it needs a credential, and the legacy inline
    # parser reads only type/url/format/path - so an inline smtp target would
    # be a target that silently cannot deliver. Credentials live in
    # operator-defined handlers, which is what list_form_handlers offers.
    return { ok => 0, kind => 'invalid',
        error => "target.type must be webhook, api or file (got '$type')" }
        unless $type =~ /\A(?:webhook|api|file)\z/;

    my %out = ( type => $type );
    if ( $type eq 'file' ) {
        my $path = $t->{path} // '';
        $path =~ s{^/+|/+$}{}g;
        return { ok => 0, kind => 'invalid',
            error => 'target.path is required for a file target' }
            unless length $path;
        # Same confinement the rest of the file surface applies: relative, no
        # traversal. A store outside the docroot is not a store.
        return { ok => 0, kind => 'invalid-path',
            error => "invalid target.path '$path'" }
            if $path =~ m{(?:\A|/)\.\.(?:/|\z)} || $path =~ m{\A~};
        $out{path} = $path;
    }
    else {
        my $url = $t->{url} // '';
        return { ok => 0, kind => 'invalid',
            error => 'target.url is required for a webhook/api target' }
            unless length $url;
        return { ok => 0, kind => 'invalid',
            error => 'target.url must be an http(s) URL' }
            unless $url =~ m{\Ahttps?://\S+\z};
        return { ok => 0, kind => 'invalid',
            error => 'target.url must not contain a newline' }
            if $url =~ /[\r\n]/;
        $out{url} = $url;
    }
    if ( defined $t->{format} && length $t->{format} ) {
        return { ok => 0, kind => 'invalid', error => 'invalid target.format' }
            unless $t->{format} =~ /\A[A-Za-z0-9_-]+\z/;
        $out{format} = $t->{format};
    }

    my $block = "  - type: $out{type}\n";
    for my $k (qw(url path format)) {
        $block .= "    $k: $out{$k}\n" if defined $out{$k};
    }
    return { ok => 1, block => $block };
}

# One writer for both shapes. Atomic: temp + rename, so a racing binder of the
# same form never leaves a partial/empty .conf and a reader always sees a
# complete binding.
sub _write_form_conf {
    my ( $form, $targets_block, $result ) = @_;
    my $dir = "$LAZYSITE_DIR/forms";
    return { ok => 0, error => 'forms directory is missing' } unless -d $dir;
    my $conf = "$dir/$form.conf";
    my $tmp  = "$conf.tmp.$$";
    open my $fh, '>', $tmp
        or return { ok => 0, error => "cannot write the form config: $!" };
    my $wrote = print {$fh} "targets:\n$targets_block";
    unless ( close($fh) && $wrote ) {
        unlink $tmp;
        return { ok => 0, error => "cannot write the form config: $!" };
    }
    unless ( rename $tmp, $conf ) {
        unlink $tmp;
        return { ok => 0, error => "cannot write the form config: $!" };
    }
    return { ok => 1, %$result, path => "/lazysite/forms/$form.conf" };
}

# --- SM102: agent/connector feedback ------------------------------------------
# The agent supplies the content (summary/good/bad/rating/context); the server
# stamps the identity + context (user, method, ip, site, version, capabilities) so
# the report's provenance is trustworthy. Saved under lazysite/feedback/ (internal,
# never web-served like the rest of lazysite/).
sub _submit_feedback {
    my ( $a, $user, $caps ) = @_;
    ( my $summary = defined $a->{summary} ? $a->{summary} : '' ) =~ s/\A\s+|\s+\z//g;
    return { ok => 0, kind => 'invalid', error => 'summary is required' }
        unless length $summary;

    my $dir = "$LAZYSITE_DIR/feedback";
    unless ( -d $dir ) {
        mkdir $dir or return { ok => 0, error => "cannot create feedback dir: $!" };
    }

    my @t   = gmtime;
    my $iso = sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
    my $stamp = sprintf '%04d%02d%02d-%02d%02d%02d',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
    ( my $safe = defined $user ? $user : 'anon' ) =~ s/[^A-Za-z0-9_.-]/_/g;
    my $id = "$stamp-$safe";

    # SM516 MC-16: this roster was written by hand and then left behind -
    # manage_domains, manage_data, read_submissions, feedback, mcp, audit,
    # notifications and manage_users all arrived after it, so a report from a
    # partner holding them under-stated what that partner could do. Ask the one
    # source of truth (Auth::Settings::@CAP_KEYS, via Capabilities) instead.
    my @caplist = sort grep { $caps->{$_} } Lazysite::Capabilities::capability_keys();

    my $report = {
        ts           => $iso,
        user         => $user,
        method       => ( $AUTH_INFO{method} // 'mcp' ),
        ip           => ( $ENV{REMOTE_ADDR}  // '' ),
        site         => ( $ENV{HTTP_HOST}    // '' ),
        version      => $VERSION,
        capabilities => \@caplist,
        rating       => ( defined $a->{rating} ? $a->{rating} + 0 : undef ),
        summary      => $summary,
        good         => ( defined $a->{good}    ? $a->{good}    : '' ),
        bad          => ( defined $a->{bad}     ? $a->{bad}     : '' ),
        context      => ( defined $a->{context} ? $a->{context} : '' ),
    };

    open my $fh, '>', "$dir/$id.json"
        or return { ok => 0, error => "cannot save feedback: $!" };
    print {$fh} encode_json($report);
    close $fh;

    # SM136: feedback is written to be read - tell the sysops (bell + XMPP).
    eval {
        require Lazysite::Notify;
        my $short = length($summary) > 120 ? substr( $summary, 0, 117 ) . '...' : $summary;
        Lazysite::Notify::notify( $DOCROOT, {
                type    => 'feedback',
                message => "Agent feedback from '" . ( $user // 'anon' ) . "': $short",
                target  => $id,
        } );
        1;
    } or log_event( 'WARN', 'feedback', 'notify failed', error => "$@" );

    return { ok => 1, id => $id, message => 'Thanks - your feedback was logged for the operators.' };
}

# --- SM087: page-aware verbs (create / delete / rename) -------------------
sub _yaml_scalar {
    my ($v) = @_;
    $v = '' unless defined $v;
    return ( $v =~ /[:#\[\]"']/ || $v =~ /\A["'\s]/ )
        ? '"' . ( $v =~ s/"/\\"/gr ) . '"' : $v;
}

# MC-8: upload_file, site_apply and create_form each carried thirty to forty
# lines of body inside the tool table, where every other entry of comparable
# weight is a one-line call to a named sub. The table is read as a CATALOGUE -
# by agents through tools/list, and by five lint tests that parse its shape -
# and three long bodies in the middle of it made the catalogue hard to read
# and the handlers hard to find. The code is unchanged; only where it lives is.

sub _upload_file {
    my ( $a, $user ) = @_;
    my $b64 = $a->{content_base64} // '';
    ( my $clean = $b64 ) =~ s/\s+//g;
    # Reject what does not decode rather than writing a corrupt file:
    # decode_base64 silently ignores characters outside the alphabet, so
    # a truncated or mangled payload would otherwise land on disk looking
    # like a successful upload.
    return { ok => 0, kind => 'bad-encoding',
        error => 'content_base64 is not valid base64 - expected only '
            . 'A-Z a-z 0-9 + / and = padding.' }
        if $clean =~ m{[^A-Za-z0-9+/=]} || $clean =~ m{=[^=]};
    return { ok => 0, kind => 'bad-encoding',
        error => 'content_base64 length is not a multiple of 4 - the '
            . 'payload looks truncated.' }
        if length($clean) % 4;
    require MIME::Base64;
    my $bytes = MIME::Base64::decode_base64($clean);
    return { ok => 0, kind => 'bad-encoding',
        error => 'content_base64 decoded to nothing.' }
        unless length $bytes;
    return action_save_binary( $a->{path}, $user, $bytes );
}

sub _site_apply {
    my ( $a, $user, $caps ) = @_;
    my $name = $a->{name} // '';
    return { ok => 0, error => 'A package name is required' }
        unless $name =~ /\Alazysite-site-[A-Za-z0-9._-]+\.tar\.gz\z/ && $name !~ /\.\./;
    my $pkg = "$LAZYSITE_DIR/backups/$name";
    return { ok => 0, error => "Package not found: $name" } unless -f $pkg;

    my $host = lc( $a->{host} // '' );
    $host = '' if $host eq '(default)';

    # Resolve the target content root + enforce the scope union.
    my $croot = '';
    if ( length $host ) {
        my $row = _domain_row($host);
        return { ok => 0, error => "Not a configured domain: $host" } unless $row;
        $croot = $row->{content_root} // '';
        return { ok => 0, error => "$host has no content folder of its own" }
            unless length $croot;
    }
    if ( _croot_outside_scope( $caps, $croot ) ) {
        return { ok => 0, error => 'Target is outside your assigned scope.' };
    }
    local $Lazysite::Manager::SitePackage::auth_user = $user;
    return apply_and_configure( $pkg,
        host           => $host,
        clean          => ( $a->{clean}          ? 1 : 0 ),
        adopt_identity => ( $a->{adopt_identity} ? 1 : 0 ) );
}

sub _create_form {
    my ( $a, $user ) = @_;
    my $name = lc( $a->{name} // '' );
    return { ok => 0, error => 'A form name (a-z0-9_-) is required' }
        unless $name =~ /\A[a-z0-9][a-z0-9_-]*\z/;
    return { ok => 0, error => 'A page path is required' }
        unless defined $a->{path} && length $a->{path};

    my @fields = ( ref $a->{fields} eq 'ARRAY' && @{ $a->{fields} } )
        ? @{ $a->{fields} }
        : ( 'name | Your name | required max:200',
        'email | Email | required email',
        'message | Message | required textarea' );
    my $submit = $a->{submit} // 'Send';
    my $block  = ":::form\n" . join( "\n", @fields ) . "\nsubmit | $submit\n:::\n";

    # Read the page if it exists; ensure front matter carries form: NAME,
    # then append the block. A page with a different form already bound is
    # left alone (do not silently rebind).
    my $rd      = action_read( $a->{path}, $user );
    my $content = ( ref $rd eq 'HASH' && $rd->{ok} ) ? ( $rd->{content} // '' ) : '';
    if ( length $content && $content =~ /\A---\s*\n(.*?)\n---\s*\n/s ) {
        my $fm = $1;
        if ( $fm =~ /^\s*form\s*:\s*(\S+)/m && lc($1) ne $name ) {
            return { ok => 0, error => "Page already has a different form ('$1'); "
                    . 'edit it directly or pick that name.' };
        }
        $content =~ s/\A(---\s*\n)/$1form: $name\n/ unless $fm =~ /^\s*form\s*:/m;
        $content =~ s/\s*\z/\n/;
        $content .= "\n$block";
    }
    else {
        # No usable front matter - create a fresh page.
        my $title = ucfirst($name) =~ s/[-_]+/ /gr;
        $content = "---\ntitle: $title\nform: $name\n---\n\n$block";
    }

    # SM655: RESOLVE THE PATH, as _create_page does three subs below.
    #
    # This saved $a->{path} verbatim, so the idiomatic call - an extensionless
    # page path, which is what every other tool on this surface takes and what
    # this tool's own schema describes ("Page to add the form to") - wrote a
    # file with NO extension. The site then 404s it, and nothing else says so:
    # ok:true, page_status exists:true and read_file returning valid page source
    # all report success. Only fetching the URL reveals it.
    #
    # The irony is exact: this tool exists so agents stop hand-writing <form>
    # HTML, because that "has no delivery handler and ships dead". Called the
    # way the surface teaches, the sanctioned tool shipped dead too.
    my $slug = _norm_slug( $a->{path}, dots => 1, md => 1, trail => 1 );
    return { ok => 0, error => 'a page path is required' } unless length $slug;
    my $save = action_save( "/$slug.md", $user, $content, undef );
    return $save unless ref $save eq 'HASH' && $save->{ok};
    return {
        ok => 1,
        # SM655: the path it actually wrote, not the one it was handed. A caller
        # that echoes this back - or fetches it - should get the page that
        # exists, and the two differed whenever the caller used the idiom.
        path     => "/$slug",
        form     => $name,
        delivers => JSON::PP::false,
        next     => "Form scaffolded but NOT delivering yet. Call list_form_handlers, "
            . "then bind_form(form: '$name', handler: <id>) to wire delivery.",
    };
}

sub _create_page {
    my ( $a, $user ) = @_;
    my $slug = $a->{slug} // '';
    $slug = _norm_slug( $slug, dots => 1, md => 1, trail => 1 );
    return { ok => 0, error => 'slug required' } unless length $slug;
    return { ok => 0, kind => 'exists', error => "page already exists: /$slug (use write_file to overwrite)" }
        if -e "$DOCROOT/$slug.md";
    my $fm = "---\n";
    $fm .= 'title: ' . _yaml_scalar( $a->{title} ) . "\n" if defined $a->{title} && length $a->{title};
    $fm .= 'subtitle: ' . _yaml_scalar( $a->{subtitle} ) . "\n" if defined $a->{subtitle} && length $a->{subtitle};
    # SM483: BLOCK style, because that is what the reader has always parsed -
    # the flow form this emitted made every page created here invisible to
    # every registry. And names are NORMALISED against the registries that
    # exist: the schema's old example said "sitemap" while the reader matches
    # template output names ("sitemap.xml"), so a stem is resolved to its
    # template's output name and an unknown name is kept as given.
    if ( ref $a->{register} eq 'ARRAY' && @{ $a->{register} } ) {
        my %out;
        if ( opendir my $rdh, "$LAZYSITE_DIR/templates/registries" ) {
            for my $t ( readdir $rdh ) {
                next unless $t =~ /^(.+)\.tt$/;
                my $o = $1;
                $out{$o} = $o;
                ( my $stem = $o ) =~ s/\.[^.]+$//;
                $out{$stem} //= $o;
            }
            closedir $rdh;
        }
        my @names = map { $out{$_} // $_ } @{ $a->{register} };
        $fm .= "register:\n" . join( '', map { "  - $_\n" } @names );
    }
    $fm .= "---\n";
    my $body = defined $a->{body} ? $a->{body} : '';
    $body .= "\n" unless $body eq '' || $body =~ /\n\z/;
    if ( my $refusal = _page_parse_refusal( "/$slug.md", $fm . $body ) ) {
        return $refusal;
    }
    return action_save( "/$slug.md", $user, $fm . $body, undef );
}

sub _delete_page {
    my ( $a, $user ) = @_;

    # SM513: `slug` as before, or `path` in read_page's spelling - two page
    # tools with two identifiers was a mistake every agent made once.
    my $slug = $a->{slug} // $a->{path} // '';
    $slug = _norm_slug( $slug, dots => 1, md => 1 );
    return { ok => 0, error => 'slug or path required - the page to delete, '
            . 'as a slug (about) or a path (/about.md)' }
        unless length $slug;
    my $r = action_delete( "/$slug.md", $user );
    return $r unless ref $r eq 'HASH' && $r->{ok};
    # Report remaining references (nav, other pages).
    # MCO-4: without a limit this takes _mcp_search's DEFAULT of 200, so on a
    # site with more references than that `still_referenced_in` was silently
    # short - and the one thing the caller uses it for is deciding whether
    # deleting this page breaks anything. Ask for the ceiling the search will
    # enforce anyway.
    my $s = _mcp_search( "/$slug", '/', $SEARCH_LIMIT_MAX );
    my %seen;
    $r->{still_referenced_in} = [ grep { !$seen{$_}++ } map { $_->{path} } @{ $s->{matches} || [] } ];

    # SM264: say that the registries lag, rather than leaving the caller to infer
    # it. The page 404s at once and the generated registries are cleared, but the
    # rebuild happens on the next request for one - so an agent that deletes and
    # immediately checks the sitemap sees the old URL and reasonably concludes
    # the delete failed. On one live site that led to hand-editing a generated
    # registry. A bare ok is what made that a reasonable conclusion.
    $r->{registries} = 'cleared; they rebuild on the next request for one. '
        . 'The sitemap may still show this URL until then - call '
        . 'regenerate_registries and fetch a registry if you need to verify now.';
    return $r;
}

sub _rewrite_links {
    my ( $old, $new, $user ) = @_;
    my $changed = 0;
    _each_page( sub {
            my ( $rel, $full ) = @_;
            open my $fh, '<:utf8', $full or return;
            local $/; my $c = <$fh>; close $fh;
            my $orig = $c;
            $c =~ s{(/)\Q$old\E(?=[\s)"'#?\]]|\z)}{$1$new}g;
            $c =~ s{\b\Q$old\E\.md\b}{$new.md}g;
            if ( $c ne $orig ) {
                my $sr = action_save( "/$rel", $user, $c, undef );
                $changed++ if ref $sr eq 'HASH' && $sr->{ok};
            }
    } );
    return $changed;
}

sub _rename_page {
    my ( $a,   $user ) = @_;
    my ( $old, $new )  = ( $a->{old} // '', $a->{new} // '' );
    for my $s ( \$old, \$new ) { $$s = _norm_slug( $$s, dots => 1, md => 1, trail => 1 ) }
    return { ok => 0, error => 'old and new required' } unless length $old && length $new;
    my $r = action_move( "/$old.md", "/$new.md", $user );
    return $r unless ref $r eq 'HASH' && $r->{ok};
    $r->{links_updated} = _rewrite_links( $old, $new, $user ) if $a->{update_links};

    # SM243: a rename retires a URL. Every old URL is supposed to get an
    # `aliases:` entry on its successor, and today that rule is enforced by a
    # person remembering it - twenty legacy URLs were recovered by hand on one
    # site after a conversion dropped them.
    #
    # Reported by DEFAULT and written only on request. Adding the alias means
    # editing the successor page's front matter, which is a write with its own
    # failure modes; doing it silently on every rename would surprise anyone who
    # moved a page they had never published. So the result always says what the
    # alias should be, and add_alias => 1 makes it so.
    my $alias = "/$old";
    $r->{alias_suggested} = $alias;
    if ( $a->{add_alias} ) {
        my $rd = action_read( "/$new.md", $user );
        if ( ref $rd ne 'HASH' || !$rd->{ok} ) {
            # SM256: this used to fall out of the `if` silently, leaving
            # alias_added unset - indistinguishable from never having asked.
            $r->{alias_added} = JSON::PP::false;
            $r->{alias_error} = 'could not read the renamed page to add the alias'
                . ( ref $rd eq 'HASH' && $rd->{error} ? ": $rd->{error}" : '' );
        }
        else {
            my $c = $rd->{content} // '';
            my ($fm) = $c =~ m{\A---\s*\n(.*?)\n---\s*\n}s;

            if ( defined $fm && index( $fm, $alias ) >= 0 ) {
                # Already listed. That is the DESIRED end state, not a failure -
                # a second rename back and forth must not report a problem.
                $r->{alias_added}   = JSON::PP::false;
                $r->{alias_present} = JSON::PP::true;
            }
            else {
                if ( !defined $fm ) {
                    # SM256: front matter is OPTIONAL in lazysite, and a page
                    # without it is ordinary - if anything it is more likely to
                    # be an old hand-written page whose URL has been published
                    # for years, which is exactly when the alias matters most.
                    # This branch used to do nothing at all and still report
                    # ok:1 with alias_suggested set, which reads as "added".
                    $c = "---\naliases:\n  - $alias\n---\n" . $c;
                }
                elsif ( $fm =~ /^aliases\s*:/m ) {
                    $c =~ s/^(aliases\s*:[^\n]*\n)/$1  - $alias\n/m;
                }
                else {
                    $c =~ s/\A(---\s*\n)/$1aliases:\n  - $alias\n/;
                }

                my $w = action_save( "/$new.md", $user, $c, undef );
                $r->{alias_added} =
                    ( ref $w eq 'HASH' && $w->{ok} ) ? JSON::PP::true : JSON::PP::false;
                $r->{alias_error} = $w->{error}
                    if ref $w eq 'HASH' && !$w->{ok} && $w->{error};
            }
        }
    }
    return $r;
}

# MCO-1: two constant rosters the dispatch reads and never writes - which tools
# are reads (so the audit skips them) and which refusal kinds are worth retrying.
# Both were built inside the request path, one of them inside an `if` that runs
# only on a failure, so a literal that cannot change was assembled per request
# and per refusal. They live with %ANNOTATE now: same three lists, one place a
# reader looks to find out what the dispatch believes about a tool.
my %READ = ( whoami => 1, list_files => 1, read_file => 1, search_files => 1,
    page_status => 1, list_pages => 1, read_page => 1, validate_page => 1, audit_site => 1, list_form_handlers => 1, form_list => 1, get_permissions => 1, preview_page => 1, read_nav => 1, list_themes => 1, theme_tokens => 1, analyse_visitors => 1,
    list_versions => 1, list_content_history => 1, view_version => 1 ); # history reads: audit-skipped like the API's git-history/show

my %TRANSIENT = ( 'lock-held' => 1, 'locked' => 1, 'rate-limited' => 1, 'busy' => 1 );

# MCP tool annotation hints [readOnly, destructive, openWorld, changesAccess].
# The first three are the MCP spec's own hints, required by ChatGPT (they drive
# its per-call approval + read/write gating) and good practice for every client.
# openWorld = the action publishes to / changes the live site.
# SM537: EVERY tool is named here - t/lint/85 refuses one that is not. The
# default in tool_list is a safety net for the dispatcher, never a value an
# entry may rely on: a read that falls to it advertises as an open-world write,
# and a drop advertises as non-destructive.
#
# SM587: the FOURTH slot is lazysite's own axis, published as
# `changesAccessHint` beside the three. HOW EITHER FLAG IS ASSIGNED is written
# once, beside %MUTATING / %DESTRUCTIVE / %CHANGES_ACCESS in
# lazysite-manager-api.pl - read it there rather than inferring a rule from the
# rows below. In one line: `destructive` asks whether a copy survives, and
# `changesAccess` asks whether the call alters who may read. t/lint/23 keeps
# both this table's second slot and its fourth equal to the API's twins, so the
# two spellings of each fact cannot drift.
# The fourth slot may be omitted - an absent value is 0, as it is for a tool
# that moves no read boundary, which is nearly all of them.
my %ANNOTATE = (
    # SM632: destroys a registration; the twin form-delete is in %DESTRUCTIVE.
    # Not idempotent in the third slot's sense - a second call finds nothing to
    # remove and says so, which is a different answer, not the same one again.
    delete_form            => [ 0, 1, 0 ],
    whoami                 => [ 1, 0, 0 ],
    describe_capabilities  => [ 1, 0, 0 ],
    upload_file            => [ 0, 0, 1 ],
    list_data_tables       => [ 1, 0, 0 ],
    describe_data_table    => [ 1, 0, 0 ],
    read_data_table_source => [ 1, 0, 0 ],
    plan_data_migration    => [ 1, 0, 0 ],
    read_data_rows         => [ 1, 0, 0 ],
    save_data_table => [ 0, 0, 1 ], # a descriptor's public flag decides what the site serves
    migrate_data_table => [ 0, 0, 1 ],    # applies the safe changes to the live table
    rebuild_data_table => [ 0, 1, 1 ],    # drops columns, by named confirmation
    drop_data_table    => [ 0, 1, 1 ],
    save_data_row      => [ 0, 0, 1 ],
    delete_data_row    => [ 0, 1, 1 ],
    list_domains       => [ 1, 0, 0 ],
    # SM647: the fourth slot. domain_set writes allowed_groups - the domain
    # access model - so it moves the read boundary as surely as set_permissions
    # does, and the twin table on the control API says so now too.
    domain_set            => [ 0, 0, 1, 1 ],
    preview_public_page   => [ 1, 0, 0 ],
    preview_domain        => [ 1, 0, 0 ],
    site_backup           => [ 0, 0, 0 ],  # writes an archive; changes nothing live
    site_apply            => [ 0, 1, 1 ],  # overwrites the live content tree
    delete_theme          => [ 0, 1, 1 ],
    read_form_submissions => [ 1, 0, 0 ],
    create_form           => [ 0, 0, 1 ],
    analyse_visitors      => [ 1, 0, 0 ],
    regenerate_registries => [ 0, 0, 1 ],
    read_brief            => [ 1, 0, 0 ],
    append_brief          => [ 0, 0, 0 ],  # writes the engine store, changes nothing live
    list_briefs           => [ 1, 0, 0 ],
    list_data_safety_exports   => [ 1, 0, 0 ],
    delete_data_safety_export  => [ 0, 1, 0 ],   # destroys the only copy of dropped rows
    read_data_safety_export    => [ 1, 0, 0 ],
    restore_data_safety_export => [ 0, 0, 1 ],   # writes rows into a live table
    delete_brief               => [ 0, 1, 0 ],   # destroys a record; changes nothing live

    list_files         => [ 1, 0, 0 ],
    read_file          => [ 1, 0, 0 ],
    search_files       => [ 1, 0, 0 ],
    page_status        => [ 1, 0, 0 ],
    preview_page       => [ 1, 0, 0 ],
    list_pages         => [ 1, 0, 0 ],
    read_page          => [ 1, 0, 0 ],
    validate_page      => [ 1, 0, 0 ],
    audit_site         => [ 1, 0, 0 ],
    list_form_handlers => [ 1, 0, 0 ],
    form_list          => [ 1, 0, 0 ],
    bind_form          => [ 0, 0, 1 ],
    write_file         => [ 0, 0, 1 ],
    replace_text       => [ 0, 0, 1 ],
    copy_file          => [ 0, 0, 1 ],
    create_page        => [ 0, 0, 1 ],
    read_nav           => [ 1, 0, 0 ],
    set_nav            => [ 0, 0, 1 ],
    submit_feedback => [ 0, 0, 0 ], # writes a report, but changes nothing on the live site
    delete_page     => [ 0, 1, 1 ],
    rename_page     => [ 0, 0, 1 ],
    get_permissions => [ 1, 0, 0 ],
    move_file       => [ 0, 0, 1 ],
    delete_file     => [ 0, 1, 1 ],
    set_permissions => [ 0, 0, 0, 1 ], # SM587: acl-set's twin - it moves the read boundary
    list_themes           => [ 1, 0, 0 ],
    theme_tokens          => [ 1, 0, 0 ],
    activate_theme        => [ 0, 0, 1 ],
    create_theme          => [ 0, 0, 1 ],
    activate_layout       => [ 0, 0, 1 ],
    list_layout_catalogue => [ 1, 0, 0 ],
    install_layout        => [ 0, 0, 1 ],
    delete_layout         => [ 0, 1, 1 ],
    # SM572: the four twins of the API's %DESTRUCTIVE that carried no hint
    # and so defaulted to "not destructive"; t/lint/23 keeps the pair equal.
    delete_theme         => [ 0, 1, 1 ],
    drop_data_table      => [ 0, 1, 1 ],
    rebuild_data_table   => [ 0, 1, 1 ],
    delete_data_row      => [ 0, 1, 1 ],
    invalidate_cache     => [ 0, 0, 0 ],
    list_versions        => [ 1, 0, 0 ],
    list_content_history => [ 1, 0, 0 ],
    view_version         => [ 1, 0, 0 ],
    restore_version      => [ 0, 0, 1 ],
);

# SM525: whoami's tool list is tools/list's answer for the same session - one
# filtered source, so the two cannot disagree about what a grant may call.
sub _tool_names { my ($caps) = @_; return [ map { $_->{name} } @{ tool_list($caps) } ] }

# SM653: THE TWO CLASSES, REPORTED SEPARATELY.
#
# tools/list offers a themes-only grant 26 content tools it cannot call
# anywhere it would think to try - they are reachable only on theme and layout
# paths, through the path-aware override. The listing now SAYS so in each
# tool's description, which was the first remedy; this is the second, and it is
# for a reader that counts rather than reads.
#
# whoami answered one flat list, so an agent comparing "what I hold" against
# "what I can call" saw 26 tools it would be refused on every ordinary path and
# had no way to tell them from the rest. Two lists, derived from the SAME rule
# that decides callability - never a second hand-kept list of names, which
# would be wrong the first time a tool gained a capability.
sub _tool_classes {
    my ($caps) = @_;
    my ( @anywhere, @path_only );
    for my $t ( @{ tool_list($caps) } ) {
        my $name = $t->{name};
        if ( $TOOLS{$name} && _path_only_for( $name, $TOOLS{$name}, $caps ) ) {
            push @path_only, $name;
        }
        else { push @anywhere, $name }
    }
    return ( \@anywhere, \@path_only );
}

# SM196: which tools an AUTHENTICATED session may invoke - the same gate as
# tools/call (mcp channel + per-tool capability; path-aware tools are also
# unlocked by manage_themes/manage_layouts; an interactive manager account is
# refused on the mcp channel), minus the path argument (listing is
# path-independent). Introspection is always allowed. Used only to FILTER a
# tools/list for a session that presents a valid bearer - enforcement stays at
# tools/call.
my %INTROSPECTION_TOOLS = ( whoami => 1, describe_capabilities => 1 );

# SM653: is this tool offered ONLY because of the path-aware theme/layout
# override? If so the caller may call it on theme and layout paths and nowhere
# else, and the listing has no vocabulary for that - so the description says it.
#
# DERIVED FROM THE SAME RULE rather than a second list of tool names. A hand-kept
# list of "the path-only ones" is a sixth place to update when the rule changes
# (SM662), and it would be wrong the first time a tool gained a capability.
sub _path_only_for {
    my ( $name, $tool, $caps ) = @_;
    return 0 unless $tool->{path_aware};
    return 0 unless $caps->{manage_themes} || $caps->{manage_layouts};
    # Offered on its own merits? Then it is not path-only, whatever the flag.
    return 0 if !defined $tool->{cap};
    return 0 if $caps->{ $tool->{cap} };
    return 0 if defined $tool->{cap_also} && $caps->{ $tool->{cap_also} };
    return 1;
}

sub _tool_callable {
    my ( $name, $tool, $caps ) = @_;
    return 1 if $INTROSPECTION_TOOLS{$name};
    return 0 unless $caps->{mcp};                   # mcp channel required
    return 0 if $caps->{manager_ui} && $caps->{ui}; # interactive manager account: mcp-refused
    return 1 unless defined $tool->{cap};           # channel-only tool
    return 1 if $caps->{ $tool->{cap} };
    # SM576 part 1: the second capability a tool accepts, if it declares one.
    # Discovery must agree with tools/call or a grant is offered a tool it will
    # be refused, or refused one it may call - SM210's lesson either way round.
    return 1 if defined $tool->{cap_also} && $caps->{ $tool->{cap_also} };
    return 1
        if $tool->{path_aware} && ( $caps->{manage_themes} || $caps->{manage_layouts} );
    return 0;
}

sub tool_list {
    my ($caps) = @_;

    # SM196: when $caps is defined (a resolved session), filter to the tools this
    # session may invoke. SM210: when $caps is undef there is NO resolved identity
    # (anonymous, or an unrecognised/revoked/rotated-out token) - advertise only
    # the introspection subset, not the full tool vocabulary. Enforcement is
    # unchanged either way (tools/call still gates); this only aligns discovery.
    my @list;
    for my $name ( sort keys %TOOLS ) {
        if ( defined $caps ) {
            next unless _tool_callable( $name, $TOOLS{$name}, $caps );
        }
        else {
            next unless $INTROSPECTION_TOOLS{$name};
        }
        my $a = $ANNOTATE{$name} || [ 0, 0, 1, 0 ];

        # SM653: the listing could say "yes" or "no" and the truth was
        # "yes, on some paths". It is said in the DESCRIPTION rather than as a
        # new annotation: a client that does not know a new hint ignores it
        # silently, and the caller this is for is a language model reading the
        # description. One place, not two.
        my $desc = $TOOLS{$name}{description};
        if ( defined $caps && _path_only_for( $name, $TOOLS{$name}, $caps ) ) {
            $desc .= ' NOTE: with your current grant this tool is callable only'
                . ' on theme and layout paths; elsewhere it will be refused.'
                . " Reaching other paths needs the $TOOLS{$name}{cap} capability.";
        }

        push @list, {
            name         => $name,
            description  => $desc,
            inputSchema  => $TOOLS{$name}{inputSchema},
            outputSchema => { type => 'object' },
            annotations  => {
                title           => $name,
                readOnlyHint    => $a->[0] ? JSON::PP::true : JSON::PP::false,
                destructiveHint => $a->[1] ? JSON::PP::true : JSON::PP::false,
                openWorldHint   => $a->[2] ? JSON::PP::true : JSON::PP::false,

                # SM587: lazysite's own axis, named in the house style of its
                # three neighbours. A client that does not know it ignores it;
                # one that does learns that this call moves the read boundary,
                # which no MCP hint says and which `destructive` deliberately
                # does not mean.
                changesAccessHint => $a->[3] ? JSON::PP::true : JSON::PP::false,
            },
        };
    }
    return \@list;
}

# --- request handling -----------------------------------------------------

# Service killswitch (0.9.0): the MCP surface is OFF unless the sysop enables
# it in lazysite.conf (mcp_enabled: true), mirroring webdav_enabled. This runs
# BEFORE any handling - including the unauthenticated discovery (GET,
# initialize, tools/list) - so a disabled instance discloses nothing. Default
# off; the sysop opts it in from the Services page.
unless ( Lazysite::Util::service_enabled( $DOCROOT, 'mcp_enabled' ) ) {
    if ( ( $ENV{REQUEST_METHOD} // '' ) eq 'POST' ) {
        my $b   = '';
        my $len = $ENV{CONTENT_LENGTH} || 0;
        read( STDIN, $b, $len ) if $len > 0;
        my $parsed = eval { decode_json($b) };
        my $rid    = ( ref $parsed eq 'HASH' ) ? $parsed->{id} : undef;
        rpc_error( $rid, -32601,
            'The MCP service is not enabled on this site. Ask the operator to enable it (Services -> MCP).' );
    }
    send_status( 404, 'Not Found' );
}

# GET has no SSE stream in v1.
if ( ( $ENV{REQUEST_METHOD} // '' ) eq 'GET' ) {
    send_status( 405, 'Method Not Allowed' );
}

my $len  = $ENV{CONTENT_LENGTH} || 0;
my $body = '';
binmode STDIN;    # raw bytes - decode_json does the UTF-8 decode (some setups
                  # otherwise apply a :utf8 layer and corrupt non-ASCII content)
read( STDIN, $body, $len ) if $len > 0;
my $req = eval { decode_json($body) };
rpc_error( undef, -32700, 'Parse error' ) unless ref $req eq 'HASH';

my $id     = $req->{id};
my $method = $req->{method} // '';

# Notifications (no id) get a 202 with no JSON-RPC body.
if ( !defined $id ) {
    send_status( 202, 'Accepted' );
}

# SM179 P7: when this instance is a language set, append a paragraph to the
# connector instructions stating the invariant, the rule, the pointer and the
# prohibition - so an agent translates the right way instead of inventing a
# convention (hand-built switchers, translated keys/paths). Empty string when
# there is no set, so a monolingual instance's instructions are unchanged.
sub _mcp_language_note {
    my $conf  = _read_conf_text(':raw');
    my $group = ( $conf =~ /^lang_group\h*:\h*(\S+)\h*$/m ) ? $1 : '';
    return '' unless length $group;
    my @members = set_members( $conf, $group );
    return '' unless @members;
    return
        ' This instance is a LANGUAGE SET (group '
        . $group
        . '): the same site in several languages, each language rooted at its own '
        . 'content folder that MIRRORS the source-language folder file-for-file. To '
        . 'translate, copy a source file to the sibling root at the IDENTICAL path and '
        . 'translate only the language-bearing values (front-matter strings, JSON '
        . 'values, Markdown prose) - never the keys, paths or structure. Call whoami '
        . 'to see the set and which root is the source; call lang-status (control API) '
        . 'to see exactly which files are missing or stale, and re-translate that set. '
        . 'Do NOT hand-build a language switcher or hreflang tags: the layout receives '
        . 'the language set from the engine and renders them itself. You translate into '
        . 'the EXISTING sibling roots only - creating a NEW language is a sysop act '
        . '(it needs a domain configured with its own content_root plus DNS/TLS for the '
        . 'host, which are outside this tool surface), so if a target language has no '
        . 'sibling root yet, ask the sysop to add the domain rather than trying to '
        . 'create the language plane yourself.';
}

if ( $method eq 'initialize' ) {
    rpc_result( $id, {
            protocolVersion => $PROTOCOL,
            capabilities    => { tools => { listChanged => JSON::PP::false } },
            serverInfo      => { name  => 'lazysite-mcp', version => $VERSION },
            instructions    =>
                'You are connected to a lazysite site as a maintenance agent. Before '
                . 'creating or restructuring pages, read the site briefing '
                . '/docs/ai-briefing-building-sites: keep content (Markdown), layout and '
                . 'theme separate, and never put ordinary pages in raw mode (api:true / '
                . 'raw:true) or hand-author HTML into /lazysite-assets/. Forms are native: '
                . 'use the create_form tool (or a :::form block bound to a sysop-vetted '
                . 'handler via bind_form) - never hand-written form HTML or a third-party '
                . 'form service for CONTENT. (SM361: the shipped system pages that post to '
                . 'the auth CGI, such as /forgot, are the one exception and say so where '
                . 'they do it - native forms bind to content handlers and cannot '
                . 'authenticate. Do not read those as permission.) '
                . 'To rename or move a page, use rename_page (or move_file) - '
                . 'never write a new file at the new path and delete the old one, which '
                . 'breaks the page content history (a move keeps it; a delete ends it). '
                . 'For content rules '
                . 'see /docs/ai-briefing-authoring; for layouts and themes '
                . '/docs/ai-briefing-layouts. This site publishes around thirty '
                . 'documentation pages - call describe_capabilities for the full index '
                . '(under "docs") or read /docs/ rather than assuming a feature is '
                . 'absent because no tool advertises it. '
                # SM390: this said "so your hits stay out of the visitor
                # analytics", which is not what happens. The UA moves you out
                # of the HUMAN class into `bot` - you are still counted, in a
                # class an operator can see and filter. Measured from the
                # field, where a partner following this instruction found its
                # traffic present in the export and reasonably concluded the
                # opt-out was broken. It is not broken; the sentence was.
                . 'When you screenshot or QA the live site, set '
                . 'your User-Agent to lazysite-agent/<partner-id>. That keeps your '
                . 'hits out of the HUMAN visitor counts - they are recorded as '
                . 'bot traffic rather than dropped, so a sysop can still see '
                . 'what their tooling did.'
                . _mcp_language_note(),
    } );
}
elsif ( $method eq 'ping' ) {
    rpc_result( $id, {} );
}
elsif ( $method eq 'tools/list' ) {
    # SM196: discovery stays OPEN (no 401), but when a valid bearer is present,
    # filter to the tools this session can actually invoke - so an agent is not
    # advertised tools it will only be denied (e.g. submit_feedback without the
    # feedback capability). SM210: an unidentified caller (no bearer, or an
    # unrecognised/revoked token) gets only the introspection subset, not the full
    # surface. Enforcement is unchanged (tools/call still gates); this only aligns
    # the advertised set with the caller's identity.
    my ( $lu, $lcaps ) = verify_bearer();
    rpc_result( $id, { tools => tool_list( defined $lu ? $lcaps : undef ) } );
}
elsif ( $method eq 'tools/call' ) {
    my $params = $req->{params} || {};
    my $name   = $params->{name} // '';
    my $tool   = $TOOLS{$name};

    # SM521: authenticate BEFORE looking the name up. With the lookup first, an
    # anonymous caller got -32602 for an unknown name and 401 for a known one -
    # a tool-name oracle that handed back the vocabulary SM210 withholds from an
    # anonymous tools/list, one probe at a time.
    my ( $user, $caps ) = verify_bearer();
    send_401($id)                                   unless defined $user;
    rpc_error( $id, -32602, "Unknown tool: $name" ) unless $tool;

    # Introspection tools (whoami, describe_capabilities) stay open to ANY
    # authenticated session, per the SM072/SM126 contract. %INTROSPECTION_TOOLS
    # is the one list; BOTH gates below honour it (the SM127 gate previously ran
    # ahead of it and wrongly refused whoami on a manager-linked account).

    # SM127: manager/UI-remote separation. An account that can ACTUALLY use the
    # interactive manager UI must not drive the site over MCP (a leaked connector
    # on a live manager account is the accidental-grant vector). "Can use the UI" =
    # the `ui` capability from a group (manager_ui) AND interactive login enabled
    # (the account-level `ui` flag). An account with ui:false is a deliberate agent
    # account - as this message advises - so its connector honours its own mcp/api
    # capabilities regardless of any manager group it also sits in; per the partner
    # contract the token path is capability-based. Introspection is exempt.
    if ( $caps->{manager_ui} && $caps->{ui} && !$INTROSPECTION_TOOLS{$name} ) {
        my $a = $params->{arguments} || {};
        audit_log( $user, $name, ( $a->{path} // '' ), $ENV{REMOTE_ADDR} // '',
            'fail', 'mcp', 'denied: interactive manager account on the mcp channel' );
        rpc_error( $id, -32002,
            "This account can use the interactive manager UI, which is interactive-only: "
                . "it cannot be driven over MCP. Use a dedicated agent account (mcp "
                . "capability, interactive login disabled) instead. Do not retry." );
    }

    # SM126: strict channel gate. An MCP session operates on the `mcp` channel and
    # must hold the `mcp` capability, enforced ahead of the per-tool action cap so
    # a credential without the channel is refused uniformly. (initialize and
    # tools/list stay open for discovery; only tool invocation is gated.)
    # Introspection tools (whoami, describe_capabilities) stay open to any
    # authenticated session so a capless agent can self-diagnose and learn it
    # lacks the channel, per the SM072 introspection contract.
    unless ( $caps->{mcp} || $INTROSPECTION_TOOLS{$name} ) {
        my $a = $params->{arguments} || {};
        audit_log( $user, $name, ( $a->{path} // '' ), $ENV{REMOTE_ADDR} // '',
            'fail', 'mcp', 'denied: mcp channel capability' );
        rpc_error( $id, -32002,
            "The 'mcp' capability is required to use this connector. Ask the "
                . "sysop to grant the mcp capability to your account's group. Do not retry." );
    }

    # Compute the capability this call requires. File tools are path-aware (SM082):
    # a theme/layout path (lazysite/layouts/**) is authorised by manage_themes /
    # manage_layouts - matching WebDAV's path-aware gate - so a theme-only partner
    # can edit theme files but not content; everything else keeps the tool's cap.
    my ( $cap_ok, $need ) = ( 1, '' );
    if ( defined $tool->{cap} ) {
        $need   = $tool->{cap};
        $cap_ok = $caps->{ $tool->{cap} } ? 1 : 0;

        # SM576 part 1: `cap_also` - a SECOND capability the same tool accepts.
        # The control API has always been able to say this (its %need entries
        # are predicates, so `manage_content || manage_briefs` is one line);
        # MCP's table could only name one, which would have forced the brief
        # READS onto manage_briefs alone and broken every site that has only
        # ever granted manage_content. One optional key, read here and in
        # _tool_callable so discovery and enforcement agree, rather than a
        # second tool entry saying the same thing.
        if ( !$cap_ok && defined $tool->{cap_also} && $caps->{ $tool->{cap_also} } ) {
            $cap_ok = 1;
        }
        $need .= " or $tool->{cap_also}" if defined $tool->{cap_also};
        if ( $tool->{path_aware} ) {
            my $a = $params->{arguments} || {};
            # SM661: the same list again, so the override and the confinement
            # cannot disagree about which argument carries the path.
            my $p = '';
            for my $pk (@Lazysite::Manager::Common::PATH_ARGS) {
                next unless defined $a->{$pk} && length $a->{$pk};
                $p = $a->{$pk};
                last;
            }
            if ( $p =~ m{^/?lazysite/layouts/} ) {
                $need   = 'manage_themes or manage_layouts';
                $cap_ok = ( $caps->{manage_themes} || $caps->{manage_layouts} ) ? 1 : 0;
            }
        }
    }
    unless ($cap_ok) {
        # Audit the denied attempt (a material security event - invisible before).
        my $a = $params->{arguments} || {};
        audit_log( $user, $name, ( $a->{path} // $a->{theme} // $a->{layout} // $a->{to} // '' ),
            $ENV{REMOTE_ADDR} // '', 'fail', 'mcp', "denied: needs $need" );
        # SM101: a missing capability is permanent - tell the agent to stop, not retry.
        rpc_error( $id, -32002, "Insufficient capability for $name (needs $need). "
                . "Do not retry; ask the sysop to grant it. Call describe_capabilities "
                . "to see what your account currently holds and what each capability unlocks." );
    }

    # SM268 H4: the same carve-out gate the control API applies, from the same
    # definition in Manager::Common - nav.conf needs manage_nav and the
    # submission store needs read_submissions/manage_forms, whichever channel
    # names the path. Without this an mcp+manage_content partner read every
    # submission through read_file and rewrote the navigation through
    # write_file, while set_nav and read_form_submissions refused it the caps.
    if ( $tool->{path_aware} ) {
        my $a = $params->{arguments} || {};
        my $w = ( $name =~ /^(?:read|list|search|preview|view)/ ) ? 'read' : 'write';
        # SM661: every argument that carries a path, from the one list in
        # Manager::Common - not a hardcoded three. create_page's `slug` and
        # rename_page's `old`/`new` were not inspected here either.
        for my $pk (@Lazysite::Manager::Common::PATH_ARGS) {
            my $p = $a->{$pk};
            next unless defined $p && length $p;
            my $refusal
                = Lazysite::Manager::Common::carveout_refusal( $p, $w, $caps );
            next unless $refusal;
            audit_log( $user, $name, $p, $ENV{REMOTE_ADDR} // '',
                'fail', 'mcp', 'denied: carve-out capability' );
            rpc_error( $id, -32002,
                "$refusal Do not retry; ask the sysop to grant it." );
        }
    }

    # SEC-2026-07 (M2) / SM155: enforce the group-derived scope union on the MCP
    # channel too. A scoped partner (via its group(s)) is confined to its content
    # subtree(s) over WebDAV and must be here as well. Applies to every content
    # path argument (path/to/from); the lazysite/ theme-authoring namespace is out
    # of scope's remit (governed by manage_themes/layouts).
    my $scopes = $caps->{dav_scopes};
    if ( ref $scopes eq 'ARRAY' && @$scopes ) {
        my $a = $params->{arguments} || {};
        # SM661: the same list. A grant scoped to one domain created a page in
        # another through create_page, because `slug` was not among the three
        # names this loop knew about - a well-formed call the confinement never
        # looked at.
        for my $pk (@Lazysite::Manager::Common::PATH_ARGS) {
            my $p = $a->{$pk};
            next unless defined $p && length $p;
            next if $p =~ m{^/?lazysite/};
            next
                unless Lazysite::Manager::Common::outside_all_scopes( $scopes, $p );
            audit_log( $user, $name, $p, $ENV{REMOTE_ADDR} // '',
                'fail', 'mcp', 'denied: outside dav_scope' );
            my $names = join ', ',
                map { ( my $s = $_ ) =~ s{^/+|/+$}{}g; "$s/" } @$scopes;
            rpc_error( $id, -32002,
                "Path '$p' is outside your assigned scope ($names). Do not retry; "
                    . "ask the operator to widen your group's dav_scope." );
        }
    }

    setup_context($user);
    # SM593: the data surface confines itself by the caller's grant, from the
    # same dav_scopes this tool call was just checked against - so the control
    # API and MCP cannot disagree about which domain's tables a partner reaches.
    @Lazysite::Manager::Data::CALLER_SCOPES
        = ( ref $scopes eq 'ARRAY' ) ? @{$scopes} : ();
    # SM648: every MCP caller is a token, so it is a confined principal. An
    # empty scope set means it reaches no domain, not every one.
    $Lazysite::Manager::Data::CALLER_CONFINED = 1;
    # SM464: the grant's own settings, for the acl audit-read override - same
    # line the control API sets, so the two token surfaces cannot disagree.
    %Lazysite::Auth::Acl::token_caps = %{ $caps || {} };
    my $args = $params->{arguments} || {};

    # SM278: the published schema is enforced here, after the channel and
    # capability gates (so a caller without the capability is told that, not
    # given a schema critique of a call it was never allowed to make).
    if ( my $bad = validate_args( $name, $tool, $args ) ) {
        audit_log( $user, $name, ( $args->{path} // '' ), $ENV{REMOTE_ADDR} // '',
            'fail', 'mcp', 'invalid arguments' );
        rpc_error( $id, -32602, $bad );
    }

    my $out = eval { $tool->{run}->( $args, $user, $caps ) };
    if ($@) {
        log_event( 'ERROR', 'mcp', 'tool died', tool => $name, err => "$@" );
        rpc_error( $id, -32603, "Tool error: $name" );
    }
    log_event( 'INFO', 'mcp', 'tool call',
        tool => $name, user => $user, ok => ( $out->{ok} ? 1 : 0 ) );

    # Audit state-changing tools (origin = mcp) alongside the manager UI / API.
    unless ( $READ{$name} ) {
        my $target = $args->{path} // $args->{from} // $args->{theme}
            // $args->{name} // $args->{layout} // '';
        # Meaningful file-event labels (create/edit/delete/move) to match the
        # manager UI + WebDAV audit vocabulary.
        my $act =
            $name eq 'write_file' ? ( ( ref $out eq 'HASH' && $out->{created} ) ? 'create' : 'edit' )
            : $name eq 'replace_text'    ? 'edit'
            : $name eq 'create_page'     ? 'create'
            : $name eq 'create_theme'    ? 'theme-create'
            : $name eq 'delete_file'     ? 'delete'
            : $name eq 'delete_page'     ? 'delete'
            : $name eq 'rename_page'     ? 'move'
            : $name eq 'move_file'       ? 'move'
            : $name eq 'submit_feedback' ? 'feedback'
            :                              $name;
        my $aok    = ref $out eq 'HASH' && $out->{ok};
        my $detail = $aok ? ''
            : ( ref $out eq 'HASH' ? ( $out->{kind} || $out->{error} || '' ) : '' );
        audit_log( $user, $act, $target, $ENV{REMOTE_ADDR} // '',
            ( $aok ? 'ok' : 'fail' ), 'mcp', $detail );
    }

    # SM101: tell the agent whether a retry could ever succeed, so it backs off on a
    # permanent refusal (permission, blocked, bad path, already-exists, ...) instead
    # of hammering. Only a small set of kinds is genuinely transient.
    if ( ref $out eq 'HASH' && !$out->{ok} ) {
        my $retry = $TRANSIENT{ $out->{kind} // '' } ? 1 : 0;
        $out->{retryable} = $retry ? JSON::PP::true : JSON::PP::false;
        $out->{hint} = 'Do not retry - this will not succeed unless the request changes '
            . 'or the sysop grants access.'
            if !$retry && !defined $out->{hint};
    }

    my $is_err = ( ref $out eq 'HASH' && $out->{ok} ) ? JSON::PP::false : JSON::PP::true;

    # SM353: `ok` is a boolean here too, coerced at the one point every tool
    # result passes through rather than in each handler. MCP was not internally
    # consistent either - describe_capabilities emitted true and validate_page
    # emitted 1 - so this is not the API being brought into line with MCP, it is
    # both surfaces being given a rule where there was none. Mirrors
    # Lazysite::Manager::Common::respond; t/lint/57 pins the pair.
    $out->{ok} = $out->{ok} ? JSON::PP::true : JSON::PP::false
        if ref $out eq 'HASH' && exists $out->{ok};

    # The text part is $out re-serialised to JSON. encode_json emits UTF-8 BYTES;
    # decode them back to characters so the OUTER encode_json (in send_json)
    # encodes them exactly once - otherwise non-ASCII in the text part is
    # double-encoded into mojibake (the structuredContent part is already fine).
    my $text = encode_json($out);
    utf8::decode($text);
    rpc_result( $id, {
            content           => [ { type => 'text', text => $text } ],
            structuredContent => $out,
            isError           => $is_err,
    } );
}
else {
    rpc_error( $id, -32601, "Method not found: $method" );
}
