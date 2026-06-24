#!/usr/bin/perl
# lazysite-manager-api.pl - file operations CGI for lazysite manager
use strict;
use warnings;
use Digest::SHA qw(hmac_sha256_hex sha256_hex);
use JSON::PP qw(encode_json decode_json);
use File::Find;
use File::Path qw(make_path);
use File::Basename qw(dirname basename);
use Cwd qw(realpath);
use IPC::Open2;
use Fcntl qw(:flock O_RDWR O_CREAT);
use POSIX qw(strftime);

BEGIN {
    # Locate the Lazysite module tree relative to this script (run-in-place,
    # tar and Hestia installs), falling back to the system @INC (package
    # installs). No configuration needed.
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}
use Lazysite::Util qw(log_event const_eq);
use Lazysite::Auth::Acl qw(load_acls save_acls _acl_norm _to_list _acl_allows _is_operator _acl_denied);
use Lazysite::Auth::Session qw(generate_csrf_token verify_csrf_token);
use Lazysite::Manager::Common qw(validate_path is_blocked_path write_file_checked respond
    is_blocked_config is_blocked_upload_target upload_limits load_upload_limits _reset_upload_limits_cache
    _write_conf_key);
use Lazysite::Manager::Upload qw(action_file_upload action_file_download action_file_zip_download
    check_upload_rate is_editable_text);
use Lazysite::Manager::Plugins qw(action_plugin_list action_plugin_enable action_plugin_disable
    action_plugin_read action_plugin_save action_plugin_action action_handler_list
    action_handler_save action_handler_delete action_form_targets_read action_form_targets_save);
use Lazysite::Manager::Files qw(action_list action_read action_save action_delete action_mkdir
    action_move acquire_lock release_lock renew_lock _get_lock_info
    action_acl_get action_acl_set action_acl_remove);
use Lazysite::Manager::Themes qw(action_theme_list action_themes_list_all action_theme_activate
    action_layout_activate action_theme_delete action_theme_rename action_theme_upload
    action_cache_list action_cache_invalidate _read_active_layout_and_theme
    action_artifact_manifest action_artifact_validate);
use Lazysite::Manager::Layouts qw(action_layouts_releases action_layouts_install
    action_layouts_release_contents action_layouts_available action_themes_for_layout
    action_layouts_repo_get action_layouts_repo_set);
$Lazysite::Util::COMPONENT = 'manager-api';

my $DOCROOT      = $ENV{DOCUMENT_ROOT} // die "No DOCUMENT_ROOT\n";
$Lazysite::Auth::Acl::DOCROOT = $DOCROOT;
$Lazysite::Manager::Common::DOCROOT = $DOCROOT;
$Lazysite::Manager::Upload::DOCROOT = $DOCROOT;
$Lazysite::Manager::Plugins::DOCROOT = $DOCROOT;
$Lazysite::Manager::Files::DOCROOT = $DOCROOT;
$Lazysite::Manager::Themes::DOCROOT = $DOCROOT;
$Lazysite::Manager::Layouts::DOCROOT = $DOCROOT;
my $LAZYSITE_DIR = "$DOCROOT/lazysite";
$Lazysite::Auth::Session::LAZYSITE_DIR = $LAZYSITE_DIR;
$Lazysite::Manager::Upload::LAZYSITE_DIR = $LAZYSITE_DIR;
$Lazysite::Manager::Themes::LAZYSITE_DIR = $LAZYSITE_DIR;
$Lazysite::Manager::Layouts::LAZYSITE_DIR = $LAZYSITE_DIR;
$Lazysite::Manager::Artifact::LAZYSITE_DIR = $LAZYSITE_DIR;
my $LOCK_DIR     = "$LAZYSITE_DIR/manager/locks";
my $LOCK_TIMEOUT = 300;
$Lazysite::Manager::Files::LOCK_DIR     = $LOCK_DIR;
$Lazysite::Manager::Files::LOCK_TIMEOUT = $LOCK_TIMEOUT;

# SM071 Phase 1: theme/layout preview. preview-grant mints the signed
# cookie the processor verifies; declared here (before dispatch runs) so
# the action subs see initialised values.
my $PREVIEW_COOKIE = 'lzs_preview';
my $PREVIEW_TTL    = 3600;   # 1 hour

# SM019: download Content-Type table. Unknown extensions fall back to
# application/octet-stream so the browser treats the body as raw bytes.

# SM019: extensions treated as editable text by the manager editor.
# Paths whose extension is not listed here are treated as binary and
# the editor shows a download panel instead of CodeMirror. Dotfiles
# like .htaccess match the regex with "htaccess" as the extension,
# which is not in this list, so they are treated as binary. That is
# intentional - a browser textarea is the wrong tool for .htaccess.

# SM019: unit-test hook. When set, `do "lazysite-manager-api.pl"` from a
# test returns after the lexicals are initialised but before the auth
# check, request parsing, and dispatch, so tests can exercise helper
# subs directly (parse_multipart_body, detect_content_type, etc.)
# without spawning a subprocess. Has no effect in normal CGI use.
return 1 if $ENV{LAZYSITE_API_LOAD_ONLY};

# --- Auth check ---

# Read manager_groups from lazysite.conf to determine if auth is required
my $manager_groups_conf = '';
if ( open my $cfh, '<', "$LAZYSITE_DIR/lazysite.conf" ) {
    while (<$cfh>) {
        $manager_groups_conf = $1 if /^manager_groups\s*:\s*(.+)/;
    }
    close $cfh;
}
$manager_groups_conf =~ s/^\s+|\s+$//g;

# SM071 Phase 3: control-API token front-path. A request authenticated by
# Authorization: Basic <user>:<lzs_ token> carries no session cookie; it is
# verified against the user database (via the users tool, which owns the
# hashing), gated per-action by capability (below), and exempt from the
# CSRF check (no cookie ⇒ no ambient authority ⇒ no CSRF vector).
my $auth_user;
my $token_auth = 0;
my %token_caps;
{
    my $hdr = $ENV{HTTP_AUTHORIZATION} // '';
    if ( $hdr =~ /^Basic\s+(\S+)/ ) {
        require MIME::Base64;
        my ( $u, $secret ) = split /:/,
            ( MIME::Base64::decode_base64($1) // '' ), 2;
        if ( defined $u && defined $secret && $secret =~ /^lzs_/ ) {
            # A token request must not also carry a session cookie, so the
            # CSRF exemption can never be used to ride a browser session.
            if ( length( $ENV{HTTP_X_REMOTE_USER} // '' ) ) {
                respond({ ok => 0, error => 'Do not combine cookie and token auth' });
                exit 0;
            }
            my $v = users_api({ action => 'verify-credential',
                                username => $u, secret => $secret });
            unless ( $v && $v->{ok} ) {
                sleep 1;   # brute-force delay (per-IP limiter lands in P3.6)
                respond({ ok => 0, error => 'Invalid credentials' });
                exit 0;
            }
            $auth_user  = $u;
            $token_auth = 1;
            %token_caps = %{ $v->{settings} || {} };
        }
    }
}

# Cookie (manager) auth: the trusted X-Remote-User set by the auth wrapper.
unless ( $token_auth ) {
    $auth_user = $ENV{HTTP_X_REMOTE_USER} // '';
    if ( $manager_groups_conf && !$auth_user ) {
        respond({ ok => 0, error => "Authentication required" });
        exit 0;
    }
    $auth_user ||= 'local';
}

# --- Parse request ---

my %params;
for my $pair ( split /&/, $ENV{QUERY_STRING} // '' ) {
    my ( $k, $v ) = split /=/, $pair, 2;
    next unless defined $k;
    $k =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    $v //= '';
    $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    $v =~ s/\+/ /g;
    $params{$k} = $v;
}

my $action = $params{action} // '';
my $path   = $params{path}   // '/';
# Mirror the per-request context into Manager::Common for log attribution.
$Lazysite::Manager::Common::action    = $action;
$Lazysite::Manager::Common::auth_user = $auth_user;
$Lazysite::Manager::Upload::auth_user = $auth_user;
$Lazysite::Manager::Plugins::action   = $action;
$Lazysite::Manager::Files::auth_user  = $auth_user;
$Lazysite::Manager::Files::action     = $action;
$Lazysite::Manager::Themes::auth_user = $auth_user;
$Lazysite::Manager::Themes::action    = $action;
$Lazysite::Manager::Layouts::auth_user = $auth_user;
$Lazysite::Manager::Layouts::action    = $action;
$Lazysite::Auth::Acl::auth_user            = $auth_user;
$Lazysite::Auth::Acl::token_auth           = $token_auth;
$Lazysite::Auth::Acl::manager_groups_conf  = $manager_groups_conf;
# SM077: requester's groups for @group ACL entries (cookie users carry them in
# X-Remote-Groups; token partners carry none, so a @group never matches them).
@Lazysite::Auth::Acl::user_groups = grep { length } split /[,\s]+/, ( $ENV{HTTP_X_REMOTE_GROUPS} // '' );

my $body = '';
if ( ( $ENV{REQUEST_METHOD} // '' ) eq 'POST' ) {
    my $len = $ENV{CONTENT_LENGTH} // 0;

    # SM019: size + rate-limit gate for file-upload. Runs before the
    # body read so oversize or rate-exceeding requests are rejected
    # without allocating the body. Other POST actions carry small JSON
    # bodies and fall through to the normal read.
    if ( ( $params{action} // '' ) eq 'file-upload' ) {
        my $max = upload_limits()->{max_bytes};
        if ( $len > $max ) {
            log_event( 'WARN', 'file-upload', 'upload too large',
                size => $len, max => $max, user => $auth_user );
            respond({ ok => 0,
                error => "Upload exceeds limit of "
                       . int( $max / 1024 / 1024 ) . " MB" });
            exit 0;
        }
        my $rate = check_upload_rate( $auth_user, $len );
        unless ( $rate->{ok} ) {
            respond({ ok => 0, error => $rate->{error} });
            exit 0;
        }
    }

    read( STDIN, $body, $len ) if $len > 0;
}

# --- M-1: CSRF gate on write actions --------------------------------
# The gate is keyed on HTTP method, not action name. Every write action
# in this script is dispatched via POST; reads (list, cache-list,
# theme-list, plugin-list, nav-read, handler-list, form-targets-read,
# csrf-token itself, etc.) come in over GET and do not need a token.
# Going by method rather than an action allowlist means we cannot
# accidentally leave a new read action out of the list.
my $method = $ENV{REQUEST_METHOD} // 'GET';
if ( $method eq 'POST' && !$token_auth ) {
    # Token can arrive via (in order of preference):
    #   - X-CSRF-Token header (HTTP_X_CSRF_TOKEN env var) - works for any
    #     body type including raw binary uploads (theme-upload).
    #   - csrf_token field in a JSON body - convenient for existing
    #     apiCall() patterns that send JSON.
    #   - csrf_token query-string parameter - last-resort fallback for
    #     sendBeacon() calls that cannot set headers.
    my $token = $ENV{HTTP_X_CSRF_TOKEN} // '';
    my $source = $token ? 'header' : '';
    if ( !$token && $body ) {
        my $parsed = eval { decode_json($body) };
        if ( ref $parsed eq 'HASH' ) {
            $token = $parsed->{csrf_token} // '';
            $source = 'body' if $token;
        }
    }
    if ( !$token ) {
        $token  = $params{csrf_token} // '';
        $source = 'query' if $token;
    }

    log_event('DEBUG', $action, 'CSRF check',
        method    => $method,
        user      => $auth_user,
        token_len => length($token),
        source    => $source || 'none',
        result    => $token ? 'has-token' : 'no-token');

    my $valid = verify_csrf_token( $token, $auth_user );

    log_event('DEBUG', $action, 'CSRF verify',
        user   => $auth_user,
        result => $valid ? 'ok' : 'fail');

    unless ( $valid ) {
        respond({ ok => 0, error => 'Invalid or missing CSRF token' });
        exit 0;
    }
}

# Per-action csrf-token read
if ( $action eq 'csrf-token' ) {
    respond({ ok => 1, token => generate_csrf_token($auth_user) });
    exit 0;
}

# SM071 Phase 3: token clients are confined to the control-API action set
# and gated by capability. Cookie (manager) requests are unaffected and
# keep their existing manager-group authorisation.
if ( $token_auth ) {
    my %need = (
        'artifact-manifest' => sub { $_[0]->{manage_themes} || $_[0]->{manage_layouts} },
        'artifact-validate' => sub { $_[0]->{manage_themes} || $_[0]->{manage_layouts} },
        'theme-activate'    => sub { $_[0]->{manage_themes} },
        'layout-activate'   => sub { $_[0]->{manage_layouts} },
        'preview-grant'     => sub { $_[0]->{manage_themes} || $_[0]->{manage_layouts} },
        'config-set'        => sub { $_[0]->{manage_config} },
        'whoami'            => sub { 1 },   # any authenticated token may introspect its own grant
        # SM074: a publishing partner manages ACLs on the content it owns.
        'acl-get'           => sub { $_[0]->{webdav} },
        'acl-set'           => sub { $_[0]->{webdav} },
        'acl-remove'        => sub { $_[0]->{webdav} },
    );
    my $check = $need{$action};
    unless ($check) {
        respond({ ok => 0, error => "Action not available to token clients: $action" });
        exit 0;
    }
    unless ( $check->( \%token_caps ) ) {
        respond({ ok => 0, error => "Insufficient capability for $action" });
        exit 0;
    }

    # SM071 Phase 3 (P3.6): per-token volume throttle. 429 + Retry-After
    # so the client can back off per the documented retry contract.
    my $rl = _rate_ok($auth_user);
    unless ( $rl->{ok} ) {
        binmode( STDOUT, ':utf8' );
        print "Status: 429 Too Many Requests\r\n";
        print "Retry-After: $rl->{retry_after}\r\n";
        print "Content-Type: application/json; charset=utf-8\r\n\r\n";
        print encode_json({ ok => 0, error => 'Rate limit exceeded' });
        exit 0;
    }
}

# --- Dispatch ---

my $result;
if    ( $action eq 'list' )             { $result = action_list($path) }
elsif ( $action eq 'read' )             { $result = action_read($path, $auth_user) }
elsif ( $action eq 'save' )             {
    my $req = eval { decode_json($body) } // {};
    $result = action_save( $path, $auth_user, $req->{content}, $req->{mtime} );
}
elsif ( $action eq 'delete' )           { $result = action_delete( $path, $auth_user ) }
elsif ( $action eq 'acl-get' )          { $result = action_acl_get( $path, $auth_user ) }
elsif ( $action eq 'acl-set' )          {
    my $req = eval { decode_json($body) } // {};
    $result = action_acl_set( $path, $auth_user,
        $req->{read}, $req->{write}, $req->{owner} );
}
elsif ( $action eq 'acl-remove' )       { $result = action_acl_remove( $path, $auth_user ) }
elsif ( $action eq 'mkdir' )            { $result = action_mkdir($path) }
elsif ( $action eq 'move' )             { $result = action_move( $path, $params{to}, $auth_user ) }
elsif ( $action eq 'lock' )             { $result = acquire_lock( $path, $auth_user ) }
elsif ( $action eq 'unlock' )           { $result = release_lock( $path, $auth_user ) }
elsif ( $action eq 'renew-lock' )       { $result = renew_lock( $path, $auth_user ) }
elsif ( $action eq 'preview' )          { $result = action_preview($path) }
elsif ( $action eq 'cache-list' )       { $result = action_cache_list() }
elsif ( $action eq 'cache-invalidate' ) { $result = action_cache_invalidate($path) }
elsif ( $action eq 'config-set' )       {
    my $req = eval { decode_json($body) } // {};
    $result = action_config_set(
        ( defined $req->{key}   ? $req->{key}   : $params{key} ),
        ( defined $req->{value} ? $req->{value} : $params{value} ) );
}
elsif ( $action eq 'theme-list' )       { $result = action_theme_list() }
elsif ( $action eq 'themes-list-all' )  { $result = action_themes_list_all() }
elsif ( $action eq 'theme-activate' )   { $result = action_theme_activate($path, \%params) }
elsif ( $action eq 'layout-activate' )  { $result = action_layout_activate($path, \%params) }
elsif ( $action eq 'theme-delete' )     { $result = action_theme_delete($path) }
elsif ( $action eq 'theme-rename' )     {
    my $req = eval { decode_json($body) } // {};
    $result = action_theme_rename( $path, $req->{new_name} );
}
elsif ( $action eq 'theme-upload' )     { $result = action_theme_upload( $body, $params{filename} ) }
elsif ( $action eq 'layouts-releases' ) { $result = action_layouts_releases() }
elsif ( $action eq 'layouts-install' )  { $result = action_layouts_install($body) }
elsif ( $action eq 'layouts-release-contents' ) {
    $result = action_layouts_release_contents( $params{tag} );
}
elsif ( $action eq 'layouts-available' ) { $result = action_layouts_available() }
elsif ( $action eq 'themes-for-layout' ) { $result = action_themes_for_layout( $params{layout} ) }
elsif ( $action eq 'layouts-repo-get' )  { $result = action_layouts_repo_get() }
elsif ( $action eq 'layouts-repo-set' )  {
    my $req = eval { decode_json($body) } // {};
    $result = action_layouts_repo_set( $req->{value} );
}
elsif ( $action eq 'users' )            { $result = action_users( $body, \%params ) }
elsif ( $action eq 'principals' )       { $result = action_principals() }
elsif ( $action eq 'rotate-auth-secret' ) { $result = action_rotate_auth_secret( $auth_user ) }
elsif ( $action eq 'plugin-list' )      { $result = action_plugin_list() }
elsif ( $action eq 'plugin-enable' )    {
    my $req = eval { decode_json($body) } // {};
    $result = action_plugin_enable($req->{script});
}
elsif ( $action eq 'plugin-disable' )   {
    my $req = eval { decode_json($body) } // {};
    $result = action_plugin_disable($req->{script});
}
elsif ( $action eq 'plugin-read' )      {
    my $req = eval { decode_json($body) } // {};
    $result = action_plugin_read( $params{plugin}, $req->{script} );
}
elsif ( $action eq 'plugin-save' )      {
    my $req = eval { decode_json($body) } // {};
    $result = action_plugin_save( $params{plugin}, $req->{script}, $req->{values} // {} );
}
elsif ( $action eq 'plugin-action' )    {
    my $req = eval { decode_json($body) } // {};
    $result = action_plugin_action( $params{plugin}, $req->{script}, $req->{action_id} );
}
elsif ( $action eq 'nav-read' )         { $result = action_nav_read() }
elsif ( $action eq 'nav-save' )         {
    my $req = eval { decode_json($body) } // {};
    $result = action_nav_save( $req->{items} // [] );
}
elsif ( $action eq 'handler-list' )     { $result = action_handler_list() }
elsif ( $action eq 'version' )          { $result = action_version() }
elsif ( $action eq 'whoami' )           { $result = action_whoami($auth_user) }
elsif ( $action eq 'audit' )            { $result = action_audit( user => $params{user}, target => $params{target} ) }
elsif ( $action eq 'handler-save' )     {
    my $req = eval { decode_json($body) } // {};
    $result = action_handler_save($req);
}
elsif ( $action eq 'handler-delete' )   {
    my $req = eval { decode_json($body) } // {};
    $result = action_handler_delete( $req->{id} );
}
elsif ( $action eq 'form-targets-read' ) {
    $result = action_form_targets_read( $params{form} );
}
elsif ( $action eq 'form-targets-save' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_form_targets_save( $params{form}, $req->{targets} // [] );
}
elsif ( $action eq 'file-upload' ) {
    $result = action_file_upload( $path, $body );
}
elsif ( $action eq 'file-download' ) {
    action_file_download($path);
    exit 0;
}
elsif ( $action eq 'file-zip-download' ) {
    action_file_zip_download();
    exit 0;
}
elsif ( $action eq 'preview-grant' ) {
    action_preview_grant( \%params );
    exit 0;
}
elsif ( $action eq 'preview-clear' ) {
    action_preview_clear();
    exit 0;
}
elsif ( $action eq 'artifact-manifest' ) { $result = action_artifact_manifest( \%params ) }
elsif ( $action eq 'artifact-validate' ) { $result = action_artifact_validate( \%params ) }
else  { $result = { ok => 0, error => "Unknown action: $action" } }

# SM072 audit trail: record state-changing (POST) requests to a
# manager-readable log - who did what, TO WHAT (SM078), when, from where, and
# the outcome. The target is the path for content/ACL/theme/layout ops, or the
# config key for config-set.
if ( ( $ENV{REQUEST_METHOD} // '' ) eq 'POST' && $action ne 'csrf-token' ) {
    my $target = $action eq 'config-set' ? ( $params{key} // '' ) : ( $path // '' );
    audit_log( $auth_user, $action, $target, $ENV{REMOTE_ADDR} // '',
        ( ref $result eq 'HASH' && $result->{ok} ) ? 'ok' : 'fail',
        $token_auth ? 'api' : 'ui' );
}

respond($result);

# --- M-1: CSRF helpers ---

# Shared secret for CSRF token HMAC. Reuses the auth secret if present,
# otherwise creates a dedicated manager secret under lazysite/auth/.




# --- SM071 Phase 1: theme/layout preview minting ---
#
# preview-grant mints the signed lzs_preview cookie the processor
# verifies (see lazysite-processor.pl check_preview). Same primitive as
# the auth cookie: payload ":" hmac_sha256_hex over lazysite/auth/.secret.
# Manager-only (behind the manager auth + CSRF gate). A valid cookie tells
# the processor to render that session against the named layout/theme,
# uncacheable. Payload: v1:<exp-epoch>:<layout>:<theme>:<user>.

# Read (or mint) the per-install auth secret - the same file the auth
# wrapper and the processor's preview verifier use. Fail closed without
# a CSPRNG.
sub _preview_secret {
    my $path = "$LAZYSITE_DIR/auth/.secret";
    if ( -f $path && open my $fh, '<', $path ) {
        chomp( my $s = <$fh> );
        close $fh;
        return $s if length $s;
    }
    make_path("$LAZYSITE_DIR/auth") unless -d "$LAZYSITE_DIR/auth";
    open my $rand, '<:raw', '/dev/urandom'
        or die "Cannot open /dev/urandom - no CSPRNG available: $!\n";
    my $raw = '';
    my $got = read( $rand, $raw, 32 );
    close $rand;
    die "Short read from /dev/urandom\n" unless $got == 32;
    my $s = unpack( 'H*', $raw );
    open my $wfh, '>', $path or die "Cannot write $path: $!\n";
    chmod 0o600, $path;
    print $wfh "$s\n";
    close $wfh;
    return $s;
}

sub action_preview_grant {
    my ($p) = @_;
    my $layout = $p->{layout} // '';
    my $theme  = $p->{theme}  // '';

    unless ( $layout =~ /^[A-Za-z0-9_-]+$/ ) {
        respond({ ok => 0, error => 'Invalid or missing layout' });
        return;
    }
    unless ( $theme =~ /^[A-Za-z0-9_-]*$/ ) {
        respond({ ok => 0, error => 'Invalid theme' });
        return;
    }

    # The layout must exist; a named theme must exist under it. An empty
    # theme means "preview the layout, no theme styling". This stops the
    # manager handing out a preview of something that cannot render.
    unless ( -f "$LAZYSITE_DIR/layouts/$layout/layout.tt" ) {
        respond({ ok => 0, error => "No such layout: $layout" });
        return;
    }
    if ( length $theme
        && !-f "$LAZYSITE_DIR/layouts/$layout/themes/$theme/theme.json" ) {
        respond({ ok => 0, error => "No such theme: $theme" });
        return;
    }

    # Cookie-safe user field (no CRLF / header injection); the processor
    # records but does not re-validate it.
    ( my $user = $auth_user ) =~ s/[^A-Za-z0-9_.\@-]//g;

    my $exp     = time() + $PREVIEW_TTL;
    my $payload = "v1:$exp:$layout:$theme:$user";
    my $sig     = hmac_sha256_hex( $payload, _preview_secret() );
    my $value   = "$payload:$sig";
    my $secure  = $ENV{HTTPS} ? '; Secure' : '';

    log_event( 'INFO', 'preview-grant', 'preview granted',
        layout => $layout, theme => $theme, user => $auth_user );

    binmode( STDOUT, ':utf8' );
    print "Status: 200 OK\r\n";
    print "Set-Cookie: $PREVIEW_COOKIE=$value; HttpOnly; SameSite=Lax; Path=/; Max-Age=$PREVIEW_TTL$secure\r\n";
    # Non-HttpOnly UI marker so the manager can show/hide "Stop preview".
    # Carries no auth value - the signed HttpOnly cookie above is the gate.
    print "Set-Cookie: ${PREVIEW_COOKIE}_active=1; SameSite=Lax; Path=/; Max-Age=$PREVIEW_TTL$secure\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json({ ok => 1, layout => $layout, theme => $theme, expires => $exp });
}

sub action_preview_clear {
    my $secure = $ENV{HTTPS} ? '; Secure' : '';
    log_event( 'INFO', 'preview-clear', 'preview cleared', user => $auth_user );
    binmode( STDOUT, ':utf8' );
    print "Status: 200 OK\r\n";
    print "Set-Cookie: $PREVIEW_COOKIE=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0$secure\r\n";
    print "Set-Cookie: ${PREVIEW_COOKIE}_active=; SameSite=Lax; Path=/; Max-Age=0$secure\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json({ ok => 1 });
}

# --- SM071 Phase 3: control-API helpers ---

# SM071 Phase 3 (P3.6): per-token volume token-bucket, shared with the
# DAV endpoint (same store + format, keyed by user) so one identity has
# one bucket across both surfaces. Defaults burst 200 / refill 20/s,
# overridable via env for tuning and tests. Fails open on any IO error.
sub _rate_ok {
    my ($key) = @_;
    my $burst = defined $ENV{LAZYSITE_RATE_BURST}  ? $ENV{LAZYSITE_RATE_BURST}  : 200;
    my $rate  = defined $ENV{LAZYSITE_RATE_REFILL} ? $ENV{LAZYSITE_RATE_REFILL} : 20;
    return { ok => 1 } if $burst <= 0;
    my $path = "$LAZYSITE_DIR/auth/.token-rate.json";
    make_path("$LAZYSITE_DIR/auth") unless -d "$LAZYSITE_DIR/auth";
    sysopen( my $fh, $path, O_RDWR | O_CREAT, 0600 ) or return { ok => 1 };
    flock( $fh, LOCK_EX );
    my $raw  = do { local $/; <$fh> };
    my $data = eval { decode_json( $raw || '{}' ) };
    $data = {} unless ref $data eq 'HASH';
    my $now    = time();
    my $b      = $data->{$key} || { tokens => $burst, last => $now };
    my $tokens = $b->{tokens} + ( $now - ( $b->{last} // $now ) ) * $rate;
    $tokens = $burst if $tokens > $burst;
    my ( $allow, $retry ) = ( 0, 0 );
    if ( $tokens >= 1 ) { $tokens -= 1; $allow = 1 }
    else { $retry = $rate > 0 ? int( ( 1 - $tokens ) / $rate ) + 1 : 60 }
    $data->{$key} = { tokens => $tokens, last => $now };
    seek( $fh, 0, 0 ); truncate( $fh, 0 ); print $fh encode_json($data);
    flock( $fh, LOCK_UN ); close $fh;
    return $allow ? { ok => 1 } : { ok => 0, retry_after => $retry };
}

# Resolve the user-management tool across install layouts (cgi-bin sibling
# of tools/ in production; repo root in tests). LAZYSITE_USERS_TOOL wins.
sub _users_tool_path {
    for my $c (
        $ENV{LAZYSITE_USERS_TOOL},
        dirname($0) . "/../tools/lazysite-users.pl",
        dirname($0) . "/tools/lazysite-users.pl",
        "$DOCROOT/../tools/lazysite-users.pl",
    ) {
        return $c if defined $c && -f $c;
    }
    return undef;
}

# Run a request against tools/lazysite-users.pl --api and return the
# decoded response (used by the token front-path's verify-credential).
sub users_api {
    my ($payload) = @_;
    my $script = _users_tool_path();
    return { ok => 0, error => 'user management unavailable' } unless $script;
    my ( $out, $in );
    my $pid = eval { open2( $out, $in, $^X, $script, '--api', '--docroot', $DOCROOT ) };
    return { ok => 0, error => 'cannot run user management' } unless $pid;
    print $in encode_json($payload);
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return eval { decode_json( $resp // '{}' ) } // { ok => 0, error => 'invalid response' };
}

# Resolve a theme/layout artifact directory from request params.

# Content-hash manifest of a theme/layout: { relpath => {sha256,size} }.

# Content manifest of a directory: { relpath => { sha256, size } }.


# Dry-run validation of a theme/layout (the activate gate, P3.4 reuses it).
# Theme: theme.json present with a non-empty layouts[]. Layout: layout.tt
# present (the TT-compile check is added in P3.5).

# --- Response ---


# --- Path validation ---



# SM020: every manager write path that previously did
# open/print/close had the same ENOSPC/EIO/quota blind spot.
# Centralised here so a future site gets the checked pattern by
# default. unlink-on-failure is deliberate: a half-written
# handlers.conf or nav.conf breaks every subsequent form
# submission or page render, which is worse than no file at all
# - the operator can restore from backup or re-save from the UI.
# Returns ($ok, $error_string). $! is captured into a lexical
# before close because close itself resets $!.

# --- Lock management ---

# SM070: lock records are shared with lazysite-dav.pl. On-disk format
# is a JSON object {user,at,origin,token,timeout,owner}; a legacy
# single-line "user epoch" file (pre-SM070 manager locks) is read as
# an origin=manager record. This lets the manager editor and WebDAV
# clients see each other's locks through one store.






# --- File actions ---


# SM074: per-file ACLs. Ownership + read/write allowlists live in one
# central store, lazysite/auth/acls.json (keyed by the content-relative
# path), not in per-file sidecars - so the content tree stays uncluttered.
# Operators (manager group, or 'local' when unsecured) administer
# everything; otherwise access follows the owner + allowlists. The store is
# read by the dav for enforcement and written here via the acl-* actions.




# Normalise a list value (arrayref or comma/space string) to an arrayref,
# or undef if not provided.



# Returns an error hashref if $user may not access $rel in $mode
# ('read'|'write'), else undef. Operators always pass.

# --- SM074 ACL management actions (manager + control API) ----------------






# SM019b: dedicated mkdir so "Add Folder" creates a genuinely empty
# directory. The previous files.md trick of writing /<name>/.gitkeep
# through action_save materialised the directory but left a hidden
# file inside, which conflicts with the new "empty dirs are
# deletable" rule - a freshly-created folder would not have a
# checkbox. Keeping this as a distinct action (rather than piggybacking
# on action_save with an empty body) also makes the log line clearer.

sub action_preview {
    my ($rel_path) = @_;

    my $uri = $rel_path;
    $uri =~ s{^/*}{/};
    $uri =~ s/\.md$//;
    $uri =~ s{/index$}{/};

    local $ENV{LAZYSITE_NOCACHE}  = '1';
    local $ENV{REDIRECT_URL}      = $uri;
    local $ENV{DOCUMENT_ROOT}     = $DOCROOT;

    my $processor = "$DOCROOT/../cgi-bin/lazysite-processor.pl";
    $processor = $ENV{LAZYSITE_PROCESSOR} if $ENV{LAZYSITE_PROCESSOR};
    my $output = qx($^X \Q$processor\E 2>/dev/null);

    # Strip CGI headers
    $output =~ s/\A.*?\r?\n\r?\n//s;

    return { ok => 1, html => $output };
}

# --- Cache actions ---



# --- Theme actions ---

# D013: read both the active layout: and theme: values from
# lazysite.conf. Used by every theme action to locate the nested
# themes directory under the active layout.


# SM068: list every installed theme across all layouts, not only
# the active one. The Installed Themes panel on /manager/themes
# uses this to show themes grouped by layout — themes for the
# active layout are activatable; themes for other layouts are
# shown for visibility but with no Activate button.
#
# Shape matches action_theme_list where possible but adds a
# `layout` field per entry (action_theme_list implies it from the
# top-level active layout).

# SM071 Phase 3: activate-with-backup. Validates the candidate, optionally
# enforces an optimistic-concurrency base manifest (409 on drift), takes an
# artifact-level lock for the transition, snapshots the outgoing live theme
# (for back-out) with retention, then flips the pointer and drops the cache.

# Rewrite the theme: pointer in conf and invalidate the page cache.


# Theme validity gate: theme.json present + valid JSON + layouts[] declares
# the active layout. { valid => 0/1, errors => [...] }.

# Snapshot an artifact dir as <name>-backup-<UTCstamp> alongside it, for
# back-out (the snapshot is itself a selectable theme).

# Keep the newest backup_retention snapshots of $name; remove older ones.
# Names embed a UTC stamp, so a lexical sort is chronological.


# SM071 Phase 3 (P3.5): activate a layout. Reuses the activate-with-backup
# machinery, adds the layout-specific rules: layout.tt must compile, and
# the resulting (layout, theme) pair must be compatible - either the
# current theme declares the new layout, or a compatible theme is named.

# Rewrite the layout: pointer (and theme: when a theme is given), then
# invalidate the page cache.

# Layout validity gate: layout.tt present and parses as Template Toolkit.
# The compile check is best-effort - if Template::Parser is unavailable
# we fall back to the presence check rather than blocking.

# Does the theme declare compatibility with the layout (theme.json layouts[])?




# D013: install a theme from an already-extracted directory. Themes
# declare compatible layouts via theme.json's layouts[] array; we
# install a copy under each declared layout at
# {DOCROOT}/lazysite/layouts/LAYOUT/themes/THEME/ and duplicate
# assets at {DOCROOT}/lazysite-assets/LAYOUT/THEME/. DP-C: missing
# layouts[] is a strict reject.


# SM060: install a layout from $layout_source (the extracted
# zipball's $wrapper/layouts/LAYOUT/ directory). Called by
# action_layouts_install before each LAYOUT's theme walk, so
# _install_theme_from_dir's target-site check
# (layouts/LAYOUT/layout.tt must exist) passes for themes shipping
# in the same release as their target layout.
#
# Collision policy: skip-if-identical, refuse-if-different. Byte
# comparison across every file the release would write. Any content
# difference is an operator edit we won't clobber.
#
# Return actions:
#   'installed'         - new install, files copied
#   'already_installed' - on-disk files byte-match the release
# Or ok=0 with error:
#   - 'missing layout.tt in release'
#   - 'already installed and differs; refusing to overwrite (LIST)'


# --- SM037 + D013: layouts-releases browser + release installer ---
# The external repo is lazysite-layouts; the config key and function
# names rename accordingly. The action remains a theme-browser (SM037
# scope) — it walks release zipballs for theme.json-bearing subdirs
# and invokes _install_theme_from_dir on each.




# SM068: write-or-replace a single key in lazysite.conf. Same
# replace-or-append pattern as action_plugin_save and
# action_layouts_repo_set, kept as a small helper so the
# auto-set-on-install path isn't a third copy. Empty value is
# rejected (callers should skip rather than write an empty key).


# SM072 §13 / control API: set an allowlisted site-config key in
# lazysite.conf. The allowlist is deliberately narrow - benign display /
# behaviour keys only, NEVER privilege-relevant keys (manager_groups,
# plugins, auth_default) or ones with dedicated actions (layout/theme via
# theme-activate/layout-activate). Gated on manage_config by %need.
# (Defined inside the sub: the dispatch runs above this point in the file,
# so a file-level `my` initialised here would still be empty at call time.)
sub action_config_set {
    my ( $key, $value ) = @_;
    my %allow = map { $_ => 1 } qw(site_name site_url search_default);
    $key = '' unless defined $key;
    return { ok => 0, error => "Config key '$key' is not settable via the API" }
        unless $allow{$key};
    return { ok => 0, error => "A value is required" }
        unless defined $value && length $value;
    return { ok => 0, error => "Value must be a single line" }
        if $value =~ /[\r\n]/;
    _write_conf_key( $key, $value )
        or return { ok => 0, error => "Could not write lazysite.conf" };
    log_event( 'INFO', 'config-set', 'config key set', key => $key, user => $auth_user );
    return { ok => 1, key => $key, value => $value };
}

# SM056: fetch a single release zipball and walk
# layouts/LAYOUT/themes/THEME/theme.json, returning a flat array of
# {layout, name, description} entries. Lazy: UI calls this per
# release on an explicit "show contents" click, NOT for every
# release in the listing. Does NOT install anything.
#
# Shares fetch + extract shape with action_layouts_install but
# stops before the install step and doesn't enforce source-path
# consistency — contents-preview is operator-informational, not
# contract-enforcing.

# --- SM044: dropdown population + layouts_repo read/write ---
#
# layouts-available / themes-for-layout feed the config-page
# dropdowns for the active layout and active theme. layouts-repo-get /
# layouts-repo-set surface the layouts_repo lazysite.conf key on the
# /manager/themes page, so operators don't have to hand-edit the conf
# just to point the release browser at a different repo.
#
# Scans are filesystem directory reads; not cached. N is small (<10
# for typical installs).





# --- User management proxy ---

# SM072: capabilities the site provides, collected from the `provides`
# field of ENABLED plugins (e.g. form-smtp provides 'email-send'). Lets
# other code detect whether the site can, say, send email.
sub site_capabilities {
    my %caps;
    my $pl = action_plugin_list() || {};
    for my $p ( @{ $pl->{plugins} || [] } ) {
        next unless $p->{_enabled} && ref $p->{provides} eq 'ARRAY';
        $caps{$_} = 1 for @{ $p->{provides} };
    }
    return [ sort keys %caps ];
}

# SM072: agent introspection. Returns the CALLER's grant (capabilities,
# groups, scope) and what the site offers (plugins with status, layouts and
# themes with their active flags) - so an agent learns its real grant rather
# than parsing the bootstrap prose. Allowed for any authenticated caller.
sub action_whoami {
    my ($user) = @_;
    my $s = ( users_api({ action => 'settings-get', username => $user }) || {} )->{settings} || {};

    my $allg = ( users_api({ action => 'groups' }) || {} )->{groups} || {};
    my @groups = sort grep {
        ref $allg->{$_} eq 'ARRAY' && ( grep { $_ eq $user } @{ $allg->{$_} } )
    } keys %$allg;

    my ( $active_layout, $active_theme ) = _read_active_layout_and_theme();
    my $bool = sub { $_[0] ? JSON::PP::true() : JSON::PP::false() };

    return {
        ok      => 1,
        partner => $user,
        capabilities => {
            webdav           => $bool->( $s->{webdav} ),
            ui               => $bool->( !( exists $s->{ui} && !$s->{ui} ) ),
            manage_themes    => $bool->( $s->{manage_themes} ),
            manage_layouts   => $bool->( $s->{manage_layouts} ),
            manage_config    => $bool->( $s->{manage_config} ),
            create_sub_users => $bool->( $s->{create_sub_users} ),
        },
        groups => \@groups,
        scope  => {
            allow => ( defined $s->{dav_scope} && length $s->{dav_scope} ) ? $s->{dav_scope} : '/',
            deny  => [ '/cgi-bin/', '/manager/', '/lazysite/auth/',
                       '/lazysite/forms/smtp.conf', '/lazysite/forms/handlers.conf',
                       '/lazysite/forms/submissions/', '/lazysite/cache/',
                       '/lazysite/logs/', '/lazysite/manager/',
                       '/lazysite/templates/', '/lazysite/lazysite.conf', '*.pl' ],
        },
        layouts => {
            active_layout => $active_layout,
            active_theme  => $active_theme,
            available     => ( action_layouts_available() || {} )->{layouts} || [],
        },
        themes  => ( action_theme_list()  || {} )->{themes}  || [],
        plugins => ( action_plugin_list() || {} )->{plugins} || [],
        # SM072: site-level capabilities from enabled plugins (e.g. email-send).
        site_capabilities => site_capabilities(),
    };
}

# SM072 audit trail: append one line per state-changing request to a
# manager-readable log. Fields are pipe-delimited: ts | user | action | ip | status.
sub audit_log {
    my ( $user, $act, $target, $ip, $status, $origin ) = @_;
    my $dir = "$LAZYSITE_DIR/logs";
    return unless -d $dir || mkdir($dir);
    require POSIX;
    my $ts = POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime );
    # SM077: origin (ui = cookie manager, api = control-API token) is appended
    # last so the existing column positions stay stable for older readers.
    $_ = defined $_ ? "$_" : '' for ( $user, $act, $target, $ip, $status, $origin );
    s/[|\r\n]+/ /g for ( $user, $act, $target, $ip, $status, $origin );
    open my $fh, '>>', "$dir/audit.log" or return;
    print $fh "$ts | $user | $act | $target | $ip | $status | $origin\n";
    close $fh;
    return;
}

# SM072: read the audit trail (newest first), optionally filtered by user.
sub action_audit {
    my (%opt) = @_;
    my $file = "$LAZYSITE_DIR/logs/audit.log";
    return { ok => 1, entries => [] } unless -f $file;
    open my $fh, '<', $file or return { ok => 1, entries => [] };
    my @lines = <$fh>;
    close $fh;
    my $want   = $opt{user};
    my $want_t = $opt{target};    # SM077: filter to one file's history
    my @entries;
    for my $line ( reverse @lines ) {
        chomp $line;
        my @f = split / \| /, $line;
        # Column growth over releases: 5 = ts|user|action|ip|status (pre-SM078);
        # 6 adds target (SM078); 7 appends origin (SM077, ui/api). Parse by count.
        my ( $ts, $u, $act, $target, $ip, $status, $origin );
        if    ( @f >= 7 ) { ( $ts, $u, $act, $target, $ip, $status, $origin ) = @f[ 0 .. 6 ] }
        elsif ( @f == 6 ) { ( $ts, $u, $act, $target, $ip, $status ) = @f[ 0 .. 5 ]; $origin = '' }
        else              { ( $ts, $u, $act, $ip, $status ) = @f[ 0 .. 4 ]; $target = ''; $origin = '' }
        next if defined $want   && length $want   && ( $u      // '' ) ne $want;
        next if defined $want_t && length $want_t && ( $target // '' ) ne $want_t;
        push @entries, { ts => $ts, user => $u, action => $act,
            target => $target, ip => $ip, status => $status, origin => $origin };
        last if @entries >= 500;
    }
    return { ok => 1, entries => \@entries };
}

# SM072: the running version, read from the install state .install-state.json.
sub action_version {
    my $path = "$DOCROOT/lazysite/.install-state.json";
    return { ok => 1, version => undef } unless -f $path;
    open my $fh, '<', $path or return { ok => 1, version => undef };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { decode_json($raw) } || {};
    return { ok => 1, version => $d->{version}, installed_at => $d->{installed_at} };
}

# SM077: assignable principals for the permissions pickers - usernames + group
# names only (no settings/records). Cookie-manager action, like 'users'.
sub action_principals {
    my $u = users_api( { action => 'list' } )   || {};
    my $g = users_api( { action => 'groups' } )  || {};
    my @users  = ref $u->{users}  eq 'ARRAY' ? @{ $u->{users} } : ();
    my @groups = ref $g->{groups} eq 'HASH'  ? ( sort keys %{ $g->{groups} } ) : ();
    return { ok => 1, users => \@users, groups => \@groups };
}

sub action_users {
    my ( $request_body, $params_ref ) = @_;

    my $users_script = _users_tool_path();
    return { ok => 0, error => "User management not available" }
        unless $users_script;

    # The child (tools/lazysite-users.pl --api) always expects a single
    # JSON object on stdin. If we're hit with a plain GET (empty body),
    # pipe through a read-only request derived from the query string
    # rather than feeding the child an empty buffer and surfacing its
    # "Invalid JSON input" reply. Allowed GET sub-actions are list and
    # groups; writes (add / passwd / remove / group-add / group-remove)
    # must go via POST so they pass through the CSRF gate upstream.
    my $method = $ENV{REQUEST_METHOD} // 'GET';
    if ( $method ne 'POST' || !length $request_body ) {
        my $sub = ( $params_ref && $params_ref->{sub} ) || 'list';
        return { ok => 0, error => "Read-only sub-action on GET; allowed: list, groups" }
            unless $sub eq 'list' || $sub eq 'groups';
        $request_body = encode_json({ action => $sub });
    }

    # SM071/SM072: scope sub-user management to the actor's own sub-tree.
    # claim-redeem is the PUBLIC redemption flow (lazysite-auth.pl /claim) -
    # the user sets their own secret, so it is never a manager action and is
    # refused here. For the account-* actions and claim-create (Generate setup
    # link / Reset credential) we inject actor=$auth_user so the users tool
    # confines a DELEGATED sub-manager to its own sub-tree.
    #
    # A manager-group operator (and 'local') is unrestricted and must get NO
    # actor, or it can only manage accounts it personally created - the cause
    # of "Not authorised to manage 'X'" when an operator generates a setup
    # link for a user it owns through the tree but did not directly create.
    # created_by still defaults to the actor so a new account has an owner.
    if ( length $request_body ) {
        my $parsed = eval { decode_json($request_body) };
        if ( ref $parsed eq 'HASH' ) {
            my $act = $parsed->{action} // '';
            return { ok => 0, error => "claim-redeem is not a manager action" }
                if $act eq 'claim-redeem';
            if ( $auth_user ne 'local'
                 && $act =~ /^(?:account-(?:create|disable|enable|reassign)|claim-create|rename)$/ ) {
                $parsed->{actor} = $auth_user unless _is_operator();
                $parsed->{created_by} //= $auth_user if $act eq 'account-create';
                $request_body = encode_json($parsed);
            }
        }
    }

    my ( $child_out, $child_in );
    my $pid = eval {
        open2( $child_out, $child_in,
            $^X, $users_script, '--api', '--docroot', $DOCROOT );
    };
    return { ok => 0, error => "Cannot run user management: $@" } unless $pid;

    print $child_in $request_body;
    close $child_in;

    my $output = do { local $/; <$child_out> };
    close $child_out;
    waitpid $pid, 0;

    return eval { decode_json( $output // '{}' ) } // { ok => 0, error => "Invalid response" };
}

# Rotate the per-installation HMAC secret in lazysite/auth/.secret.
# Every existing auth cookie is signed with the previous secret, so
# rewriting this file invalidates every outstanding session (the
# operator's own session included). This is the "log everyone out"
# lever - the server-side mitigation for the known "no session
# revocation" constraint.
sub action_rotate_auth_secret {
    my ($auth_user) = @_;
    my $path = "$LAZYSITE_DIR/auth/.secret";

    # Fail closed if CSPRNG unavailable (M-6 convention)
    open my $rand, '<:raw', '/dev/urandom'
        or return { ok => 0, error => "Cannot open /dev/urandom: $!" };
    my $raw = '';
    my $got = read( $rand, $raw, 32 );
    close $rand;
    return { ok => 0, error => "Short read from /dev/urandom ($got of 32)" }
        unless defined $got && $got == 32;
    my $new = unpack( 'H*', $raw );

    make_path( dirname($path) ) unless -d dirname($path);

    # Atomic write: tempfile + rename. If anything in the chain fails,
    # the original .secret keeps working - we never leave the file
    # empty or partial, which would lock everyone out without giving
    # them a way back in.
    my $tmp = "$path.tmp.$$";
    open my $wfh, '>', $tmp
        or return { ok => 0, error => "Cannot write $tmp: $!" };
    chmod 0o600, $tmp;
    print $wfh "$new\n";
    close $wfh;
    unless ( rename $tmp, $path ) {
        my $err = $!;
        unlink $tmp;
        return { ok => 0, error => "Cannot replace $path: $err" };
    }
    chmod 0o600, $path;

    # Also clear the CSRF secret cache file (if dedicated one exists).
    # The CSRF helper falls back to .secret, so the new .secret
    # becomes the new CSRF secret too - but the operator's next POST
    # will race with their about-to-expire session cookie, so bail
    # out cleanly by cycling them through /login.
    my $csrf_secret = "$LAZYSITE_DIR/manager/.csrf-secret";
    unlink $csrf_secret if -f $csrf_secret;

    log_event( 'WARN', $auth_user,
        'auth secret rotated - all sessions invalidated' );

    return {
        ok      => 1,
        message => 'All sessions invalidated. You will need to sign in again.',
    };
}

# --- Helpers ---

# --- Plugin actions ---


# --- Nav actions ---

sub _nav_conf_path {
    # Read nav_file from lazysite.conf, default to lazysite/nav.conf
    my $nav_file = 'lazysite/nav.conf';
    my $conf = "$DOCROOT/lazysite/lazysite.conf";
    if ( -f $conf ) {
        open my $fh, '<:utf8', $conf;
        while (<$fh>) {
            if ( /^nav_file\s*:\s*(.+)/ ) {
                $nav_file = $1;
                $nav_file =~ s/^\s+|\s+$//g;
                last;
            }
        }
        close $fh;
    }
    return "$DOCROOT/$nav_file";
}

sub action_nav_read {
    my $path = _nav_conf_path();
    my @items;

    if ( -f $path ) {
        open my $fh, '<:utf8', $path or return { ok => 0, error => "Cannot read nav" };
        my $current_parent = -1;
        while (<$fh>) {
            chomp;
            next if /^\s*#/ || /^\s*$/;

            my $is_child = /^\s+/;
            s/^\s+|\s+$//g;

            my ( $label, $url ) = split /\s*\|\s*/, $_, 2;
            $label //= '';
            $url   //= '';
            $label =~ s/^\s+|\s+$//g;
            $url   =~ s/^\s+|\s+$//g;
            next unless length $label;

            if ($is_child && $current_parent >= 0) {
                push @{ $items[$current_parent]{children} },
                    { label => $label, url => $url };
            } else {
                push @items, { label => $label, url => $url, children => [] };
                $current_parent = $#items;
            }
        }
        close $fh;
    }

    return { ok => 1, items => \@items, path => $path };
}

sub action_nav_save {
    my ($items) = @_;
    my $path = _nav_conf_path();

    my $content = "# lazysite navigation\n";
    $content .= "# Format: Label | /url\n";
    $content .= "# Indent child items with any whitespace\n\n";

    for my $item ( @$items ) {
        my $label = $item->{label} // '';
        my $url   = $item->{url}   // '';
        $label =~ s/^\s+|\s+$//g;
        $url   =~ s/^\s+|\s+$//g;
        next unless length $label;

        if ( length $url ) {
            $content .= "$label | $url\n";
        } else {
            $content .= "$label\n";
        }

        for my $child ( @{ $item->{children} // [] } ) {
            my $cl = $child->{label} // '';
            my $cu = $child->{url}   // '';
            $cl =~ s/^\s+|\s+$//g;
            $cu =~ s/^\s+|\s+$//g;
            next unless length $cl;
            $content .= "  $cl | $cu\n";
        }
    }

    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    my ( $wok, $werr ) = write_file_checked( $path, $content );
    return { ok => 0, error => "Cannot write nav: $werr" } unless $wok;

    return { ok => 1 };
}








# --- Handler actions ---









# --- SM019: upload / download / zip-download ---

# Read the manager_upload_* / manager_blocked_* keys from
# lazysite.conf. All are optional; invalid values fall back to
# the hard-coded defaults and are logged at WARN. Called once
# per request via upload_limits().
#
# SM019c renamed manager_upload_blocked_paths to
# manager_blocked_paths because the list now gates download,
# save, and delete as well as upload. The old key is still
# accepted with a one-time INFO log so operators have a chance
# to update their conf on the next restart.


# Reset hook used by tests that rewrite the conf between calls. Not
# referenced from production code paths; CGI processes are one-shot.

# Second gate on top of is_blocked_path. is_blocked_path enforces a
# hard-coded list plus the .pl rule; this one reads the configurable
# blocked_paths and (for uploads only) blocked_extensions lists.
#
# SM019c widened the caller set: the path list now gates save,
# delete, download, zip-download, and upload. The extension list
# is still upload-only (no reason to block a user from downloading
# a .pl they already created through other means). The
# $check_extensions flag controls that.

# SM019c: kept as a thin compat shim so callers (and tests)
# written against the SM019 name still work. New call sites
# should use is_blocked_config directly.

# Per-user hourly budget on upload count and total bytes. Mirrors the
# .login-rate.db pattern in lazysite-auth.pl: fail-open on DB failure,
# reserve budget up-front from CONTENT_LENGTH, age out stale buckets
# opportunistically. Returns { ok => 1 } or { ok => 0, error => ... }.







# The query-string parser at the top of the script collapses repeated
# keys (last-write-wins). Re-parse from QUERY_STRING directly to pick
# up every paths=... value from the zip-download request.


# --- Helpers ---


# --- Logging ---


