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
    is_blocked_config is_blocked_upload_target upload_limits load_upload_limits _reset_upload_limits_cache);
use Lazysite::Manager::Upload qw(action_file_upload action_file_download action_file_zip_download
    check_upload_rate is_editable_text);
use Lazysite::Manager::Plugins qw(action_plugin_list action_plugin_enable action_plugin_disable
    action_plugin_read action_plugin_save action_plugin_action action_handler_list
    action_handler_save action_handler_delete action_form_targets_read action_form_targets_save);
use Lazysite::Manager::Files qw(action_list action_read action_save action_delete action_mkdir
    acquire_lock release_lock renew_lock _get_lock_info
    action_acl_get action_acl_set action_acl_remove);
$Lazysite::Util::COMPONENT = 'manager-api';

my $DOCROOT      = $ENV{DOCUMENT_ROOT} // die "No DOCUMENT_ROOT\n";
$Lazysite::Auth::Acl::DOCROOT = $DOCROOT;
$Lazysite::Manager::Common::DOCROOT = $DOCROOT;
$Lazysite::Manager::Upload::DOCROOT = $DOCROOT;
$Lazysite::Manager::Plugins::DOCROOT = $DOCROOT;
$Lazysite::Manager::Files::DOCROOT = $DOCROOT;
my $LAZYSITE_DIR = "$DOCROOT/lazysite";
$Lazysite::Auth::Session::LAZYSITE_DIR = $LAZYSITE_DIR;
$Lazysite::Manager::Upload::LAZYSITE_DIR = $LAZYSITE_DIR;
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
$Lazysite::Auth::Acl::auth_user            = $auth_user;
$Lazysite::Auth::Acl::token_auth           = $token_auth;
$Lazysite::Auth::Acl::manager_groups_conf  = $manager_groups_conf;

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
elsif ( $action eq 'audit' )            { $result = action_audit( user => $params{user} ) }
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
# manager-readable log - who did what, when, from where, and the outcome.
if ( ( $ENV{REQUEST_METHOD} // '' ) eq 'POST' && $action ne 'csrf-token' ) {
    audit_log( $auth_user, $action, $ENV{REMOTE_ADDR} // '',
        ( ref $result eq 'HASH' && $result->{ok} ) ? 'ok' : 'fail' );
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
sub _artifact_dir {
    my ($p) = @_;
    my $layout = $p->{layout} // '';
    my $theme  = $p->{theme}  // '';
    return { ok => 0, error => 'invalid or missing layout' }
        unless $layout =~ /^[A-Za-z0-9_-]+$/;
    if ( length $theme ) {
        return { ok => 0, error => 'invalid theme' }
            unless $theme =~ /^[A-Za-z0-9_-]+$/;
        return { ok => 1, layout => $layout, theme => $theme,
                 dir => "$LAZYSITE_DIR/layouts/$layout/themes/$theme" };
    }
    return { ok => 1, layout => $layout, theme => '',
             dir => "$LAZYSITE_DIR/layouts/$layout" };
}

# Content-hash manifest of a theme/layout: { relpath => {sha256,size} }.
sub action_artifact_manifest {
    my ($p) = @_;
    my $a = _artifact_dir($p);
    return $a unless $a->{ok};
    return { ok => 0, error => 'artifact not found' } unless -d $a->{dir};

    my $manifest = _compute_manifest( $a->{dir} );
    # digest is the optimistic-concurrency token: the client passes it back
    # as `base` to activate, which 409s if the artifact drifted since.
    return { ok => 1, layout => $a->{layout}, theme => $a->{theme},
             manifest => $manifest,
             digest   => sha256_hex( JSON::PP->new->canonical->encode($manifest) ) };
}

# Content manifest of a directory: { relpath => { sha256, size } }.
sub _compute_manifest {
    my ($dir) = @_;
    my %m;
    return \%m unless -d $dir;
    File::Find::find( { no_chdir => 1, wanted => sub {
        return unless -f $_;
        ( my $rel = $_ ) =~ s{^\Q$dir\E/}{};
        open my $fh, '<:raw', $_ or return;
        my $sha = Digest::SHA->new(256);
        $sha->addfile($fh);
        close $fh;
        $m{$rel} = { sha256 => $sha->hexdigest, size => ( -s $_ ) + 0 };
    } }, $dir );
    return \%m;
}

sub _artifact_digest {
    my ($dir) = @_;
    return sha256_hex( JSON::PP->new->canonical->encode( _compute_manifest($dir) ) );
}

# Dry-run validation of a theme/layout (the activate gate, P3.4 reuses it).
# Theme: theme.json present with a non-empty layouts[]. Layout: layout.tt
# present (the TT-compile check is added in P3.5).
sub action_artifact_validate {
    my ($p) = @_;
    my $a = _artifact_dir($p);
    return $a unless $a->{ok};
    return { ok => 1, valid => 0, errors => ['artifact not found'] }
        unless -d $a->{dir};

    my @err;
    if ( length $a->{theme} ) {
        my $tj = "$a->{dir}/theme.json";
        if ( !-f $tj ) { push @err, 'theme.json missing' }
        else {
            open my $fh, '<:utf8', $tj or push @err, 'theme.json unreadable';
            if (@err == 0) {
                my $raw  = do { local $/; <$fh> };
                close $fh;
                my $data = eval { decode_json($raw) };
                if ( ref $data ne 'HASH' ) { push @err, 'theme.json invalid' }
                elsif ( ref $data->{layouts} ne 'ARRAY' || !@{ $data->{layouts} } ) {
                    push @err, 'theme.json layouts[] missing or empty';
                }
            }
        }
    }
    else {
        my $v = _validate_layout_dir( $a->{dir} );
        return { ok => 1, valid => $v->{valid}, errors => $v->{errors} };
    }
    return { ok => 1, valid => ( @err ? 0 : 1 ), errors => \@err };
}

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

sub action_cache_list {
    my @cached;
    find(
        sub {
            return unless /\.html$/;
            my $rel = $File::Find::name;
            $rel =~ s{^\Q$DOCROOT\E/?}{/};
            return if $rel =~ m{^/lazysite/};
            ( my $src = $File::Find::name ) =~ s/\.html$/.md/;
            push @cached, {
                path       => $rel,
                mtime      => ( stat $_ )[9],
                has_source => -f $src ? 1 : 0,
            };
        },
        $DOCROOT
    );
    return { ok => 1, cached => \@cached };
}

sub action_cache_invalidate {
    my ($rel_path) = @_;

    if ( $rel_path eq '*' ) {
        my $count = 0;
        find(
            sub {
                return unless /\.html$/;
                my $rel = $File::Find::name;
                $rel =~ s{^\Q$DOCROOT\E/?}{/};
                return if $rel =~ m{^/lazysite/};
                unlink $_;
                $count++;
            },
            $DOCROOT
        );
        return { ok => 1, count => $count };
    }

    my $full = "$DOCROOT$rel_path";
    $full =~ s/\.md$/.html/;
    $full .= '.html' unless $full =~ /\.html$/;

    my $real = realpath($full);
    return { ok => 0, error => "Invalid path" }
        unless $real && index( $real, $DOCROOT ) == 0;

    unlink $real if -f $real;
    log_event('INFO', $action, 'cache invalidated', path => $rel_path, user => $auth_user);
    return { ok => 1, path => $rel_path };
}

# --- Theme actions ---

# D013: read both the active layout: and theme: values from
# lazysite.conf. Used by every theme action to locate the nested
# themes directory under the active layout.
sub _read_active_layout_and_theme {
    my $layout = '';
    my $theme  = '';
    if ( open my $fh, '<', "$DOCROOT/lazysite/lazysite.conf" ) {
        while (<$fh>) {
            $layout = $1 if /^layout\s*:\s*(\S+)/;
            $theme  = $1 if /^theme\s*:\s*(\S+)/;
        }
        close $fh;
    }
    $layout =~ s/[^a-zA-Z0-9_-]//g;
    $theme  =~ s/[^a-zA-Z0-9_-]//g;
    return ( $layout, $theme );
}

sub action_theme_list {
    my ( $active_layout, $active_theme ) = _read_active_layout_and_theme();

    my @themes;
    if ( length $active_layout ) {
        my $themes_dir = "$DOCROOT/lazysite/layouts/$active_layout/themes";
        if ( -d $themes_dir ) {
            opendir( my $dh, $themes_dir );
            for my $name ( sort readdir $dh ) {
                next if $name =~ /^\./;
                next unless -d "$themes_dir/$name";
                push @themes, {
                    name   => $name,
                    active => $name eq $active_theme ? 1 : 0,
                    valid  => -f "$themes_dir/$name/theme.json" ? 1 : 0,
                };
            }
            closedir $dh;
        }
    }

    return {
        ok     => 1,
        themes => \@themes,
        active => $active_theme,
        layout => $active_layout,
    };
}

# SM068: list every installed theme across all layouts, not only
# the active one. The Installed Themes panel on /manager/themes
# uses this to show themes grouped by layout — themes for the
# active layout are activatable; themes for other layouts are
# shown for visibility but with no Activate button.
#
# Shape matches action_theme_list where possible but adds a
# `layout` field per entry (action_theme_list implies it from the
# top-level active layout).
sub action_themes_list_all {
    my ( $active_layout, $active_theme ) = _read_active_layout_and_theme();

    my $layouts_dir = "$DOCROOT/lazysite/layouts";
    my @themes;

    if ( -d $layouts_dir ) {
        opendir my $ld, $layouts_dir or return {
            ok => 1, themes => [], active => $active_theme,
            active_layout => $active_layout,
        };
        for my $layout_name ( sort readdir $ld ) {
            next if $layout_name =~ /^\./;
            my $themes_path = "$layouts_dir/$layout_name/themes";
            next unless -d $themes_path;

            opendir my $th, $themes_path or next;
            for my $name ( sort readdir $th ) {
                next if $name =~ /^\./;
                next unless -d "$themes_path/$name";

                my $valid  = -f "$themes_path/$name/theme.json" ? 1 : 0;
                my $active = ( $layout_name eq $active_layout
                            && $name         eq $active_theme ) ? 1 : 0;
                push @themes, {
                    layout => $layout_name,
                    name   => $name,
                    active => $active,
                    valid  => $valid,
                };
            }
            closedir $th;
        }
        closedir $ld;
    }

    return {
        ok            => 1,
        themes        => \@themes,
        active        => $active_theme,
        active_layout => $active_layout,
    };
}

# SM071 Phase 3: activate-with-backup. Validates the candidate, optionally
# enforces an optimistic-concurrency base manifest (409 on drift), takes an
# artifact-level lock for the transition, snapshots the outgoing live theme
# (for back-out) with retention, then flips the pointer and drops the cache.
sub action_theme_activate {
    my ( $theme_name, $params ) = @_;
    $params ||= {};
    $theme_name =~ s/[^a-zA-Z0-9_-]//g;

    # Deactivation: clear the pointer, no validation/backup.
    return _set_theme_pointer('') if $theme_name eq '';

    my ( $active_layout, $old_theme ) = _read_active_layout_and_theme();
    return { ok => 0, error => "No active layout set" } unless length $active_layout;

    my $themes_dir = "$LAZYSITE_DIR/layouts/$active_layout/themes";
    my $theme_dir  = "$themes_dir/$theme_name";
    return { ok => 0, error => "Theme not found" } unless -d $theme_dir;

    # Artifact-level lock across validate -> snapshot -> flip.
    my $lock_rel = "lazysite/layouts/$active_layout/themes/$theme_name";
    my $lk = acquire_lock( $lock_rel, $auth_user );
    unless ( $lk->{ok} ) {
        return { ok => 0, locked => 1, error => "Theme is locked by "
            . ( $lk->{locked_by} // 'another session' ) };
    }

    my $out = eval {
        my $v = _validate_theme_dir( $theme_dir, $active_layout );
        return { ok => 0, error => "Theme invalid: " . join( '; ', @{ $v->{errors} } ) }
            unless $v->{valid};

        if ( defined $params->{base} && length $params->{base} ) {
            return { ok => 0, conflict => 1,
                error => "Theme changed since the supplied base manifest" }
                if _artifact_digest($theme_dir) ne $params->{base};
        }

        if ( length $old_theme && $old_theme ne $theme_name ) {
            _snapshot_artifact( $themes_dir, $old_theme );
            _prune_backups( $themes_dir, $old_theme );
        }
        return _set_theme_pointer($theme_name);
    };
    my $err = $@;
    release_lock( $lock_rel, $auth_user );
    die $err if $err;
    return $out;
}

# Rewrite the theme: pointer in conf and invalidate the page cache.
sub _set_theme_pointer {
    my ($theme_name) = @_;
    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    return { ok => 0, error => "Cannot read conf" } unless -f $conf_path;
    open my $fh, '<:utf8', $conf_path or return { ok => 0, error => "Cannot read conf" };
    my $conf = do { local $/; <$fh> };
    close $fh;
    if    ( $theme_name eq '' )         { $conf =~ s/^theme\s*:.*\n?//m }
    elsif ( $conf =~ /^theme\s*:/m )    { $conf =~ s/^theme\s*:.*$/theme: $theme_name/m }
    else                                { $conf .= "\ntheme: $theme_name\n" }
    open my $o, '>:utf8', $conf_path or return { ok => 0, error => "Cannot write conf" };
    print $o $conf;
    close $o;
    _invalidate_html_cache();
    return { ok => 1, theme => $theme_name };
}

sub _invalidate_html_cache {
    find( sub {
        return unless /\.html$/;
        my $rel = $File::Find::name;
        $rel =~ s{^\Q$DOCROOT\E/?}{/};
        return if $rel =~ m{^/lazysite/};
        # Only delete a GENERATED cache file: a <page>.html whose <page>.md or
        # <page>.url source exists. An author-supplied .html with no such
        # source (e.g. an include partial) is content, not cache - never
        # delete it (deleting author partials gutted pages, SM072 report).
        ( my $base = $File::Find::name ) =~ s/\.html$//;
        unlink $_ if -f "$base.md" || -f "$base.url";
    }, $DOCROOT );
}

# Theme validity gate: theme.json present + valid JSON + layouts[] declares
# the active layout. { valid => 0/1, errors => [...] }.
sub _validate_theme_dir {
    my ( $dir, $layout ) = @_;
    my $tj = "$dir/theme.json";
    return { valid => 0, errors => ['theme.json missing'] } unless -f $tj;
    open my $fh, '<:utf8', $tj
        or return { valid => 0, errors => ['theme.json unreadable'] };
    my $raw  = do { local $/; <$fh> };
    close $fh;
    my $data = eval { decode_json($raw) };
    my @err;
    if ( ref $data ne 'HASH' ) {
        my $why = $@ ? do { ( my $e = $@ ) =~ s/\s+at \S+ line \d+.*//s; $e =~ s/\s+$//; $e }
                     : 'top level is not a JSON object';
        push @err, "theme.json invalid: $why";
    }
    elsif ( ref $data->{layouts} ne 'ARRAY' || !@{ $data->{layouts} } ) {
        push @err, 'theme.json layouts[] missing or empty';
    }
    elsif ( !grep { $_ eq $layout } @{ $data->{layouts} } ) {
        push @err, "theme not declared for active layout '$layout'";
    }
    return { valid => ( @err ? 0 : 1 ), errors => \@err };
}

# Snapshot an artifact dir as <name>-backup-<UTCstamp> alongside it, for
# back-out (the snapshot is itself a selectable theme).
sub _snapshot_artifact {
    my ( $parent, $name ) = @_;
    my $src = "$parent/$name";
    return unless -d $src;
    my $dst = "$parent/$name-backup-" . strftime( '%Y%m%dT%H%M%SZ', gmtime );
    return if -e $dst;
    system( 'cp', '-r', $src, $dst );
}

# Keep the newest backup_retention snapshots of $name; remove older ones.
# Names embed a UTC stamp, so a lexical sort is chronological.
sub _prune_backups {
    my ( $parent, $name ) = @_;
    my $keep = _backup_retention();
    return if $keep <= 0;   # 0 (or negative) = keep all
    opendir my $dh, $parent or return;
    my @backups = sort grep { /^\Q$name\E-backup-/ && -d "$parent/$_" } readdir $dh;
    closedir $dh;
    while ( @backups > $keep ) {
        my $old = shift @backups;
        system( 'rm', '-rf', "$parent/$old" );
    }
}

sub _backup_retention {
    my $n = 3;
    if ( open my $fh, '<', "$DOCROOT/lazysite/lazysite.conf" ) {
        while (<$fh>) { if (/^backup_retention\s*:\s*(-?\d+)/) { $n = $1; last } }
        close $fh;
    }
    return $n;
}

# SM071 Phase 3 (P3.5): activate a layout. Reuses the activate-with-backup
# machinery, adds the layout-specific rules: layout.tt must compile, and
# the resulting (layout, theme) pair must be compatible - either the
# current theme declares the new layout, or a compatible theme is named.
sub action_layout_activate {
    my ( $layout_name, $params ) = @_;
    $params ||= {};
    $layout_name =~ s/[^a-zA-Z0-9_-]//g;
    return { ok => 0, error => "Layout name required" } unless length $layout_name;

    my ( $old_layout, $cur_theme ) = _read_active_layout_and_theme();
    my $layout_dir = "$LAZYSITE_DIR/layouts/$layout_name";
    return { ok => 0, error => "Layout not found" } unless -d $layout_dir;

    my $theme = defined $params->{theme} ? $params->{theme} : $cur_theme;
    $theme = '' unless defined $theme;
    $theme =~ s/[^a-zA-Z0-9_-]//g;
    my $theme_specified = ( defined $params->{theme} && length $params->{theme} ) ? 1 : 0;

    my $lock_rel = "lazysite/layouts/$layout_name";
    my $lk = acquire_lock( $lock_rel, $auth_user );
    unless ( $lk->{ok} ) {
        return { ok => 0, locked => 1, error => "Layout is locked by "
            . ( $lk->{locked_by} // 'another session' ) };
    }

    my $out = eval {
        my $v = _validate_layout_dir($layout_dir);
        return { ok => 0, error => "Layout invalid: " . join( '; ', @{ $v->{errors} } ) }
            unless $v->{valid};

        # Compatible (layout, theme) pair.
        if ( length $theme && !_theme_declares_layout( $layout_name, $theme ) ) {
            return { ok => 0, incompatible => 1,
                error => "Theme '$theme' is not declared for layout '$layout_name'"
                       . " - name a compatible theme to switch to" };
        }

        if ( defined $params->{base} && length $params->{base} ) {
            return { ok => 0, conflict => 1,
                error => "Layout changed since the supplied base manifest" }
                if _artifact_digest($layout_dir) ne $params->{base};
        }

        if ( length $old_layout && $old_layout ne $layout_name ) {
            _snapshot_artifact( "$LAZYSITE_DIR/layouts", $old_layout );
            _prune_backups( "$LAZYSITE_DIR/layouts", $old_layout );
        }
        return _set_layout_pointer( $layout_name,
            ( $theme_specified && length $theme ) ? $theme : undef );
    };
    my $err = $@;
    release_lock( $lock_rel, $auth_user );
    die $err if $err;
    return $out;
}

# Rewrite the layout: pointer (and theme: when a theme is given), then
# invalidate the page cache.
sub _set_layout_pointer {
    my ( $layout, $theme ) = @_;
    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    return { ok => 0, error => "Cannot read conf" } unless -f $conf_path;
    open my $fh, '<:utf8', $conf_path or return { ok => 0, error => "Cannot read conf" };
    my $conf = do { local $/; <$fh> };
    close $fh;
    if ( $conf =~ /^layout\s*:/m ) { $conf =~ s/^layout\s*:.*$/layout: $layout/m }
    else                           { $conf .= "\nlayout: $layout\n" }
    if ( defined $theme ) {
        if ( $conf =~ /^theme\s*:/m ) { $conf =~ s/^theme\s*:.*$/theme: $theme/m }
        else                          { $conf .= "\ntheme: $theme\n" }
    }
    open my $o, '>:utf8', $conf_path or return { ok => 0, error => "Cannot write conf" };
    print $o $conf;
    close $o;
    _invalidate_html_cache();
    return { ok => 1, layout => $layout, ( defined $theme ? ( theme => $theme ) : () ) };
}

# Layout validity gate: layout.tt present and parses as Template Toolkit.
# The compile check is best-effort - if Template::Parser is unavailable
# we fall back to the presence check rather than blocking.
sub _validate_layout_dir {
    my ($dir) = @_;
    my $lt = "$dir/layout.tt";
    return { valid => 0, errors => ['layout.tt missing'] } unless -f $lt;
    my $ok = eval {
        require Template::Parser;
        open my $fh, '<:utf8', $lt or die "layout.tt unreadable\n";
        my $src = do { local $/; <$fh> };
        close $fh;
        my $p = Template::Parser->new( {} );
        $p->parse($src) or die( $p->error . "\n" );
        1;
    };
    return { valid => 1, errors => [] } if $ok;
    my $e = $@ || 'parse error';
    return { valid => 1, errors => [] } if $e =~ /Can't locate Template/;
    chomp $e;
    return { valid => 0, errors => ["layout.tt does not compile: $e"] };
}

# Does the theme declare compatibility with the layout (theme.json layouts[])?
sub _theme_declares_layout {
    my ( $layout, $theme ) = @_;
    my $tj = "$LAZYSITE_DIR/layouts/$layout/themes/$theme/theme.json";
    return 0 unless -f $tj;
    open my $fh, '<:utf8', $tj or return 0;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $data = eval { decode_json($raw) };
    return 0 unless ref $data eq 'HASH' && ref $data->{layouts} eq 'ARRAY';
    return ( grep { $_ eq $layout } @{ $data->{layouts} } ) ? 1 : 0;
}

sub action_theme_delete {
    my ($theme_name) = @_;
    $theme_name =~ s/[^a-zA-Z0-9_-]//g;

    my ( $active_layout, $active_theme ) = _read_active_layout_and_theme();
    return { ok => 0, error => "Cannot delete the active theme" }
        if $theme_name eq $active_theme;
    return { ok => 0, error => "No active layout set" }
        unless length $active_layout;

    # D013: delete only from the active layout's themes dir. A theme
    # installed under multiple layouts (via theme.json's layouts[])
    # has copies elsewhere — those remain, and the operator can remove
    # them by switching to each layout in turn.
    my $themes_dir = "$DOCROOT/lazysite/layouts/$active_layout/themes";
    my $theme_dir  = "$themes_dir/$theme_name";
    return { ok => 0, error => "Theme not found" } unless -d $theme_dir;

    my $real = realpath($theme_dir);
    return { ok => 0, error => "Invalid theme path" }
        unless $real && index( $real, $themes_dir ) == 0;

    my $rc = system( "rm", "-rf", $theme_dir );
    if ( $rc != 0 ) {
        log_event('ERROR', 'theme-delete', 'rm failed',
            path => $theme_dir, rc => ( $rc >> 8 ));
        return { ok => 0, error => "Delete failed" };
    }
    my $assets_dir = "$DOCROOT/lazysite-assets/$active_layout/$theme_name";
    if ( -d $assets_dir ) {
        $rc = system( "rm", "-rf", $assets_dir );
        if ( $rc != 0 ) {
            log_event('WARN', 'theme-delete', 'rm assets failed',
                path => $assets_dir, rc => ( $rc >> 8 ));
        }
    }

    return { ok => 1, deleted => $theme_name };
}

sub action_theme_rename {
    my ( $old_name, $new_name ) = @_;
    $old_name =~ s/[^a-zA-Z0-9_-]//g;
    $new_name =~ s/[^a-zA-Z0-9_-]//g if defined $new_name;
    $new_name = lc( $new_name // '' );

    return { ok => 0, error => "Invalid name" } unless $old_name && $new_name;

    my ( $active_layout ) = _read_active_layout_and_theme();
    return { ok => 0, error => "No active layout set" }
        unless length $active_layout;

    my $themes_dir = "$DOCROOT/lazysite/layouts/$active_layout/themes";
    return { ok => 0, error => "Theme not found" } unless -d "$themes_dir/$old_name";
    return { ok => 0, error => "Name already in use" } if -d "$themes_dir/$new_name";

    rename "$themes_dir/$old_name", "$themes_dir/$new_name";

    my $old_assets = "$DOCROOT/lazysite-assets/$active_layout/$old_name";
    my $new_assets = "$DOCROOT/lazysite-assets/$active_layout/$new_name";
    rename $old_assets, $new_assets if -d $old_assets;

    return { ok => 1, old => $old_name, new => $new_name };
}

sub action_theme_upload {
    my ( $zip_data, $filename ) = @_;

    # M-4: use Archive::Zip for safe extraction with per-entry path
    # validation, replacing system("unzip") which had to be trusted not
    # to zip-slip. Archive::Zip is an optional dep - install.sh warns if
    # missing, and this action returns a clear error instead of crashing.
    my $have_azip = eval { require Archive::Zip; Archive::Zip->import(qw(:ERROR_CODES)); 1 };
    unless ($have_azip) {
        return { ok => 0,
            error => "Archive::Zip not installed (apt-get install libarchive-zip-perl)" };
    }

    my $tmp_dir = "/tmp/lazysite-theme-$$";
    make_path($tmp_dir);

    my $zip_path = "$tmp_dir/upload.zip";
    open my $fh, '>:raw', $zip_path
        or do { _cleanup_tmp($tmp_dir); return { ok => 0, error => "Cannot write upload" } };
    print $fh $zip_data;
    close $fh;

    my $extract_dir = "$tmp_dir/extracted";
    make_path($extract_dir);

    my $extract_real = realpath($extract_dir);
    unless ( defined $extract_real ) {
        _cleanup_tmp($tmp_dir);
        return { ok => 0, error => "Cannot resolve extract dir" };
    }

    my $zip = Archive::Zip->new();
    unless ( $zip->read($zip_path) == Archive::Zip::AZ_OK() ) {
        _cleanup_tmp($tmp_dir);
        return { ok => 0, error => "Cannot read uploaded zip" };
    }

    # Validate every entry before extracting any.
    for my $member ( $zip->members ) {
        my $name = $member->fileName;
        if ( $name =~ m{\A/} ) {
            _cleanup_tmp($tmp_dir);
            return { ok => 0, error => "Zip entry has absolute path: $name" };
        }
        if ( $name =~ m{(?:^|/)\.\.(?:/|$)} ) {
            _cleanup_tmp($tmp_dir);
            return { ok => 0, error => "Zip slip detected in: $name" };
        }
    }

    # Extract with tree layout under $extract_dir. extractTree returns
    # AZ_OK on full success.
    unless ( $zip->extractTree( '', "$extract_dir/" ) == Archive::Zip::AZ_OK() ) {
        _cleanup_tmp($tmp_dir);
        return { ok => 0, error => "Extraction failed" };
    }

    my $result = _install_theme_from_dir( $extract_dir, $action, $auth_user );
    _cleanup_tmp($tmp_dir);
    return $result;
}

# D013: install a theme from an already-extracted directory. Themes
# declare compatible layouts via theme.json's layouts[] array; we
# install a copy under each declared layout at
# {DOCROOT}/lazysite/layouts/LAYOUT/themes/THEME/ and duplicate
# assets at {DOCROOT}/lazysite-assets/LAYOUT/THEME/. DP-C: missing
# layouts[] is a strict reject.
sub _install_theme_from_dir {
    my ( $extract_dir, $action_label, $user ) = @_;

    return { ok => 0, error => "Upload must contain theme.json" }
        unless -f "$extract_dir/theme.json";

    open my $jf, '<:utf8', "$extract_dir/theme.json"
        or return { ok => 0, error => "Cannot read theme.json" };
    my $json = do { local $/; <$jf> };
    close $jf;
    my $meta = eval { decode_json($json) }
        or return { ok => 0, error => "Invalid theme.json" };

    my $theme_name = $meta->{name} // '';
    $theme_name =~ s/[^a-zA-Z0-9_-]//g;
    $theme_name = lc($theme_name);

    return { ok => 0, error => "Invalid theme name in theme.json" }
        unless $theme_name;

    # DP-C: strict reject when layouts[] is missing or empty.
    my $layouts = $meta->{layouts};
    unless ( ref $layouts eq 'ARRAY' && @$layouts ) {
        return { ok => 0,
            error => "Theme theme.json missing required 'layouts' field. Cannot install." };
    }

    my @clean_layouts;
    for my $l (@$layouts) {
        next unless defined $l && length $l;
        ( my $sane = $l ) =~ s/[^a-zA-Z0-9_-]//g;
        next unless length $sane;
        push @clean_layouts, $sane;
    }
    unless (@clean_layouts) {
        return { ok => 0,
            error => "Theme theme.json 'layouts' contains no usable layout names." };
    }

    # Verify every declared layout is installed. Reject the whole
    # upload if any are missing — the theme author explicitly said
    # "install under these" and we shouldn't silently skip.
    my @missing;
    for my $l (@clean_layouts) {
        push @missing, $l
            unless -f "$DOCROOT/lazysite/layouts/$l/layout.tt";
    }
    if (@missing) {
        return { ok => 0,
            error => "Theme targets missing layout(s): " . join(', ', @missing) };
    }

    # Resolve the on-disk install name once, using the first layout
    # to detect collisions. The same $install_name is reused across
    # every layout so operators can refer to the theme by a single
    # name in lazysite.conf's theme: key.
    my $install_name = $theme_name;
    my $first_dest   = "$DOCROOT/lazysite/layouts/$clean_layouts[0]/themes/$theme_name";
    if ( -d $first_dest ) {
        my @t = localtime( time() );
        $install_name = sprintf( "%04d%02d%02d-%s",
            $t[5] + 1900, $t[4] + 1, $t[3], $theme_name );
    }

    my @installed;
    for my $l (@clean_layouts) {
        my $dest = "$DOCROOT/lazysite/layouts/$l/themes/$install_name";
        make_path($dest);
        my $rc = system( "cp", "-r", "$extract_dir/.", $dest );
        if ( $rc != 0 ) {
            log_event( 'ERROR', $action_label, 'cp failed',
                path => $dest, rc => ( $rc >> 8 ) );
            return { ok => 0,
                error => "Install failed (cp theme files to $l)" };
        }

        # Nested asset path: /lazysite-assets/LAYOUT/THEME/
        if ( -d "$extract_dir/assets" ) {
            my $assets_dest = "$DOCROOT/lazysite-assets/$l/$install_name";
            make_path($assets_dest);
            $rc = system( "cp", "-r", "$extract_dir/assets/.", $assets_dest );
            if ( $rc != 0 ) {
                log_event( 'WARN', $action_label, 'cp assets failed',
                    path => $assets_dest, rc => ( $rc >> 8 ) );
            }
        }

        push @installed, $l;
    }

    log_event( 'INFO', $action_label, 'theme installed',
        name    => $install_name,
        layouts => join( ',', @installed ),
        user    => $user );

    return {
        ok           => 1,
        name         => $install_name,
        installed_as => $install_name,
        layouts      => \@installed,
    };
}

sub _cleanup_tmp {
    my ($dir) = @_;
    system( "rm", "-rf", $dir ) if $dir =~ m{^/tmp/lazysite-theme-\d+$};
}

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
sub _install_layout_from_dir {
    my ( $layout_source, $layout_name, $action_label, $user ) = @_;

    return { ok => 0, error => 'missing layout.tt in release' }
        unless -f "$layout_source/layout.tt";

    my $target_dir = "$DOCROOT/lazysite/layouts/$layout_name";

    # Collect the release's layout files (layout.tt + layout.json).
    # layout.json is optional; copy if present.
    my @rel_files;
    opendir my $sh, $layout_source
        or return { ok => 0, error => 'Cannot read layout source dir' };
    for my $f ( sort readdir $sh ) {
        next if $f =~ /^\./;
        my $src = "$layout_source/$f";
        # Only copy regular files at the layout root (layout.tt,
        # layout.json). The themes/ subtree is handled by the walker.
        next if $f eq 'themes';
        next unless -f $src;
        push @rel_files, $f;
    }
    closedir $sh;

    # Compare files. If the target directory exists AND every
    # release file is present AND byte-identical, it's a no-op.
    # If anything differs, refuse.
    if ( -d $target_dir ) {
        my @differs;
        for my $f (@rel_files) {
            my $src = "$layout_source/$f";
            my $dst = "$target_dir/$f";
            unless ( -f $dst ) {
                push @differs, $f;
                next;
            }
            # Cheap byte compare.
            my $sb = _slurp_bytes($src);
            my $db = _slurp_bytes($dst);
            if ( !defined $sb || !defined $db || $sb ne $db ) {
                push @differs, $f;
            }
        }
        if (@differs) {
            return { ok => 0,
                error => 'already installed and differs; refusing to overwrite ('
                       . join( ', ', @differs ) . ')' };
        }
        return { ok => 1, action => 'already_installed' };
    }

    # New install.
    make_path($target_dir);
    for my $f (@rel_files) {
        my $rc = system( 'cp', "$layout_source/$f", "$target_dir/$f" );
        if ( $rc != 0 ) {
            log_event( 'ERROR', $action_label, 'cp layout failed',
                file => $f, layout => $layout_name, rc => ( $rc >> 8 ) );
            return { ok => 0,
                error => "Install failed (cp $f to layout $layout_name)" };
        }
    }

    log_event( 'INFO', $action_label, 'layout installed',
        name => $layout_name, files => join( ',', @rel_files ),
        user => $user );

    return { ok => 1, action => 'installed' };
}

sub _slurp_bytes {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    my $data = do { local $/; <$fh> };
    close $fh;
    return $data;
}

# --- SM037 + D013: layouts-releases browser + release installer ---
# The external repo is lazysite-layouts; the config key and function
# names rename accordingly. The action remains a theme-browser (SM037
# scope) — it walks release zipballs for theme.json-bearing subdirs
# and invokes _install_theme_from_dir on each.

sub _layouts_repo {
    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    my $repo;
    if ( -f $conf_path && open my $fh, '<', $conf_path ) {
        while (<$fh>) {
            if (/^layouts_repo\s*:\s*(\S+)/) { $repo = $1; last }
        }
        close $fh;
    }
    # Sensible default so the release browser works out of the box; a
    # layouts_repo key in lazysite.conf overrides it for a custom repo.
    return ( defined $repo && length $repo ) ? $repo
                                             : 'OpenDigitalCC/lazysite-layouts';
}

sub action_layouts_releases {
    my $repo = _layouts_repo();
    return { ok => 0,
        error => 'Unable to fetch releases. Check the Layouts repo setting above.' }
        unless defined $repo && length $repo
            && $repo =~ m{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$};

    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new( timeout => 10, agent => 'lazysite/1.0' );
    my $url = "https://api.github.com/repos/$repo/releases";
    my $res = $ua->get( $url, 'Accept' => 'application/vnd.github+json' );

    return { ok => 0,
        error => 'Unable to fetch releases. Check the Layouts repo setting above.' }
        unless $res->is_success;

    my $data = eval { decode_json( $res->decoded_content ) };
    return { ok => 0,
        error => 'Unable to fetch releases. Check the Layouts repo setting above.' }
        unless ref $data eq 'ARRAY';

    my @releases;
    for my $r (@$data) {
        push @releases, {
            tag_name     => $r->{tag_name}     // '',
            name         => $r->{name}         // '',
            published_at => $r->{published_at} // '',
            body         => $r->{body}         // '',
        };
    }
    return { ok => 1, repo => $repo, releases => \@releases };
}

sub action_layouts_install {
    my ($request_body) = @_;
    my $req = eval { decode_json( $request_body // '{}' ) } // {};
    my $tag = $req->{tag} // '';

    # Tags can hold versioned names like v1.2.0 or release-2026-04-01
    # (and optionally refs/tags-style slashes). Reject any ".." sequence
    # to stop URL traversal into other GitHub API endpoints.
    return { ok => 0, error => 'Invalid tag' }
        unless length $tag
            && $tag =~ m{^[A-Za-z0-9._/-]+$}
            && $tag !~ m{\.\.};

    my $repo = _layouts_repo();
    return { ok => 0, error => 'layouts_repo not set or invalid in lazysite.conf' }
        unless defined $repo && length $repo
            && $repo =~ m{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$};

    my $have_azip = eval { require Archive::Zip; Archive::Zip->import(qw(:ERROR_CODES)); 1 };
    return { ok => 0,
        error => 'Archive::Zip not installed (apt-get install libarchive-zip-perl)' }
        unless $have_azip;

    require LWP::UserAgent;
    # Zipballs are larger than the releases JSON; allow more time.
    my $ua  = LWP::UserAgent->new( timeout => 30, agent => 'lazysite/1.0' );
    my $url = "https://api.github.com/repos/$repo/zipball/$tag";
    my $res = $ua->get($url);
    return { ok => 0, error => 'Failed to fetch zipball: ' . $res->status_line }
        unless $res->is_success;

    my $tmp_dir = "/tmp/lazysite-layouts-$$";
    make_path($tmp_dir);

    my $zip_path = "$tmp_dir/release.zip";
    unless ( open my $zfh, '>:raw', $zip_path ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Cannot write zipball' };
    }
    else {
        print $zfh $res->content;
        close $zfh;
    }

    my $extract_dir = "$tmp_dir/extracted";
    make_path($extract_dir);

    my $zip = Archive::Zip->new();
    unless ( $zip->read($zip_path) == Archive::Zip::AZ_OK() ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Cannot read zipball' };
    }

    for my $member ( $zip->members ) {
        my $name = $member->fileName;
        if ( $name =~ m{\A/} ) {
            _cleanup_tmp_layouts($tmp_dir);
            return { ok => 0, error => "Zip entry has absolute path: $name" };
        }
        if ( $name =~ m{(?:^|/)\.\.(?:/|$)} ) {
            _cleanup_tmp_layouts($tmp_dir);
            return { ok => 0, error => "Zip slip detected in: $name" };
        }
    }

    unless ( $zip->extractTree( '', "$extract_dir/" ) == Archive::Zip::AZ_OK() ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Extraction failed' };
    }

    # GitHub zipballs nest everything under a single top-level wrapper
    # dir named OWNER-REPO-SHA. Strip it so the theme subdirs sit at
    # the top of our walk.
    my @top;
    unless ( opendir my $dh, $extract_dir ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Cannot read extracted dir' };
    }
    else {
        for my $e ( readdir $dh ) {
            next if $e =~ /^\./;
            push @top, $e if -d "$extract_dir/$e";
        }
        closedir $dh;
    }

    unless ( @top == 1 ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0,
            error => 'Unexpected zipball layout (expected single wrapper dir)' };
    }
    my $wrapper = "$extract_dir/$top[0]";

    # SM046: LL v0.3.0+ release shape. Themes live nested at
    # $wrapper/layouts/LAYOUT/themes/THEME/, with theme.json at each
    # theme root. Pre-LL-v0.3.0 flat shape (theme.json in a top-level
    # subdir) is rejected — that shape pre-dates D013 and would fail
    # _install_theme_from_dir's layouts[] check anyway.
    my $layouts_dir = "$wrapper/layouts";
    unless ( -d $layouts_dir ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0,
            error => 'Release does not contain a layouts/ directory '
                   . '(repo must follow D013 nested shape: layouts/LAYOUT/themes/THEME/)' };
    }

    my @results;
    my @layout_results;    # SM060: per-layout install outcomes
    unless ( opendir my $ld, $layouts_dir ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Cannot read layouts dir' };
    }
    else {
        for my $layout_name ( sort readdir $ld ) {
            next if $layout_name =~ /^\./;
            my $layout_path = "$layouts_dir/$layout_name";
            next unless -d $layout_path;

            # SM060: install the layout itself before its themes, so
            # _install_theme_from_dir's target-site check finds the
            # expected layout.tt on disk. A layout without a themes/
            # subdir still gets installed — operators can publish a
            # release with just a layout update.
            my $layout_src_rel = "layouts/$layout_name";
            my $layout_had_tt  = -f "$layout_path/layout.tt";
            my $layout_ok      = 1;
            if ($layout_had_tt) {
                my $lr = _install_layout_from_dir(
                    $layout_path, $layout_name,
                    'layouts-install', $auth_user );
                push @layout_results,
                    { source => $layout_src_rel, %$lr };
                $layout_ok = $lr->{ok} ? 1 : 0;
            }
            # If there's no layout.tt in the release for this layout
            # dir, we don't record a layout entry — this is common
            # for release repos that ship only themes, and the
            # existing theme-level error ('Theme targets missing
            # layout(s): X') carries the useful message when the
            # target site doesn't have the layout either.

            my $themes_path = "$layout_path/themes";
            next unless -d $themes_path;

            # Per-layout failure: don't install orphaned themes under
            # a layout we couldn't successfully place or verify.
            unless ($layout_ok) {
                if ( opendir my $th_skip, $themes_path ) {
                    for my $theme_name ( sort readdir $th_skip ) {
                        next if $theme_name =~ /^\./;
                        my $theme_path = "$themes_path/$theme_name";
                        next unless -d $theme_path;
                        push @results, {
                            source => "layouts/$layout_name/themes/$theme_name",
                            ok     => JSON::PP::false(),
                            error  => "Skipped: layout $layout_name install did "
                                   . "not succeed",
                        };
                    }
                    closedir $th_skip;
                }
                next;
            }

            opendir my $th, $themes_path or next;
            for my $theme_name ( sort readdir $th ) {
                next if $theme_name =~ /^\./;
                my $theme_path = "$themes_path/$theme_name";
                next unless -d $theme_path;

                my $source_rel = "layouts/$layout_name/themes/$theme_name";

                unless ( -f "$theme_path/theme.json" ) {
                    push @results, {
                        source => $source_rel,
                        ok     => JSON::PP::false(),
                        error  => 'Missing theme.json',
                    };
                    next;
                }

                # SM046 consistency check: theme.json's layouts[] must
                # include the source-path LAYOUT. Catches repo-author
                # mistakes (theme filed under the wrong layout dir) at
                # install time rather than at render time. Does NOT
                # replace _install_theme_from_dir's target-site check
                # — that validates every declared layout exists on
                # this install.
                my $mismatch;
                if ( open my $jf, '<:utf8', "$theme_path/theme.json" ) {
                    my $raw = do { local $/; <$jf> };
                    close $jf;
                    my $meta = eval { decode_json($raw) };
                    if ( ref $meta eq 'HASH' && ref $meta->{layouts} eq 'ARRAY' ) {
                        unless ( grep { $_ eq $layout_name } @{ $meta->{layouts} } ) {
                            $mismatch = sprintf(
                                "Theme %s under %s declares layouts: [%s], "
                                . "mismatching source path",
                                $theme_name, $source_rel,
                                join( ', ', @{ $meta->{layouts} } )
                            );
                        }
                    }
                }
                if ($mismatch) {
                    push @results, {
                        source => $source_rel,
                        ok     => JSON::PP::false(),
                        error  => $mismatch,
                    };
                    next;
                }

                my $r = _install_theme_from_dir(
                    $theme_path, 'layouts-install', $auth_user );
                push @results, { source => $source_rel, %$r };
            }
            closedir $th;
        }
        closedir $ld;
    }

    _cleanup_tmp_layouts($tmp_dir);

    # SM060: release may ship a layout-only update (no themes at all).
    # Only error "no themes found" if we ALSO installed no layouts.
    unless ( @results || @layout_results ) {
        return { ok => 0,
            error => 'No layouts or themes found under layouts/*/ in release' };
    }

    my $themes_installed  = scalar grep { $_->{ok} } @results;
    my $layouts_installed = scalar grep { $_->{ok} } @layout_results;

    # SM068: auto-set layout:/theme: in lazysite.conf on a fresh
    # site so the operator isn't left at an empty config after a
    # successful install. Never overwrite an operator-set value —
    # only populate when the key is currently unset or empty. If
    # the install had zero layout successes, no auto-set happens
    # (same for theme).
    my ( $layout_auto_set, $layout_auto_set_name ) = ( 0, '' );
    my ( $theme_auto_set,  $theme_auto_set_name )  = ( 0, '' );
    if ( $layouts_installed >= 1 ) {
        my ($cur_layout, $cur_theme) = _read_active_layout_and_theme();

        unless ( length $cur_layout ) {
            my ($first_layout) = map  { $_->{source} =~ m{^layouts/([^/]+)$} ? $1 : () }
                                 grep { $_->{ok} } @layout_results;
            if ( defined $first_layout && length $first_layout ) {
                if ( _write_conf_key( 'layout', $first_layout ) ) {
                    $layout_auto_set      = 1;
                    $layout_auto_set_name = $first_layout;
                    $cur_layout           = $first_layout;
                    log_event( 'INFO', 'layouts-install',
                        'layout auto-set', name => $first_layout,
                        user => $auth_user );
                }
            }
        }

        # Theme auto-set only when we now have a layout AND theme is
        # unset AND at least one theme installed under that layout.
        if ( length $cur_layout && !length $cur_theme
             && $themes_installed >= 1 ) {
            my ($first_theme) = map  {
                    $_->{source} =~ m{^layouts/\Q$cur_layout\E/themes/([^/]+)$}
                        ? $1 : ()
                } grep { $_->{ok} } @results;
            if ( defined $first_theme && length $first_theme ) {
                if ( _write_conf_key( 'theme', $first_theme ) ) {
                    $theme_auto_set      = 1;
                    $theme_auto_set_name = $first_theme;
                    log_event( 'INFO', 'layouts-install',
                        'theme auto-set', name => $first_theme,
                        layout => $cur_layout, user => $auth_user );
                }
            }
        }
    }

    log_event( 'INFO', 'layouts-install', 'release installed',
        repo             => $repo, tag => $tag,
        layouts_total    => scalar @layout_results,
        layouts_ok       => $layouts_installed,
        themes_total     => scalar @results,
        themes_ok        => $themes_installed,
        layout_auto_set  => $layout_auto_set,
        theme_auto_set   => $theme_auto_set,
        user             => $auth_user );

    return {
        ok              => 1,
        repo            => $repo,
        tag             => $tag,
        layouts         => \@layout_results,
        themes          => \@results,
        layout_auto_set => $layout_auto_set
                            ? JSON::PP::true() : JSON::PP::false(),
        theme_auto_set  => $theme_auto_set
                            ? JSON::PP::true() : JSON::PP::false(),
        layout_auto_set_name => $layout_auto_set_name,
        theme_auto_set_name  => $theme_auto_set_name,
    };
}

# SM068: write-or-replace a single key in lazysite.conf. Same
# replace-or-append pattern as action_plugin_save and
# action_layouts_repo_set, kept as a small helper so the
# auto-set-on-install path isn't a third copy. Empty value is
# rejected (callers should skip rather than write an empty key).
sub _write_conf_key {
    my ( $key, $value ) = @_;
    return 0 unless defined $key && length $key && defined $value && length $value;
    return 0 unless $key =~ /^[A-Za-z_][A-Za-z0-9_-]*$/;

    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    my $content   = '';
    if ( -f $conf_path ) {
        open my $fh, '<:utf8', $conf_path or return 0;
        $content = do { local $/; <$fh> };
        close $fh;
    }

    if ( $content =~ /^$key\s*:/m ) {
        $content =~ s/^$key\s*:.*$/$key: $value/m;
    }
    else {
        $content =~ s/\n?$/\n/;
        $content .= "$key: $value\n";
    }

    my ( $ok, $err ) = write_file_checked( $conf_path, $content );
    return $ok ? 1 : 0;
}

sub _cleanup_tmp_layouts {
    my ($dir) = @_;
    system( "rm", "-rf", $dir ) if $dir =~ m{^/tmp/lazysite-layouts-\d+$};
}

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
sub action_layouts_release_contents {
    my ($tag) = @_;
    $tag //= '';

    return { ok => 0, error => 'Invalid tag' }
        unless length $tag
            && $tag =~ m{^[A-Za-z0-9._/-]+$}
            && $tag !~ m{\.\.};

    my $repo = _layouts_repo();
    return { ok => 0, error => 'layouts_repo not set or invalid in lazysite.conf' }
        unless defined $repo && length $repo
            && $repo =~ m{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$};

    my $have_azip = eval { require Archive::Zip; Archive::Zip->import(qw(:ERROR_CODES)); 1 };
    return { ok => 0,
        error => 'Archive::Zip not installed (apt-get install libarchive-zip-perl)' }
        unless $have_azip;

    require LWP::UserAgent;
    my $ua  = LWP::UserAgent->new( timeout => 30, agent => 'lazysite/1.0' );
    my $url = "https://api.github.com/repos/$repo/zipball/$tag";
    my $res = $ua->get($url);
    return { ok => 0, error => 'Failed to fetch zipball: ' . $res->status_line }
        unless $res->is_success;

    my $tmp_dir = "/tmp/lazysite-layouts-$$";
    make_path($tmp_dir);

    my $zip_path = "$tmp_dir/release.zip";
    unless ( open my $zfh, '>:raw', $zip_path ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Cannot write zipball' };
    }
    else {
        print $zfh $res->content;
        close $zfh;
    }

    my $extract_dir = "$tmp_dir/extracted";
    make_path($extract_dir);

    my $zip = Archive::Zip->new();
    unless ( $zip->read($zip_path) == Archive::Zip::AZ_OK() ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Cannot read zipball' };
    }

    for my $member ( $zip->members ) {
        my $name = $member->fileName;
        if ( $name =~ m{\A/} || $name =~ m{(?:^|/)\.\.(?:/|$)} ) {
            _cleanup_tmp_layouts($tmp_dir);
            return { ok => 0, error => "Unsafe zip entry: $name" };
        }
    }

    unless ( $zip->extractTree( '', "$extract_dir/" ) == Archive::Zip::AZ_OK() ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Extraction failed' };
    }

    # Strip the GitHub wrapper dir (OWNER-REPO-SHA/).
    my @top;
    opendir my $dh, $extract_dir or do {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Cannot read extracted dir' };
    };
    for my $e ( readdir $dh ) {
        next if $e =~ /^\./;
        push @top, $e if -d "$extract_dir/$e";
    }
    closedir $dh;
    unless ( @top == 1 ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0,
            error => 'Unexpected zipball layout (expected single wrapper dir)' };
    }
    my $wrapper = "$extract_dir/$top[0]";

    my $layouts_dir = "$wrapper/layouts";
    unless ( -d $layouts_dir ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0,
            error => 'Release does not contain a layouts/ directory '
                   . '(repo must follow D013 nested shape)' };
    }

    # Walk layouts/LAYOUT/themes/THEME/theme.json. Any parse errors
    # or missing manifests produce an entry with ok => 0 rather than
    # aborting the whole walk — the operator still gets a partial
    # preview.
    my @themes;
    if ( opendir my $ld, $layouts_dir ) {
        for my $layout_name ( sort readdir $ld ) {
            next if $layout_name =~ /^\./;
            my $themes_path = "$layouts_dir/$layout_name/themes";
            next unless -d $themes_path;

            opendir my $th, $themes_path or next;
            for my $theme_name ( sort readdir $th ) {
                next if $theme_name =~ /^\./;
                my $theme_path = "$themes_path/$theme_name";
                next unless -d $theme_path;

                my $tj = "$theme_path/theme.json";
                my $description = '';
                if ( -f $tj && open my $jf, '<:utf8', $tj ) {
                    my $raw = do { local $/; <$jf> };
                    close $jf;
                    my $meta = eval { decode_json($raw) };
                    if ( ref $meta eq 'HASH' && defined $meta->{description} ) {
                        $description = $meta->{description};
                    }
                }
                push @themes, {
                    layout      => $layout_name,
                    name        => $theme_name,
                    description => $description,
                };
            }
            closedir $th;
        }
        closedir $ld;
    }

    _cleanup_tmp_layouts($tmp_dir);

    return { ok => 1, repo => $repo, tag => $tag, themes => \@themes };
}

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

sub action_layouts_available {
    my $layouts_dir = "$DOCROOT/lazysite/layouts";
    my @layouts;
    if ( -d $layouts_dir ) {
        opendir my $dh, $layouts_dir
            or return { ok => 1, layouts => [] };
        for my $name ( sort readdir $dh ) {
            next if $name =~ /^\./;
            # Sanitise: reject anything that wouldn't be a valid layout
            # directory under D013's contract.
            next unless $name =~ /^[A-Za-z0-9_-]+$/;
            next unless -f "$layouts_dir/$name/layout.tt";
            push @layouts, $name;
        }
        closedir $dh;
    }
    return { ok => 1, layouts => \@layouts };
}

sub action_themes_for_layout {
    my ($layout) = @_;
    $layout //= '';
    $layout =~ s/[^A-Za-z0-9_-]//g;
    return { ok => 0, error => 'layout parameter required', themes => [] }
        unless length $layout;

    my $themes_dir = "$DOCROOT/lazysite/layouts/$layout/themes";
    my @themes;
    if ( -d $themes_dir ) {
        opendir my $dh, $themes_dir
            or return { ok => 1, themes => [] };
        for my $name ( sort readdir $dh ) {
            next if $name =~ /^\./;
            next unless $name =~ /^[A-Za-z0-9_-]+$/;
            my $tj = "$themes_dir/$name/theme.json";
            next unless -f $tj;

            # Verify theme declares compatibility with this layout.
            # A theme whose layouts[] doesn't include $layout got there
            # via some non-manager install path and shouldn't surface
            # as a valid choice.
            open my $jf, '<:utf8', $tj or next;
            my $raw = do { local $/; <$jf> };
            close $jf;
            my $meta = eval { decode_json($raw) };
            next unless ref $meta eq 'HASH'
                     && ref $meta->{layouts} eq 'ARRAY'
                     && grep { $_ eq $layout } @{ $meta->{layouts} };

            push @themes, $name;
        }
        closedir $dh;
    }
    return { ok => 1, themes => \@themes, layout => $layout };
}

sub action_layouts_repo_get {
    my $value = _layouts_repo() // '';
    return { ok => 1, value => $value };
}

sub action_layouts_repo_set {
    my ($value) = @_;
    $value //= '';

    # Empty string is the explicit "unset" signal; the key is removed
    # from the conf rather than written as an empty value.
    if ( length $value ) {
        # Match GitHub's actual allowed repo-name chars: each segment
        # starts with alnum and contains alnum/./_/-.
        unless ( $value =~
            m{^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$} ) {
            return { ok => 0,
                error => 'Invalid layouts_repo format (expected OWNER/REPO)' };
        }
    }

    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    my $content   = '';
    if ( -f $conf_path ) {
        open my $fh, '<:utf8', $conf_path
            or return { ok => 0, error => "Cannot read lazysite.conf" };
        $content = do { local $/; <$fh> };
        close $fh;
    }

    if ( length $value ) {
        if ( $content =~ /^layouts_repo\s*:/m ) {
            $content =~ s/^layouts_repo\s*:.*$/layouts_repo: $value/m;
        }
        else {
            $content =~ s/\n?$/\n/;    # ensure trailing newline
            $content .= "layouts_repo: $value\n";
        }
    }
    else {
        # Unset: drop any layouts_repo line entirely.
        $content =~ s/^layouts_repo\s*:.*\n?//m;
    }

    my ( $wok, $werr ) = write_file_checked( $conf_path, $content );
    return { ok => 0, error => "Cannot write lazysite.conf: $werr" }
        unless $wok;

    log_event( 'INFO', 'layouts-repo-set',
        'layouts_repo updated', value => $value, user => $auth_user );

    return { ok => 1, value => $value };
}

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
    my ( $user, $act, $ip, $status ) = @_;
    my $dir = "$LAZYSITE_DIR/logs";
    return unless -d $dir || mkdir($dir);
    require POSIX;
    my $ts = POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime );
    $_ = defined $_ ? "$_" : '' for ( $user, $act, $ip, $status );
    s/[|\r\n]+/ /g for ( $user, $act, $ip, $status );
    open my $fh, '>>', "$dir/audit.log" or return;
    print $fh "$ts | $user | $act | $ip | $status\n";
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
    my $want = $opt{user};
    my @entries;
    for my $line ( reverse @lines ) {
        chomp $line;
        my ( $ts, $u, $act, $ip, $status ) = split / \| /, $line, 5;
        next if defined $want && length $want && ( $u // '' ) ne $want;
        push @entries, { ts => $ts, user => $u, action => $act, ip => $ip, status => $status };
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


