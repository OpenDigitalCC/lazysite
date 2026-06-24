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
use JSON::PP qw(encode_json decode_json);
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
use Lazysite::Util qw(log_event);
use Lazysite::Audit qw(audit_log);
use Lazysite::Auth::OAuth ();
use Lazysite::Manager::Files qw(action_list action_read action_save action_delete
    action_move action_acl_set action_acl_remove);
use Lazysite::Manager::Themes qw(action_theme_activate action_layout_activate
    _read_active_layout_and_theme);

our $VERSION = '0.1';
my $PROTOCOL = '2025-11-25';

my $DOCROOT      = $ENV{DOCUMENT_ROOT} // '';
my $LAZYSITE_DIR = "$DOCROOT/lazysite";
my $LOCK_DIR     = "$LAZYSITE_DIR/manager/locks";
$Lazysite::Auth::OAuth::LAZYSITE_DIR = $LAZYSITE_DIR;

# --- output helpers -------------------------------------------------------

sub send_json {
    my ($obj) = @_;
    my $body = encode_json($obj);
    binmode STDOUT, ':utf8';
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
    binmode STDOUT, ':utf8';
    print "Status: 401 Unauthorized\r\n";
    print "WWW-Authenticate: Bearer resource_metadata=\"$meta\"\r\n";
    print "Content-Type: application/json\r\n";
    print "MCP-Protocol-Version: $PROTOCOL\r\n\r\n";
    print encode_json( { jsonrpc => '2.0', id => $id,
        error => { code => -32001, message => 'Unauthorized' } } );
    exit 0;
}

# --- token auth (reuses the control-API credential verification) ----------

sub _users_tool {
    for my $c ( $ENV{LAZYSITE_USERS_TOOL},
        dirname( Cwd::abs_path(__FILE__) ) . "/tools/lazysite-users.pl",
        dirname( Cwd::abs_path(__FILE__) ) . "/../tools/lazysite-users.pl",
        "$DOCROOT/../tools/lazysite-users.pl" ) {
        return $c if defined $c && -f $c;
    }
    return undef;
}

sub _users_api {
    my ($payload) = @_;
    my $tool = _users_tool() or return undef;
    my ( $out, $in );
    my $pid = eval { open2( $out, $in, $^X, $tool, '--api', '--docroot', $DOCROOT ) }
        or return undef;
    print $in encode_json($payload);
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return eval { decode_json( $resp // '{}' ) };
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
        return ( $user, $v->{settings} || {} );
    }

    # Opaque OAuth access token: resolve to its partner, then its capabilities
    # (partner-caps also stamps first use for the connector-setup detection).
    my $partner = Lazysite::Auth::OAuth::validate_token($cred);
    return () unless defined $partner;
    my $r = _users_api( { action => 'partner-caps', username => $partner } );
    return () unless $r && $r->{ok};
    return ( $partner, $r->{settings} || {} );
}

# Set the per-request module context once the caller is known.
sub setup_context {
    my ($user) = @_;
    $Lazysite::Manager::Files::DOCROOT         = $DOCROOT;
    $Lazysite::Manager::Files::LOCK_DIR        = $LOCK_DIR;
    $Lazysite::Manager::Files::auth_user       = $user;
    $Lazysite::Manager::Files::action          = 'mcp';
    $Lazysite::Manager::Themes::DOCROOT        = $DOCROOT;
    $Lazysite::Manager::Themes::LAZYSITE_DIR   = $LAZYSITE_DIR;
    $Lazysite::Manager::Themes::auth_user      = $user;
    $Lazysite::Manager::Themes::action         = 'mcp';
    $Lazysite::Manager::Common::DOCROOT        = $DOCROOT;
    $Lazysite::Manager::Common::action         = 'mcp';
    $Lazysite::Manager::Artifact::LAZYSITE_DIR = $LAZYSITE_DIR;
    $Lazysite::Auth::Acl::DOCROOT              = $DOCROOT;
    $Lazysite::Auth::Acl::auth_user            = $user;
    $Lazysite::Auth::Acl::token_auth           = 1;     # never an operator
    @Lazysite::Auth::Acl::user_groups          = ();    # token carries no groups
    $Lazysite::Audit::LAZYSITE_DIR             = $LAZYSITE_DIR;
    return;
}

# --- tool registry --------------------------------------------------------
# Each tool: description, inputSchema (JSON Schema), cap (required capability
# or undef = any authenticated), run (coderef: \%args, $user -> result hash).

my %TOOLS = (
    whoami => {
        description => 'Report the calling partner identity, capabilities, and the active layout/theme.',
        cap         => undef,
        inputSchema => { type => 'object', properties => {}, additionalProperties => JSON::PP::false },
        run => sub {
            my ( $args, $user, $caps ) = @_;
            my ( $layout, $theme ) = _read_active_layout_and_theme();
            return { ok => 1, user => $user, capabilities => $caps,
                active_layout => $layout, active_theme => $theme };
        },
    },
    list_files => {
        description => 'List files and folders under a site-relative directory path (default "/").',
        cap         => 'webdav',
        inputSchema => { type => 'object',
            properties => { path => { type => 'string', description => 'Directory path, e.g. /content' } },
            additionalProperties => JSON::PP::false },
        run => sub { action_list( $_[0]->{path} // '/' ) },
    },
    read_file => {
        description => 'Read the contents of a text file by site-relative path.',
        cap         => 'webdav',
        inputSchema => { type => 'object',
            properties => { path => { type => 'string' } },
            required => ['path'], additionalProperties => JSON::PP::false },
        run => sub { action_read( $_[0]->{path}, $_[1] ) },
    },
    write_file => {
        description => 'Create or overwrite a text file with the given content.',
        cap         => 'webdav',
        inputSchema => { type => 'object',
            properties => { path => { type => 'string' }, content => { type => 'string' } },
            required => [ 'path', 'content' ], additionalProperties => JSON::PP::false },
        run => sub { action_save( $_[0]->{path}, $_[1], $_[0]->{content}, undef ) },
    },
    move_file => {
        description => 'Rename or move a file (carries its .brief and re-keys its ACL).',
        cap         => 'webdav',
        inputSchema => { type => 'object',
            properties => { from => { type => 'string' }, to => { type => 'string' } },
            required => [ 'from', 'to' ], additionalProperties => JSON::PP::false },
        run => sub { action_move( $_[0]->{from}, $_[0]->{to}, $_[1] ) },
    },
    delete_file => {
        description => 'Delete a file by site-relative path.',
        cap         => 'webdav',
        inputSchema => { type => 'object',
            properties => { path => { type => 'string' } },
            required => ['path'], additionalProperties => JSON::PP::false },
        run => sub { action_delete( $_[0]->{path}, $_[1] ) },
    },
    set_permissions => {
        description => 'Set the per-file ACL: owner plus read/write lists (users or @groups).',
        cap         => 'webdav',
        inputSchema => { type => 'object',
            properties => {
                path  => { type => 'string' },
                read  => { type => 'string', description => 'comma-separated users / @groups' },
                write => { type => 'string' },
            },
            required => ['path'], additionalProperties => JSON::PP::false },
        run => sub {
            action_acl_set( $_[0]->{path}, $_[1], $_[0]->{read}, $_[0]->{write}, undef );
        },
    },
    activate_theme => {
        description => 'Activate a theme for the current layout (clears the HTML cache).',
        cap         => 'manage_themes',
        inputSchema => { type => 'object',
            properties => { theme => { type => 'string' } },
            required => ['theme'], additionalProperties => JSON::PP::false },
        run => sub { action_theme_activate( $_[0]->{theme}, {} ) },
    },
    activate_layout => {
        description => 'Activate a layout (optionally naming a compatible theme).',
        cap         => 'manage_layouts',
        inputSchema => { type => 'object',
            properties => { layout => { type => 'string' }, theme => { type => 'string' } },
            required => ['layout'], additionalProperties => JSON::PP::false },
        run => sub {
            my $p = {};
            $p->{theme} = $_[0]->{theme} if defined $_[0]->{theme};
            action_layout_activate( $_[0]->{layout}, $p );
        },
    },
);

sub tool_list {
    my @list;
    for my $name ( sort keys %TOOLS ) {
        push @list, {
            name        => $name,
            description => $TOOLS{$name}{description},
            inputSchema => $TOOLS{$name}{inputSchema},
        };
    }
    return \@list;
}

# --- request handling -----------------------------------------------------

# GET has no SSE stream in v1.
if ( ( $ENV{REQUEST_METHOD} // '' ) eq 'GET' ) {
    send_status( 405, 'Method Not Allowed' );
}

my $len  = $ENV{CONTENT_LENGTH} || 0;
my $body = '';
read( STDIN, $body, $len ) if $len > 0;
my $req = eval { decode_json($body) };
rpc_error( undef, -32700, 'Parse error' ) unless ref $req eq 'HASH';

my $id     = $req->{id};
my $method = $req->{method} // '';

# Notifications (no id) get a 202 with no JSON-RPC body.
if ( !defined $id ) {
    send_status( 202, 'Accepted' );
}

if ( $method eq 'initialize' ) {
    rpc_result( $id, {
        protocolVersion => $PROTOCOL,
        capabilities    => { tools => { listChanged => JSON::PP::false } },
        serverInfo      => { name => 'lazysite-mcp', version => $VERSION },
    } );
}
elsif ( $method eq 'ping' ) {
    rpc_result( $id, {} );
}
elsif ( $method eq 'tools/list' ) {
    rpc_result( $id, { tools => tool_list() } );
}
elsif ( $method eq 'tools/call' ) {
    my $params = $req->{params} || {};
    my $name   = $params->{name} // '';
    my $tool   = $TOOLS{$name};
    rpc_error( $id, -32602, "Unknown tool: $name" ) unless $tool;

    my ( $user, $caps ) = verify_bearer();
    send_401($id) unless defined $user;

    if ( defined $tool->{cap} && !$caps->{ $tool->{cap} } ) {
        rpc_error( $id, -32002, "Insufficient capability for $name (needs $tool->{cap})" );
    }

    setup_context($user);
    my $args = $params->{arguments} || {};
    my $out  = eval { $tool->{run}->( $args, $user, $caps ) };
    if ($@) {
        log_event( 'ERROR', 'mcp', 'tool died', tool => $name, err => "$@" );
        rpc_error( $id, -32603, "Tool error: $name" );
    }
    log_event( 'INFO', 'mcp', 'tool call',
        tool => $name, user => $user, ok => ( $out->{ok} ? 1 : 0 ) );

    # Audit state-changing tools (origin = mcp) alongside the manager UI / API.
    my %READ = ( whoami => 1, list_files => 1, read_file => 1 );
    unless ( $READ{$name} ) {
        my $target = $args->{path} // $args->{from} // $args->{theme} // $args->{layout} // '';
        audit_log( $user, $name, $target, $ENV{REMOTE_ADDR} // '',
            ( ref $out eq 'HASH' && $out->{ok} ) ? 'ok' : 'fail', 'mcp' );
    }

    my $is_err = ( ref $out eq 'HASH' && $out->{ok} ) ? JSON::PP::false : JSON::PP::true;
    rpc_result( $id, {
        content          => [ { type => 'text', text => encode_json($out) } ],
        structuredContent => $out,
        isError          => $is_err,
    } );
}
else {
    rpc_error( $id, -32601, "Method not found: $method" );
}
