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
    action_move action_acl_get action_acl_set action_acl_remove);
use Lazysite::Manager::Themes qw(action_theme_activate action_layout_activate
    action_cache_invalidate _read_active_layout_and_theme);

our $VERSION = '0.1';
my $PROTOCOL = '2025-11-25';
# Cap a single read_file response so a huge file can't produce a slow/oversized
# reply that trips the client's per-call timeout. Normal pages are a few KB.
my $MAX_READ_BYTES = 512 * 1024;

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
    # Disambiguate the cause: no credential reached us (connector not yet signed
    # in / authorisation incomplete) vs a credential that didn't verify (expired
    # or revoked - reconnect). Points the agent + operator at the right fix.
    my $had_cred = ( $ENV{HTTP_AUTHORIZATION} || $ENV{REDIRECT_HTTP_AUTHORIZATION} ) ? 1 : 0;
    my $msg = $had_cred
        ? 'Credential did not verify (expired or revoked) - reconnect the connector.'
        : 'Connector sign-in incomplete - finish authorising the connector before calling tools (this is not a missing-header you can fix in the prompt).';
    binmode STDOUT, ':utf8';
    print "Status: 401 Unauthorized\r\n";
    print "WWW-Authenticate: Bearer resource_metadata=\"$meta\"\r\n";
    print "Content-Type: application/json\r\n";
    print "MCP-Protocol-Version: $PROTOCOL\r\n\r\n";
    print encode_json( { jsonrpc => '2.0', id => $id,
        error => { code => -32001, message => $msg,
            data => { reason => ( $had_cred ? 'credential-invalid' : 'sign-in-incomplete' ) } } } );
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
            # Echo the full tool list so an agent sees every available tool in one
            # call (the connector loads tools a few at a time, which can hide some).
            return { ok => 1, user => $user, capabilities => $caps,
                active_layout => $layout, active_theme => $theme,
                tools => _tool_names() };
        },
    },
    list_files => {
        description => 'List files and folders under a site-relative directory path (default "/").',
        cap         => 'manage_content',
        inputSchema => { type => 'object',
            properties => { path => { type => 'string', description => 'Directory path, e.g. /content' } },
            additionalProperties => JSON::PP::false },
        run => sub { action_list( $_[0]->{path} // '/' ) },
    },
    read_file => {
        description => 'Read the contents of a text file by site-relative path.',
        cap         => 'manage_content',
        inputSchema => { type => 'object',
            properties => { path => { type => 'string' } },
            required => ['path'], additionalProperties => JSON::PP::false },
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
    write_file => {
        description => 'Create or overwrite a text file with the given content.',
        cap         => 'manage_content',
        inputSchema => { type => 'object',
            properties => { path => { type => 'string' }, content => { type => 'string' } },
            required => [ 'path', 'content' ], additionalProperties => JSON::PP::false },
        run => sub { action_save( $_[0]->{path}, $_[1], $_[0]->{content}, undef ) },
    },
    replace_text => {
        description => 'Edit a file by replacing exact text - safer than rewriting the whole file for a small change to a page with HTML / front matter / scripts. Replaces every occurrence of "old" with "new"; errors if "old" is not present. read_file first to copy the exact text (including whitespace).',
        cap         => 'manage_content',
        inputSchema => { type => 'object',
            properties => {
                path => { type => 'string' },
                old  => { type => 'string', description => 'exact text to find (must match including whitespace)' },
                new  => { type => 'string', description => 'replacement text' },
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
            my $s = action_save( $a->{path}, $user, $content, undef );
            $s->{replacements} = $count if ref $s eq 'HASH' && $s->{ok};
            return $s;
        },
    },
    copy_file => {
        description => 'Copy a text file to a new path - templating a new page from an existing one. The destination starts with a fresh ACL.',
        cap         => 'manage_content',
        inputSchema => { type => 'object',
            properties => { from => { type => 'string' }, to => { type => 'string' } },
            required => [ 'from', 'to' ], additionalProperties => JSON::PP::false },
        run => sub {
            my ( $a, $user ) = @_;
            my $r = action_read( $a->{from}, $user );
            return $r unless ref $r eq 'HASH' && $r->{ok};
            return action_save( $a->{to}, $user, $r->{content}, undef );
        },
    },
    get_permissions => {
        description => 'Read the access-control list for a path (owner + per-user / @group read & write grants). Call this before set_permissions to see the current state.',
        cap         => 'manage_content',
        inputSchema => { type => 'object',
            properties => { path => { type => 'string' } },
            required => ['path'], additionalProperties => JSON::PP::false },
        run => sub { action_acl_get( $_[0]->{path}, $_[1] ) },
    },
    move_file => {
        description => 'Rename or move a file (carries its .brief and re-keys its ACL).',
        cap         => 'manage_content',
        inputSchema => { type => 'object',
            properties => { from => { type => 'string' }, to => { type => 'string' } },
            required => [ 'from', 'to' ], additionalProperties => JSON::PP::false },
        run => sub { action_move( $_[0]->{from}, $_[0]->{to}, $_[1] ) },
    },
    delete_file => {
        description => 'Delete a file by site-relative path.',
        cap         => 'manage_content',
        inputSchema => { type => 'object',
            properties => { path => { type => 'string' } },
            required => ['path'], additionalProperties => JSON::PP::false },
        run => sub { action_delete( $_[0]->{path}, $_[1] ) },
    },
    set_permissions => {
        description => 'Set the per-file ACL: owner plus read/write lists (users or @groups).',
        cap         => 'manage_content',
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
    list_form_handlers => {
        description => 'List the configured form delivery handlers (id, type, name) - what a form can be bound to. Destinations and credentials are operator-only and never returned.',
        cap         => 'manage_content',
        inputSchema => { type => 'object', properties => {}, additionalProperties => JSON::PP::false },
        run         => sub { _list_form_handlers() },
    },
    bind_form => {
        description => 'Wire a form to delivery by referencing an existing handler (from list_form_handlers). A :::form only delivers once bound. You choose an operator-vetted handler by id; you never set a destination or credential (those stay operator-only). Writes lazysite/forms/<form>.conf.',
        cap         => 'manage_content',
        inputSchema => { type => 'object',
            properties => {
                form    => { type => 'string', description => 'the form name (the _form / front-matter form key)' },
                handler => { type => 'string', description => 'an existing handler id from list_form_handlers' },
            },
            required => [ 'form', 'handler' ], additionalProperties => JSON::PP::false },
        run => sub { _bind_form( $_[0]->{form}, $_[0]->{handler} ) },
    },
    audit_site => {
        description => 'Audit the whole site: broken internal links, orphan pages (nothing links to them), pages missing a title, stale generated HTML (no source), and duplicate content blocks (the same paragraph on multiple pages, e.g. repeated reviews). Returns lists per category.',
        cap         => 'manage_content',
        inputSchema => { type => 'object', properties => {}, additionalProperties => JSON::PP::false },
        run         => sub { _audit_site() },
    },
    validate_page => {
        description => 'Check page content before saving: malformed/unterminated front matter, missing title, invalid form-field rules, and a PUBLIC-DATA warning (Wi-Fi passwords, postcodes/addresses, phone numbers) so private operational details are not published by accident. Pass content to check a draft, or path to check a saved file.',
        cap         => 'manage_content',
        inputSchema => { type => 'object',
            properties => {
                path    => { type => 'string', description => 'page to validate' },
                content => { type => 'string', description => 'draft content to validate instead of a saved file' },
            },
            additionalProperties => JSON::PP::false },
        run => sub { _validate_page( $_[0]->{path}, $_[0]->{content}, $_[1] ) },
    },
    list_pages => {
        description => 'List the site pages with their title, public URL, and which registries (sitemap/llms/feed) each is in. A page-level view rather than a raw file list.',
        cap         => 'manage_content',
        inputSchema => { type => 'object', properties => {}, additionalProperties => JSON::PP::false },
        run         => sub { _list_pages() },
    },
    read_page => {
        description => 'Read a page as structured data: parsed front matter, the Markdown body, whether it has an authoring brief, and its public URL. Higher-level than read_file for editing a page.',
        cap         => 'manage_content',
        inputSchema => { type => 'object',
            properties => { path => { type => 'string', description => 'page path, e.g. /enquire.md' } },
            required => ['path'], additionalProperties => JSON::PP::false },
        run => sub { _read_page( $_[0]->{path}, $_[1] ) },
    },
    page_status => {
        description => 'Publish status for a page: whether the source exists, when it was last modified, whether the public HTML render is pending (cache dropped after an edit - it re-renders on the next visit), and the public URL. Use after an edit to confirm it will reach visitors.',
        cap         => 'manage_content',
        inputSchema => { type => 'object',
            properties => { path => { type => 'string', description => 'page path, e.g. /enquire.md' } },
            required => ['path'], additionalProperties => JSON::PP::false },
        run => sub { _page_status( $_[0]->{path} ) },
    },
    search_files => {
        description => 'Search the site text files for a string (case-insensitive). Returns matching files with line numbers and snippets - use to find pages mentioning a term, links to a path, or duplicated text. Excludes the lazysite/ infrastructure and binary/asset files.',
        cap         => 'manage_content',
        inputSchema => { type => 'object',
            properties => {
                query => { type => 'string', description => 'text to search for' },
                path  => { type => 'string', description => 'directory to search under (default /)' },
            },
            required => ['query'], additionalProperties => JSON::PP::false },
        run => sub { _mcp_search( $_[0]->{query}, $_[0]->{path} ) },
    },
    invalidate_cache => {
        description => 'Drop the cached HTML for a page so it re-renders on the next request. A normal write already clears the saved page; use this to force a refresh or to rebuild pages that embed another (pass "*" to clear every page).',
        cap         => 'manage_content',
        inputSchema => { type => 'object',
            properties => { path => { type => 'string', description => 'Page path (e.g. /enquire), or "*" for all pages' } },
            required => ['path'], additionalProperties => JSON::PP::false },
        run => sub { action_cache_invalidate( $_[0]->{path} ) },
    },
);

# Content search (grep) over site text files. Excludes the lazysite/ infra and
# binary/asset files; bounded by file + match caps so a big site can't produce a
# runaway response.
my %SEARCH_EXT = map { $_ => 1 } qw(md txt html htm xml json js css svg atom rss);
sub _mcp_search {
    my ( $query, $base ) = @_;
    return { ok => 0, error => 'query must not be empty' } unless defined $query && length $query;
    $base = '/' unless defined $base && length $base;
    $base =~ s{^/+}{}; $base =~ s{/+$}{}; $base =~ s{\.\.}{}g;
    my $root = $DOCROOT . ( length $base ? "/$base" : '' );
    my $qre  = qr/\Q$query\E/i;
    my ( @matches, $files, $truncated );
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
            if ( ++$files > 2000 ) { $truncated = 1; last }
            open my $fh, '<', $full or next;
            my $ln = 0;
            while ( my $line = <$fh> ) {
                $ln++;
                next unless $line =~ $qre;
                ( my $rel = $full ) =~ s{^\Q$DOCROOT\E/?}{/};
                chomp $line; $line =~ s/^\s+//; $line = substr( $line, 0, 200 );
                push @matches, { path => $rel, line => $ln, text => $line };
                if ( @matches >= 200 ) { $truncated = 1; last }
            }
            close $fh;
            last if $truncated;
        }
        closedir $dh;
        last if $truncated;
    }
    return { ok => 1, query => $query, count => scalar @matches,
        matches => \@matches, truncated => ( $truncated ? JSON::PP::true : JSON::PP::false ) };
}

# Publish status for a page: is the source there, has the rendered HTML cache
# been dropped (so a visitor re-renders it fresh), and where is it public.
sub _page_status {
    my ($path) = @_;
    return { ok => 0, error => 'path required' } unless defined $path && length $path;
    ( my $rel = $path ) =~ s{^/+}{}; $rel =~ s{\.\.}{}g;
    my $full   = "$DOCROOT/$rel";
    my $exists = -f $full;
    my %out = ( ok => 1, path => "/$rel",
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
        ( my $slug = $rel ) =~ s/\.md$//;
        my $host = $ENV{HTTP_HOST} // $ENV{SERVER_NAME} // '';
        $out{public_url} = length $host ? "https://$host/$slug" : "/$slug";
    }
    return \%out;
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
        else { $v =~ s/^["']|["']$//g; $h{$k} = $v; }
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
    my $r = action_read( $path, $user );
    return $r unless ref $r eq 'HASH' && $r->{ok};
    my ( $fm, $body ) = _split_front_matter( $r->{content} );
    ( my $rel = $path ) =~ s{^/+}{};
    return { ok => 1, path => "/$rel",
        front_matter => _parse_fm($fm), body => $body,
        has_brief  => ( -f "$DOCROOT/$rel.brief" ? JSON::PP::true : JSON::PP::false ),
        public_url => _public_url($rel), modified => $r->{mtime} };
}

# Walk top-level + content/ .md pages (skip infra/manager/generated partials).
sub _each_page {
    my ($cb) = @_;
    my @stack = ($DOCROOT);
    my $n = 0;
    while (@stack) {
        my $dir = pop @stack;
        opendir my $dh, $dir or next;
        for my $e ( sort readdir $dh ) {
            next if $e =~ /^\./;
            my $full = "$dir/$e";
            if ( -d $full ) {
                push @stack, $full
                    unless $e =~ /^(lazysite|lazysite-assets|manager|img|quotes|docs)$/;
                next;
            }
            next unless -f $full && $e =~ /\.md$/ && $e !~ /\.md\.brief$/;
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
        open my $fh, '<', $full or return;
        local $/; my $c = <$fh>; close $fh;
        my ( $fm ) = _split_front_matter($c);
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
sub _validate_page {
    my ( $path, $content, $user ) = @_;
    if ( !defined $content ) {
        return { ok => 0, error => 'path or content required' }
            unless defined $path && length $path;
        my $r = action_read( $path, $user );
        return $r unless ref $r eq 'HASH' && $r->{ok};
        $content = $r->{content};
    }
    my ( @issues, @warnings );

    # Front matter: opened-but-unterminated, and missing title.
    if ( $content =~ /\A---\s*\n/ && $content !~ /\A---\s*\n.*?\n---\s*\n/s ) {
        push @issues, { kind => 'front-matter-unterminated',
            message => 'front matter opened with --- but never closed' };
    }
    my ( $fm, $body ) = _split_front_matter($content);
    my $h = _parse_fm($fm);
    push @warnings, { kind => 'no-title', message => 'page has no title in front matter' }
        unless length( $h->{title} // '' );

    # Form-field rules (catch typos/unsupported rules before publish).
    if ( $content =~ /:::\s*form\b(.*?):::/s ) {
        for my $line ( split /\n/, $1 ) {
            $line =~ s/^\s+|\s+$//g;
            next unless length $line;
            my ( $name, undef, $rules ) = split /\s*\|\s*/, $line, 3;
            next if !defined $name || $name eq 'submit' || !defined $rules;
            for my $tok ( split /\s+/, $rules ) {
                next if $FORM_FLAGS{$tok} || $tok =~ /^[a-z]+:/;    # known flag or key:value
                next if $tok !~ /^[a-z]+$/;                          # only flag plain words
                push @issues, { kind => 'invalid-form-rule',
                    message => "unknown form rule '$tok' on field '$name'" };
            }
        }
    }

    # Public-data warnings - private/operational details that should not be
    # published accidentally (guest-instruction uploads carry these).
    my $ln = 0;
    for my $line ( split /\n/, $body ) {
        $ln++;
        push @warnings, { kind => 'public-credential', line => $ln,
            message => 'possible Wi-Fi / password value - confirm this should be public' }
            if $line =~ /\b(?:wi-?fi|password|passphrase|wpa2?|psk)\b\s*[:=]/i;
        push @warnings, { kind => 'public-postcode', line => $ln,
            message => 'looks like a UK postcode - confirm the full address should be public' }
            if $line =~ /\b[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}\b/;
        push @warnings, { kind => 'public-phone', line => $ln,
            message => 'contains a phone number - fine for a contact CTA, not for a private number' }
            if $line =~ /\+?\d[\d\s().-]{8,}\d/ && $line =~ /\d{3}/;
    }

    return { ok => 1, valid => ( @issues ? JSON::PP::false : JSON::PP::true ),
        issues => \@issues, warnings => \@warnings };
}

# --- SM087 Tier 2: whole-site audit ---------------------------------------
sub _audit_site {
    my ( %exists, %inbound, %para, @info, @links );
    _each_page( sub {
        my ( $rel, $full ) = @_;
        ( my $slug = "/$rel" ) =~ s/\.md$//;
        $exists{$slug} = 1;
        open my $fh, '<', $full or return;
        local $/; my $c = <$fh>; close $fh;
        my ( $fm, $body ) = _split_front_matter($c);
        my $h = _parse_fm($fm);
        push @info, { slug => $slug, title => ( $h->{title} // '' ) };
        while ( $body =~ /\]\(([^)\s]+)\)/g )      { push @links, [ $slug, $1 ] }
        while ( $body =~ /href=["']([^"'#?]+)/g )   { push @links, [ $slug, $1 ] }
        for my $p ( split /\n\s*\n/, $body ) {
            $p =~ s/\s+/ /g; $p =~ s/^\s+|\s+$//g;
            push @{ $para{$p} }, $slug if length $p >= 60;
        }
    } );

    my @broken;
    for my $l (@links) {
        my ( $from, $to ) = @$l;
        next unless $to =~ m{^/};
        next if $to =~ m{^/(?:cgi-bin|manager|lazysite|img|lazysite-assets)/};
        ( my $t = $to ) =~ s/[#?].*$//; $t =~ s{/$}{};
        next unless length $t;
        if ( $exists{$t} || -e "$DOCROOT$t" || -f "$DOCROOT$t.md" || -f "$DOCROOT$t.html" ) {
            $inbound{$t}++;
        }
        else { push @broken, { from => $from, to => $to }; last if @broken >= 200 }
    }

    my @orphans   = map { $_->{slug} } grep { $_->{slug} ne '/index' && !$inbound{ $_->{slug} } } @info;
    my @no_title  = map { $_->{slug} } grep { !length $_->{title} } @info;

    # Stale generated HTML: a rendered .html with no .md source.
    my ( @stale, @stack ) = ( (), $DOCROOT );
    while (@stack) {
        my $dir = pop @stack;
        opendir my $dh, $dir or next;
        for my $e ( readdir $dh ) {
            next if $e =~ /^\./;
            my $full = "$dir/$e";
            if ( -d $full ) { push @stack, $full unless $e =~ /^(?:lazysite|lazysite-assets)$/; next }
            next unless $e =~ /\.html$/;
            ( my $src = $full ) =~ s/\.html$/.md/;
            unless ( -f $src ) { ( my $rel = $full ) =~ s{^\Q$DOCROOT\E/+}{/}; push @stale, $rel; last if @stale >= 200 }
        }
        closedir $dh;
    }

    my @dups;
    for my $p ( sort keys %para ) {
        my %u = map { $_ => 1 } @{ $para{$p} };
        next unless keys %u > 1;
        push @dups, { text => substr( $p, 0, 120 ), pages => [ sort keys %u ] };
        last if @dups >= 50;
    }

    return { ok => 1, pages => scalar @info,
        broken_links => \@broken, orphan_pages => \@orphans,
        missing_title => \@no_title, stale_html => \@stale, duplicate_blocks => \@dups };
}

# --- SM088: bind a form to an operator-vetted delivery handler ------------
# Handlers (with their destinations + credentials) live in handlers.conf and
# are operator-only. The connector may only REFERENCE an existing handler by id;
# it never sees or sets a destination or secret.
sub _list_form_handlers {
    my $f = "$LAZYSITE_DIR/forms/handlers.conf";
    return { ok => 1, handlers => [] } unless -f $f;
    open my $fh, '<', $f or return { ok => 0, error => 'cannot read handlers.conf' };
    local $/; my $c = <$fh>; close $fh;
    my @h;
    while ( $c =~ /^[ \t]*-[ \t]+id:[ \t]*(\S+)(.*?)(?=^[ \t]*-[ \t]+id:|\z)/gms ) {
        my ( $id, $block ) = ( $1, $2 );
        my %x = ( id => $id, type => 'unknown' );
        $x{type} = $1 if $block =~ /^[ \t]*type:[ \t]*(\S+)/m;
        $x{name} = $1 if $block =~ /^[ \t]*name:[ \t]*(.+?)[ \t]*$/m;
        $x{enabled} = ( $block =~ /^[ \t]*enabled:[ \t]*(?:true|yes|1)[ \t]*$/mi )
            ? JSON::PP::true : JSON::PP::false;
        push @h, \%x;
    }
    return { ok => 1, handlers => \@h };
}

sub _bind_form {
    my ( $form, $handler ) = @_;
    $form    = '' unless defined $form;
    $handler = '' unless defined $handler;
    return { ok => 0, error => 'form and handler are required' } unless length $form && length $handler;
    for my $n ( $form, $handler ) {
        return { ok => 0, error => "invalid name '$n'", kind => 'invalid-path' }
            unless $n =~ /\A[A-Za-z0-9_-]+\z/;
    }
    my $hl = _list_form_handlers();
    return $hl unless $hl->{ok};
    unless ( grep { $_->{id} eq $handler } @{ $hl->{handlers} } ) {
        return { ok => 0, kind => 'not-found',
            error => "no handler '$handler' - call list_form_handlers to see the configured ones" };
    }
    my $dir = "$LAZYSITE_DIR/forms";
    return { ok => 0, error => 'forms directory is missing' } unless -d $dir;
    open my $fh, '>', "$dir/$form.conf" or return { ok => 0, error => "cannot write the form config: $!" };
    print {$fh} "targets:\n  - handler: $handler\n";
    close $fh;
    return { ok => 1, form => $form, handler => $handler, path => "/lazysite/forms/$form.conf" };
}

# MCP tool annotation hints [readOnly, destructive, openWorld]. Required by
# ChatGPT (drives its per-call approval + read/write gating) and good practice
# for every client. openWorld = the action publishes to / changes the live site.
my %ANNOTATE = (
    whoami          => [ 1, 0, 0 ],
    list_files      => [ 1, 0, 0 ],
    read_file       => [ 1, 0, 0 ],
    search_files    => [ 1, 0, 0 ],
    page_status     => [ 1, 0, 0 ],
    list_pages      => [ 1, 0, 0 ],
    read_page       => [ 1, 0, 0 ],
    validate_page   => [ 1, 0, 0 ],
    audit_site      => [ 1, 0, 0 ],
    list_form_handlers => [ 1, 0, 0 ],
    bind_form          => [ 0, 0, 1 ],
    write_file      => [ 0, 0, 1 ],
    replace_text    => [ 0, 0, 1 ],
    copy_file       => [ 0, 0, 1 ],
    get_permissions => [ 1, 0, 0 ],
    move_file       => [ 0, 0, 1 ],
    delete_file     => [ 0, 1, 1 ],
    set_permissions => [ 0, 0, 0 ],
    activate_theme  => [ 0, 0, 1 ],
    activate_layout => [ 0, 0, 1 ],
    invalidate_cache => [ 0, 0, 0 ],
);

sub _tool_names { return [ sort keys %TOOLS ] }

sub tool_list {
    my @list;
    for my $name ( sort keys %TOOLS ) {
        my $a = $ANNOTATE{$name} || [ 0, 0, 1 ];
        push @list, {
            name         => $name,
            description  => $TOOLS{$name}{description},
            inputSchema  => $TOOLS{$name}{inputSchema},
            outputSchema => { type => 'object' },
            annotations  => {
                title           => $name,
                readOnlyHint    => $a->[0] ? JSON::PP::true : JSON::PP::false,
                destructiveHint => $a->[1] ? JSON::PP::true : JSON::PP::false,
                openWorldHint   => $a->[2] ? JSON::PP::true : JSON::PP::false,
            },
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
    my %READ = ( whoami => 1, list_files => 1, read_file => 1, search_files => 1,
        page_status => 1, list_pages => 1, read_page => 1, validate_page => 1, audit_site => 1, list_form_handlers => 1, get_permissions => 1 );
    unless ( $READ{$name} ) {
        my $target = $args->{path} // $args->{from} // $args->{theme} // $args->{layout} // '';
        # Meaningful file-event labels (create/edit/delete/move) to match the
        # manager UI + WebDAV audit vocabulary.
        my $act =
            $name eq 'write_file'   ? ( ( ref $out eq 'HASH' && $out->{created} ) ? 'create' : 'edit' )
          : $name eq 'replace_text' ? 'edit'
          : $name eq 'delete_file'  ? 'delete'
          : $name eq 'move_file'    ? 'move'
          :                           $name;
        my $aok = ref $out eq 'HASH' && $out->{ok};
        my $detail = $aok ? ''
            : ( ref $out eq 'HASH' ? ( $out->{kind} || $out->{error} || '' ) : '' );
        audit_log( $user, $act, $target, $ENV{REMOTE_ADDR} // '',
            ( $aok ? 'ok' : 'fail' ), 'mcp', $detail );
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
