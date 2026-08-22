#!/usr/bin/perl
# lazysite-manager-api.pl - file operations CGI for lazysite manager
use strict;
use warnings;
use Digest::SHA qw(hmac_sha256_hex sha256_hex);
use JSON::PP    qw(encode_json decode_json);
use File::Find;
use File::Path     qw(make_path);
use File::Basename qw(dirname basename);
use Cwd            qw(realpath);
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
use Lazysite::Util                qw(log_event const_eq);
use Lazysite::Paths               ();
use Lazysite::Audit               qw(audit_log);
use Lazysite::Capabilities        qw(describe capability_keys channel_service);
use Lazysite::ControlApi::Actions ();                                             # SM350
use Lazysite::BadUrl              qw(list_blocks unblock);
use Lazysite::Auth::Settings      qw(site_grants_manager);
use Lazysite::Auth::Acl qw(load_acls save_acls _acl_norm _to_list _acl_allows _is_operator _acl_denied);
use Lazysite::Auth::Session   qw(generate_csrf_token verify_csrf_token);
use Lazysite::Manager::Common qw(validate_path is_blocked_path write_file_checked respond
    is_blocked_config is_blocked_upload_target upload_limits load_upload_limits _reset_upload_limits_cache
    _write_conf_key processor_path);
use Lazysite::Manager::Upload qw(action_file_upload action_file_download action_file_zip_download
    check_upload_rate is_editable_text parse_multipart_body);
use Lazysite::Manager::Plugins qw(action_plugin_list action_plugin_enable action_plugin_disable
    action_plugin_read action_plugin_save action_plugin_action action_handler_list
    action_handler_save action_handler_delete action_form_targets_read action_form_targets_save
    action_form_submissions action_form_submission_delete action_form_list
    action_form_submission_confirm action_form_submissions_delete_bulk);
use Lazysite::Manager::Files qw(action_list action_read action_save action_delete action_mkdir
    action_move action_copy action_migrate_to_local action_aliases_list
    acquire_lock release_lock renew_lock _get_lock_info
    action_acl_get action_acl_set action_acl_remove action_protected_sections
    action_git_status action_git_history action_git_history_summary
    action_git_show action_git_restore action_git_init
    action_regenerate_registries);
use Lazysite::Manager::Themes qw(action_theme_list action_themes_list_all action_theme_activate
    action_layout_activate action_theme_delete action_theme_rename action_theme_upload
    action_cache_list action_cache_invalidate _read_active_layout_and_theme
    action_artifact_manifest action_artifact_validate);
use Lazysite::Manager::Nav     qw(action_nav_read action_nav_save);
use Lazysite::Manager::Layouts qw(action_layouts_releases action_layouts_install
    action_layouts_release_contents action_layouts_available action_themes_for_layout
    action_layout_delete action_layouts_manifest action_layout_install
    action_artifact_backups_delete
    action_layouts_repo_get action_layouts_repo_set);
use Lazysite::Manager::Backups qw(action_backup_list action_backup_create action_backup_download
    action_backup_restore action_backup_delete);
use Lazysite::Manager::Sessions qw(action_sessions_list action_session_revoke action_user_revoke);
use Lazysite::Manager::Domains qw(domains_list domain_add domain_remove domain_set domain_check domain_preview preview_public known_domain_host);
use Lazysite::Manager::Data        ();
use Lazysite::Lang                 qw(lang_status sole_group);
use Lazysite::Manager::SitePackage qw(package_create package_apply package_inspect);
$Lazysite::Util::COMPONENT = 'manager-api';

my $DOCROOT = $ENV{DOCUMENT_ROOT} // die "No DOCUMENT_ROOT\n";
$Lazysite::Auth::Acl::DOCROOT            = $DOCROOT;
$Lazysite::Manager::Common::DOCROOT      = $DOCROOT;
$Lazysite::Manager::Upload::DOCROOT      = $DOCROOT;
$Lazysite::Manager::Plugins::DOCROOT     = $DOCROOT;
$Lazysite::Manager::Files::DOCROOT       = $DOCROOT;
$Lazysite::Manager::Themes::DOCROOT      = $DOCROOT;
$Lazysite::Manager::Nav::DOCROOT         = $DOCROOT;
$Lazysite::Manager::Layouts::DOCROOT     = $DOCROOT;
$Lazysite::Manager::Backups::DOCROOT     = $DOCROOT;
$Lazysite::Manager::Domains::DOCROOT     = $DOCROOT;
$Lazysite::Manager::Data::DOCROOT        = $DOCROOT;
$Lazysite::Manager::SitePackage::DOCROOT = $DOCROOT;
my $LAZYSITE_DIR = Lazysite::Paths::lazysite_dir($DOCROOT);    # SM293
$Lazysite::Manager::Backups::LAZYSITE_DIR = $LAZYSITE_DIR;
$Lazysite::Audit::LAZYSITE_DIR            = $LAZYSITE_DIR;
$Lazysite::Auth::Session::LAZYSITE_DIR    = $LAZYSITE_DIR;
$Lazysite::Auth::Settings::AUTH_DIR = "$LAZYSITE_DIR/auth";   # SM138: site_grants_manager
$Lazysite::Manager::Upload::LAZYSITE_DIR   = $LAZYSITE_DIR;
$Lazysite::Manager::Themes::LAZYSITE_DIR   = $LAZYSITE_DIR;
$Lazysite::Manager::Nav::LAZYSITE_DIR      = $LAZYSITE_DIR;
$Lazysite::Manager::Layouts::LAZYSITE_DIR  = $LAZYSITE_DIR;
$Lazysite::Manager::Sessions::LAZYSITE_DIR = $LAZYSITE_DIR;    # SM141
$Lazysite::Manager::Artifact::LAZYSITE_DIR = $LAZYSITE_DIR;
my $LOCK_DIR     = "$LAZYSITE_DIR/manager/locks";
my $LOCK_TIMEOUT = 300;
$Lazysite::Manager::Files::LOCK_DIR     = $LOCK_DIR;
$Lazysite::Manager::Files::LOCK_TIMEOUT = $LOCK_TIMEOUT;

# SM071 Phase 1: theme/layout preview. preview-grant mints the signed
# cookie the processor verifies; declared here (before dispatch runs) so
# the action subs see initialised values.
my $PREVIEW_COOKIE = 'lzs_preview';
my $PREVIEW_TTL    = 3600;            # 1 hour

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

# --- Trust gate (in-app backstop for the identity headers) -------------------
#
# SEC (advisory 2026-07): the identity headers X-Remote-* are trusted ONLY when
# they come from our auth wrapper, which sets them from the HMAC-verified cookie
# and flags LAZYSITE_AUTH_TRUSTED=1 (lazysite-auth.pl). A client must never assert
# its own identity by sending the headers. The web-server edge is meant to strip
# them, but that is not guaranteed (the dev server, a hand-written vhost, or a
# proxy that forwards them), so - exactly as lazysite-processor.pl's
# apply_trust_gate does - the manager-API (the most sensitive endpoint: user
# management, config, file read/write) deletes any client-supplied X-Remote-*
# unless the wrapper vouched for them (LAZYSITE_AUTH_TRUSTED=1) or the operator
# opted into a trusted reverse proxy (auth_proxy_trusted: true). A forged header
# is thus ignored - and logged - rather than granting operator access.
{
    my $trusted = ( $ENV{LAZYSITE_AUTH_TRUSTED} // '' ) eq '1';
    my $proxy   = 'false';
    if ( !$trusted && open my $fh, '<', "$LAZYSITE_DIR/lazysite.conf" ) {
        while ( my $l = <$fh> ) {
            if ( $l =~ /^auth_proxy_trusted\s*:\s*(\S+)/ ) { $proxy = lc $1; last }
        }
        close $fh;
    }
    unless ( $trusted || $proxy eq 'true' ) {
        if ( length( $ENV{HTTP_X_REMOTE_USER} // '' ) ) {
            log_event( 'WARN', 'manager-api',
                'untrusted auth header ignored - set auth_proxy_trusted: true to enable proxy auth',
                header => 'X-Remote-User',
                value  => substr( $ENV{HTTP_X_REMOTE_USER}, 0, 32 ) );
        }
        delete @ENV{
            qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS HTTP_X_REMOTE_NAME HTTP_X_REMOTE_EMAIL)};
    }
}

# --- Auth check ---

# SM138: is the site secured? A site where some group grants manager access
# requires an authenticated user; one where none does is unsecured/dev (any
# authenticated user is a manager, unauthenticated falls back to 'local').
# Replaces the retired lazysite.conf manager_groups signal.
my $site_secured = site_grants_manager();

# SM237: every action name the dispatch chain below recognises, whichever channel
# serves it. Needed because the token-client gate runs BEFORE dispatch and only
# knows %need (the token subset), so without this it cannot tell "exists, but
# cookie-only" from "no such action" - and reported both as the former.
#
# This is a literal because the dispatch is an if/elsif chain rather than a
# table, so there is no runtime set to consult. That is the underlying issue and
# it deserves its own request; a guarded list fixes the misreport now without a
# 108-branch refactor in a copy-and-discoverability release. Drift is impossible:
# t/lint/22-known-action-parity.t extracts the chain's action names and asserts
# this set matches exactly.
# SM262: set when the request authenticated with a TOKEN rather than a manager
# cookie, so theme-delete can be restricted to themes the caller created. Declared
# here because it is set in the auth branch and read at dispatch.
my $RESTRICT_THEME_DELETE = 0;

my %KNOWN_ACTION = map { $_ => 1 } qw(
    acl-get acl-remove acl-set actions-list aliases-list analyse_visitors
    artifact-backups-delete artifact-manifest artifact-validate audit
    backup-create backup-delete backup-download backup-list backup-restore bad-url-blocks
    bad-url-unblock cache-invalidate cache-list channel-services
    config-read config-set copy csrf-token
    data-migrate data-row-delete data-row-save data-rows data-table
    data-table-save data-tables
    delete describe-capabilities
    domain-add domain-check domain-preview domain-remove domain-set preview-public
    domains-list file-download file-upload file-zip-download form-list
    form-submission-confirm form-submission-delete form-submissions
    form-submissions-delete-bulk form-targets-read form-targets-save
    git-history git-history-summary git-init git-restore git-show
    git-status handler-delete handler-list handler-save key-revoke
    keys-list lang-status layout-activate layout-delete layout-install
    regenerate-registries
    layouts-available layouts-install layouts-manifest
    layouts-release-contents layouts-releases layouts-repo-get
    layouts-repo-set list lock migrate-to-local mkdir move nav-read
    nav-save notices notices-seen pages plugin-action plugin-disable
    plugin-enable plugin-list plugin-read plugin-save preview preview-clear
    preview-grant principals protected-sections read recent-changes renew-lock
    rotate-auth-secret save session-revoke sessions-list site-backup-apply
    site-backup-create site-backup-delete site-backup-download
    site-backup-inspect site-backup-upload site-export-primary
    theme-activate theme-delete theme-list theme-rename themes-for-layout
    themes-list-all theme-upload unlock user-revoke users version whoami
);

# SM230: the control API is not callable from a browser page, by design. Its
# authenticated surfaces are for agents, scripts and the manager, all of which
# hold operator-issued credentials; a page on an arbitrary origin holds none, and
# a credential a browser could hold is a credential that is exposed.
#
# That position was previously expressed only by the ABSENCE of CORS headers,
# which fails opaquely: the browser reports a generic CORS error naming no cause,
# and the server logs nothing an operator could correlate. Answer the preflight
# explicitly instead - refuse, say why, and record the origin that tried. This
# grants nothing: no Access-Control-Allow-* header is emitted here or anywhere on
# this surface, and 405 is the honest status because OPTIONS is not a method this
# API serves. Handled BEFORE auth, because a preflight carries no credentials and
# would otherwise 401 into the same opaque failure.
if ( ( $ENV{REQUEST_METHOD} // '' ) eq 'OPTIONS' ) {
    my $origin = $ENV{HTTP_ORIGIN} // '';
    log_event( 'INFO', 'cors', 'browser-origin preflight refused',
        origin => ( length $origin ? $origin : '(none)' ) );
    binmode(STDOUT);
    print "Status: 405 Method Not Allowed\r\n";
    print "Allow: GET, POST\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json( {
            ok    => JSON::PP::false,                                             # SM353
            error => 'The control API is not callable from a browser page. It '
                . 'serves agents, scripts and the manager, which hold '
                . 'operator-issued credentials; a page cannot hold one safely. To '
                . 'send something from a browser, use a form POST (same-origin, '
                . 'validated, stored, and it raises a notification). To do '
                . 'privileged work, call this API from somewhere that holds a '
                . 'credential. See /docs/api.',
    } );
    exit 0;
}

# SM071 Phase 3: control-API token front-path. A request authenticated by
# Authorization: Basic <user>:<lzs_ token> carries no session cookie; it is
# verified against the user database (via the users tool, which owns the
# hashing), gated per-action by capability (below), and exempt from the
# CSRF check (no cookie ⇒ no ambient authority ⇒ no CSRF vector).
my $auth_user;
my $token_auth = 0;
my %token_caps;
my @REQUEST_SCOPES;    # SM158: the request's resolved dav_scopes (union), for
                       # per-domain content-access checks in actions like
                       # site-backup-create/apply. Empty => unconfined operator.
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
                respond( { ok => 0, error => 'Do not combine cookie and token auth' } );
                exit 0;
            }
            # Service killswitch (0.9.0): the control-API token surface is OFF
            # unless the operator enables it in lazysite.conf
            # (control_api_enabled: true), mirroring webdav_enabled. Checked as
            # soon as a token is presented - before verification - so a disabled
            # instance does no token processing at all. The cookie manager UI
            # reaches the same endpoint and is unaffected (it is gated by
            # `manager:`). Default off; opt in from the Services page.
            unless ( Lazysite::Util::service_enabled( $DOCROOT, 'control_api_enabled' ) ) {
                respond( { ok => 0, code => 'service_disabled',
                        error => 'The control API (token access) is not '
                            . 'enabled on this site. Ask the operator to enable it (Services -> Control API).' } );
                exit 0;
            }
            my $v = users_api( { action => 'verify-credential',
                    username => $u, secret => $secret } );
            unless ( $v && $v->{ok} ) {
                sleep 1;    # brute-force delay (per-IP limiter lands in P3.6)
                respond( { ok => 0, error => 'Invalid credentials' } );
                exit 0;
            }
            $auth_user  = $u;
            $token_auth = 1;
            %token_caps = %{ $v->{settings} || {} };
        }
    }
}

# Cookie (manager) auth: the trusted X-Remote-User set by the auth wrapper.
unless ($token_auth) {
    $auth_user = $ENV{HTTP_X_REMOTE_USER} // '';

    # SM268 H9: an unauthenticated request is REFUSED. Always.
    #
    # This used to fall through to `$auth_user ||= 'local'` whenever no group
    # granted manager access - and `local` is the operator sentinel, so an
    # "unsecured" site was not "any authenticated user is a manager" (as
    # security.md claimed) but "no credential required, and you are the
    # operator". Two ways to be there:
    #
    #   * a fresh install, before setup-manager has run. The window had no lower
    #     bound on a manual install.
    #   * a site pushed BACK into it - a manage_users delegate stripping ui /
    #     manage_users / manager from every group, which the lockout guard in
    #     cmd_group_settings_set did not prevent because it only ever covered the
    #     `manager` flag.
    #
    # The intended first-run flow is the CLI: `lazysite-users.pl setup-manager`
    # creates the first manager account and hands over the credential. Until it
    # has run there is no account to log in as, so refusing is not a loss of
    # function - it is the accurate answer. `local` remains the CLI's identity
    # and is unaffected; it never arrives over HTTP.
    unless ( length $auth_user ) {
        respond(
            { ok => 0,
                error => $site_secured
                ? 'Authentication required'
                : 'This site has no manager account yet. Create one from the '
                    . 'command line with: lazysite-users.pl --docroot <docroot> '
                    . 'setup-manager'
            }
        );
        exit 0;
    }
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
$Lazysite::Manager::Common::action      = $action;
$Lazysite::Manager::Common::auth_user   = $auth_user;
$Lazysite::Manager::Upload::auth_user   = $auth_user;
$Lazysite::Manager::Backups::auth_user  = $auth_user;
$Lazysite::Manager::Plugins::action     = $action;
$Lazysite::Manager::Files::auth_user    = $auth_user;
$Lazysite::Manager::Files::action       = $action;
$Lazysite::Manager::Themes::auth_user   = $auth_user;
$Lazysite::Manager::Nav::auth_user      = $auth_user;
$Lazysite::Manager::Themes::action      = $action;
$Lazysite::Manager::Layouts::auth_user  = $auth_user;
$Lazysite::Manager::Layouts::action     = $action;
$Lazysite::Manager::Sessions::auth_user = $auth_user;    # SM141
$Lazysite::Manager::Domains::auth_user  = $auth_user;    # SM154
$Lazysite::Auth::Acl::auth_user         = $auth_user;
$Lazysite::Auth::Acl::token_auth        = $token_auth;
# SM077 / SM288: the requester's groups, for @group ACL entries.
#
# A COOKIE client's groups arrive in X-Remote-Groups, set by the auth wrapper
# from the validated session - that is the trusted path and it stays.
#
# A TOKEN client cannot send that header at all, so this used to leave a partner
# with no groups and an @group entry silently never matched it - while the same
# account over WebDAV matched fine. Resolve from the account instead: a group is
# a property of the account, not of the door it arrived through.
@Lazysite::Auth::Acl::user_groups
    = $token_auth
    ? Lazysite::Auth::Acl::groups_for_user($auth_user)
    : grep { length } split /[,\s]+/, ( $ENV{HTTP_X_REMOTE_GROUPS} // '' );

# SEC-2026-07 (M2) / SM154 (P1): the content path-bearing actions whose target a
# dav_scope binding confines (WebDAV enforces the same). Non-content actions
# carry no path (or $path defaults to '/'); the lazysite/ theme-authoring
# namespace is outside scope's remit (governed by manage_themes/manage_layouts).
my %SCOPED_ACTION = map { $_ => 1 } qw(
    list read save delete mkdir move copy migrate-to-local file-upload
    file-download file-zip-download
    acl-get acl-set acl-remove git-status git-history git-show git-restore
    cache-invalidate preview lock unlock renew-lock
);

# Confine this request to a SET of content-root scopes, refusing any content
# path outside EVERY scope. SM155: the binding moved to groups, so the set is the
# UNION of the user's scoped groups (already resolved into the settings'
# `dav_scopes` by effective_settings). Shared by the token/partner (M2) and
# cookie (SM154) channels; $origin tags the audit entry ('api' | 'ui'). An empty
# set confines nothing (an unbound account).
sub _confine_scope {
    my ( $scopes, $origin ) = @_;
    return unless $SCOPED_ACTION{$action} && ref $scopes eq 'ARRAY' && @$scopes;
    for my $p ( grep { defined && length } ( $path, $params{to}, $params{from} ) ) {
        next if $p =~ m{^/?lazysite/};
        next
            unless Lazysite::Manager::Common::outside_all_scopes( $scopes, $p );
        audit_log( $auth_user, $action, $p, $ENV{REMOTE_ADDR} // '',
            'fail', $origin, 'denied: outside dav_scope' );
        my $names = join ', ',
            map { ( my $s = $_ ) =~ s{^/+|/+$}{}g; "$s/" } @$scopes;
        respond( { ok => 0, kind => 'forbidden',
                error => "Path '$p' is outside your assigned scope ($names)." } );
        exit 0;
    }
}

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
            respond( { ok => 0,
                    error => "Upload exceeds limit of "
                        . int( $max / 1024 / 1024 ) . " MB" } );
            exit 0;
        }
        my $rate = check_upload_rate( $auth_user, $len );
        unless ( $rate->{ok} ) {
            respond( { ok => 0, error => $rate->{error} } );
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
    my $token  = $ENV{HTTP_X_CSRF_TOKEN} // '';
    my $source = $token ? 'header' : '';
    if ( !$token && $body ) {
        my $parsed = eval { decode_json($body) };
        if ( ref $parsed eq 'HASH' ) {
            $token  = $parsed->{csrf_token} // '';
            $source = 'body' if $token;
        }
    }
    if ( !$token ) {
        $token  = $params{csrf_token} // '';
        $source = 'query' if $token;
    }

    log_event( 'DEBUG', $action, 'CSRF check',
        method    => $method,
        user      => $auth_user,
        token_len => length($token),
        source    => $source || 'none',
        result    => $token ? 'has-token' : 'no-token' );

    my $valid = verify_csrf_token( $token, $auth_user );

    log_event( 'DEBUG', $action, 'CSRF verify',
        user   => $auth_user,
        result => $valid ? 'ok' : 'fail' );

    unless ($valid) {
        respond( { ok => 0, error => 'Invalid or missing CSRF token' } );
        exit 0;
    }
}

# Per-action csrf-token read
if ( $action eq 'csrf-token' ) {
    respond( { ok => 1, token => generate_csrf_token($auth_user) } );
    exit 0;
}

# SEC-2026-07 (H1/H2): cookie/manager path authorization. The %need map below
# gates only TOKEN clients; a cookie session historically reached every action
# ungated ("manager UI = trusted operator"), so a low-privilege interactive
# account (content-editors) could config-set, run backups, enable plugins, etc.
# Now the cookie path is capability-gated by the same model, and a state-changing
# action must be POST (a GET would bypass the CSRF gate above - and be CSRF-able
# from an admin's browser). Operators (manage_users, or the unsecured/dev
# fallback where no group grants manager) bypass the CAPABILITY gate, matching
# the rest of the manager. The users/sessions/keys/audit/notices actions keep
# their own bespoke gates in dispatch (they carry actor confinement / forbidden
# messaging), so they are not listed here.
if ( !$token_auth ) {
    my %COOKIE_CAP = (
        # Content-mutation actions (save/delete/mkdir/move/copy/file-upload/
        # migrate-to-local) and acl-get/set/remove self-authorize per file via
        # the ACL layer (action_save -> _acl_can_write; action_acl_* by
        # ownership): a file owner or @group-listed writer need not hold the
        # global manage_content cap. They are absent from the token %need map
        # for the same reason (token clients write over WebDAV). So they are NOT
        # capability-gated here - only POST-gated below (CSRF). Content-history
        # reads/restore ARE gated (they mirror the token %need manage_content).
        'git-restore'         => 'manage_content', 'git-status' => 'manage_content',
        'git-history'         => 'manage_content', 'git-show'   => 'manage_content',
        'git-history-summary' => 'manage_content',   # SM199: site-level file list + stats
            # SM160: domains + the portable site-package family are their own
            # capability (manage_domains), carved out of the broad manage_config.
            # SM447: the data plugin's capability. Reads and writes alike -
            # unlike content, a table row has no per-file ACL to self-authorize
            # against, so the capability IS the gate.
        'data-tables'        => 'manage_data', 'data-table'      => 'manage_data',
        'data-rows'          => 'manage_data', 'data-migrate'    => 'manage_data',
        'data-row-save'      => 'manage_data', 'data-row-delete' => 'manage_data',
        'data-table-save'    => 'manage_data',
        'site-backup-create' => 'manage_domains', 'site-backup-upload' => 'manage_domains',
        'site-backup-apply'  => 'manage_domains',
        'site-backup-inspect' => 'manage_domains', # SM183: read a package manifest (no apply)
        'site-backup-delete'   => 'manage_domains', # SM183: remove a package
        'site-backup-download' => 'manage_domains', # SM193: token-client package download
        'site-export-primary' => 'manage_content', # SM185: package the DEFAULT site (no domains feature needed)
        'git-init'            => 'manage_config',
        'config-set'     => 'manage_config', 'config-read' => 'manage_config',
        'bad-url-blocks' => 'manage_config',
        'domains-list'   => 'manage_domains', 'domain-add'    => 'manage_domains',
        'domain-set'     => 'manage_domains', 'domain-remove' => 'manage_domains',
        'domain-preview' => 'manage_domains', 'domain-check'  => 'manage_domains',
        'lang-status' => 'manage_content', # SM179 P6: read-only set coverage (a translation agent's cap)
            # F3 audit: the account/group roster backs the ACL "grant to whom" picker
            # (Files, manage_content) and the domain-groups picker (Domains,
            # manage_domains). Gate it to those callers so a user with no
            # grant-related capability cannot enumerate every username/group.
        'principals' => 'manage_content|manage_domains',
        # SM267: the Protected sections list names ACL prefixes and their read
        # lists, which is the same disclosure acl-get carries per file - so it
        # takes the same capability, and the response is scope-filtered on top.
        'protected-sections' => 'manage_content',
        'bad-url-unblock'    => 'manage_config', 'rotate-auth-secret' => 'manage_config',
        'backup-create'      => 'manage_config', 'backup-restore'     => 'manage_config',
        # SM268 03-F11: removing a snapshot is the same authority as taking or
        # restoring one.
        'backup-delete'   => 'manage_config',
        'backup-download' => 'manage_config',  'backup-list'     => 'manage_config',
        'theme-activate'  => 'manage_themes',  'theme-delete'    => 'manage_themes',
        'theme-rename'    => 'manage_themes',  'theme-upload'    => 'manage_themes',
        'layout-activate' => 'manage_layouts', 'layout-delete'   => 'manage_layouts',
        'layout-install'  => 'manage_layouts', 'layouts-install' => 'manage_layouts',
        'layouts-repo-set'        => 'manage_layouts',
        'preview-grant'           => 'manage_themes|manage_layouts',
        'preview-clear'           => 'manage_themes|manage_layouts',
        'artifact-backups-delete' => 'manage_themes|manage_layouts',
        'nav-save'                => 'manage_nav',
        'handler-save'            => 'manage_forms', 'handler-delete' => 'manage_forms',
        'form-targets-save'       => 'manage_forms',
        'form-submissions' => 'manage_forms|read_submissions', # SM182/SM187: read PII submissions (GET)
        'form-list' => 'manage_forms|read_submissions',   # SM214: PII-free form discovery
        'form-submission-delete' => 'manage_forms', # SM187: remove a handled submission row
        'form-submission-confirm' => 'manage_forms', # SM216: clear a row's quarantine flag
        'form-submissions-delete-bulk' => 'manage_forms', # SM187: delete several rows at once
        'plugin-enable' => 'manage_config', 'plugin-disable'   => 'manage_config',
        'plugin-read'   => 'manage_config', 'plugin-save'      => 'manage_config',
        'plugin-action' => 'manage_config', 'analyse_visitors' => 'analytics',
        # SEC-2026-07 (C1): the account-management action requires a user-mgmt
        # capability to be reached at all - a content-only account could
        # previously reset any password (incl. the admin's). A delegated
        # sub-manager (create_sub_users) is then confined to its own sub-tree by
        # the actor logic in the users tool.
        'users' => 'manage_users|create_sub_users|delegate_sub_user_creation',
    );
    # Mutating actions are cookie-manager-only; a token client gets "not available".
    # SM214: form-submission-delete is in this set DELIBERATELY - deleting a stored
    # submission is a destructive PII operation, so it stays interactive-only. A
    # token client discovers forms (form-list) and reads submissions (form-submissions),
    # but a human confirms deletions in the manager.
    my %MUTATING = map { $_ => 1 } qw(
        data-migrate data-row-save data-row-delete data-table-save
        save delete mkdir move copy migrate-to-local file-upload git-restore
        git-init cache-invalidate acl-set acl-remove config-set bad-url-unblock
        rotate-auth-secret backup-create backup-delete backup-restore theme-activate
        theme-delete theme-rename theme-upload layout-activate layout-delete
        layout-install layouts-install layouts-repo-set artifact-backups-delete
        preview-grant preview-clear nav-save handler-save handler-delete
        form-targets-save form-submission-delete form-submission-confirm form-submissions-delete-bulk plugin-enable plugin-disable plugin-save plugin-action
        lock unlock renew-lock notices-seen regenerate-registries
        domain-add domain-set domain-remove
        session-revoke user-revoke key-revoke
        site-backup-create site-backup-upload site-backup-apply site-backup-delete
        site-export-primary
    );
    # NB: 'users' is deliberately NOT listed - it is dual-mode (GET reads
    # list/groups; writes self-enforce POST inside action_users). session/user/
    # key revocation are pure writes, so forcing POST here (SEC-2026-07, CSRF
    # completeness) makes the method-keyed CSRF gate above cover them by
    # construction, rather than relying on their target param arriving in the
    # POST body.

    if ( $MUTATING{$action} && $method ne 'POST' ) {
        respond( { ok => 0, error => "This action must be sent as POST." } );
        exit 0;
    }
    if ( !_is_operator() ) {
        my $caps = _user_caps($auth_user);

        # Capability gate (H1): the escalation-sensitive actions need their cap.
        if ( my $req_cap = $COOKIE_CAP{$action} ) {
            my $ok = 0;
            $ok ||= $caps->{$_} for split /\|/, $req_cap;
            unless ($ok) {
                audit_log( $auth_user, $action, ( $path // '' ), $ENV{REMOTE_ADDR} // '',
                    'fail', 'ui', 'denied: capability' );
                ( my $names = $req_cap ) =~ s/\|/ or /g;
                respond( { ok => 0, kind => 'forbidden',
                        error => "This action requires the '$names' permission. An "
                            . "administrator can grant it on the Groups page." } );
                exit 0;
            }
        }

        # SM154/SM155 (P1): a domain-bound cookie user (via their scoped
        # group(s)) is confined to the union of their content roots on the
        # interactive channel too, so a delegated domain editor cannot reach
        # another domain's content through the manager UI.
        _confine_scope( $caps->{dav_scopes}, 'ui' );
        @REQUEST_SCOPES = @{ $caps->{dav_scopes} || [] };
    }
}

# SM071 Phase 3: token clients are confined to the control-API action set
# and gated by capability. Cookie (manager) requests are unaffected and
# keep their existing manager-group authorisation.
if ($token_auth) {
    # Introspection (whoami, describe-capabilities) stays open to ANY authenticated
    # token - a capless or manager-linked agent must still be able to ask "what am
    # I / what may I do", per the SM072/SM126 contract. Declared here so BOTH gates
    # below honour it (the SM127 gate previously ran ahead of it and wrongly refused
    # whoami on a manager-linked account).
    # SM350 adds actions-list: the reference to what this account may call is
    # exactly what a capless agent needs BEFORE it knows what it may call.
    my %introspection
        = ( 'whoami' => 1, 'describe-capabilities' => 1, 'actions-list' => 1 );

    # SM127: manager/UI-remote separation. An account that can ACTUALLY use the
    # interactive manager UI must not drive the site over a remote token (a leaked
    # token on a live manager account is the accidental-grant vector). "Can use the
    # UI" = the `ui` capability from a group (manager_ui) AND interactive login
    # enabled (the account-level `ui` flag). An account with ui:false is a
    # deliberate agent account - as this message itself advises - so its token
    # honours its own api-channel capabilities regardless of any manager group it
    # also sits in; per the partner contract the token path is capability-based and
    # manager/operator status neither adds nor removes access here. Introspection is
    # exempt (see above). Audited when it fires.
    if ( $token_caps{manager_ui} && $token_caps{ui} && !$introspection{$action} ) {
        audit_log( $auth_user, $action, ( $path // '' ), $ENV{REMOTE_ADDR} // '',
            'fail', 'api', 'denied: interactive manager account on the api channel' );
        respond( { ok => 0, error => "This account can use the interactive manager UI, "
                    . "which is interactive-only: it cannot be driven over the API or MCP. "
                    . "Use a dedicated agent account (api/mcp capabilities, interactive login "
                    . "disabled) instead." } );
        exit 0;
    }

    # SM126: strict channel gate. A token client operates on the `api` channel and
    # must hold the `api` capability, enforced ahead of the per-action check so a
    # token without the channel is refused uniformly. The manager UI reaches the
    # same endpoint over a cookie - that is the `ui` channel, gated at login, and
    # is unaffected (this branch runs only for token auth). Introspection actions
    # (whoami, describe-capabilities) stay open to any authenticated token - a
    # capless agent must still be able to ask "what am I / what may I do" and learn
    # it lacks the channel, per the SM072 introspection contract.
    unless ( $token_caps{api} || $introspection{$action} ) {
        audit_log( $auth_user, $action, ( $path // '' ), $ENV{REMOTE_ADDR} // '',
            'fail', 'api', 'denied: api channel capability' );
        respond( { ok => 0, error => "The 'api' capability is required to use the "
                    . "control API. Ask the operator to grant the api capability to your "
                    . "account's group." } );
        exit 0;
    }

    # SM262: this whole branch runs ONLY for token auth, so reaching it is what
    # marks the caller as automated rather than a human at the manager console.
    # The flag is read at dispatch, where the acting user is also known.
    $RESTRICT_THEME_DELETE = 1;

    my %need = (
        'artifact-manifest' => sub { $_[0]->{manage_themes} || $_[0]->{manage_layouts} },
        'artifact-validate' => sub { $_[0]->{manage_themes} || $_[0]->{manage_layouts} },
        'theme-activate'    => sub { $_[0]->{manage_themes} },
        'layout-activate'   => sub { $_[0]->{manage_layouts} },
        'preview-grant'     => sub { $_[0]->{manage_themes} || $_[0]->{manage_layouts} },
        'config-set'        => sub { $_[0]->{manage_config} },
        'config-read'       => sub { $_[0]->{manage_config} }, # SM122: read a safe subset
            # SM160: domain management + the portable site-package family are the
            # manage_domains capability (carved out of manage_config), so an
            # orchestrating control panel drives the lazysite side of a deploy
            # with a manage_domains token, same as the CLI/UI.
            # SM447: token clients are the point of the data plugin - an agent
            # populating a table is the primary use, not an afterthought.
        'data-tables'     => sub { $_[0]->{manage_data} },
        'data-table'      => sub { $_[0]->{manage_data} },
        'data-rows'       => sub { $_[0]->{manage_data} },
        'data-migrate'    => sub { $_[0]->{manage_data} },
        'data-row-save'   => sub { $_[0]->{manage_data} },
        'data-table-save' => sub { $_[0]->{manage_data} },
        'data-row-delete' => sub { $_[0]->{manage_data} },
        'domains-list'    => sub { $_[0]->{manage_domains} },   # read-only domains view
        'domain-add'      => sub { $_[0]->{manage_domains} },
        'domain-set'      => sub { $_[0]->{manage_domains} },
        'domain-remove'   => sub { $_[0]->{manage_domains} },
        'domain-preview'  => sub { $_[0]->{manage_domains} },   # SM155: pre-DNS render
        'domain-check'    => sub { $_[0]->{manage_domains} },   # SM156: live config check
        'lang-status' => sub { $_[0]->{manage_content} }, # SM179 P6: set coverage (translation agent)
            # SM301: the twin of MCP's regenerate_registries. Same capability, and
            # now the same availability - the account that holds manage_content can
            # reach it whichever door it was granted.
        'regenerate-registries' => sub { $_[0]->{manage_content} },
        # SM281 item 3: the notice store as a READ surface.
        #
        # `notifications` unlocked a manager page and had no remote surface at
        # all - the bell reads the store, and MCP and the control API could
        # not. That is an SM239 parity gap on its own, and it is the half that
        # makes the agent door real: SM231 recorded, from observation rather
        # than speculation, that remote agents had been EDITING THE BRIEFING
        # DOCUMENT to talk to each other, because it was the only durable,
        # shared, writable place they both had.
        #
        # Read only. Writing is emission, which SM231 built and which routes by
        # type; a remote writer is item 2's addressing question and is not
        # answered by making the store readable.
        'notices' => sub { $_[0]->{notifications} },
        # SM282: seeing what a VISITOR gets for a path you can already read.
        # It renders anonymously, so it can never show more than the public
        # sees - manage_content is the grant that makes the question yours to
        # ask, not a grant to see anything new.
        'preview-public'       => sub { $_[0]->{manage_content} },
        'site-backup-create'   => sub { $_[0]->{manage_domains} },    # SM158
        'site-backup-upload'   => sub { $_[0]->{manage_domains} },
        'site-backup-apply'    => sub { $_[0]->{manage_domains} },
        'site-backup-inspect'  => sub { $_[0]->{manage_domains} },    # SM183
        'site-backup-delete'   => sub { $_[0]->{manage_domains} },    # SM183
        'site-backup-download' => sub { $_[0]->{manage_domains} },    # SM193
        'site-export-primary'  => sub { $_[0]->{manage_content} },    # SM185
            # SM187: agents read form submissions with a least-privilege read_submissions
            # cap OR the operator's manage_forms - parity with the cookie channel.
        'form-submissions' => sub { $_[0]->{manage_forms} || $_[0]->{read_submissions} },
        'form-list' => sub { $_[0]->{manage_forms} || $_[0]->{read_submissions} }, # SM214: read-only, PII-free
        'bad-url-blocks'  => sub { $_[0]->{manage_config} },    # SM128: blocked-IP list
        'bad-url-unblock' => sub { $_[0]->{manage_config} },
        'pages' => sub { $_[0]->{manage_nav} },  # SM097: page-URL list for the nav editor
            # SM123: a theme/layout manager may list what is installed (was previously
            # unavailable to token clients, so they activated each in turn to discover).
        'theme-list'        => sub { $_[0]->{manage_themes} || $_[0]->{manage_layouts} },
        'themes-for-layout' => sub { $_[0]->{manage_themes} || $_[0]->{manage_layouts} },
        'themes-list-all'   => sub { $_[0]->{manage_themes} || $_[0]->{manage_layouts} },
        'layouts-available' => sub { $_[0]->{manage_themes} || $_[0]->{manage_layouts} },
        'layouts-manifest'  => sub { $_[0]->{manage_themes} || $_[0]->{manage_layouts} },
        # SM: a layouts manager may install/remove layouts on demand from the repo.
        'layout-install' => sub { $_[0]->{manage_layouts} },
        'layout-delete'  => sub { $_[0]->{manage_layouts} },
        # SM262: a caller that can create a theme may remove one IT created, and
        # nothing else - enforced in action_theme_delete, which this branch asks
        # for by setting $RESTRICT_THEME_DELETE below. Without this an agent
        # accumulated an experiment per attempt and only the operator could clear
        # them. The manager UI over a cookie session does not take this path and
        # keeps the unrestricted delete: a human at the console is the case the
        # UI-only rule was protecting, and it still is.
        'theme-delete'            => sub { $_[0]->{manage_themes} },
        'artifact-backups-delete' => sub { $_[0]->{manage_layouts} || $_[0]->{manage_themes} },
        # SM105: navigation is a token-client action gated by manage_nav (which
        # inherits manage_content / webdav), so a WebDAV/API partner can read and
        # write the site nav without the MCP connector or raw WebDAV to lazysite/.
        'nav-read' => sub { $_[0]->{manage_nav} },
        'nav-save' => sub { $_[0]->{manage_nav} },
        # SM134 follow-ups: the alias-redirect map is content-derived - a content
        # partner may list it (read-only; aliases are front-matter-authored).
        'aliases-list' => sub { $_[0]->{manage_content} },
        # SM085: content history. Reads and restore follow the content grant
        # (restore routes through the normal save path); enabling/initialising
        # the repo is a site-configuration act.
        'git-status'          => sub { $_[0]->{manage_content} },
        'git-history'         => sub { $_[0]->{manage_content} },
        'git-history-summary' => sub { $_[0]->{manage_content} },    # SM199
        'git-show'            => sub { $_[0]->{manage_content} },
        'git-restore'         => sub { $_[0]->{manage_content} },
        'git-init'            => sub { $_[0]->{manage_config} },
        'whoami' => sub { 1 },    # any authenticated token may introspect its own grant
        'describe-capabilities' => sub { 1 },  # SM126: introspection - the capability map
        'actions-list' => sub { 1 },    # SM350: introspection - the action reference
            # Visitor-log analysis over the control API (token clients), same grant as
            # the MCP analyse_visitors tool - so an API-channel agent gets analytics too.
        'analyse_visitors' => sub { $_[0]->{analytics} },
        # The audit trail is its own capability, separate from visitor analytics.
        'audit' => sub { $_[0]->{audit} },
        # SM074: a publishing partner manages ACLs on the content it owns.
        'acl-get'    => sub { $_[0]->{webdav} },
        'acl-set'    => sub { $_[0]->{webdav} },
        'acl-remove' => sub { $_[0]->{webdav} },
    );
    # SM212: why a KNOWN action is withheld from token clients, where the answer
    # is a decision and not just "the manager UI owns this screen". Only the
    # actions whose absence would otherwise read as an oversight need an entry;
    # the rest fall back to the generic sentence.
    my %COOKIE_ONLY_REASON = (
        'form-submission-delete' =>
            'deleting a stored submission is a destructive operation on personal '
            . 'data, and often on the only copy, so SM214 keeps it interactive: a '
            . 'human confirms it in the manager. Reading submissions IS available '
            . 'to this account with the right capability',
        'form-submissions-delete-bulk' =>
            'the same reason as form-submission-delete, and more so - a bulk '
            . 'delete of personal data is not an operation to expose to an '
            . 'automated caller',
        'rotate-auth-secret' =>
            'rotating the signing secret invalidates every live session, '
            . 'including the caller\'s own, so it is done by a human who can see '
            . 'what breaks',
    );

    my $check = $need{$action};
    unless ($check) {
        # SM237: "not available to token clients" answered BOTH an action that
        # exists and that token clients may not call, AND an action name the
        # server does not recognise at all. Those point in opposite directions -
        # ask the operator for a grant, versus fix your request - and an agent
        # that mis-sent a query string read the first and reported a capability
        # problem that did not exist. %need is only the token-client subset, so it
        # cannot tell them apart; %KNOWN_ACTION is the full recognised set and
        # t/lint/22-known-action-parity.t pins it to the dispatch chain.
        if ( $KNOWN_ACTION{$action} ) {
            # SM212: and say WHY, where the reason is a decision rather than
            # simply the shape of the interactive UI.
            #
            # SM237 fixed "exists but you may not call it" versus "no such
            # action", which are the two an agent must not confuse. This is the
            # third: an action withheld ON PURPOSE reads exactly like one nobody
            # got round to exposing, so a site agent validating 0.10.7 recorded
            # the submission deletes as a parity gap to be closed. They are not a
            # gap. Naming the reason is the difference between a report that says
            # "not built" and one that says "held back, and here is the
            # argument".
            my $why = $COOKIE_ONLY_REASON{$action};
            respond( { ok => 0,
                    error => "Action not available to token clients: $action. It "
                        . 'exists, but is served only to the manager UI over a cookie '
                        . 'session'
                        . ( $why ? " - $why" : '' ) . '. '
                        . 'Call describe-capabilities to see what this '
                        . 'account can do over the API.' } );
        }
        else {
            respond( { ok => 0,
                    error => "Unrecognised action name: '$action'. This is not an "
                        . 'action - check the spelling and the query string (a '
                        . 'doubled "action=" is the usual cause). Call '
                        . 'describe-capabilities for the actions this account can '
                        . 'use.' } );
        }
        exit 0;
    }
    unless ( $check->( \%token_caps ) ) {
        # Audit the denied attempt (was invisible before).
        audit_log( $auth_user, $action, ( $path // '' ), $ENV{REMOTE_ADDR} // '',
            'fail', 'api', 'denied: capability' );
        respond( { ok => 0, error => "Insufficient capability for $action. Call "
                    . "describe-capabilities to see what your account holds and what each "
                    . "capability unlocks." } );
        exit 0;
    }

    # SEC-2026-07 (M2) / SM155: enforce the group-derived scope union on the
    # control-API channel too - a scoped partner credential is confined to its
    # content subtree(s) over WebDAV and must be here as well.
    _confine_scope( $token_caps{dav_scopes}, 'api' );
    @REQUEST_SCOPES = @{ $token_caps{dav_scopes} || [] };

    # SM071 Phase 3 (P3.6): per-token volume throttle. 429 + Retry-After
    # so the client can back off per the documented retry contract.
    my $rl = _rate_ok($auth_user);
    unless ( $rl->{ok} ) {
        binmode(STDOUT);    # encode_json emits UTF-8 bytes; do not re-encode
        print "Status: 429 Too Many Requests\r\n";
        print "Retry-After: $rl->{retry_after}\r\n";
        print "Content-Type: application/json; charset=utf-8\r\n\r\n";
        print encode_json(
            { ok => JSON::PP::false, error => 'Rate limit exceeded' } );    # SM353
        exit 0;
    }
}

# SM268 H4: the generic file surface reaches two paths inside lazysite/ that
# every other plane gates on a capability - nav.conf (manage_nav) and the
# submission store (read_submissions / manage_forms). Reaching them by path
# defeated all three. The requirement is defined once, in Manager::Common;
# applied here against the caller's resolved capabilities, and in lazysite-mcp.pl
# against the partner's, so the two dispatchers cannot drift apart.
#
# Skipped on an unsecured site (no group grants manager access at all), which is
# the dev/first-run state where _is_operator() already treats every
# authenticated user as the operator - the same exemption, not a new one.
{
    my %file_surface = (
        'list'        => 'read',
        'read'        => 'read',
        'acl-get'     => 'read',
        'preview'     => 'read',
        'git-history' => 'read',
        'git-show'    => 'read',
        'save'        => 'write',
        'delete'      => 'write',
        'acl-set'     => 'write',
        'acl-remove'  => 'write',
        'mkdir'       => 'write',
        'move'        => 'write',
        'copy'        => 'write',
        # SM418: the DISPATCHED action name, which is 'file-upload'. Keyed
        # 'upload' this lookup was always undef, so the carve-out gate never
        # ran for a single upload - an unscoped manage_content account could
        # upload onto lazysite/nav.conf without manage_nav, and into the form
        # submission store, which are the exact bypasses SM268 H4 closed on
        # every other verb.
        'file-upload'      => 'write',
        'git-restore'      => 'write',
        'migrate-to-local' => 'write',
        'lock'             => 'write',
        'unlock'           => 'write',
        'renew-lock'       => 'write',
    );
    my $fs_mode = $file_surface{$action};
    if ( defined $fs_mode && $site_secured ) {
        my $caps = $token_auth ? \%token_caps : _user_caps($auth_user);
        for my $p ( $path, $params{to} ) {
            next unless defined $p && length $p;
            my $refusal = Lazysite::Manager::Common::carveout_refusal( $p, $fs_mode, $caps );
            next unless $refusal;
            audit_log( $auth_user, $action, $p, $ENV{REMOTE_ADDR} // '',
                'fail', ( $token_auth ? 'api' : 'ui' ), 'denied: carve-out capability' );
            respond( { ok => 0, error => $refusal } );
            exit 0;
        }
    }
}

# --- Dispatch ---

my $result;
if    ( $action eq 'list' ) { $result = action_list($path) }
elsif ( $action eq 'read' ) { $result = action_read( $path, $auth_user ) }
elsif ( $action eq 'save' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_save( $path, $auth_user, $req->{content}, $req->{mtime} );
}
elsif ( $action eq 'delete' )  { $result = action_delete( $path, $auth_user ) }
elsif ( $action eq 'acl-get' ) { $result = action_acl_get( $path, $auth_user ) }
elsif ( $action eq 'acl-set' ) {
    my $req = eval { decode_json($body) } // {};

    # SM306: acl-set will not take the whole site private because an argument
    # was left out.
    #
    # $path above defaults to '/' for EVERY action. That is right for `list`,
    # which should list the site root when asked for nothing in particular, and
    # harmless for acl-get and acl-remove. acl-set inherited it, where the same
    # omission applies a site-wide read restriction and returns ok:1. Before
    # SM287 a root entry sat inert, so this was a no-op; SM287 made a root rule
    # take effect, and the default has been hazardous since.
    #
    # SM287 was careful about every OTHER spelling of the root - '/' canonical,
    # '', '.' and './' normalised to it, glob spellings refused with a message
    # naming '/'. That care covered every way of saying "the whole site" except
    # saying nothing at all, so the most destructive available target was the one
    # you got by omitting an argument.
    #
    # An empty path= counts as absent. It is a spelling SM287 accepts elsewhere
    # and still holds there; here it is overwhelmingly a form or client sending
    # a blank field rather than an operator asking for the site.
    unless ( defined $params{path} && length $params{path} ) {
        $result = { ok => 0,
            error => 'acl-set needs an explicit path. To govern the whole '
                . 'site, including every folder beneath it, pass path=/ - it '
                . 'is deliberately spelled out, because a rule that broad '
                . 'should not be what you get by leaving the argument out.' };
    }
    # The body/query split is what invited the original mistake. `save` takes
    # its content from the body, `domain-add` takes host, content_root and the
    # rest from the body, and acl-set takes its lists from the body and its path
    # from the query string - so a caller who has just used the first two has
    # been taught where arguments go. It was discarded in silence, which cost a
    # live site a minute of 302s. Refusing an argument the action does not read
    # is what SM278 already does on all 51 MCP tools.
    elsif ( exists $req->{path} ) {
        $result = { ok => 0,
            error => 'acl-set reads its path from the query string, not the '
                . 'request body, so the "path" key here would have been '
                . 'ignored and the rule applied somewhere else. Pass it as '
                . 'action=acl-set&path=... instead.' };
    }
    else {
        $result = action_acl_set( $path, $auth_user,
            $req->{read}, $req->{write}, $req->{owner}, $req->{draft} );
    }
}
elsif ( $action eq 'acl-remove' ) { $result = action_acl_remove( $path, $auth_user ) }
elsif ( $action eq 'protected-sections' ) {
    # SM267: read-only, and scoped - a confined manager is shown only the
    # sections inside their own scope, so the list cannot be used to discover
    # that content exists elsewhere.
    $result = action_protected_sections( $auth_user, \@REQUEST_SCOPES, $params{path} );
}
elsif ( $action eq 'mkdir' ) { $result = action_mkdir($path) }
elsif ( $action eq 'move' )  { $result = action_move( $path, $params{to}, $auth_user ) }
elsif ( $action eq 'copy' )  { $result = action_copy( $path, $params{to}, $auth_user ) }
elsif ( $action eq 'migrate-to-local' ) { $result = action_migrate_to_local( $path, $auth_user ) }
elsif ( $action eq 'aliases-list' ) {
    $result = action_aliases_list( $params{host}, $params{path} );
}
elsif ( $action eq 'git-status' ) { $result = action_git_status() }
elsif ( $action eq 'git-history' ) { $result = action_git_history( $path, $auth_user, $params{limit} ) }
elsif ( $action eq 'git-history-summary' ) {
    # SM419: the summary is scope-confined like every per-file history op.
    # It carries no path, so _confine_scope never sees it - the scopes have to
    # be handed over explicitly, as action_protected_sections already does.
    $result = action_git_history_summary( \@REQUEST_SCOPES );
}
elsif ( $action eq 'git-show' ) { $result = action_git_show( $path, $auth_user, $params{sha} ) }
elsif ( $action eq 'git-restore' ) { $result = action_git_restore( $path, $auth_user, $params{sha} ) }
elsif ( $action eq 'git-init' )   { $result = action_git_init($auth_user) }
elsif ( $action eq 'lock' )       { $result = acquire_lock( $path, $auth_user ) }
elsif ( $action eq 'unlock' )     { $result = release_lock( $path, $auth_user ) }
elsif ( $action eq 'renew-lock' ) { $result = renew_lock( $path, $auth_user ) }
elsif ( $action eq 'preview' )    { $result = action_preview($path) }
elsif ( $action eq 'cache-list' ) { $result = action_cache_list() }
elsif ( $action eq 'cache-invalidate' ) { $result = action_cache_invalidate( $path, $params{host} ) }

# SM301: the same operation MCP has had since SM264, on the channel a WebDAV +
# control-API partner actually holds. t/lint/23 recorded the MCP-only exposure
# as deliberate, with the condition "the API path can add one when someone asks
# for it"; a live site asked, having taken its own sitemap.xml down for a minute
# and llms.txt for longer by deleting the generated file - which is not a cache
# invalidation but an outage that ordinary traffic does not clear, because a
# registry rebuilds during page PROCESSING and a cached page request is not a
# render.
elsif ( $action eq 'regenerate-registries' ) {
    $result = action_regenerate_registries();
}
elsif ( $action eq 'config-read' )  { $result = action_config_read() }
elsif ( $action eq 'domains-list' ) { $result = action_domains_list() }
elsif ( $action eq 'domain-add' ) {
    my $req = eval { decode_json($body) } // {};
    $result = domain_add(
        $req->{host},
        content_root   => $req->{content_root},
        site_url       => $req->{site_url},
        site_name      => $req->{site_name},
        theme          => $req->{theme},
        layout         => $req->{layout},
        nav_file       => $req->{nav_file},
        search_default => $req->{search_default},
        lang           => $req->{lang},
        lang_group     => $req->{lang_group},
        seed           => ( $req->{seed} ? 1 : 0 ),
    );
}
elsif ( $action eq 'domain-set' ) {
    my $req = eval { decode_json($body) } // {};
    $result = domain_set( $req->{host}, $req->{key}, $req->{value} );
}
elsif ( $action eq 'domain-remove' ) {
    my $req = eval { decode_json($body) } // {};
    $result = domain_remove( $req->{host}, purge => ( $req->{purge} ? 1 : 0 ) );
}
elsif ( $action eq 'domain-preview' ) {
    $result = domain_preview( $params{host} );
}
elsif ( $action eq 'domain-check' ) {
    $result = action_domain_check( $params{host} );
}
elsif ( $action eq 'data-tables' ) {
    $result = Lazysite::Manager::Data::action_data_tables();
}
elsif ( $action eq 'data-table' ) {
    $result = Lazysite::Manager::Data::action_data_table( $params{table} );
}
elsif ( $action eq 'data-rows' ) {
    $result = Lazysite::Manager::Data::action_data_rows(
        $params{table},
        order_by => $params{order_by},
        order    => $params{order},
        limit    => $params{limit},
        offset   => $params{offset},
    );
}
elsif ( $action eq 'data-table-save' ) {
    # The descriptor arrives as YAML TEXT in the body, not as a structure. The
    # file on disk is YAML and a human may edit it, so text is what
    # round-trips: comments and ordering survive, and what the author wrote is
    # what is stored.
    my $req = eval { decode_json($body) } // {};
    $result = Lazysite::Manager::Data::action_data_table_save(
        $req->{table} // $params{table},
        $req->{descriptor} );
}
elsif ( $action eq 'data-migrate' ) {
    $result = Lazysite::Manager::Data::action_data_migrate( $params{table} );
}
elsif ( $action eq 'data-row-save' ) {
    # THE ROW COMES FROM THE BODY, as a nested object, and both halves of that
    # are deliberate.
    #
    # From the BODY because %params carries the query string; a row of site
    # data is not a query parameter and putting it there would cap it at
    # whatever the front end allows in a URL.
    #
    # NESTED under `row` rather than flattened into the request, because a
    # descriptor may declare a field called `table` or `key` - flattening would
    # make the site's own data collide with the action's own parameters, and
    # the collision would be silent.
    my $req = eval { decode_json($body) } // {};
    my $row = $req->{row};
    $result
        = ref $row eq 'HASH'
        ? Lazysite::Manager::Data::action_data_row_save(
        $req->{table} // $params{table},
        $req->{key} // $params{key}, $row )
        : { ok => 0, error => 'row must be a JSON object' };
}
elsif ( $action eq 'data-row-delete' ) {
    my $req = eval { decode_json($body) } // {};
    $result = Lazysite::Manager::Data::action_data_row_delete(
        $req->{table} // $params{table},
        $req->{key}   // $params{key} );
}
elsif ( $action eq 'lang-status' ) {
    $result = action_lang_status( $params{group} );
}
elsif ( $action eq 'site-backup-create' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_site_backup_create( $req->{host} // $params{host} );
}
elsif ( $action eq 'site-backup-upload' ) {
    $result = action_site_backup_upload($body);
}
elsif ( $action eq 'site-backup-apply' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_site_backup_apply($req);
}
elsif ( $action eq 'site-export-primary' ) {
    $result = action_site_export_primary();
}
elsif ( $action eq 'site-backup-inspect' ) {
    $result = action_site_backup_inspect( $params{name}, $params{host} );
}
elsif ( $action eq 'site-backup-delete' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_site_backup_delete( $req->{name} // $params{name} );
}
elsif ( $action eq 'site-backup-download' ) {
    my $req = eval { decode_json($body) } // {};
    my $r   = action_site_backup_download( $req->{name} // $params{name} );
    exit 0 if $r->{streamed}; # the tarball was streamed; a pre-stream error falls through
    $result = $r;
}
elsif ( $action eq 'config-set' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_config_set(
        ( defined $req->{key}   ? $req->{key}   : $params{key} ),
        ( defined $req->{value} ? $req->{value} : $params{value} ) );
}
elsif ( $action eq 'bad-url-blocks' ) { $result = { ok => 1, blocks => list_blocks($DOCROOT) } }
elsif ( $action eq 'bad-url-unblock' ) {
    my $ip = defined $params{ip} ? $params{ip} : ( eval { decode_json($body) } || {} )->{ip};
    my $removed = ( defined $ip && length $ip ) ? unblock( $DOCROOT, $ip ) : 0;
    log_event( 'INFO', 'bad-url-unblock', 'IP unblocked', ip => ( $ip // '' ), user => $auth_user );
    $result = { ok => 1, removed => ( $removed ? JSON::PP::true : JSON::PP::false ) };
}
elsif ( $action eq 'theme-list' )      { $result = action_theme_list() }
elsif ( $action eq 'themes-list-all' ) { $result = action_themes_list_all() }

# SM261: these two take the theme/layout NAME in a parameter called `path`,
# which is the file-ish parameter everywhere else on this surface - so a caller
# building from the action reference sends `theme=` or `layout=`, which is what
# everyone tries first. SM247 made that survivable (an empty name is now an
# error naming `path` rather than a silent deactivation), but only for someone
# who has already made the call and read the error. Accept the obvious spelling
# as an alias so the trap stops being reachable.
#
# NB: `path` DEFAULTS to '/', so "absent" here means empty or '/' - testing
# length($path) alone would never reach the alias, which is the same defaulting
# that made SM247 read a missing parameter as an instruction.
elsif ( $action eq 'theme-activate' ) {
    my $name = ( length($path) && $path ne '/' ) ? $path : ( $params{theme} // '' );
    $result = action_theme_activate( $name, \%params );
}
elsif ( $action eq 'layout-activate' ) {
    my $name = ( length($path) && $path ne '/' ) ? $path : ( $params{layout} // '' );
    $result = action_layout_activate( $name, \%params );
}
elsif ( $action eq 'theme-delete' ) {
    # SM262: a token client may remove a theme it created; a cookie session (a
    # human in the manager) keeps the unrestricted delete.
    $result = action_theme_delete( $path,
        { restrict_to_creator => $RESTRICT_THEME_DELETE, user => $auth_user } );
}
elsif ( $action eq 'layout-delete' )           { $result = action_layout_delete($path) }
elsif ( $action eq 'artifact-backups-delete' ) { $result = action_artifact_backups_delete($path) }
elsif ( $action eq 'theme-rename' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_theme_rename( $path, $req->{new_name} );
}
elsif ( $action eq 'theme-upload' ) { $result = action_theme_upload( $body, $params{filename} ) }
elsif ( $action eq 'layouts-releases' ) { $result = action_layouts_releases() }
elsif ( $action eq 'layouts-install' )  { $result = action_layouts_install($body) }
elsif ( $action eq 'layouts-manifest' ) { $result = action_layouts_manifest() }
elsif ( $action eq 'layout-install' )   { $result = action_layout_install($body) }
elsif ( $action eq 'layouts-release-contents' ) {
    $result = action_layouts_release_contents( $params{tag} );
}
elsif ( $action eq 'layouts-available' ) { $result = action_layouts_available() }
elsif ( $action eq 'themes-for-layout' ) { $result = action_themes_for_layout( $params{layout} ) }
elsif ( $action eq 'layouts-repo-get' ) { $result = action_layouts_repo_get() }
elsif ( $action eq 'layouts-repo-set' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_layouts_repo_set( $req->{value} );
}
elsif ( $action eq 'users' )              { $result = action_users( $body, \%params ) }
elsif ( $action eq 'principals' )         { $result = action_principals() }
elsif ( $action eq 'rotate-auth-secret' ) { $result = action_rotate_auth_secret($auth_user) }
elsif ( $action eq 'sessions-list' || $action eq 'session-revoke' || $action eq 'user-revoke'
    || $action eq 'keys-list' || $action eq 'key-revoke' ) {
    # SM141/SM145: session AND access-key visibility + revocation are all
    # user-management powers. Cookie (manager) callers need the manage_users
    # capability - same strict cookie-side gate pattern as the audit trail;
    # token clients cannot reach these at all (not in the %need set above).
    # (A denied revoke is still audited: the generic POST audit block below
    # records the fail with kind 'forbidden'; the -list actions are GET reads.)
    if ( !$token_auth && !_user_manage_users($auth_user) ) {
        $result = { ok => 0, kind => 'forbidden',
            error => "Managing sessions and keys requires the 'Users & groups' permission. "
                . "An administrator can grant it on the Groups page." };
    }
    elsif ( $action eq 'sessions-list' ) { $result = action_sessions_list() }
    elsif ( $action eq 'keys-list' ) {
        # SM145: the access-key inventory lives in the users tool (it reads the
        # credential store); forward the read.
        $result = _users_tool_call( { action => 'keys-list' } );
    }
    elsif ( $action eq 'key-revoke' ) {
        my $req = eval { decode_json($body) } // {};
        $result = _users_tool_call( { action => 'key-revoke', username => $req->{username} } );
    }
    else {
        my $req = eval { decode_json($body) } // {};
        $result = $action eq 'session-revoke'
            ? action_session_revoke( $req->{sid} )
            : action_user_revoke( $req->{username} );
    }
}
elsif ( $action eq 'plugin-list' ) { $result = action_plugin_list() }
elsif ( $action eq 'plugin-enable' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_plugin_enable( $req->{script} );
}
elsif ( $action eq 'plugin-disable' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_plugin_disable( $req->{script} );
}
elsif ( $action eq 'plugin-read' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_plugin_read( $params{plugin}, $req->{script} );
}
elsif ( $action eq 'plugin-save' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_plugin_save( $params{plugin}, $req->{script}, $req->{values} // {} );
}
elsif ( $action eq 'plugin-action' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_plugin_action( $params{plugin}, $req->{script}, $req->{action_id},
        $req->{params} );
}
elsif ( $action eq 'nav-read' ) { $result = action_nav_read( $params{host} ) }
elsif ( $action eq 'pages' )    { $result = action_pages() }
elsif ( $action eq 'notices' || $action eq 'notices-seen' ) {
    # Operator notifications require the 'notifications' capability (granted via
    # a group; seeded on user-managers). Same cookie-side gate pattern as audit;
    # the bell UI hides itself when this returns forbidden.
    if ( !$token_auth && !_user_cap_notifications($auth_user) ) {
        $result = { ok => 0, kind => 'forbidden',
            error => "Notifications require the 'Notifications' permission. An "
                . "administrator can grant it on the Groups page." };
    }
    else {
        $result = $action eq 'notices' ? action_notices() : action_notices_seen();
    }
}
elsif ( $action eq 'nav-save' ) {
    my $req = eval { decode_json($body) } // {};
    # SM443: host from EITHER place. nav-read takes it in the query and
    # nav-save took it only in the body, so a caller passing it the way the
    # read requires had it silently dropped on the write - and the write then
    # fell back to the shared nav.conf and replaced a neighbouring site's
    # menu. The audit trail made it worse rather than catching it:
    # _audit_implicit_target already read `$params->{host} // $req->{host}`,
    # so the log recorded "nav (<the domain>)" for a write that went to the
    # primary's file. The record agreed with the intention and not with what
    # happened.
    $result = action_nav_save( $req->{items} // [],
        $params{host} // $req->{host} );
}
elsif ( $action eq 'handler-list' ) { $result = action_handler_list() }
elsif ( $action eq 'version' )      { $result = action_version() }
elsif ( $action eq 'analyse_visitors' ) {
    $result = action_analyse_visitors(
        window => $params{window}, day   => $params{day},
        month  => $params{month},  index => $params{index},
        trails => $params{trails} );
}
elsif ( $action eq 'whoami' )                { $result = action_whoami($auth_user) }
elsif ( $action eq 'describe-capabilities' ) { $result = action_describe_capabilities($auth_user) }
elsif ( $action eq 'actions-list' ) { $result = action_actions_list($auth_user) }  # SM350
elsif ( $action eq 'preview-public' ) {                                            # SM282
    $result = preview_public( $params{path} );
}
elsif ( $action eq 'audit' ) {
    # Strict gate: the FULL audit trail requires the 'audit' capability (separate
    # from visitor analytics). Token clients are already gated by %need above (a
    # token still needs 'audit' for the full log). SM173: a cookie (manager) user
    # who holds create_sub_users but NOT 'audit' gets a SCOPED view - their own
    # activity plus that of the accounts beneath them in the managed_by tree.
    my $scope;    # undef = full log; hashref of usernames = restrict to these
    my $denied = 0;
    if ( !$token_auth ) {
        my $caps = _user_caps($auth_user);
        if ( !$caps->{audit} ) {
            if ( $caps->{create_sub_users} ) {
                my $sc = users_api( { action => 'audit-scope', username => $auth_user } ) || {};
                $scope = { map { $_ => 1 } @{ $sc->{users} || [] }, $auth_user };
            }
            else {
                audit_log( $auth_user, 'audit', '', $ENV{REMOTE_ADDR} // '', 'fail', 'ui', 'denied: needs audit' );
                $result = { ok => 0, kind => 'forbidden',
                    error => "The audit trail requires the 'Audit trail' permission. An "
                        . "administrator can grant it on the Groups page: give a group the "
                        . "'Audit trail' action, and add the user to it." };
                $denied = 1;
            }
        }
    }
    $result = action_audit( user => $params{user}, target => $params{target},
        start    => $params{start},    end   => $params{end}, page => $params{page},
        per_page => $params{per_page}, scope => $scope )
        unless $denied;
}
elsif ( $action eq 'recent-changes' ) { $result = action_recent_changes( $params{window} ) }
elsif ( $action eq 'channel-services' ) { $result = action_channel_services() }
elsif ( $action eq 'handler-save' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_handler_save($req);
}
elsif ( $action eq 'handler-delete' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_handler_delete( $req->{id} );
}
elsif ( $action eq 'form-targets-read' ) {
    $result = action_form_targets_read( $params{form} );
}
elsif ( $action eq 'form-submissions' ) {
    $result = action_form_submissions( $params{file} );
}
elsif ( $action eq 'form-list' ) { # SM214: PII-free form discovery (names + types + row counts)
    $result = action_form_list();
}
elsif ( $action eq 'form-submission-delete' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_form_submission_delete( $req->{file} // $params{file}, $req->{id} );
}
elsif ( $action eq 'form-submission-confirm' ) {    # SM216: un-quarantine a row
    my $req = eval { decode_json($body) } // {};
    $result = action_form_submission_confirm( $req->{file} // $params{file}, $req->{id} );
}
elsif ( $action eq 'form-submissions-delete-bulk' ) {    # SM187: delete several rows
    my $req = eval { decode_json($body) } // {};
    $result = action_form_submissions_delete_bulk( $req->{file} // $params{file}, $req->{ids} );
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
elsif ( $action eq 'backup-list' ) { $result = action_backup_list() }
elsif ( $action eq 'backup-create' ) {
    # scope=full = a full-system snapshot (config + auth + content) for DR and
    # cross-domain migration; otherwise a content-only snapshot. These are
    # manager (cookie) actions - not in %need, so a token client cannot reach them.
    $result = action_backup_create(
        ( $params{scope} // '' ) eq 'full' ? 'full' : undef );
}
elsif ( $action eq 'backup-restore' ) { $result = action_backup_restore( $params{name} ) }
elsif ( $action eq 'backup-delete' ) {
    my $req = eval { decode_json($body) } // {};
    $result = action_backup_delete( $req->{name} // $params{name} );
}
elsif ( $action eq 'backup-download' ) {
    action_backup_download( $params{name} );
    exit 0;
}
elsif ( $action eq 'file-zip-download' ) {
    action_file_zip_download( \@REQUEST_SCOPES );    # F2: confine each path to scope
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
else { $result = { ok => 0, error => "Unknown action: $action" } }

# Audit trail: record MATERIAL actions only - state changes and security grants
# (who did what, TO WHAT, when, from where, outcome). Reads/browsing are NOT
# audited; the access log and the stats plugin cover those, and the audit must
# not overlap with them. Read-ish POSTs (the UI POSTs everything) are skipped.
if ( ( $ENV{REQUEST_METHOD} // '' ) eq 'POST' ) {
    my %skip = map { $_ => 1 } qw(
        csrf-token list read principals whoami describe-capabilities actions-list preview-public audit version acl-get cache-list analyse_visitors
        cache-invalidate regenerate-registries nav-read aliases-list config-read domains-list domain-preview domain-check lang-status bad-url-blocks recent-changes channel-services pages theme-list themes-list-all themes-for-layout
        layouts-available layouts-releases layouts-repo-get layouts-release-contents
        handler-list plugin-list plugin-read form-targets-read form-submissions form-list artifact-manifest
        artifact-validate lock unlock renew-lock preview preview-clear preview-grant
        backup-list sessions-list keys-list git-status git-history git-history-summary git-show
        site-backup-inspect protected-sections
        data-tables data-table data-rows );

    # SM447: the three data READS are skip-listed for the same reason as every
    # other read here - they change nothing, and an audit trail of who looked
    # at a table would bury the entries that record who CHANGED one.
    #
    # The three data WRITERS - data-migrate, data-row-save, data-row-delete -
    # are deliberately NOT here, so they are audited by construction. A schema
    # migration and a row edit are exactly what an operator asks the trail
    # about.

    my ( $aud_action, $aud_target ) =
        ( $action, $action eq 'config-set' ? ( $params{key} // '' ) : ( $path // '' ) );

    # action=users carries its sub-action in the POST body; audit only the
    # material ones (add / remove / settings-set / token / ...), not the reads.
    if ( $action eq 'users' ) {
        my $b     = eval { decode_json($body) };
        my $sub   = ( ref $b eq 'HASH' ) ? ( $b->{action} // '' ) : '';
        my %uskip = map { $_ => 1 } qw(
            list users-detail users-page groups group-settings-get permissions-grid capability-holders settings-get credential-status partner-caps
            verify-credential totp-code onboarding );
        if ( $sub eq '' || $uskip{$sub} ) { $aud_action = undef }
        else {
            $aud_action = "user-$sub";
            # Group changes (capabilities, membership) record the group as the
            # target - "user@group" for membership, the group alone for settings.
            if ( ref $b eq 'HASH' && $b->{group} ) {
                $aud_target = $b->{username} ? "$b->{username}\@$b->{group}" : $b->{group};
            }
            else {
                $aud_target = ( ref $b eq 'HASH' ? $b->{username} : undef ) // '';
            }
        }
    }

    # SM141/SM145: the revokes carry their target in the POST body - name it
    # (a sid prefix / the username) instead of the meaningless '/' path.
    if ( $action eq 'session-revoke' || $action eq 'user-revoke' || $action eq 'key-revoke' ) {
        my $b = eval { decode_json($body) };
        if ( $action eq 'session-revoke' ) {
            my $sid = ( ref $b eq 'HASH' ? $b->{sid} : undef ) // '';
            $sid =~ s/[^0-9a-f]//g;
            $aud_target = length $sid ? 'sid:' . substr( $sid, 0, 8 ) : '';
        }
        else {
            my $u = ( ref $b eq 'HASH' ? $b->{username} : undef ) // '';
            $u =~ s/[^a-zA-Z0-9_.-]//g;
            $aud_target = $u;
        }
    }

    # Plugin actions log '/' as their path; name the plugin instead (from the
    # plugin param, else the body's script basename) so the audit says WHICH one.
    if ( $action =~ /^plugin-/ ) {
        my $plugin = _audit_plugin_target( \%params, $body, $action, $result );
        $aud_target = $plugin if length $plugin;
    }

    # Actions with no path/key but a well-known target (nav-save edits the site
    # navigation) - record that instead of a bare '/'.
    my $imp = _audit_implicit_target( $action, \%params, $body );
    if ( length $imp && ( !length $aud_target || $aud_target eq '/' ) ) {
        $aud_target = $imp;
    }

    # Meaningful file events: a save is a create (new file) or an edit.
    if ( $action eq 'save' && ref $result eq 'HASH' ) {
        $aud_action = $result->{created} ? 'create' : 'edit';
    }

    if ( defined $aud_action && !$skip{$aud_action} ) {
        my $ok = ref $result eq 'HASH' && $result->{ok};
        # On failure, record a short reason (kind, else the error text) as the
        # detail field so the audit can show WHY it failed.
        my $detail = $ok ? ''
            : ( ref $result eq 'HASH' ? ( $result->{kind} || $result->{error} || '' ) : '' );
        audit_log( $auth_user, $aud_action, $aud_target, $ENV{REMOTE_ADDR} // '',
            ( $ok ? 'ok' : 'fail' ), ( $token_auth ? 'api' : 'ui' ), $detail );
    }
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
    # 0660: identity-shared secret (site-user CLI + www-data CGI via the
    # setgid auth dir group); owner-only minting locks the other side out.
    chmod 0o660, $path;
    print $wfh "$s\n";
    close $wfh;
    return $s;
}

sub action_preview_grant {
    my ($p)    = @_;
    my $layout = $p->{layout} // '';
    my $theme  = $p->{theme}  // '';

    unless ( $layout =~ /^[A-Za-z0-9_-]+$/ ) {
        respond( { ok => 0, error => 'Invalid or missing layout' } );
        return;
    }
    unless ( $theme =~ /^[A-Za-z0-9_-]*$/ ) {
        respond( { ok => 0, error => 'Invalid theme' } );
        return;
    }

    # The layout must exist; a named theme must exist under it. An empty
    # theme means "preview the layout, no theme styling". This stops the
    # manager handing out a preview of something that cannot render.
    unless ( -f "$LAZYSITE_DIR/layouts/$layout/layout.tt" ) {
        respond( { ok => 0, error => "No such layout: $layout" } );
        return;
    }
    if ( length $theme
        && !-f "$LAZYSITE_DIR/layouts/$layout/themes/$theme/theme.json" ) {
        respond( { ok => 0, error => "No such theme: $theme" } );
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

    binmode(STDOUT);    # encode_json emits UTF-8 bytes; do not re-encode
    print "Status: 200 OK\r\n";
    print "Set-Cookie: $PREVIEW_COOKIE=$value; HttpOnly; SameSite=Lax; Path=/; Max-Age=$PREVIEW_TTL$secure\r\n";
    # Non-HttpOnly UI marker so the manager can show/hide "Stop preview".
    # Carries no auth value - the signed HttpOnly cookie above is the gate.
    print "Set-Cookie: ${PREVIEW_COOKIE}_active=1; SameSite=Lax; Path=/; Max-Age=$PREVIEW_TTL$secure\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json(
        { ok => JSON::PP::true, layout => $layout, theme => $theme, expires => $exp } ); # SM353
}

sub action_preview_clear {
    my $secure = $ENV{HTTPS} ? '; Secure' : '';
    log_event( 'INFO', 'preview-clear', 'preview cleared', user => $auth_user );
    binmode(STDOUT);    # encode_json emits UTF-8 bytes; do not re-encode
    print "Status: 200 OK\r\n";
    print "Set-Cookie: $PREVIEW_COOKIE=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0$secure\r\n";
    print "Set-Cookie: ${PREVIEW_COOKIE}_active=; SameSite=Lax; Path=/; Max-Age=0$secure\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json( { ok => JSON::PP::true } );    # SM353
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
    else                { $retry = $rate > 0 ? int( ( 1 - $tokens ) / $rate ) + 1 : 60 }
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

# Resolve the real content processor to shell for a server-side render.
#
# We must NOT shell $ENV{LAZYSITE_PROCESSOR} directly: in the wrapped
# deployment (Apache/Hestia and the dev server) the auth wrapper sets
# LAZYSITE_PROCESSOR to the ORIGINALLY requested CGI - which is THIS
# manager-api when a preview action runs - so trusting it re-enters
# manager-api (auth stripped -> "Authentication required") instead of the
# processor. Take only the cgi-bin DIRECTORY it names and resolve the
# processor by its own name there, falling back to the docroot-relative path.
sub action_preview {
    my ($rel_path) = @_;

    my $uri = $rel_path;
    $uri =~ s{^/*}{/};
    $uri =~ s/\.md$//;
    $uri =~ s{/index$}{/};

    local $ENV{LAZYSITE_NOCACHE} = '1';
    local $ENV{REDIRECT_URL}     = $uri;
    local $ENV{DOCUMENT_ROOT}    = $DOCROOT;

    # SM441: render under the Host of the domain that OWNS this path. Without
    # it the preview inherited the Host of whatever the operator was browsing
    # the manager on - normally the primary - so SM151's per-Host routing never
    # fired and a domain's page came back with the BASE layout, theme and nav.
    # The content was right and the presentation was another site's, which
    # reads as a page given the wrong theme rather than as a preview that has
    # not been told which site it is. An operator who happened to open the
    # manager on the domain's own host saw a correct preview, which is what
    # made it intermittent.
    my ($owner) = Lazysite::Manager::Domains::host_for_path($rel_path);
    local $ENV{HTTP_HOST} = length $owner ? $owner : ( $ENV{HTTP_HOST} // '' );

    my $processor = processor_path();
    my $output    = qx($^X \Q$processor\E 2>/dev/null);

    # Strip CGI headers
    $output =~ s/\A.*?\r?\n\r?\n//s;

    return { ok => 1, html => $output };
}

# SM155: render a configured domain's HOME page as an anonymous public visitor
# would see it under its own Host - so an operator can prepare/debug a new domain
# BEFORE DNS/TLS is pointing at it. Shells the processor exactly like the dev
# server / action_preview, but with HTTP_HOST set (SM151 per-Host routing picks
# the domain's content_root + theme/layout/nav overrides) and the auth headers
# cleared (so the render is the public site, no manager admin bar).
# A host is "known" iff it is a registered alias host OR it is the primary
# site's own host (derived from its site_url). This BOUNDS the preview render
# and, more importantly, the domain-check outbound probe to operator-declared
# hosts - grepping `|| is_primary` matched the ever-present (default) row and so
# accepted ANY host, which for the SSRF-sensitive check must not happen.
# SM156: a stable, non-sensitive per-install id - identical to the processor's
# (same one-way function over the same docroot), so a domain-check can tell
# whether an HTTPS request to the candidate host lands back on THIS install.
sub _instance_id {
    my $base = realpath($DOCROOT) // $DOCROOT;
    return substr( hmac_sha256_hex( $base, 'lazysite-instance' ), 0, 32 );
}

# SM156: check whether a configured domain is configured to serve THIS install
# live (DNS resolves -> points here -> valid HTTPS cert -> terminates on this
# instance). The authoritative half of the hybrid check - it does the DNS / IP /
# TLS / marker work a browser cannot. self_ip is the address Apache accepted the
# manager request on (SERVER_ADDR); instance_id is our own marker value.
sub action_domain_check {
    my ($host) = @_;
    $host = lc( $host // '' );
    return { ok => 0, error => 'Invalid domain host' }
        unless $host =~ /\A [a-z0-9] (?:[a-z0-9-]*[a-z0-9])?
            (?: \. [a-z0-9] (?:[a-z0-9-]*[a-z0-9])? )* \z/x;

    # Bound the outbound probe to operator-declared hosts (no SSRF to arbitrary
    # targets): only a configured domain or the primary site's own host.
    return { ok => 0, error => "Not a configured domain: $host" }
        unless known_domain_host($host);

    # Self-discover this install's PUBLIC address(es): SERVER_ADDR is the private
    # inbound IP behind a proxy/NAT, so instance_public_ips prefers the operator's
    # canonical_ip config, then the install's own domain, then a public
    # SERVER_ADDR. An empty list makes the "points here" check indeterminate
    # rather than a false failure.
    my @self = Lazysite::Manager::Domains::instance_public_ips(
        fallback_ip => ( $ENV{SERVER_ADDR} // '' ) );

    return domain_check(
        $host,
        self_ips    => \@self,
        instance_id => _instance_id(),
    );
}

# SM158: package one domain's SITE (content root + nav + bundled theme/layout +
# manifest) into a portable .tar.gz alongside the backups, downloadable via
# backup-download. manage_content-gated (above); additionally the caller must
# have ACCESS to that domain's content root - a scope-confined editor can only
# package a domain within their dav_scope union (operators are unconfined).
sub action_site_backup_create {
    my ($host) = @_;
    $host = lc( $host // '' );
    return { ok => 0, kind => 'invalid', error => 'A domain host is required' }
        unless length $host;

    # Resolve the domain's own content root, and confine to the caller's scope.
    my ($row) = grep { lc( $_->{host} // '' ) eq $host } @{ domains_list()->{domains} || [] };
    return { ok => 0, kind => 'not-found', error => "Not a configured domain: $host" }
        unless $row;
    my $croot = $row->{content_root} // '';
    if ( @REQUEST_SCOPES
        && length $croot
        && Lazysite::Manager::Common::outside_all_scopes( \@REQUEST_SCOPES, $croot ) )
    {
        return { ok => 0, kind => 'forbidden',
            error => "You do not have access to the content of $host." };
    }

    local $Lazysite::Manager::SitePackage::auth_user = $auth_user;
    return package_create($host);
}

# SM185: package the DEFAULT/primary site as a self-contained site package,
# independent of the domains feature (manage_content-gated, so a site owner who
# does not use additional domains can still export/hand off their site). A
# scope-confined editor (bound to a sub-area) may NOT export the whole default
# site. The package excludes lazysite/ and every other domain's content.
sub action_site_export_primary {
    return { ok => 0, kind => 'forbidden',
        error => 'Exporting the default site needs full content access (you are confined to an area).' }
        if @REQUEST_SCOPES;
    local $Lazysite::Manager::SitePackage::auth_user = $auth_user;
    return package_create('(default)');
}

# SM183: resolve a site-package name to its path under lazysite/backups/, confined
# to the lazysite-site- namespace - a full/content backup or any other file (or a
# traversal) is unreachable. Returns the abs path, or undef for an invalid name.
sub _site_package_path {
    my ($name) = @_;
    $name //= '';
    return undef
        unless $name =~ /\Alazysite-site-[A-Za-z0-9._-]+\.tar\.gz\z/ && $name !~ /\.\./;
    return "$LAZYSITE_DIR/backups/$name";
}

# SM183: read a package's manifest WITHOUT applying it. manage_domains-gated
# (above) + read-only. A scope-confined caller may only inspect a package whose
# (source) content root lies within their dav_scope union - so one client's
# manager cannot read another client's package metadata (or the primary site's)
# on a shared instance. Operators (no scope) are unconfined.
sub action_site_backup_inspect {
    my ( $name, $host ) = @_;
    my $pkg = _site_package_path($name)
        or return { ok => 0, kind => 'invalid', error => 'A site package name is required' };
    return { ok => 0, kind => 'not-found', error => 'Package not found' } unless -f $pkg;

    # SM266: with a target host, the caller wants the DRY RUN as well - what an
    # apply would add versus overwrite there. The target's content root is
    # resolved here (not passed in), so a caller cannot aim the comparison at an
    # arbitrary directory and use the counts to probe the filesystem.
    my $target = '';
    if ( defined $host && length $host ) {
        my ($d) = grep { ( $_->{host} // '' ) eq $host }
            @{ Lazysite::Manager::Domains::domains_list()->{domains} || [] };
        $target = ( ref $d eq 'HASH' ? $d->{content_root} : '' ) // '';
        return { ok => 0, kind => 'invalid',
            error => "No configured domain '$host' with its own content root." }
            unless length $target;
        return { ok => 0, kind => 'forbidden',
            error => 'You do not have access to that target.' }
            if @REQUEST_SCOPES
            && Lazysite::Manager::Common::outside_all_scopes( \@REQUEST_SCOPES, $target );
    }

    my $info = package_inspect( $pkg, $target );
    return $info unless $info->{ok};

    if (@REQUEST_SCOPES) {
        my $croot = $info->{manifest}{keys}{content_root} // '';
        return { ok => 0, kind => 'forbidden', error => 'You do not have access to this package.' }
            if !length $croot
            || Lazysite::Manager::Common::outside_all_scopes( \@REQUEST_SCOPES, $croot );
    }
    return $info;
}

# SM183: remove a site package from the backups area. manage_domains-gated;
# name-confined to the lazysite-site- namespace; scope-confined to the package's
# content root like inspect. Audited via the generic dispatch wrapper.
sub action_site_backup_delete {
    my ($name) = @_;
    my $pkg = _site_package_path($name)
        or return { ok => 0, kind => 'invalid', error => 'A site package name is required' };
    return { ok => 0, kind => 'not-found', error => 'Package not found' } unless -f $pkg;

    if (@REQUEST_SCOPES) {
        my $info  = package_inspect($pkg);
        my $croot = $info->{ok} ? ( $info->{manifest}{keys}{content_root} // '' ) : '';
        return { ok => 0, kind => 'forbidden', error => 'You do not have access to this package.' }
            if !length $croot
            || Lazysite::Manager::Common::outside_all_scopes( \@REQUEST_SCOPES, $croot );
    }

    unlink $pkg or return { ok => 0, error => "Could not delete the package: $!" };
    # SM183: and its integrity sidecar, or the next listing shows a digest for a
    # package that no longer exists - and a later package reusing the name would
    # inherit a digest that never described it.
    unlink "$pkg.sha256" if -f "$pkg.sha256";
    return { ok => 1, name => $name };
}

# SM193 gap 1: stream a SITE PACKAGE for download. manage_domains-gated and so
# TOKEN-accessible (unlike the manage_config full-system backup-download),
# name-confined to the lazysite-site- namespace and scope-confined to the
# package's content root - so a token client (an agent) can DOWNLOAD a package it
# created, completing the create -> download -> upload -> apply cross-instance
# migration loop, without reaching the full-system backups. Streams like
# action_backup_download; returns {streamed=>1} after the body, or a hash error
# before any output.
sub action_site_backup_download {
    my ($name) = @_;
    my $pkg = _site_package_path($name)
        or return { ok => 0, kind => 'invalid', error => 'A site package name is required' };
    return { ok => 0, kind => 'not-found', error => 'Package not found' } unless -f $pkg;

    if (@REQUEST_SCOPES) {
        my $info  = package_inspect($pkg);
        my $croot = $info->{ok} ? ( $info->{manifest}{keys}{content_root} // '' ) : '';
        return { ok => 0, kind => 'forbidden', error => 'You do not have access to this package.' }
            if !length $croot
            || Lazysite::Manager::Common::outside_all_scopes( \@REQUEST_SCOPES, $croot );
    }

    my $size = ( stat $pkg )[7] // 0;
    ( my $safe = $name ) =~ s/[\r\n"\\]//g;
    log_event( 'INFO', 'site-backup-download', 'site package downloaded',
        file => $name, user => $auth_user );

    binmode STDOUT;
    local $| = 1;
    print "Status: 200 OK\r\n";
    print "Content-Type: application/gzip\r\n";
    print "Content-Length: $size\r\n";
    print "Content-Disposition: attachment; filename=\"$safe\"\r\n";
    print "Cache-Control: no-store, private\r\n";
    print "\r\n";
    open my $fh, '<', $pkg or return { ok => 0, error => 'Cannot read the package' };
    binmode $fh;
    my $buf;
    while ( my $n = sysread $fh, $buf, 65536 ) { syswrite STDOUT, $buf, $n }
    close $fh;
    return { ok => 1, streamed => 1 };
}

# SM158: upload a site package (a multipart file) into lazysite/backups/, so it
# can then be applied. This is the "import" step - the one thing the old backup
# tooling could not do (backups were server-only). The stored name is forced to
# the lazysite-site- namespace and .tar.gz; content is written raw (a package is
# a gzip blob, never executed). manage_content-gated (above) + upload rate limit.
sub action_site_backup_upload {
    my ($raw) = @_;
    my $ct = $ENV{CONTENT_TYPE} // '';
    return { ok => 0, error => 'Expected a multipart file upload' }
        unless $ct =~ m{multipart/form-data}i;

    my $rate = check_upload_rate($DOCROOT);
    return { ok => 0, kind => 'rate', error => $rate->{error} }
        if ref $rate eq 'HASH' && !$rate->{ok};

    my ($file) = grep { defined $_->{filename} && length $_->{filename} }
        parse_multipart_body( $raw, $ct );
    return { ok => 0, error => 'No file in the upload' } unless $file;
    return { ok => 0, error => 'A site package is a .tar.gz file' }
        unless $file->{filename} =~ /\.tar\.gz\z/;
    return { ok => 0, error => 'Empty upload' } unless length( $file->{data} // '' );

    # A stored package always carries the namespace prefix + a UTC stamp; the
    # uploaded filename is never trusted for the on-disk name.
    my $stamp = strftime( '%Y%m%dT%H%M%SZ', gmtime );
    my $name  = "lazysite-site-uploaded-$stamp.tar.gz";
    my $dir   = "$LAZYSITE_DIR/backups";
    make_path($dir) unless -d $dir;
    my $out = "$dir/$name";
    open my $fh, '>:raw', $out or return { ok => 0, error => "Cannot store the upload: $!" };
    print {$fh} $file->{data};
    close $fh;

    # Audited by the generic dispatch wrapper (site-backup-upload is not in
    # %skip), like every other write action.
    my @st = stat $out;
    return { ok => 1, name => $name, size => ( $st[7] // 0 ) };
}

# SM158: apply a site package (already in lazysite/backups/) to a TARGET domain
# on this instance. Safety-snapshots the whole docroot first, extracts + copies
# the vetted content into the target content root, installs the bundled
# theme/layout if missing, places the nav override, then writes the target
# domain's presentation keys. Requires manage_domains + access (scope) to the
# target content root. $req: { name, host, clean }.
#   host present + registered => apply into that domain (its content_root);
#   host omitted / '(default)' => apply to the PRIMARY/base site.
sub action_site_backup_apply {
    my ($req) = @_;
    $req ||= {};
    my $name = $req->{name} // '';
    my $host = lc( $req->{host} // '' );
    $host = '' if $host eq '(default)';

    return { ok => 0, kind => 'invalid', error => 'A package name is required' }
        unless $name =~ /\Alazysite-site-[A-Za-z0-9._-]+\.tar\.gz\z/ && $name !~ /\.\./;
    my $pkg = "$LAZYSITE_DIR/backups/$name";
    return { ok => 0, kind => 'not-found', error => 'Package not found' } unless -f $pkg;

    # Resolve the TARGET content root.
    my $croot;
    if ( length $host ) {
        my ($row) = grep { lc( $_->{host} // '' ) eq $host }
            @{ domains_list()->{domains} || [] };
        return { ok => 0, kind => 'not-found', error => "Not a configured domain: $host" }
            unless $row;
        $croot = $row->{content_root} // '';
        return { ok => 0, kind => 'invalid',
            error => "$host has no content folder of its own - set one on the Domains "
                . 'page (or apply to the default site) first.' }
            unless length $croot;
    }
    else {
        # Primary/base: use the base content_root, else adopt the package's.
        my ($base) = grep { $_->{is_primary} } @{ domains_list()->{domains} || [] };
        $croot = $base->{content_root} // '';
        $croot = ( $req->{content_root} // '' ) unless length $croot;
    }
    $croot =~ s{^/+|/+$}{}g;

    # Scope: the caller must have access to the target content root.
    if ( @REQUEST_SCOPES
        && length $croot
        && Lazysite::Manager::Common::outside_all_scopes( \@REQUEST_SCOPES, $croot ) )
    {
        return { ok => 0, kind => 'forbidden',
            error => 'You do not have access to the target content root.' };
    }

    # Safety snapshot BEFORE any write, so an apply is always reversible.
    # Taken here rather than in apply_and_configure because it must precede the
    # scope checks above on this surface; snapshot => 0 below stops the shared
    # layer taking a second one. SM183 moved the snapshot INTO the shared layer
    # so MCP and the CLI get it too - this surface always had it.
    my $safety = action_backup_create('prerestore');

    # SM378: the third copy of the same discard. A refusal that will not say
    # why is its own defect, and this is the surface a remote caller meets.
    unless ( $safety->{ok} ) {
        my $why = $safety->{reason} || $safety->{error} || 'no reason given';
        return { ok => 0, kind => 'snapshot-failed',
            error => "Refusing to apply: safety snapshot failed - $why",
            ( $safety->{detail} ? ( detail => $safety->{detail} ) : () ) };
    }

    local $Lazysite::Manager::SitePackage::auth_user = $auth_user;
    my $ap = Lazysite::Manager::SitePackage::apply_and_configure(
        $pkg,
        host         => $host,
        content_root => ( length $croot ? $croot : ( $req->{content_root} // '' ) ),
        clean        => ( $req->{clean} ? 1      : 0 ),
        snapshot     => 0,
        # SM193: keep the TARGET domain's site_url/site_name by default; opt into
        # taking the package's identity with adopt_identity (a migration vs handoff).
        adopt_identity => ( $req->{adopt_identity} ? 1 : 0 ),
        # SM266: presentation keys the operator chose to KEEP on the target -
        # take the package's content without taking its look. Filtered against
        # the portable set so a caller cannot use this to skip a key the apply
        # depends on (content_root above all, which is what makes the write land
        # in the right place).
        keep_presentation => [
            grep { /\A(?:theme|layout|nav)\z/ }
                @{ ref $req->{keep_presentation} eq 'ARRAY' ? $req->{keep_presentation} : [] }
        ],
    );
    unless ( $ap->{ok} ) {
        $ap->{safety} = $safety->{name};
        return $ap;
    }

    # SM158: applying a site is a bulk content change - like a restore, commit it
    # so it is visible in content history and recoverable (instant no-op when the
    # Content history plugin is off). Parity with backup-restore.
    require Lazysite::Git;
    Lazysite::Git::commit_all( $DOCROOT, $auth_user,
        "apply site package $name" . ( length $host ? " to $host" : '' ) );

    # Drop caches so the applied site renders fresh.
    require Lazysite::Util;
    Lazysite::Util::clear_host_cache($DOCROOT) if Lazysite::Util->can('clear_host_cache');

    # Audited by the generic dispatch wrapper (target = the host, via
    # _audit_implicit_target's site-backup- branch).
    return {
        ok               => 1,
        applied_to       => ( length $host ? $host : '(default)' ),
        content_root     => $ap->{content_root},
        nav              => $ap->{nav},
        layout_installed => $ap->{layout_installed},
        safety           => $safety->{name},
        source_host      => $ap->{source_host},
    };
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
# SM122: a manage_config token may read a safe subset of the site config to
# self-diagnose (active layout/theme, whether WebDAV is on) instead of inferring
# from HTTP codes. No secrets - just the operator-visible site settings.
# SM097: the public-page URL list, for the nav editor's autocomplete. Walks the
# docroot for .md/.url pages and maps each to its clean URL (about.md -> /about,
# index.md -> /, foo/index.md -> /foo/), skipping internal trees.
# SM113: operator notifications. A small append-only store (logs/notices.jsonl)
# that producers (the first is form submissions) append to, plus a per-operator
# last-seen marker (logs/notices-seen.json) so the manager can show an unread
# count. Operator-only (not in the token %need set); poll-based for v1.
sub _notices_path      { return "$LAZYSITE_DIR/logs/notices.jsonl" }
sub _notices_seen_path { return "$LAZYSITE_DIR/logs/notices-seen.json" }

sub action_notices {
    my @notices;
    if ( open my $fh, '<', _notices_path() ) {
        my @lines = <$fh>;
        close $fh;
        @lines = @lines[ -100 .. -1 ] if @lines > 100;    # bound: most recent 100
        for my $l ( reverse @lines ) {                    # newest first
            chomp $l;
            my $n = eval { decode_json($l) };
            push @notices, $n if ref $n eq 'HASH';
        }
    }
    my $seen = 0;
    if ( open my $sf, '<', _notices_seen_path() ) {
        local $/;
        my $h = eval { decode_json(<$sf>) };
        close $sf;
        $seen = $h->{$auth_user} if ref $h eq 'HASH' && $h->{$auth_user};
    }
    my $unread = grep { ( $_->{ts} // 0 ) > $seen } @notices;
    return { ok => 1, notices => \@notices, unread => $unread, last_seen => $seen };
}

sub action_notices_seen {
    my %h;
    if ( open my $sf, '<', _notices_seen_path() ) {
        local $/;
        my $x = eval { decode_json(<$sf>) };
        close $sf;
        %h = %{$x} if ref $x eq 'HASH';
    }
    $h{$auth_user} = time();
    if ( open my $wf, '>', _notices_seen_path() ) {
        print {$wf} encode_json( \%h );
        close $wf;
    }
    return { ok => 1, unread => 0 };
}

# Derive a plugin's name for the audit target: the plugin param if present,
# else the body's script basename (form-handler.pl -> form-handler). Returns ''
# when neither is available.
# Audit target for an action that carries no file PATH of its own - so the audit
# trail names WHAT was acted on (a domain, a config key, a backup) instead of a
# bare '/'. Derives from the query params / JSON body. '' = no implicit target.
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
    return { ok => 1, services => \%svc, channel_for_key => \%by_key };
}

sub _audit_implicit_target {
    my ( $action, $params, $body ) = @_;
    $action //= '';
    $params //= {};
    my $req = ( defined $body && length $body ) ? ( eval { decode_json($body) } // {} ) : {};

    if ( $action eq 'nav-save' ) {    # nav-save edits the site navigation
        my $h = $params->{host} // $req->{host} // '';
        return length $h ? "nav ($h)" : 'nav';
    }

    # Domain + per-site actions act on a HOST (domain-add/set/remove/preview/
    # check, site-backup-create/apply/upload) - name the domain.
    return 'default' if $action eq 'site-export-primary';    # SM185
    if ( $action eq 'form-submission-delete'
        || $action eq 'form-submission-confirm'
        || $action eq 'form-submissions-delete-bulk' ) {     # SM187/SM216: name the store
        my $f = $params->{file} // $req->{file} // '';
        return $f if length $f;
    }
    if ( $action =~ /^(?:domain-|site-backup-)/ ) {
        my $h = $params->{host} // $req->{host} // '';
        return $h if length $h;
        # SM183: site-backup-delete acts on a package NAME, not a host.
        my $n = $params->{name} // $req->{name} // '';
        return $n if length $n && $action =~ /^site-backup-/;
    }
    # config-set: name the KEY that changed (e.g. site_name), not a bare '/'.
    if ( $action eq 'config-set' ) {
        my $k = $params->{key} // $req->{key} // '';
        return $k if length $k;
    }
    # Backups: create names the KIND (full/content/manual); restore/download the
    # backup file.
    return ( $req->{kind} // $params->{kind} // 'manual' ) if $action eq 'backup-create';
    if ( $action =~ /^backup-(?:restore|download)\z/ ) {
        my $n = $params->{name} // $req->{name} // '';
        return $n if length $n;
    }
    return '';
}

sub _audit_plugin_target {
    my ( $params, $body, $action, $result ) = @_;
    my $plugin = $params->{plugin} // '';
    unless ( length $plugin ) {
        my $b      = eval { decode_json( $body // '' ) };
        my $script = ( ref $b eq 'HASH' ? $b->{script} : undef ) // '';
        $plugin = $script =~ m{([^/]+?)(?:\.pl)?$} ? $1 : '';
    }

    # plugin-save: name the setting(s) changed so the audit says WHICH config key
    # was edited (e.g. "lazysite (site_name)"), not just the plugin. Keys only -
    # values may be secrets; capped so a whole-form save isn't a giant target.
    # Prefer the save handler's actual diff: the UI posts the WHOLE form, so
    # the submitted keys read "8 settings" for a one-field edit (field report).
    if ( defined $action && $action eq 'plugin-save' && length $plugin ) {
        my @keys;
        if ( ref $result eq 'HASH' && ref $result->{changed} eq 'ARRAY' ) {
            @keys = @{ $result->{changed} };
            $plugin .= ' (no changes)' unless @keys;
        }
        else {
            my $b    = eval { decode_json( $body // '' ) };
            my $vals = ( ref $b eq 'HASH' ? $b->{values} : undef );
            @keys = sort keys %{$vals} if ref $vals eq 'HASH';
        }
        if (@keys) {
            my $list = @keys > 6 ? ( scalar(@keys) . ' settings' )
                :   join( ', ', @keys );
            $plugin .= " ($list)";
        }
    }

    # plugin-action: name WHICH action ran (and any choice it carried), so a
    # git-sync push and pull are distinguishable in the trail - "git-sync
    # (pull keep_mine)" rather than a bare plugin name (SM085).
    if ( defined $action && $action eq 'plugin-action' && length $plugin ) {
        my $b      = eval { decode_json( $body // '' ) };
        my $aid    = ( ref $b eq 'HASH' ? $b->{action_id} : undef ) // '';
        my $choice = ( ref $b eq 'HASH' && ref $b->{params} eq 'HASH' )
            ? ( $b->{params}{choice} // '' ) : '';
        s/[^a-zA-Z0-9_-]//g for ( $aid, $choice );
        $aid    .= " $choice" if length $aid && length $choice;
        $plugin .= " ($aid)"  if length $aid;
    }
    return $plugin;
}

sub action_pages {
    my @urls;
    my $walk;
    $walk = sub {
        my ( $dir, $pref ) = @_;
        opendir my $dh, $dir or return;
        for my $e ( sort readdir $dh ) {
            next if $e =~ /^\./;
            my $rel  = $pref eq '' ? $e : "$pref/$e";
            my $full = "$dir/$e";
            if ( -d $full ) {
                next if $rel =~ m{^(?:lazysite|cgi-bin|manager|assets|\.well-known)(?:/|$)};
                $walk->( $full, $rel );
            }
            elsif ( $e =~ /\.(?:md|url)$/ ) {
                ( my $u = $rel ) =~ s/\.(?:md|url)$//;
                $u =~ s{(^|/)index$}{$1};                  # index -> the dir itself
                $u = "/$u";
                push @urls, $u;
            }
        }
        closedir $dh;
    };
    $walk->( $DOCROOT, '' );
    my %seen;
    @urls = grep { !$seen{$_}++ } @urls;
    return { ok => 1, urls => [ sort @urls ] };
}

sub action_config_read {
    # SM042: the Config page loads via config-read (not the retired lazysite
    # pseudo-plugin), so this subset must surface EVERY key the page shows -
    # settable ones and the readonly_with_link ones (layout/theme/layouts_repo,
    # managed on Appearance). Kept in lock-step with config.md SITE_SCHEMA and
    # config-set's allow-list by t/lint/18-config-key-parity.t.
    my %out = map { $_ => '' }
        qw(site_name site_url layout theme layouts_repo nav_file webdav_enabled
        manager manager_path search_default update_channel canonical_ip
        asset_max_age
        mcp_enabled oauth_enabled control_api_enabled token_exchange_enabled);
    if ( open my $fh, '<', "$LAZYSITE_DIR/lazysite.conf" ) {
        while ( my $line = <$fh> ) {
            next unless $line =~ /^(\w+)\s*:\s*(.*?)\s*$/;
            $out{$1} = $2 if exists $out{$1};
        }
        close $fh;
    }
    return { ok => 1, config => \%out };
}

# SM151: read-only view of the domains this instance serves - the primary host
# plus each declared alias, with the presentation/routing keys that vary per
# host (an alias inherits the base value where it has no override). Parsed
# straight from lazysite.conf; aliases are operator conf-file territory, so the
# manager only displays them, never edits them.
sub action_domains_list {
    my @keys = qw(site_name site_url content_root theme layout nav_file search_default
        allowed_groups locked_users lang lang_group);
    my %base;
    my %ov;    # host => { key => value }
    if ( open my $fh, '<', "$LAZYSITE_DIR/lazysite.conf" ) {
        while ( my $line = <$fh> ) {
            if ( $line =~ /^alias\.(\S+)\.(\w+)\s*:\s*(.*?)\s*$/ ) {
                $ov{ lc $1 }{$2} = $3;
            }
            elsif ( $line =~ /^(\w+)\s*:\s*(.*?)\s*$/ ) {
                $base{$1} = $2;
            }
        }
        close $fh;
    }

    my @domains;
    push @domains,
        {
        host       => '(default)',
        is_primary => 1,
        map { $_ => ( $base{$_} // '' ) } @keys,
        };
    for my $h ( split /,/, ( $base{alias_hosts} // '' ) ) {
        $h =~ s/^\s+|\s+$//g;
        next unless length $h;
        my %row = ( host => lc $h, is_primary => 0 );
        for my $k (@keys) {
            # An alias override wins; otherwise the host inherits the base value.
            $row{$k} = defined $ov{ lc $h }{$k} ? $ov{ lc $h }{$k} : ( $base{$k} // '' );
            $row{ $k . '_inherited' } = ( defined $ov{ lc $h }{$k} ) ? 0 : 1;
        }
        push @domains, \%row;
    }
    return { ok => 1, domains => \@domains, keys => \@keys };
}

# SM179 P6: translation-coverage status for a language set. Read-only. `group`
# selects the set; when omitted, the base host's lang_group is used (the common
# single-set case). Returns the per-root missing/stale/current report from
# Lazysite::Lang, so an operator or a translation agent sees exactly what still
# needs doing without any bookkeeping of its own.
sub action_lang_status {
    my ($group) = @_;
    my $conf = '';
    if ( open my $fh, '<:raw', "$LAZYSITE_DIR/lazysite.conf" ) {
        local $/;
        $conf = <$fh>;
        close $fh;
    }
    if ( !defined $group || !length $group ) {
        $group = sole_group($conf);
    }
    if ( !length $group ) {
        return { ok => 0, error => 'no language group (set lang_group in the conf, or pass group=)' };
    }
    my $status = lang_status( docroot => $DOCROOT, conf_text => $conf, group => $group );
    return { ok => 1, %$status };
}

sub action_config_set {
    my ( $key, $value ) = @_;
    # SM122: a small, injection-safe subset settable via the API (with manage_config).
    my %allow = map { $_ => 1 }
        qw(site_name site_url search_default webdav_enabled layout theme nav_file
        update_channel canonical_ip manager manager_path asset_max_age
        mcp_enabled oauth_enabled control_api_enabled token_exchange_enabled);
    $key = '' unless defined $key;
    return { ok => 0, error => "Config key '$key' is not settable via the API" }
        unless $allow{$key};
    # 0.9.0 service killswitches + the manager toggle: enabled/disabled, same
    # shape as webdav_enabled (SM042: the whole site-settings page now saves via
    # config-set, not the lazysite pseudo-plugin, so config-set owns their rules).
    if ( $key =~ /^(?:mcp|oauth|control_api|token_exchange)_enabled$/
        && defined $value && $value !~ /^(?:enabled|disabled)$/ )
    {
        return { ok => 0, error => "$key must be 'enabled' or 'disabled'" };
    }
    if ( $key eq 'manager' && defined $value && $value !~ /^(?:enabled|disabled)$/ ) {
        return { ok => 0, error => "manager must be 'enabled' or 'disabled'" };
    }
    if ( $key eq 'manager_path' && defined $value && length $value
        && $value !~ m{^/[A-Za-z0-9_./-]*$} )
    {
        return { ok => 0, error => 'manager_path must be an absolute URL path (e.g. /manager)' };
    }
    # SM156: canonical_ip is a comma list of this server's PUBLIC IPs (for the
    # domain-check "points here" check behind a proxy/NAT). Validate as IPv4/IPv6
    # literals, comma-separated - no hostnames, no shell/markup metacharacters.
    if ( $key eq 'canonical_ip' && defined $value && length $value ) {
        for my $ip ( split /\s*,\s*/, $value ) {
            return { ok => 0, error => 'canonical_ip must be comma-separated IP addresses' }
                unless $ip =~ /^[0-9.]+$/ || $ip =~ /^[0-9A-Fa-f:]+$/;
        }
    }
    # SM122: validate the enum/name-shaped keys.
    # SM416: seconds, bounded; 0 (or empty) restores the revalidation default.
    if ( $key eq 'asset_max_age' && defined $value && length $value
        && $value !~ /^\d{1,9}$/ ) {
        return { ok => 0, error => 'asset_max_age must be a number of seconds (0 disables)' };
    }
    if ( $key eq 'webdav_enabled' && defined $value && $value !~ /^(?:enabled|disabled)$/ ) {
        return { ok => 0, error => "webdav_enabled must be 'enabled' or 'disabled'" };
    }
    # Channel ladder: 'all' (the UI vocabulary) and 'edge' (the CLI's) are
    # synonyms - both mean "accept every release".
    if ( $key eq 'update_channel' && defined $value && $value !~ /^(?:all|edge|beta|stable)$/ ) {
        return { ok => 0, error => "update_channel must be 'all', 'beta' or 'stable'" };
    }
    if ( ( $key eq 'layout' || $key eq 'theme' ) && defined $value && length $value
        && $value !~ /^[A-Za-z0-9_-]+$/ ) {
        return { ok => 0, error => "$key must be a simple name" };
    }
    # canonical_ip may be CLEARED (empty = auto-detect); every other key needs a
    # value.
    return { ok => 0, error => "A value is required" }
        unless ( defined $value && length $value ) || $key eq 'canonical_ip';
    $value = '' unless defined $value;
    return { ok => 0, error => "Value must be a single line" }
        if $value =~ /[\r\n]/;
    my ( $wok, $werr ) = _write_conf_key( $key, $value );
    return { ok => 0,
        error => 'Could not write lazysite.conf' . ( defined $werr ? ": $werr" : '' ) }
        unless $wok;
    log_event( 'INFO', 'config-set', 'config key set', key => $key, user => $auth_user );
    # SM255: the commit is no longer made here. lazysite.conf has ONE write path
    # and it records the change itself, so every writer - config-set, the domain
    # verbs, the CLI - produces the same history entry. A caller committing its
    # own write is how the two surfaces diverged in the first place.
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
# SM126: the capability map - the static model (channels, what each capability
# unlocks, task recipes, engine-owned paths) plus this caller's own grant under
# "holds". Introspection: allowed for any authenticated caller (token or cookie).
sub action_describe_capabilities {
    my ($user) = @_;
    my $s = ( users_api( { action => 'settings-get', username => $user } ) || {} )->{settings} || {};
    my $allg   = ( users_api( { action => 'groups' } ) || {} )->{groups} || {};
    my @groups = sort grep {
        ref $allg->{$_} eq 'ARRAY' && ( grep { $_ eq $user } @{ $allg->{$_} } )
    } keys %$allg;
    my $map = describe( caps => $s, account => $user, groups => \@groups,
        docroot => $DOCROOT );    # SM225: include the documentation index
    $map->{ok} = 1;
    return $map;
}

# SM350: the control API's answer to tools/list.
#
# describe-capabilities says what this account MAY DO in capability terms; this
# says what it may CALL, with the parameters each takes and where each is read
# from. The two were meant to be read together and only one of them existed.
#
# Subset by grant, exactly as tools/list does (SM210). A reference listing every
# action regardless would be a list of things to try and be refused, which is
# what an agent does with it - the refusals then look like defects.
#
# The cookie/token distinction is passed rather than inferred, because it is the
# one thing that decides availability for 59 of the 111 actions and the module
# has no business reading the request.
sub action_actions_list {
    my ($user) = @_;
    my $s = ( users_api( { action => 'settings-get', username => $user } ) || {} )->{settings} || {};
    return {
        ok      => 1,
        account => $user,
        channel => ( $token_auth ? 'token' : 'cookie' ),
        actions => Lazysite::ControlApi::Actions::actions_for(
            $s, cookie => ( $token_auth ? 0 : 1 )
        ),
    };
}

sub action_whoami {
    my ($user) = @_;
    my $s = ( users_api( { action => 'settings-get', username => $user } ) || {} )->{settings} || {};

    my $allg   = ( users_api( { action => 'groups' } ) || {} )->{groups} || {};
    my @groups = sort grep {
        ref $allg->{$_} eq 'ARRAY' && ( grep { $_ eq $user } @{ $allg->{$_} } )
    } keys %$allg;

    my ( $active_layout, $active_theme ) = _read_active_layout_and_theme();
    my $bool = sub { $_[0] ? JSON::PP::true() : JSON::PP::false() };

    return {
        ok      => 1,
        partner => $user,
        # SM094: the site's manager groups, so the Users UI can tell which accounts
        # are operators (full access) vs partners gated by the capability toggles.
        # SM138: derived from group settings (ui / manage_users / the manager
        # flag) - the conf manager_groups key is retired.
        manager_groups => [ _manager_groups_from_settings() ],
        # $s is the EFFECTIVE settings (from settings-get -> the resolver), so report
        # every capability straight from it. SM126: derived from @CAP_KEYS (via
        # capability_keys) so a new capability appears here automatically - the old
        # hand-list had drifted, omitting delegate_sub_user_creation. `ui` keeps its
        # default-on semantics (true unless explicitly disabled).
        capabilities => {
            map {
                $_ => ( $_ eq 'ui'
                    ? $bool->( !( exists $s->{ui} && !$s->{ui} ) )
                    : $bool->( $s->{$_} ) )
            } capability_keys()
        },
        groups => \@groups,
        scope  => {
            # SM155: group-derived; a comma-joined list for a multi-domain editor.
            allow => ( @{ $s->{dav_scopes} || [] }
                ? join( ', ', @{ $s->{dav_scopes} } ) : '/' ),
            deny => [ '/cgi-bin/', '/manager/', '/lazysite/auth/',
                '/lazysite/forms/smtp.conf',    '/lazysite/forms/handlers.conf',
                '/lazysite/forms/submissions/', '/lazysite/cache/',
                '/lazysite/logs/',              '/lazysite/manager/',
                '/lazysite/templates/',         '/lazysite/lazysite.conf', '*.pl' ],
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
        # SM179 P7: when the bound site is a language-set member, tell the agent
        # its language, the group, and where every sibling's files live - so it
        # knows immediately a translation counterpart exists without probing.
        %{ _language_context($s) // {} },
    };
}

# SM179 P7: the language context for a partner's whoami. Returns { language =>
# { lang, lang_group, siblings => [ { host, lang, content_root, source } ] } }
# when this instance has a language set, else undef (the block is omitted). The
# partner's `lang` is that of their bound home_domain (else the source). `source`
# marks the source-of-truth root a translation agent copies FROM.
sub _language_context {
    my ($s) = @_;
    my $conf = '';
    if ( open my $fh, '<:raw', "$LAZYSITE_DIR/lazysite.conf" ) {
        local $/;
        $conf = <$fh>;
        close $fh;
    }
    my $group = sole_group($conf);
    return undef unless length $group;
    my @members = Lazysite::Lang::set_members( $conf, $group );
    return undef unless @members;

    my $bool = sub { $_[0] ? JSON::PP::true() : JSON::PP::false() };
    my $home = $s->{home_domain} // '';
    my ($me) = grep { $_->{host} eq $home } @members;
    ($me) = grep { $_->{source} } @members unless $me;

    return {
        language => {
            lang       => ( $me ? $me->{lang} : '' ),
            lang_group => $group,
            siblings   => [
                map {
                    { host => $_->{host},
                        lang         => $_->{lang},
                        content_root => $_->{content_root},
                        source       => $bool->( $_->{source} ),
                    }
                } @members
            ],
        },
    };
}

# SM072 audit trail: append one line per state-changing request to a
# manager-readable log. Fields are pipe-delimited: ts | user | action | ip | status.
# audit_log now lives in Lazysite::Audit (shared with WebDAV + MCP); imported
# at the top. action_audit (the reader, below) stays here - it is a manager
# action.

# SM: the audit trail is its own capability now, separate from visitor analytics.
# SM138: the groups that confer manager access, read from group settings.
sub _manager_groups_from_settings {
    my $gs  = Lazysite::Auth::Settings::read_group_settings();
    my @mgr = sort grep {
        my $c = $gs->{$_};
        ref $c eq 'HASH' && ( $c->{ui} || $c->{manage_users} || $c->{manager} );
    } keys %{$gs};
    return @mgr;
}

sub _user_audit {
    my ($user) = @_;
    return 0 unless defined $user && length $user;
    my $s = ( users_api( { action => 'settings-get', username => $user } ) || {} )->{settings} || {};
    return $s->{audit} ? 1 : 0;
}

# SEC-2026-07 (H1): the acting cookie user's full effective capability hash, for
# the cookie-side authorization gate (the token path uses %token_caps). Same
# resolution as the single-cap helpers above.
sub _user_caps {
    my ($user) = @_;
    return {} unless defined $user && length $user;
    return ( users_api( { action => 'settings-get', username => $user } ) || {} )->{settings} || {};
}

# SM141: the manage_users capability (session listing + revocation). Same
# resolution as _user_audit.
sub _user_manage_users {
    my ($user) = @_;
    return 0 unless defined $user && length $user;
    my $s = ( users_api( { action => 'settings-get', username => $user } ) || {} )->{settings} || {};
    return $s->{manage_users} ? 1 : 0;
}

# The notifications capability (the manager bell). Same resolution as _user_audit.
sub _user_cap_notifications {
    my ($user) = @_;
    return 0 unless defined $user && length $user;
    my $s = ( users_api( { action => 'settings-get', username => $user } ) || {} )->{settings} || {};
    return $s->{notifications} ? 1 : 0;
}

sub _audit_parse_line {
    my ($line) = @_;
    chomp $line;
    my @f = split / \| /, $line;
    # Column growth over releases: 5 = ts|user|action|ip|status (pre-SM078);
    # 6 adds target (SM078); 7 appends origin (SM077, ui/api); 8 adds detail.
    my ( $ts, $u, $act, $target, $ip, $status, $origin, $detail );
    if ( @f >= 8 ) { ( $ts, $u, $act, $target, $ip, $status, $origin, $detail ) = @f[ 0 .. 7 ] }
    elsif ( @f == 7 ) { ( $ts, $u, $act, $target, $ip, $status, $origin ) = @f[ 0 .. 6 ]; $detail = '' }
    elsif ( @f == 6 ) { ( $ts, $u, $act, $target, $ip, $status ) = @f[ 0 .. 5 ]; $origin = ''; $detail = '' }
    else { ( $ts, $u, $act, $ip, $status ) = @f[ 0 .. 4 ]; $target = ''; $origin = ''; $detail = '' }
    return { ts => $ts, user => $u, action => $act, target => $target,
        ip => $ip, status => $status, origin => $origin, detail => $detail };
}

# Append-only cache: parse only the audit lines appended since last call, keeping
# the most recent CAP entries (chronological order). Rotation/truncation-aware.
sub _audit_cached_entries {
    my $file = "$LAZYSITE_DIR/logs/audit.log";
    return [] unless -f $file;
    my $CAP        = 5000;
    my $cache_dir  = "$LAZYSITE_DIR/cache";
    my $cache_file = "$cache_dir/audit-cache.json";
    my @st         = stat($file);
    my ( $inode, $size ) = ( $st[1], $st[7] );

    my $cache;
    if ( open my $cf, '<', $cache_file ) {
        local $/; $cache = eval { decode_json(<$cf>) }; close $cf;
    }
    if ( !$cache || ref $cache ne 'HASH'
        || ( $cache->{inode}  // -1 ) != $inode
        || ( $cache->{offset} // 0 ) > $size ) {
        $cache = { inode => $inode, offset => 0, entries => [] };
    }
    $cache->{entries} ||= [];

    my $offset = $cache->{offset} // 0;
    if ( $size > $offset && open my $fh, '<', $file ) {
        seek $fh, $offset, 0;
        my $pos = $offset;
        while ( my $line = <$fh> ) {
            last unless $line =~ /\n\z/;    # incomplete final line: next time
            $pos += length $line;
            push @{ $cache->{entries} }, _audit_parse_line($line);
        }
        close $fh;
        my $over = @{ $cache->{entries} } - $CAP;
        splice @{ $cache->{entries} }, 0, $over if $over > 0;
        $cache->{offset} = $pos;
        $cache->{inode}  = $inode;
        if ( -d $cache_dir || mkdir($cache_dir) ) {
            if ( open my $w, '>', "$cache_file.$$" ) {
                print {$w} encode_json($cache); close $w;
                rename "$cache_file.$$", $cache_file;
            }
        }
    }
    return $cache->{entries};
}

sub action_recent_changes {
    my ($window) = @_;
    $window = ( defined $window && $window =~ /\A\d+\z/ ) ? $window : 86_400;    # 24h
    my $entries = _audit_cached_entries();
    # Audit timestamps are ISO (…Z), so a lexical cutoff is a time cutoff.
    my $cutoff = POSIX::strftime( '%Y-%m-%dT%H:%M:%SZ', gmtime( time() - $window ) );
    my %recent;
    for my $e ( @{$entries} ) {
        next unless ( $e->{status} // '' ) eq 'ok';
        next unless defined $e->{target} && length $e->{target} && $e->{target} ne '/';
        next unless ( $e->{ts} // '' ) ge $cutoff;
        # Entries are chronological, so the last write per target wins.
        $recent{ $e->{target} } =
            { ts => $e->{ts}, user => $e->{user}, action => $e->{action} };
    }
    return { ok => 1, window => $window, changes => \%recent };
}

sub action_audit {
    my (%opt)  = @_;
    my $cached = _audit_cached_entries();
    my $want   = $opt{user};
    my $want_t = $opt{target};              # SM077: filter to one file's history
        # Date-range filter: timestamps are ISO (2026-06-27T14:47:24Z) so they sort
        # lexically. A bare date widens to the whole day (start -> 00:00, end -> 23:59).
    my ( $start, $end ) = ( $opt{start}, $opt{end} );
    for my $b ( [ \$start, 'T00:00:00Z' ], [ \$end, 'T23:59:59Z' ] ) {
        my ( $ref, $pad ) = @$b;
        if ( defined $$ref && length $$ref ) {
            $$ref =~ s/[^0-9T:Z+-].*\z//;    # keep ISO-ish chars only
            $$ref .= $pad if $$ref =~ /\A\d{4}-\d\d-\d\d\z/;
        }
        else { $$ref = undef }
    }
    my $scope = $opt{scope};    # SM173: hashref of visible actors, or undef
    my @entries;
    my ( %fusers, %ftargets );          # SM119: distinct values for the filter dropdowns
    for my $e ( reverse @$cached ) {    # newest first
        my ( $ts, $u, $target ) = ( $e->{ts}, $e->{user}, $e->{target} );
        # SM173: a scoped (sub-user-manager) view sees only its team's activity -
        # applied before the facets so the dropdowns list only that team.
        next if $scope && !$scope->{ $u // '' };
        $fusers{ defined $u        ? $u      : '' } = 1;    # facets from all entries
        $ftargets{ defined $target ? $target : '' } = 1;
        # SM119: a "__none" filter matches blank-valued entries; else exact match.
        if ( defined $want && length $want ) {
            next if $want eq '__none' ? length( $u // '' ) : ( $u // '' ) ne $want;
        }
        if ( defined $want_t && length $want_t ) {
            next if $want_t eq '__none' ? length( $target // '' ) : ( $target // '' ) ne $want_t;
        }
        next if defined $start && ( $ts // '' ) lt $start;
        next if defined $end   && ( $ts // '' ) gt $end;
        push @entries, $e;
    }

    # Paginate (newest first); default 50 rows per page.
    my $per = $opt{per_page} || 50;
    $per = 50  if $per < 1;
    $per = 200 if $per > 200;
    my $total = scalar @entries;
    my $pages = $total ? int( ( $total + $per - 1 ) / $per ) : 1;
    my $page  = $opt{page} || 1;
    $page = 1      if $page < 1;
    $page = $pages if $page > $pages;
    my $pg_start = ( $page - 1 ) * $per;
    my $pg_end   = $pg_start + $per - 1;
    $pg_end = $#entries if $pg_end > $#entries;
    my @slice = $total ? @entries[ $pg_start .. $pg_end ] : ();

    return { ok => 1, entries => \@slice,
        total   => $total, page => $page, per_page => $per, pages => $pages,
        scoped  => ( $scope ? JSON::PP::true() : JSON::PP::false() ),    # SM173
        users   => [ sort keys %fusers ],       # SM119: filter dropdown options
        targets => [ sort keys %ftargets ] };
}

# SM072: the running version, read from the install state .install-state.json.
sub _stats_tool_path {
    for my $c (
        $ENV{LAZYSITE_STATS_TOOL},
        dirname($0) . "/../plugins/stats.pl",
        dirname($0) . "/plugins/stats.pl",
        "$DOCROOT/../plugins/stats.pl",
    ) {
        return $c if defined $c && -f $c;
    }
    return undef;
}

# SM095: visitor-log analysis over the control API (gated on `analytics`, like the
# MCP analyse_visitors tool). Returns the stats plugin's sanitised, cached export -
# aggregates + a capped event stream; never the raw log, a path, or a visitor IP.
sub action_analyse_visitors {
    my (%opt) = @_;
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
    my $pid = eval {
        open2( $out, $in, $^X, $tool, '--export', '--docroot', $DOCROOT, '--window', $window, @sel );
    } or return { ok => 0, error => 'Cannot run the stats plugin' };
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return eval { decode_json( $resp // '{}' ) } || { ok => 0, error => 'No stats output' };
}

sub action_version {
    my $path = "$LAZYSITE_DIR/.install-state.json";
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
    my $u      = users_api( { action => 'list' } )   || {};
    my $g      = users_api( { action => 'groups' } ) || {};
    my @users  = ref $u->{users} eq 'ARRAY' ? @{ $u->{users} }                : ();
    my @groups = ref $g->{groups} eq 'HASH' ? ( sort keys %{ $g->{groups} } ) : ();
    return { ok => 1, users => \@users, groups => \@groups };
}

# SM145: a thin one-shot call into the users tool (--api) for reads/writes that
# this file gates itself (keys-list / key-revoke), bypassing action_users'
# GET-guard and actor-injection which are specific to the account CRUD path.
sub _users_tool_call {
    my ($payload) = @_;
    my $script = _users_tool_path()
        or return { ok => 0, error => "User management not available" };
    my ( $out, $in );
    my $pid = eval { open2( $out, $in, $^X, $script, '--api', '--docroot', $DOCROOT ) };
    return { ok => 0, error => "Cannot run user management: $@" } unless $pid;
    print $in encode_json($payload);
    close $in;
    my $o = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return eval { decode_json( $o // '{}' ) } // { ok => 0, error => "Invalid response" };
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
        $request_body = encode_json( { action => $sub } );
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

            # SEC-2026-07 (C1): a DELEGATED sub-manager (create_sub_users, not
            # full manage_users) may run only sub-tree-confinable operations on
            # its own descendants. The powerful account operations - group
            # membership, capability settings, account removal, token minting,
            # top-level add - require full manage_users, or a delegate could add
            # itself to an admin group / reset another account. Operators and
            # 'local' bypass. passwd is now actor-confined (below + in the tool).
            # SM194: account-promote (managed_by clear) and
            # account-scope-independent (created_by ceiling lift) are OPERATOR-
            # ONLY by omission from %DELEGABLE - a delegate promoting its own
            # child out from under itself would defeat confinement. The tool
            # refuses them for any present actor too (defence in depth).
            if ( $auth_user ne 'local' && !_is_operator() && !_user_manage_users($auth_user) ) {
                my %DELEGABLE = map { $_ => 1 } qw(
                    account-create account-disable account-enable account-reassign
                    rename claim-create claim-cancel passwd
                    list groups users-detail settings-get group-settings-get
                    users-page principals recent-changes keys-list sessions-list
                );
                return { ok => 0, kind => 'forbidden',
                    error => "That account operation requires the 'Users & groups' "
                        . "permission (full user management)." }
                    unless $DELEGABLE{$act};
            }

            # SM195: group-settings-set now enforces a per-capability ceiling in
            # the tool (a non-operator may confer only what they hold, or what an
            # operator put in their groups' grantable set) - so the tool has to
            # KNOW who is asking. Without this the actor arrived undefined and the
            # ceiling silently did not apply, which is how the hole existed:
            # manage_users was the whole check.
            # NOT gated on _is_operator(). That returns TRUE for anyone holding
            # manage_users (Acl.pm:116), which is exactly the population the
            # ceiling exists to bound - so gating on it meant no actor was passed
            # for a delegate, the tool saw an operator, and the ceiling never ran.
            # An adversarial review found that; the first cut of SM195 was inert
            # through the manager while its unit test passed, because the test
            # supplied the actor this line did not.
            #
            # The tool decides. `local` is the CLI/operator sentinel and is the
            # only exemption here; the unsecured-site exemption lives in
            # _may_confer, where it can be stated once for every caller.
            # SM268 H8: the ceiling now covers every verb that can RAISE
            # privilege, not just the one that declares a capability - joining a
            # capable group, nesting one, and minting a credential all acquire
            # capabilities by another route. Each needs the actor, or the tool
            # sees an operator and the ceiling does not run.
            if ( $auth_user ne 'local'
                && $act =~ /\A(?:group-settings-set|group-add|group-nest|token)\z/ )
            {
                $parsed->{actor} = $auth_user;
                $request_body = encode_json($parsed);
            }

            # SM346: the Users page needs to know WHO IS ASKING to decide which
            # operator-only controls to show. Its single consolidated call
            # replaced three - one of which was whoami - and carried forward the
            # data and not the identity, so the page computed "am I an operator"
            # against an empty username and got false for everybody.
            #
            # A separate key from `actor` on purpose: `actor` is an
            # authorisation signal (the users tool refuses privileged verbs when
            # it names a non-operator), and this is a read-only call that just
            # needs a name to match against group membership.
            if ( $auth_user ne 'local' && $act eq 'users-page' ) {
                $parsed->{me} = $auth_user;
                $request_body = encode_json($parsed);
            }

            if ( $auth_user ne 'local'
                && $act =~ /^(?:account-(?:create|disable|enable|reassign)|claim-create|claim-cancel|rename|passwd)$/x ) {
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

    my $result = eval { decode_json( $output // '{}' ) } // { ok => 0, error => "Invalid response" };
    # The combined Users-page call folds in the current operator's identity so the
    # browser needs no separate whoami round-trip (its shape carries users+groups).
    if ( ref $result eq 'HASH' && $result->{ok}
        && exists $result->{users} && exists $result->{groups} ) {
        $result->{me} = $auth_user;
    }
    return $result;
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
    # 0660: identity-shared secret (see _preview_secret) - never world.
    chmod 0o660, $tmp;
    print $wfh "$new\n";
    close $wfh;
    unless ( rename $tmp, $path ) {
        my $err = $!;
        unlink $tmp;
        return { ok => 0, error => "Cannot replace $path: $err" };
    }
    chmod 0o660, $path;

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

# Resolve which nav file to edit. SM159: domain-aware - a $host selects that
# domain's nav_file OVERRIDE (alias.<host>.nav_file) when it has one; otherwise
# (no host, the primary/default host, or a domain with no override) the BASE
# nav_file applies. Returns ( absolute-path, rel-path, inherited, base-rel ) so a
# caller can tell an override apart from the shared base nav. The nav editor
# never writes the config pointer - giving a domain its own nav is a nav_file
# override set on the Domains page (manage_config).











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

