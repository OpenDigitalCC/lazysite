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
use Fcntl qw(:flock O_RDWR O_CREAT);
use POSIX qw(strftime);

BEGIN {
    # Locate the Lazysite module tree relative to this script (run-in-place,
    # tar and Hestia installs), falling back to the system @INC (package
    # installs). No configuration needed.
    require Cwd;
    require File::Basename;
    # SM1078: then the docroot's ../lib, where install.pl puts it whatever
    # --cgibin was (one rule in every script a cgi-bin runs, t/lint/263).
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    my $doc = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT} || '';
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib", ( length $doc ? "$doc/../lib" : () ) ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
}
use Lazysite::Util         qw(log_event const_eq);
use Lazysite::Paths        ();
use Lazysite::Audit        qw(audit_log);
use Lazysite::Capabilities        qw(describe capability_keys channel_service);
use Lazysite::ControlApi::Actions ();                        # SM350
use Lazysite::BadUrl              qw(list_blocks block unblock);
use Lazysite::Auth::Settings      qw(site_grants_manager);
use Lazysite::Auth::Acl           qw(load_acls save_acls _acl_norm _to_list _acl_allows);
use Lazysite::Auth::Session       qw(generate_csrf_token);
use Lazysite::Manager::Common qw(validate_path is_blocked_path write_file_checked respond _emit_json
    is_blocked_config is_blocked_upload_target upload_limits load_upload_limits _reset_upload_limits_cache
    processor_path
    _no_scope_refusal
    _request_ip _operator
    reset_request_context
    users_api _users_tool_run _tool_path _user_caps _json_body
    $auth_user $token_auth %token_caps @REQUEST_SCOPES $REQUEST_CONFINED $IS_OPERATOR $action $path $body %params);
use Lazysite::Manager::Upload qw(action_file_upload action_file_download action_file_zip_download stream_bytes collect_zip_paths
    check_upload_rate is_editable_text parse_multipart_body);
use Lazysite::Manager::Plugins qw(action_plugin_list action_plugin_enable action_plugin_disable
    action_plugin_read action_plugin_save action_plugin_action
    action_form_submissions action_form_submission action_form_submission_delete dispatch_form_list
    action_form_submission_confirm action_form_submissions_delete_bulk
    action_form_submission_approve
    action_form_delete);
use Lazysite::Manager::Notices qw(_notices_gate); # SM918: one notice reader, shared with MCP
use Lazysite::Manager::StartPage qw(action_start_page dispatch_start_page_set); # SM944 S23
use Lazysite::Manager::Account   qw(action_me dispatch_me_password action_me_sessions
    dispatch_me_session_revoke action_me_sign_out_everywhere
    action_me_notices dispatch_me_notices_seen
    dispatch_me_2fa_enrol dispatch_me_2fa_confirm dispatch_me_2fa_disable dispatch_me_recovery_codes); # SM1043: the member's own account
use Lazysite::Handlers         ();    # SM842: handlers, bindings, the schedule
use Lazysite::Manager::Files qw(action_list action_read action_save action_delete action_mkdir
    action_move action_copy action_migrate_to_local action_aliases_list
    acquire_lock release_lock renew_lock _get_lock_info lock_refusal
    action_acl_get dispatch_acl_set action_acl_remove action_protected_sections
    action_git_status action_git_history action_git_history_summary
    action_git_show action_git_restore action_git_init
    action_regenerate_registries);
use Lazysite::Manager::Themes qw(action_theme_list dispatch_themes_list_all action_theme_activate
    action_layout_activate action_theme_delete action_theme_copy action_theme_upload
    action_cache_list action_cache_invalidate
    action_artifact_manifest action_artifact_validate);
use Lazysite::Manager::Nav     qw(action_nav_read action_nav_save);
use Lazysite::Manager::Layouts qw(action_layouts_releases action_layouts_install
    action_layouts_release_contents action_layouts_available action_themes_for_layout
    action_layout_delete action_layouts_manifest action_layout_install
    action_artifact_backups_delete
    action_layouts_repo_get action_layouts_repo_set);
use Lazysite::Manager::Backups qw(action_backup_create action_backup_download
    action_backup_restore action_backup_delete);
use Lazysite::Manager::Sessions qw(dispatch_sessions_keys);
use Lazysite::Manager::Domains qw(domains_list domain_add domain_add_alias domain_remove domain_set domain_check domain_preview preview_public known_domain_host valid_host host_refusal domain_content_root action_domain_check action_domains_list); # SM944 S27
use Lazysite::Manager::Data        ();
use Lazysite::Manager::SitePackage qw(package_create package_apply package_inspect);
use Lazysite::Manager::Remap qw(_remap_list _remap_save); # SM944 S22: SM802's two actions
use Lazysite::Manager::Preview qw(action_preview action_preview_grant action_preview_clear); # SM944 S24: SM071's preview verbs
use Lazysite::Manager::Describe qw(action_describe_capabilities action_actions_list _json_bool); # SM944 S25
use Lazysite::Manager::Services qw(action_channel_services action_analyse_visitors action_version); # SM944 S26
use Lazysite::Manager::SiteBackup qw(action_site_backup_create action_site_backup_upload action_site_backup_apply action_site_export_primary action_site_backup_inspect action_site_backup_delete action_site_backup_download _package_scope_refusal); # SM944 S28
use Lazysite::Manager::Config qw(action_config_read action_config_set action_lang_status); # SM944 S30
use Lazysite::Manager::PagePdf qw(action_page_pdf);    # SM944 S29
use Lazysite::Manager::AuditTrail qw(_audit_trail_set _audit_implicit_target _audit_plugin_target action_recent_changes dispatch_audit); # SM944 S31
use Lazysite::Manager::Users qw(action_whoami _handler_who action_display_names action_principals action_users action_rotate_auth_secret); # SM944 S32
use Lazysite::Manager::Groups        ();    # SM1050: groups-list, group-set
use Lazysite::Manager::AccountImport ();    # SM1053: accounts-import-*
use Lazysite::Manager::SiteBackup qw(dispatch_backup_list); # SM944 S33: backup-list's branch
use Lazysite::Manager::Csrf       qw(csrf_refusal);         # SM944 S34: the M-1 CSRF gate
$Lazysite::Util::COMPONENT = 'manager-api';

# SM556: resolved once, here, so every module confines against one spelling
# of the tree (see Paths::canonical_docroot for when it is left as given).
my $DOCROOT = Lazysite::Paths::canonical_docroot( $ENV{DOCUMENT_ROOT} // die "No DOCUMENT_ROOT\n" );
$Lazysite::Auth::Acl::DOCROOT            = $DOCROOT;
$Lazysite::Manager::Common::DOCROOT      = $DOCROOT;
$Lazysite::Manager::Upload::DOCROOT      = $DOCROOT;
$Lazysite::Manager::Plugins::DOCROOT     = $DOCROOT;
$Lazysite::Manager::Notices::DOCROOT     = $DOCROOT;
$Lazysite::Manager::StartPage::DOCROOT   = $DOCROOT;           # SM944 S23
$Lazysite::Manager::Account::DOCROOT     = $DOCROOT;           # SM1043
$Lazysite::Handlers::DOCROOT             = $DOCROOT;           # SM842
$Lazysite::Manager::Files::DOCROOT       = $DOCROOT;
$Lazysite::Manager::Themes::DOCROOT      = $DOCROOT;
$Lazysite::Manager::Nav::DOCROOT         = $DOCROOT;
$Lazysite::Manager::Layouts::DOCROOT     = $DOCROOT;
$Lazysite::Manager::Backups::DOCROOT     = $DOCROOT;
$Lazysite::Manager::Domains::DOCROOT     = $DOCROOT;
$Lazysite::Manager::Data::DOCROOT        = $DOCROOT;
$Lazysite::Manager::SitePackage::DOCROOT = $DOCROOT;
$Lazysite::Manager::Remap::DOCROOT       = $DOCROOT;           # SM944 S22
my $LAZYSITE_DIR = Lazysite::Paths::lazysite_dir($DOCROOT);    # SM293
# SM944 S31: Manager::Common's _request_ip reads the request address's conf here.
$Lazysite::Manager::Common::LAZYSITE_DIR = $LAZYSITE_DIR;

$Lazysite::Manager::Backups::LAZYSITE_DIR = $LAZYSITE_DIR;
$Lazysite::Audit::LAZYSITE_DIR            = $LAZYSITE_DIR;
$Lazysite::Auth::Session::LAZYSITE_DIR    = $LAZYSITE_DIR;
$Lazysite::Auth::Settings::AUTH_DIR = "$LAZYSITE_DIR/auth";   # SM138: site_grants_manager
use Lazysite::Auth::Verify ();    # SM685: verify in-process, no subprocess
$Lazysite::Manager::Upload::LAZYSITE_DIR   = $LAZYSITE_DIR;
$Lazysite::Manager::Themes::LAZYSITE_DIR   = $LAZYSITE_DIR;
$Lazysite::Manager::Nav::LAZYSITE_DIR      = $LAZYSITE_DIR;
$Lazysite::Manager::Layouts::LAZYSITE_DIR  = $LAZYSITE_DIR;
$Lazysite::Manager::Sessions::LAZYSITE_DIR = $LAZYSITE_DIR;    # SM141
$Lazysite::Manager::Account::LAZYSITE_DIR  = $LAZYSITE_DIR;    # SM1043
$Lazysite::Manager::Artifact::LAZYSITE_DIR = $LAZYSITE_DIR;
$Lazysite::Manager::Preview::DOCROOT       = $DOCROOT;         # SM944 S24
$Lazysite::Manager::Preview::LAZYSITE_DIR  = $LAZYSITE_DIR;
$Lazysite::Manager::Describe::DOCROOT      = $DOCROOT;         # SM944 S25
$Lazysite::Manager::Services::DOCROOT      = $DOCROOT;         # SM944 S26
$Lazysite::Manager::Services::LAZYSITE_DIR = $LAZYSITE_DIR;
# SM944 S28: Manager::SiteBackup, the site backup and export verbs.
$Lazysite::Manager::SiteBackup::DOCROOT      = $DOCROOT;
$Lazysite::Manager::SiteBackup::LAZYSITE_DIR = $LAZYSITE_DIR;
# SM944 S27: Manager::Domains reads the conf for domains-list (its DOCROOT is set above).
$Lazysite::Manager::Domains::LAZYSITE_DIR = $LAZYSITE_DIR;
# SM944 S30: Manager::Config, the configuration and language verbs.
$Lazysite::Manager::Config::DOCROOT      = $DOCROOT;
$Lazysite::Manager::Config::LAZYSITE_DIR = $LAZYSITE_DIR;
# SM944 S29: Manager::PagePdf, the page PDF render.
$Lazysite::Manager::PagePdf::DOCROOT = $DOCROOT;
# SM944 S31: Manager::AuditTrail, the audit trail's views and switch.
$Lazysite::Manager::AuditTrail::DOCROOT      = $DOCROOT;
$Lazysite::Manager::AuditTrail::LAZYSITE_DIR = $LAZYSITE_DIR;
# SM944 S32: Manager::Users, the users and identity actions.
$Lazysite::Manager::Users::DOCROOT      = $DOCROOT;
$Lazysite::Manager::Users::LAZYSITE_DIR = $LAZYSITE_DIR;
my $LOCK_DIR     = "$LAZYSITE_DIR/manager/locks";
my $LOCK_TIMEOUT = 300;
$Lazysite::Manager::Files::LOCK_DIR     = $LOCK_DIR;
$Lazysite::Manager::Files::LOCK_TIMEOUT = $LOCK_TIMEOUT;

# SM019: unit-test hook. When set, `do "lazysite-manager-api.pl"` from a
# test returns after the lexicals are initialised but before the auth
# check, request parsing, and dispatch, so tests can exercise helper
# subs directly (parse_multipart_body, etc.)
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
# unless the wrapper vouched for them (LAZYSITE_AUTH_TRUSTED=1) or the sysop
# opted into a trusted reverse proxy (auth_proxy_trusted: true). A forged header
# is thus ignored - and logged - rather than granting sysop access.
{
    my $trusted = ( $ENV{LAZYSITE_AUTH_TRUSTED} // '' ) eq '1';
    my $proxy   = 'false';

    # SM917: the open is inside the !$trusted branch rather than joined to it by
    # &&, so the failure branch below belongs to the OPEN and not to the
    # short-circuit. Joined, an `else` would also fire when the wrapper had
    # already vouched for the caller and nothing had been read at all.
    #
    # This fails CLOSED either way - $proxy stays 'false' and the check below
    # refuses - so an unreadable conf costs nobody their session. What it used to
    # cost was the explanation: a sysop who set auth_proxy_trusted: true and whose
    # conf lost its permissions saw proxy auth simply not work, with nothing said.
    if ( !$trusted ) {
        if ( open my $fh, '<', "$LAZYSITE_DIR/lazysite.conf" ) {
            while ( my $l = <$fh> ) {
                if ( $l =~ /^auth_proxy_trusted\s*:\s*(\S+)/ ) { $proxy = lc $1; last }
            }
            close $fh;
        }
        else { Lazysite::Util::cannot_read( 'the site conf', "$LAZYSITE_DIR/lazysite.conf" ) }
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

# SM465: the rule before and after an acl-set, for the audit entry at the end
# of the dispatch. File scope rather than threaded through, because the audit
# block runs after the chain has finished and every action shares that one exit.
my ( $ACL_AUDIT_BEFORE, $ACL_AUDIT_AFTER );

# SM237: every action name the dispatch chain below recognises, whichever channel
# serves it. Needed because the token-client gate runs BEFORE dispatch and only
# knows %need (the token subset), so without this it cannot tell "exists, but
# cookie-only" from "no such action" - and reported both as the former.
#
# The dispatch is an if/elsif chain rather than a table, so there is no runtime
# set to consult. SM943: the set is the actions declared in
# Lazysite::ControlApi::Actions' %ACTION, which is where every per-action table
# in this file now comes from. t/lint/22-known-action-parity.t extracts the
# chain's action names and asserts the declaration matches exactly.
my %KNOWN_ACTION = Lazysite::ControlApi::Actions::known_actions();

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
    _emit_json(
        '405 Method Not Allowed',
        ['Allow: GET, POST'],
        { ok => JSON::PP::false,    # SM353
            error => 'The control API is not callable from a browser page. It '
                . 'serves agents, scripts and the manager, which hold '
                . 'sysop-issued credentials; a page cannot hold one safely. To '
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
#
# SM944 S21: THE REQUEST CONTEXT IS Lazysite::Manager::Common's, imported above
# in place of the file-scope `my` variables this file declared, so an area
# module reads the same facts. reset_request_context() leaves it fail-closed
# (nobody, a token client with no capability, confined to no path); this file
# then gives each fact the value its `my` declaration gave it, here and at the
# lines below where the others were declared ($action, $path, $body,
# $IS_OPERATOR), so the request runs as before. Only this file sets them
# (t/lint/217).
reset_request_context();
$token_auth       = 0;
%token_caps       = ();
$REQUEST_CONFINED = 0;     # SM648: were this caller's scopes RESOLVED?
@REQUEST_SCOPES   = ();    # SM158: the request's resolved dav_scopes (union), for
                           # per-domain content-access checks in actions like
                           # site-backup-create/apply. Empty => unconfined sysop.
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
                _bail( { ok => 0, error => 'Do not combine cookie and token auth' } );
            }
            # Service killswitch (0.9.0): the control-API token surface is OFF
            # unless the sysop enables it in lazysite.conf
            # (control_api_enabled: true), mirroring webdav_enabled. Checked as
            # soon as a token is presented - before verification - so a disabled
            # instance does no token processing at all. The cookie manager UI
            # reaches the same endpoint and is unaffected (it is gated by
            # `manager:`). Default off; opt in from the Services page.
            unless ( Lazysite::Util::service_enabled( $DOCROOT, 'control_api_enabled' ) ) {
                _bail( { ok => 0, code => 'service_disabled', kind => 'disabled',
                        error => 'The control API (token access) is not '
                            . 'enabled on this site. Ask the operator to enable it (Services -> Control API).' } );
            }
            # SM685: in-process; see Lazysite::Auth::Verify.
            # A deployment that NOMINATES a users tool (LAZYSITE_USERS_TOOL) has
            # nominated the authority on credentials - ask it. Otherwise verify in
            # process: SM685 takes the subprocess off the DEFAULT path, which is the
            # one every site runs. The choice is made HERE and never inside the module,
            # because the module is also loaded inside the tool - and a tool that
            # consults the variable naming itself spawns itself, without limit.
            my $v
                = $ENV{LAZYSITE_USERS_TOOL}
                ? users_api(
                { action => 'verify-credential', username => $u, secret => $secret } )
                : Lazysite::Auth::Verify::verify_credential( $DOCROOT, $u, $secret );
            # SM906 T3: the credential verified and the engine cannot tell what
            # it may do - a distinct answer, never "Invalid credentials" and
            # never an empty grant. No brute-force delay: the secret was right.
            _bail( Lazysite::Auth::Settings::cannot_tell_refusal( $v->{cannot_tell} ) )
                if $v && !$v->{ok} && $v->{cannot_tell};
            unless ( $v && $v->{ok} ) {
                sleep 1;    # brute-force delay (per-IP limiter lands in P3.6)
                _bail( { ok => 0, error => 'Invalid credentials' } );
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
    # granted manager access - and `local` is the sysop sentinel, so an
    # "unsecured" site was not "any authenticated user is a manager" (as
    # security.md claimed) but "no credential required, and you are the
    # sysop". Two ways to be there:
    #
    #   * a fresh install, before setup-sysop has run. The window had no lower
    #     bound on a manual install.
    #   * a site pushed BACK into it - a manage_users delegate stripping ui /
    #     manage_users / manager from every group, which the lockout guard in
    #     cmd_group_settings_set did not prevent because it only ever covered the
    #     `manager` flag.
    #
    # The intended first-run flow is the CLI: `lazysite-users.pl setup-sysop`
    # creates the first sysop account and hands over the credential. Until it
    # has run there is no account to log in as, so refusing is not a loss of
    # function - it is the accurate answer. `local` remains the CLI's identity
    # and is unaffected; it never arrives over HTTP.
    unless ( length $auth_user ) {
        _bail(
            { ok => 0,
                error => $site_secured
                ? 'Authentication required'
                # SM872: this named `setup-manager`, deleted by SM659 with no
                # alias - so the one message a fresh install shows told the
                # operator to run a command that exits 2. SM865 stopped the
                # installer seeding an account, which makes this the FIRST thing
                # a new operator reads.
                : 'This site has no manager account yet. Create one from the '
                    . 'command line with: lazysite-users.pl --docroot <docroot> '
                    . 'setup-sysop --user <name>'
            }
        );
    }
}

# --- Parse request ---

for my $pair ( split /&/, $ENV{QUERY_STRING} // '' ) {
    my ( $k, $v ) = split /=/, $pair, 2;
    next unless defined $k;
    $k =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    $v //= '';
    $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    $v =~ s/\+/ /g;
    $params{$k} = $v;
}

$action = $params{action} // '';

# SM817: `extension-*` IS THE NAME. `plugin-*` IS THE OLD ONE, KEPT AND
# DEPRECATED THE DAY THE NEW ONE SHIPS.
#
# These fourteen things are not plugged in by anybody: they ship in the package,
# the engine declares their capabilities, and the operator's act is switching one
# off, not installing one. `plugin` says came-from-outside, somebody-added-it,
# host-didn't-know - none of which is true. What IS true is that the core
# renderer requires nothing from them (lazysite-processor.pl loads no plugin at
# all), so they extend it, and `extension` says that.
#
# It also keeps `plugin` free for the day something genuinely is authored
# elsewhere and dropped in - SM823's ingestion sources would be the first - which
# is the only condition under which the old word would have been right.
#
# NORMALISED HERE, in the one place the action is read, rather than by declaring
# every verb twice. A second declaration is a second thing to keep in step, and
# this codebase has a filing for every time that was tried: the two spellings
# cannot drift because only one of them exists below this line.
#
# The seven: list, read, save, action, config, enable, disable.
my $action_as_sent = $action;
if ( $action =~ s/\Aextension-/plugin-/ ) {

    # The new spelling. Nothing to say about it.
}
elsif ( $action =~ /\Aplugin-/ ) {

    # The old one. INFO rather than WARN: it still works, it is correct today,
    # and a WARN on every call would train an operator to ignore the log before
    # the removal it is warning about ever arrives.
    log_event( 'INFO', $auth_user // '-',
        "action '$action_as_sent' is the deprecated spelling; "
            . "use '" . ( $action_as_sent =~ s/\Aplugin-/extension-/r ) . "'",
        action => $action_as_sent );
}

# SM831: THE SPELLING AS SENT HAS TO REACH THE PLACES THAT ANSWER FOR IT.
#
# The field measured this on 0.13.11: four paired calls - plugin-action,
# extension-action, plugin-save, extension-save - and all four audited as
# `plugin-*`. The string "extension" appeared nowhere in 10,772 bytes of audit
# across fifty entries.
#
# That defeats what the deprecation is FOR. You deprecate a spelling in order to
# retire it, the question at retirement is "is anyone still calling the old
# one", and the audit log is where an operator looks for the answer. Normalising
# at one point is right and stays; throwing the original away before anything
# recorded it was the mistake.
#
# A FLAG RATHER THAN A SECOND ACTION NAME. Recording `extension-save` in the
# action field would split one act across two spellings for everything that
# counts or filters audit lines - including readers already deployed, which
# would silently stop matching. The canonical name stays; one boolean answers
# the retirement question.
my $deprecated_spelling = ( $action_as_sent =~ /\Aplugin-/ ) ? 1 : 0;

sub _audit_detail {
    my ($detail) = @_;
    return $detail               unless $deprecated_spelling;
    $detail = ''                 unless defined $detail;
    return 'spelling=deprecated' unless length $detail;
    return "$detail; spelling=deprecated";
}

$path = $params{path} // '/';
# Mirror the per-request context into the modules that keep their own copy, for
# log attribution. SM944 S21: Manager::Common's $action and $auth_user ARE this
# file's now (imported), so the two lines that copied them here are gone; each
# module below loses its copy at its own row and imports from Common instead.
$Lazysite::Manager::Upload::auth_user   = $auth_user;
$Lazysite::Manager::Backups::auth_user  = $auth_user;
$Lazysite::Manager::Plugins::action     = $action;
$Lazysite::Manager::Files::auth_user    = $auth_user;
$Lazysite::Manager::Files::action       = $action;
$Lazysite::Manager::Themes::auth_user   = $auth_user;
$Lazysite::Manager::Data::auth_user     = $auth_user;    # SM468: schema-history actor
$Lazysite::Manager::Nav::auth_user      = $auth_user;
$Lazysite::Manager::Themes::action      = $action;
$Lazysite::Manager::Layouts::auth_user  = $auth_user;
$Lazysite::Manager::Layouts::action     = $action;
$Lazysite::Manager::Sessions::auth_user = $auth_user;    # SM141
$Lazysite::Manager::Domains::auth_user  = $auth_user;    # SM154
$Lazysite::Auth::Acl::auth_user         = $auth_user;
$Lazysite::Auth::Acl::token_auth        = $token_auth;
# SM464: the token's own grant, so may_read_any_rule can key the audit-read
# override on what the sysop explicitly granted THIS token.
%Lazysite::Auth::Acl::token_caps = %token_caps;
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

# SM906 T3: THE COOKIE DOOR ASKS THE SAME QUESTION. The token door's answer comes
# from verify_credential; a cookie session was verified by the auth wrapper, so
# it is asked here, once, before any gate reads a capability. Measured before:
# a gated action refused "requires the 'X' permission. An administrator can
# grant it" about an operator whose grant was intact, and whoami reported 0
# held. Every request from the session gets the answer, ungated ones included:
# an action that reaches no capability gate still runs on whatever the
# account's record says, and that is what cannot be read.
unless ($token_auth) {
    if ( my $store = Lazysite::Auth::Settings::auth_cannot_tell() ) {
        _refuse( Lazysite::Auth::Settings::cannot_tell_refusal($store),
            'ui', "refused: cannot tell - $store unreadable" );
    }
}

# SEC-2026-07 (M2) / SM154 (P1): the content path-bearing actions whose target a
# dav_scope binding confines (WebDAV enforces the same). Non-content actions
# carry no path (or $path defaults to '/'); the lazysite/ theme-authoring
# namespace is outside scope's remit (governed by manage_themes/manage_layouts).
# SM943: declared as `scoped => 1` on the action in Lazysite::ControlApi::Actions.
my %SCOPED_ACTION = Lazysite::ControlApi::Actions::scoped_actions();

# SM1052 (P-7): acl-set's list of paths, when it is given one (below), and the
# most one request may name - the handler's own limit.
my @ACL_PATHS;
my $ACL_PATHS_MAX = $Lazysite::Manager::Files::ACL_PATHS_MAX;


# SM1103: A PATH THE ACTION DOES NOT READ, OR NONE, IS REFUSED BY NAME.
#
# The 0.15.6/0.15.7 edge walk reported every manager save failing with
# "Cannot write file: Permission denied", and asked for root to inspect the
# host. The tester's correction (2026-10-16): "My harness sent `path` in the
# body; `save` reads it from the query." The save had no path, $path fell
# back to '/', the docroot was the write target, and write_file_checked
# tried to create `<docroot>.<pid>.tmp` in the docroot's PARENT - EACCES on
# that host, a stray file on one where the parent is writable. The audit
# target "/" was the only clue.
#
# Two refusals, after the channel's gates (an account the door refuses
# learns nothing about parameters) and before the scope check reads the
# path:
#
#  - an action that declares path `in => 'query'` and finds it only in the
#    JSON body. For `path` across every action, because no handler of a
#    query-declared path reads the body's (the SM1047 query_or_body hoist is
#    the one reader, for the actions that declare it). Not for every
#    query-declared parameter: some handlers do fall back to the body (host,
#    in places), and refusing those would break a client that works.
#  - a content write (content_write) with no path, or an empty one. Absent
#    meant '/', and '/' is the site root: never what a write meant by
#    sending nothing. An explicit '/' still reaches the handler, where an
#    upload into the root folder means it.
#    file-upload is left out: its path is the FOLDER the files go into, and an
#    empty one is the root, which clients use (t/integration/120) - nothing
#    resolves to the docroot as a FILE there.
sub _refuse_unread_or_missing_path {
    my ($origin) = @_;
    my $spec     = $Lazysite::ControlApi::Actions::ACTION{$action} || {};
    my $qpath = grep { ( $_->{name} // '' ) eq 'path' && ( $_->{in} // '' ) eq 'query' }
        @{ $spec->{params} || [] };
    return unless $qpath;
    my $jb;
    $jb = _json_body() unless $action eq 'file-upload';    # multipart, never JSON
    if ( !length( $params{path} // '' ) && ref $jb eq 'HASH' && exists $jb->{path} ) {
        # SM1121: an EMPTY query path beside a body path is the same mistake as an
        # absent one (a client that builds `?path=` from a field it left blank).
        my $bp = ( defined $jb->{path} && !ref $jb->{path} ) ? $jb->{path} : '';
        _refuse( { ok => 0, kind => 'missing-parameter', field => 'path',
                error => "path was sent in the body; $action reads it from the query string"
                    . ( length $bp ? " (?action=$action&path=$bp, not '$bp' in the JSON body)" : '' )
                    . '. Nothing was changed.' },
            $origin, 'missing-parameter: path sent in the body, read from the query', $bp );
    }
    if ( $spec->{content_write} && $action ne 'file-upload' && !length( $params{path} // '' ) ) {
        _refuse( { ok => 0, kind => 'missing-parameter', field => 'path',
                error => "path is required (in the query). $action names the file or folder "
                    . 'it writes by a docroot-relative path, such as ?path=/about.md. Nothing was changed.' },
            $origin, 'missing-parameter: path missing - path is required (in the query)', '' );
    }
    return;
}

# Confine this request to a SET of content-root scopes, refusing any content
# path outside EVERY scope. SM155: the binding moved to groups, so the set is the
# UNION of the user's scoped groups (already resolved into the settings'
# `dav_scopes` by effective_settings). Shared by the token/partner (M2) and
# cookie (SM154) channels; $origin tags the audit entry ('api' | 'ui'). An empty
# set confines nothing (an unbound account).
sub _confine_scope {
    my ( $scopes, $origin ) = @_;
    return unless $SCOPED_ACTION{$action} && ref $scopes eq 'ARRAY' && @$scopes;
    for my $p ( grep { defined && length } ( $path, $params{to}, $params{from}, @ACL_PATHS ) ) {
        next if $p =~ m{^/?lazysite/};
        next
            unless Lazysite::Manager::Common::outside_all_scopes( $scopes, $p );
        my $names = join ', ',
            map { ( my $s = $_ ) =~ s{^/+|/+$}{}g; "$s/" } @$scopes;
        _refuse(
            { ok => 0, kind => 'forbidden',
                error => "Path '$p' is outside your assigned scope ($names)." },
            $origin, 'denied: outside dav_scope', $p );
    }
}

$body = '';
if ( ( $ENV{REQUEST_METHOD} // '' ) eq 'POST' ) {
    my $len = $ENV{CONTENT_LENGTH} // 0;

    # SM019: size gate for file-upload. Runs before the body read so an
    # oversize request is rejected without allocating the body. It writes
    # nothing. Other POST actions carry small JSON bodies and fall through to
    # the normal read. The rate check is NOT here: see upload-budget at the
    # file-upload dispatch branch.
    if ( ( $params{action} // '' ) eq 'file-upload' ) {
        my $max = upload_limits()->{max_bytes};
        if ( $len > $max ) {
            log_event( 'WARN', 'file-upload', 'upload too large',
                size => $len, max => $max, user => $auth_user );
            _bail( { ok => 0, kind => 'too-large',
                    error => "Upload exceeds limit of "
                        . int( $max / 1024 / 1024 ) . " MB" } );
        }
    }

    read( STDIN, $body, $len ) if $len > 0;
}
$IS_OPERATOR = undef;    # SM516 MO-3: the memo behind _operator(), empty until asked

# --- M-1: CSRF gate on write actions --------------------------------
# The gate is keyed on HTTP method, not action name. Every write action
# in this script is dispatched via POST; reads (list, cache-list,
# theme-list, plugin-list, nav-read, handler-list, form-targets-read,
# csrf-token itself, etc.) come in over GET and do not need a token.
# Going by method rather than an action allowlist means we cannot
# accidentally leave a new read action out of the list.
my $method = $ENV{REQUEST_METHOD} // 'GET';
# csrf-audit (ruled 2026-10-11, "Audit refusals"): A CSRF REFUSAL IS AUDITED, as
# a denied request, the way every later gate's refusal is - one row naming the
# account and the action. It ended through _bail, which records nothing, so a
# cross-site write tried against a signed-in manager left no trace at the
# default log level. The token is never recorded: _refuse writes the account,
# the action, the path, the address and the reason, nothing the request carried.
if ( my $refusal = csrf_refusal($method) ) { _refuse( $refusal, 'ui', 'denied: csrf' ) } # SM944 S34: Manager::Csrf

# Per-action csrf-token read
if ( $action eq 'csrf-token' ) {
    respond( { ok => 1, token => generate_csrf_token($auth_user) } );
    exit 0;
}

# SM1047 (P-9): ONE PATH PER REQUEST, RESOLVED BEFORE ANYTHING ASKS ABOUT IT.
#
# An action that declares its path `query_or_body` (acl-set) published that the
# path may arrive in either place, and the scope check below reads $path - the
# query's, '/' when absent - while the handler read its own. A confined partner
# that sent the path in the body was told "Path '/' is outside your assigned
# scope" about a path it never sent; and two readers of one argument is the
# shape in which a check passes on one value and a write lands on another.
#
# So the body's path is taken HERE, once, into $params{path} and $path, which
# the scope check, the carve-out check, the handler and the audit all read. A
# request that sends both and they differ is refused, naming both: there is no
# reading of it under which one of them was not a mistake. A body path that is
# not one string is refused rather than stringified.
{
    my $spec = $Lazysite::ControlApi::Actions::ACTION{$action} || {};
    my $either = grep { ( $_->{name} // '' ) eq 'path' && ( $_->{in} // '' ) eq 'query_or_body' }
        @{ $spec->{params} || [] };
    my $req = $either ? _json_body() : undef;
    if ( ref $req eq 'HASH' && exists $req->{path} ) {
        my $bp     = $req->{path};
        my $origin = $token_auth ? 'api' : 'ui';
        if ( ref $bp || !defined $bp ) {
            _refuse( { ok => 0, kind => 'invalid', field => 'path',
                    error => "$action takes one path, as a string. Nothing was changed." },
                $origin, 'refused: path not a string' );
        }
        if ( exists $params{path} && $params{path} ne $bp ) {
            _refuse( { ok => 0, kind => 'conflict', field => 'path',
                    error => "$action was given two different paths, '$params{path}' in the "
                        . "query string and '$bp' in the body. Send one of them. Nothing was changed." },
                $origin, 'refused: two paths', "$params{path} | $bp" );
        }
        $params{path} = $bp;
        $path = $bp;
    }

    # SM1052 (P-7), ruled 2026-10-12 ("acl-set with a path list"): `paths`, a
    # LIST in the body, one rule for each. Every element is checked as the one
    # path is - the scope and carve-out checks below read @ACL_PATHS - and the
    # handler reads the same decoded body. A list beside a path is refused: one
    # request names its targets one way.
    my $many = grep { ( $_->{name} // '' ) eq 'paths' } @{ $spec->{params} || [] };
    my $lreq = $many ? _json_body() : undef;
    if ( ref $lreq eq 'HASH' && exists $lreq->{paths} ) {
        my $ps     = $lreq->{paths};
        my $origin = $token_auth ? 'api' : 'ui';
        _refuse( { ok => 0, kind => 'invalid', field => 'paths',
                error => "paths is a list of 1 to $ACL_PATHS_MAX paths, each a non-empty string. "
                    . 'Nothing was changed.' },
            $origin, 'refused: paths not a list of paths' )
            unless ref $ps eq 'ARRAY' && @$ps && @$ps <= $ACL_PATHS_MAX
            && !grep { ref $_ || !defined $_ || !length $_ } @$ps;
        _refuse( { ok => 0, kind => 'conflict', field => 'paths',
                error => "$action was given a path and a list of paths. Send one of them. "
                    . 'Nothing was changed.' },
            $origin, 'refused: path and paths' )
            if exists $params{path};
        @ACL_PATHS = @$ps;
        $path      = '';
    }
}

# SM475: A MUTATING ACTION IS POST-ONLY ON BOTH CHANNELS.
#
# This lived INSIDE the cookie branch below, so it never applied to a token
# client - and the field proved the consequence: an authenticated GET of
# data-migrate returned 200 and RAN, a no-op only because the schema happened
# to be current.
#
# CSRF is the cookie path's reason and is not the only one. A state-changing
# action reachable by GET is prefetchable, retried by any intermediary that
# believes GET is safe, and lands in logs and browser history as a URL somebody
# can paste. "It changes something" and "it is a GET" should not both be true,
# whoever is asking.
#
# SM943: declared as `mutates => 1` on the action in
# Lazysite::ControlApi::Actions, and derived here.
my %MUTATING = Lazysite::ControlApi::Actions::mutating();

# SM587: HOW AN ACTION IS CLASSIFIED. Read this before setting either flag on an
# action (SM943: `destructive` / `changes_access` in Lazysite::ControlApi::Actions),
# because the whole value of the two flags is that neither is ever
# assigned by an argument about consequences.
#
#   destructive     - DOES A COPY SURVIVE THE CALL? If the engine retains one,
#                     the action is not destructive however alarming it looks.
#                     data-table-drop mints a safety export, so it is not;
#                     data-safety-export-delete removes that export, so it is,
#                     and it is what makes an earlier drop permanent.
#   changes_access  - DOES THE CALL ALTER WHO MAY READ? If it moves the
#                     boundary between who can see a thing and who cannot, in
#                     EITHER direction, it is flagged.
#
# Both questions are answered by reading the code, which is why the sysop
# took Option A on 2026-08-25 rather than "can the world be put back as it
# was": under that reading publishing a page is destructive, and a flag true of
# most writes tells a caller nothing.
#
# The two axes disagree in exactly one place found so far, and that is the
# point of having two. `acl-remove` is reversible as an OBJECT - the rule can
# simply be re-set, so no copy is lost and it is NOT destructive - and
# irreversible as an EFFECT, because content that was exposed cannot be
# un-exposed. It carries changes_access, which is the honest description, and
# neither half of the fact is lost.
#
# A flag is a property of the ACTION, never of its arguments. `save` writing
# `draft: true` into front matter changes what a visitor sees, and is still not
# a changes_access action: the day that is flagged from an argument value is the
# day the classification stops being mechanical.

# SM572: the drop/delete/rebuild family - a mutating action whose effect is
# not undone by another call. actions-list and describe-capabilities publish
# it as `destructive: true` beside `mutating`, which is read from %MUTATING
# above, never restated. MCP spells the same fact by tool name in its
# %ANNOTATE (with the readOnly/openWorld hints the API has no use for);
# t/lint/23 keeps the two tables equal through its twin map.
# SM943: declared as `destructive => 1` on the action in
# Lazysite::ControlApi::Actions, with the reason an entry needs beside it.
my %DESTRUCTIVE = Lazysite::ControlApi::Actions::destructive();

# SM587: the second axis - the actions that move the read boundary. Published
# as `changes_access: true` beside `mutating` and `destructive`, from the same
# _action_effects sub, so a caller learns both facts in one answer. MCP spells
# it by tool name in the fourth slot of its %ANNOTATE and publishes it as
# `changesAccessHint`; t/lint/23's third twin check keeps the two equal.
#
# SM943: declared as `changes_access => 1` on the action in
# Lazysite::ControlApi::Actions. THE CARRIERS (acl-set, acl-remove, domain-set)
# each carry their reason there, and preview-grant carries SM649's note on why
# it and preview-clear are NOT flagged. acl-get and get_permissions READ the
# rule and move nothing, so they are not flagged.
my %CHANGES_ACCESS = Lazysite::ControlApi::Actions::changes_access();

if ( $MUTATING{$action} && $method ne 'POST' ) {
    _bail( { ok => 0, error => "This action must be sent as POST." } );
}

if ( !$token_auth ) {
    # SEC-2026-07 (H1/H2): cookie/manager path authorization. The %need map below
    # gates only TOKEN clients; a cookie session historically reached every action
    # ungated ("manager UI = trusted operator"), so a low-privilege interactive
    # account (content-editors) could config-set, run backups, enable plugins, etc.
    # Now the cookie path is capability-gated by the same model, and a state-changing
    # action must be POST (a GET would bypass the CSRF gate above - and be CSRF-able
    # from an admin's browser). Operators (SM991: a member of the operator group,
    # `local`, or the unsecured/dev fallback where no group grants manager - NOT
    # a holder of manage_users) bypass the CAPABILITY gate, matching
    # the rest of the manager. The users/sessions/keys/audit/notices actions keep
    # their own bespoke gates in dispatch (they carry actor confinement / forbidden
    # messaging), so they are not listed here.
    #
    # Content-mutation actions (save/delete/mkdir/move/copy/file-upload/
    # migrate-to-local, and the edit locks) carry no `cookie_cap`: SM1057
    # (ruled 2026-10-12, "Require manage_content") gates them below on
    # manage_content for a content path, and the file's rule still decides on
    # top. acl-get/set/remove authorise by ownership. They are absent from the
    # token %need map (token clients write over WebDAV). Content-history
    # reads/restore are gated (they mirror the token %need manage_content).
    #
    # SM943: each entry is `cookie_cap` on the action in
    # Lazysite::ControlApi::Actions, with the reason that stood beside it here.
    my %COOKIE_CAP = Lazysite::ControlApi::Actions::cookie_caps();
    # Mutating actions are cookie-manager-only; a token client gets "not available".
    # SM214: form-submission-delete is in this set DELIBERATELY - deleting a stored
    # submission is a destructive PII operation, so it stays interactive-only. A
    # token client discovers forms (form-list) and reads submissions (form-submissions),
    # but a human confirms deletions in the manager.
    # NB: 'users' is deliberately NOT listed - it is dual-mode (GET reads
    # list/groups; writes self-enforce POST inside action_users). session/user/
    # key revocation are pure writes, so forcing POST here (SEC-2026-07, CSRF
    # completeness) makes the method-keyed CSRF gate above cover them by
    # construction, rather than relying on their target param arriving in the
    # POST body.

    # SM958: actions that decide for themselves on this channel, and why.
    # SM943: `cookie_gates_itself` on the action in Lazysite::ControlApi::Actions.
    my %COOKIE_GATES_ITSELF = Lazysite::ControlApi::Actions::cookie_gates_itself();
    # SM1057: the content writes, which need manage_content on this channel.
    my %CONTENT_WRITE = Lazysite::ControlApi::Actions::content_writes();
    # SM1043: the caller-only actions, which the `ui` gate below lets through.
    my %SELF_ACTION = Lazysite::ControlApi::Actions::self_actions();
    if ( !_operator() ) {
        my $caps = _user_caps($auth_user);

        # SM1057: THE COOKIE DOOR IS THE MANAGER'S, AND THE MANAGER IS THE `ui`
        # CAPABILITY. The /manager/ pages ask for it (the processor's
        # _is_manager); this door asked only that the session carried a user. So
        # an account in no group - a member login, holding nothing - sent `save`
        # and wrote any path no rule governs, because the content actions below
        # self-authorise against the file's rule and an unruled path is open to
        # every writer. Measured on sites.lazysite.io (0.15.4): a domain's member
        # wrote /search.md and a new post into the primary's tree. The token door
        # has had its channel gate since SM126 (`api`); this is the same gate for
        # this channel, asked from the account store first and the session's
        # groups second, as _is_operator asks. The operator (SM991: a member of the
        # operator group, `local`, or every account on an unsecured site - NOT a
        # holder of manage_users) never reaches here; a manage_users holder needs
        # `ui` like any other manager.
        #
        # SM1043: EXCEPT AN ACTION DECLARED `self` - the member's own account
        # (me, me-password, ...), which acts on the signed-in caller and nobody
        # else, needs no capability and grants none. A member with no `ui` is who
        # /account is for. The set is the declaration's (Actions::self_actions,
        # whose load-time checks and t/lint/246 keep it to caller-only actions),
        # never a list kept here. csrf-token is answered above this gate.
        unless (
            $SELF_ACTION{$action}
            || $caps->{manager_ui}
            || Lazysite::Auth::Settings::groups_grant_cap( 'ui', grep { length } split /[,\s]+/,
                ( $ENV{HTTP_X_REMOTE_GROUPS} // '' ) ) )
        {
            _refuse(
                { ok => 0, kind => 'forbidden',
                    error => "This account does not have manager access (the 'ui' permission), "
                        . 'so the manager API does nothing for it. An administrator can grant '
                        . 'it on the Groups page.' },
                'ui', 'denied: manager channel capability' );
        }

        # SM1057, ruled 2026-10-12 "Require manage_content": A CONTENT WRITE NEEDS
        # manage_content HERE, AS IT DOES OVER WebDAV AND MCP. These actions carry
        # no capability of their own on this channel - they self-authorised against
        # the file's rule, which admits every writer to a path no rule governs - so
        # an account holding `ui` alone overwrote any unruled page. The rule still
        # applies on top (the action asks it). The engine's own tree keeps the
        # capabilities that govern it - nav.conf's manage_nav, the layouts' - as
        # WebDAV's content namespace does; a `ui`-only account is read-only.
        my $holds_content = sub {
            return $caps->{manage_content}
                || Lazysite::Auth::Settings::groups_grant_cap( 'manage_content', grep { length } split /[,\s]+/,
                ( $ENV{HTTP_X_REMOTE_GROUPS} // '' ) );
        };
        if ( $CONTENT_WRITE{$action} ) {
            my @content = grep { defined && !m{\A/*lazysite(?:/|\z)} } ( $path, $params{to} );
            if ( @content && !$holds_content->() ) {
                _refuse(
                    { ok => 0, kind => 'forbidden',
                        error => "Writing site content requires the 'manage_content' permission. "
                            . 'An administrator can grant it on the Groups page.' },
                    'ui', 'denied: content write capability', $content[0] );
            }
        }

        # SM1057, the second ruling of 2026-10-12, "Require manage_content": AN
        # acl-set THAT CREATES THE FIRST RULE ON A CONTENT PATH NEEDS
        # manage_content, as the token and MCP doors already require. Creating a
        # first rule was authorised by write access to the file, which an unruled
        # path grants every writer - so a `ui`-only account claimed an unruled page,
        # or the whole site, with a write list naming itself. The ownership rule
        # for an EXISTING rule is unchanged (Files::action_acl_set asks it), and
        # the engine's tree is exempt as it is for the writes above. The key is
        # the one the action writes: the site-wide spellings are '/', otherwise
        # validate_path's rel, normalised.
        if ( $action eq 'acl-set'
            && defined $params{path}
            && length $params{path}
            && $params{path} !~ m{\A/*lazysite(?:/|\z)}
            && !$holds_content->() )
        {
            my $key = Lazysite::Manager::Files::acl_set_key( $params{path} );
            if ( defined $key && !exists load_acls()->{$key} ) {
                _refuse(
                    { ok => 0, kind => 'forbidden',
                        error => "Creating the first access rule on '$params{path}' requires the "
                            . "'manage_content' permission. An administrator can grant it on the "
                            . 'Groups page.' },
                    'ui', 'denied: content write capability', $params{path} );
            }
        }

        # Capability gate (H1): the escalation-sensitive actions need their cap.
        #
        # SM958: AND AN ACTION WITH A TOKEN GATE NEEDS THE SAME CAPABILITY HERE.
        # An action absent from %COOKIE_CAP had NO capability check on this channel,
        # so every token-gated action added without a %COOKIE_CAP line was open to
        # any manager account: form-uploads-save (0.15.0) and form-notify-save
        # (0.15.2) let a manager without manage_forms turn uploads on for a public
        # form. %COOKIE_CAP still wins where it says something different (its `+`
        # entries); otherwise the token gate applies, so a new action is gated on
        # both channels by its one %GATE line. %COOKIE_GATES_ITSELF is the short,
        # reasoned list of actions that decide for themselves.
        my $req_cap = $COOKIE_CAP{$action};
        if ( !defined $req_cap && !$COOKIE_GATES_ITSELF{$action} ) {
            my $g = $Lazysite::ControlApi::Actions::GATE{$action};
            $req_cap = join '|', @$g if ref $g eq 'ARRAY' && @$g;
        }
        if ($req_cap) {
            # `a|b` = EITHER will do. `a+b` = BOTH are required (SM660). A value
            # uses one or the other, never both: a mixed expression would need
            # precedence rules, and no action has yet wanted one.
            my $ok;
            if ( $req_cap =~ /\+/ ) {
                $ok = 1;
                $ok &&= $caps->{$_} for split /\+/, $req_cap;
            }
            else {
                $ok = 0;
                $ok ||= $caps->{$_} for split /\|/, $req_cap;
            }
            unless ($ok) {
                ( my $names = $req_cap ) =~ s/\|/ or /g;
                $names =~ s/\+/ and /g;
                _refuse(
                    { ok => 0, kind => 'forbidden',
                        error => "This action requires the '$names' permission. An "
                            . "administrator can grant it on the Groups page." },
                    'ui', 'denied: capability' );
            }
        }

        # SM154/SM155 (P1): a domain-bound cookie user (via their scoped
        # group(s)) is confined to the union of their content roots on the
        # interactive channel too, so a delegated domain editor cannot reach
        # another domain's content through the manager UI.
        _refuse_unread_or_missing_path('ui');    # SM1103
        _confine_scope( $caps->{dav_scopes}, 'ui' );
        @REQUEST_SCOPES = @{ $caps->{dav_scopes} || [] };
        # SM648: resolved, therefore CONFINED - even if the resolution is empty.
        # This block is inside !_operator(), so an operator never reaches it and
        # stays unconfined, which is the distinction the flag exists to carry.
        $REQUEST_CONFINED = 1;
    }
    else {
        # SM1121: the operator takes the same refusal. The call above sits in the
        # block an operator never enters, so on edge (0.15.9) the operator's save
        # with no query path was answered "'/' is a folder": the absent path had
        # become '/' and the handler, not this refusal, was the first to look. The
        # operator is also who writes by hand, so the one who most needs to be told
        # that path goes in the query.
        _refuse_unread_or_missing_path('ui');
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
        _refuse(
            { ok => 0, kind => 'forbidden',
                error => "This account can use the interactive manager UI, "
                    . "which is interactive-only: it cannot be driven over the API or MCP. "
                    . "Use a dedicated agent account (api/mcp capabilities, interactive login "
                    . "disabled) instead." },
            'api', 'denied: interactive manager account on the api channel' );
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
        _refuse(
            { ok => 0, kind => 'permission',
                error => "The 'api' capability is required to use the "
                    . "control API. Ask the operator to grant the api capability to your "
                    . "account's group." },
            'api', 'denied: api channel capability' );
    }

    # SM662: A GATE DECLARES THE CAPABILITIES IT NEEDS, rather than testing
    # them in code that nothing can read.
    #
    # An arrayref is ANY-OF: the gate opens if the caller holds at least one of
    # the named capabilities. 'ALWAYS' means the action needs no capability.
    #
    # WHY. The old entries were predicates - sub { $_[0]->{manage_data} } -
    # which are expressive and opaque: nothing can extract which capability an
    # entry tests without executing it. That is why ControlApi::Actions.pm and
    # the unlocks map are hand-kept COPIES of this fact, why SM687 needed nine
    # registration points to add one action, and why every one of the last five
    # was found by a failing gate rather than by reading the code.
    #
    # Declared, the capabilities are DATA, so the copies can be derived from
    # the one table that decides anything.
    #
    # ANY-OF IS THE ONLY COMBINATOR HERE, and that is deliberate rather than a
    # simplification: of the 81 entries, 63 name one capability, 15 name two,
    # and 3 need none. A gate needing ALL of several would have to add a form
    # here, in the open, rather than smuggle a predicate back in.
    # SM662 / A1: THE TABLE LIVES IN Lazysite::ControlApi::Actions NOW.
    #
    # It was declared here, inside this sub, which is why everything else that
    # needed to know what a gate requires - the published action reference, both
    # unlocks maps, the channel matrix - was a hand-kept COPY, and why six lint
    # suites read it by string-eval of this file's source. Same table, same three
    # states, one home: `%GATE` there, with every comment it had here.
    #
    # Proved identical across the move: 102 gated actions and 54 cookie-only,
    # captured before it moved and asserted by t/lint/98.
    my %need_caps = %{ Lazysite::ControlApi::Actions::need_caps() };

    # The predicates, rebuilt from the declaration, so every call site still
    # receives a coderef and nothing downstream of %need changed.
    #
    # That this decides exactly what the predicates decided is not asserted,
    # it is PROVED: tools/gate-fingerprint.pl runs every gate against a fixed
    # battery - no capabilities, all of them, and each one alone - and its
    # output is byte-identical before and after this change.
    my %need = map {
        my $d = $need_caps{$_};
        $_ => (
            ( !ref $d && $d eq 'ALWAYS' )
            ? sub { 1 }
            : do { my @c = @{$d}; sub { my $h = shift; scalar grep { $h->{$_} } @c } }
        );
    } keys %need_caps;
    # SM212: why a KNOWN action is withheld from token clients, where the answer
    # is a decision and not just "the manager UI owns this screen". Only the
    # actions whose absence would otherwise read as an oversight need an entry;
    # the rest fall back to the generic sentence.
    #
    # SM924 REMOVED TWO ENTRIES FROM HERE, and the removal is the point: the two
    # submission deletes are no longer cookie-only. They are gated on
    # `delete_submissions`, a capability of their own that no group holds by
    # default, so SM214's argument - a destructive act on personal data, often on
    # the only copy - now sets the DEFAULT rather than closing the door. A reason
    # left behind for an action that is reachable would be a sentence nothing can
    # print, which is how a file comes to describe a system it no longer has.
    # SM943: `cookie_only_reason` on the action in Lazysite::ControlApi::Actions.
    my %COOKIE_ONLY_REASON = Lazysite::ControlApi::Actions::cookie_only_reasons();

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
            respond( { ok => 0, kind => 'forbidden',
                    error => "Action not available to token clients: $action_as_sent. It "
                        . 'exists, but is served only to the manager UI over a cookie '
                        . 'session'
                        . ( $why ? " - $why" : '' ) . '. '
                        . 'Call actions-list to see what this account can call '
                        . 'over this channel.' } );
        }
        else {
            respond( { ok => 0, kind => 'not-found',
                    error => "Unrecognised action name: '$action_as_sent'. This is not an "
                        . 'action - check the spelling and the query string (a '
                        . 'doubled "action=" is the usual cause). Call '
                        . 'describe-capabilities for the actions this account can '
                        . 'use.' } );
        }
        exit 0;
    }
    unless ( $check->( \%token_caps ) ) {
        # Audit the denied attempt (was invisible before).
        # SM712: NAME THE CAPABILITY, not just the action. The refusal used to
        # say only which action was refused, so a caller had to fetch and read
        # the whole capability description to learn that `data-tables` wants
        # `manage_data`. The MCP twin has always said "(needs $need)"; this is
        # the same fact, held in the same scope, that one of two hand-kept
        # copies was not using. SM662 is the general form of that.
        #
        # ANY-OF, per the declaration %need is derived from a dozen lines above:
        # an arrayref means any ONE of these grants the action, which is why the
        # separator is "or" and not a comma.
        my $d     = $need_caps{$action};
        my $names = ref $d ? join( ' or ', @$d ) : '';
        _refuse(
            { ok => 0, kind => 'permission',
                error => "Insufficient capability for $action"
                    . ( length $names ? " (needs $names)" : '' )
                    . ". Call describe-capabilities to see what your account "
                    . "holds and what each capability unlocks."
            },
            'api', 'denied: capability' );
    }

    # SEC-2026-07 (M2) / SM155: enforce the group-derived scope union on the
    # control-API channel too - a scoped partner credential is confined to its
    # content subtree(s) over WebDAV and must be here as well.
    _refuse_unread_or_missing_path('api');    # SM1103
    _confine_scope( $token_caps{dav_scopes}, 'api' );
    @REQUEST_SCOPES = @{ $token_caps{dav_scopes} || [] };
    # SM648: a token client is always a confined principal - it holds a grant,
    # and an empty scope set means it reaches no domain rather than every one.
    $REQUEST_CONFINED = 1;

    # SM071 Phase 3 (P3.6): per-token volume throttle. 429 + Retry-After
    # so the client can back off per the documented retry contract.
    my $rl = _rate_ok($auth_user);
    unless ( $rl->{ok} ) {
        _emit_json( '429 Too Many Requests',
            ["Retry-After: $rl->{retry_after}"],
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
#
# SM943: the mode is `file_surface` on the action in Lazysite::ControlApi::Actions,
# with the SM418 and SM517 reasons beside the entries they explain.
{
    my %file_surface = Lazysite::ControlApi::Actions::file_surface();
    my $fs_mode = $file_surface{$action};
    if ( defined $fs_mode && $site_secured ) {
        my $caps = $token_auth ? \%token_caps : _user_caps($auth_user);
        # SM517: the zip parses `paths=` from the query string itself, so $path
        # is `/` here; gate every entry it will read. One governed path the
        # caller may not read refuses the WHOLE zip, naming the path and the
        # capability, as `read` of that path would - the zip's own skip-and-log
        # convention is silent to the caller and would hand back an archive
        # that quietly lacked the file.
        my @targets = ( $path, $params{to}, @ACL_PATHS );
        push @targets, collect_zip_paths() if $action eq 'file-zip-download';
        for my $p (@targets) {
            next unless defined $p && length $p;
            my $refusal = Lazysite::Manager::Common::carveout_refusal( $p, $fs_mode, $caps );
            next unless $refusal;
            _refuse( { ok => 0, error => $refusal },
                ( $token_auth ? 'api' : 'ui' ), 'denied: carve-out capability', $p );
        }
    }
}

# --- Audit tables ------------------------------------------------------------
#
# The last two tables the request meets, and the only ones that used to be
# declared BELOW the dispatch, inside the audit block itself. They are
# constants; hoisting them puts every table this file consults above the chain
# that consults it (lint/39's rule stated positively).
#
# %skip: the read-ish actions the audit trail deliberately does not record.
# SM943: derived from Lazysite::ControlApi::Actions - an action is audited
# exactly when it mutates unless its entry says `audited => 0|1`.
# t/unit/lib/16-audit-guarantee.t requires every dispatched action to be
# skipped here or on its expected-audited list, so an action added to the
# chain and to neither fails.
#
# SM447: the three data READS are skip-listed for the same reason as every other
# read here - they change nothing, and an audit trail of who looked at a table
# would bury the entries that record who CHANGED one. The three data WRITERS -
# data-migrate, data-row-save, data-row-delete - are deliberately absent, so they
# are audited by construction: a schema migration and a row edit are exactly what
# an operator asks the trail about. SM245: brief-read skips as a read;
# brief-append and briefs-migrate stay out for the same reason the data writers
# do. SM508: briefs-list skips as a read; brief-delete is audited - removing a
# record of intent is exactly what a trail should remember.
my %skip = Lazysite::ControlApi::Actions::unaudited();

# %uskip: the same decision one level down, for the sub-actions action=users
# carries in its POST body - the reads of the account store.
my %uskip = map { $_ => 1 } qw(
    list users-detail users-page groups group-settings-get permissions-grid capability-holders settings-get credential-status partner-caps
    verify-credential totp-code onboarding );

# SM593: the data surface confines itself by the caller's own grant, so it
# needs the resolved scopes - and they are resolved by AUTH, which runs after
# the block of package-variable assignments above. Set here, immediately before
# dispatch, where @REQUEST_SCOPES is final for this request. Empty stays empty:
# an unconfined grant is the sysop and the data surface behaves as it always
# did.
#
# SM976 R2 (ruled 2026-10-09, "Unbound cookie manager = unconfined"): the flag is
# the shared rule's own notion of confinement, request_domain_confined - always
# for a token, and for a cookie manager only when its scope binds a domain. A
# cookie manager whose groups bind no domain was confined to no table here while
# every other surface treated it as the whole-instance manager it is.
@Lazysite::Manager::Data::CALLER_SCOPES   = @REQUEST_SCOPES;
$Lazysite::Manager::Data::CALLER_CONFINED = Lazysite::Manager::Common::request_domain_confined();

# SM976 R1 (ruled 2026-10-09, "Confined = no instance-wide"): a domain-confined
# caller changes no instance-wide setting. The closed list is `instance_wide`
# in Lazysite::ControlApi::Actions; the refusal comes before dispatch, so no
# branch below has to remember it, and t/lint/218 holds every mutating action to
# the list. The operator, an unbound cookie manager and an unbound token (which
# reaches the primary, whose settings these are) are unaffected.
#
# SM976 F4 (ruled 2026-10-09, "Activate on its domain"): an instance-wide action
# that also takes a `host`, and was given one, is addressed to that domain
# instead (theme-activate, layout-activate) and answers to the domain rule in its
# branch - as MCP's twins do.
{
    my %instance_wide = Lazysite::ControlApi::Actions::instance_wide();
    my $addressed     = length( $params{host} // '' )
        && grep { ( $_->{name} // '' ) eq 'host' }
        @{ ( $Lazysite::ControlApi::Actions::ACTION{$action} || {} )->{params} || [] };
    if ( $instance_wide{$action} && !$addressed ) {
        if ( my $r = Lazysite::Manager::Common::instance_wide_refusal( action => $action ) ) {
            _refuse( $r, ( $token_auth ? 'api' : 'ui' ), 'denied: instance-wide' );
        }
    }
}

# --- SM773: A MISSING PARAMETER IS NAMED AS MISSING, BEFORE THE BRANCH RUNS.
#
# Four times in one campaign a parameter that was absent - or sent to the other
# channel - was answered as a BAD ONE: theme-copy complained about a name it
# had never received, connector-delete about the characters in an id it had not
# read, config-set about a key of '', and start-page-set answered ok:true and
# CLEARED the setting. Each was fixed where it was found, and the next one was
# always somewhere else.
#
# The declarations already say where every parameter is read from, so the
# sentence can be generated rather than written: name the parameter, say which
# channel carries it, and stop before the branch that would mis-describe it.
#
# ONLY where the action already refuses an absent value (`required => 1` in
# Lazysite::ControlApi::Actions, marked by reading the handler). Hoisting those
# changes the message and never the behaviour; a parameter nobody has
# established either way stays unmarked and reaches the branch as before.
sub _missing_required {
    my ($name) = @_;
    my $spec = $Lazysite::ControlApi::Actions::ACTION{$name} or return undef;
    # ABSENT IS NOT EMPTY. A parameter that was SENT and is empty is a value -
    # `{"value":""}` is how start-page-set clears a start page - and only the
    # action knows what its empty means. This check answers the one question
    # the action cannot ask: was it sent at all? So it tests PRESENCE, never
    # truth or length. (The release manager's rule, 2026-09-08: a boolean has
    # four states - true, false, neither, and no answer - and almost every one
    # of them needs all four accounted for.)
    for my $p ( @{ $spec->{params} || [] } ) {
        next unless $p->{required};
        my $in   = $p->{in} // 'body';
        my $body = _json_body() || {};
        my $sent
            = $in eq 'query' ? exists $params{ $p->{name} }
            : $in eq 'body'  ? exists $body->{ $p->{name} }
            :   ( exists $params{ $p->{name} } || exists $body->{ $p->{name} } );
        next if $sent;
        my $where
            = $in eq 'query' ? 'in the query string'
            : $in eq 'body'  ? 'in the JSON body'
            :                  'in the JSON body or the query string';
        $where .= "; $p->{note}" if defined $p->{note} && length $p->{note};
        return { ok => 0, kind => 'invalid', field => $p->{name},
            error => "$p->{name} is required ($where)" };
    }
    return undef;
}

# SM1119: the absence is a row on the trail, as the handler's own refusal of
# it was (SM943 ruling 1: a refusal or an error is audited, a read included).
# This answered with no row, so marking a parameter required took away the row
# the handler wrote - t/unit/manager/206 saw it for git-show.
if ( my $missing = _missing_required($action) ) {
    _refuse( $missing, ( $token_auth ? 'api' : 'ui' ),
        "missing-parameter: $missing->{field} is required", '' );
}

# --- Dispatch ---

# P24 (WORK-PLAN-0154, under SM943's rule that refusals and errors are
# audited): A HANDLER THAT CRASHES WRITES ONE FAILURE ROW. A die in a branch
# below left the process before the audit block, so the trail had no line for
# the request at all - an error, the one outcome SM943 says must be there.
# Armed here and disarmed after the chain; the END block writes the row only
# when the chain did not finish and the process is exiting on a failure. The
# row names the action (`user-<sub>` for action=users) and never the error's
# text, which can carry what the request carried - a secret, a path - and stays
# in the error log.
our $DISPATCH_CRASH_GUARD = 1;
END { _audit_crashed_dispatch() }

my $result;
if    ( $action eq 'list' ) { $result = action_list($path) }
elsif ( $action eq 'read' ) { $result = action_read( $path, $auth_user ) }
elsif ( $action eq 'save' ) {
    my $req = _json_body();
    $result = action_save( $path, $auth_user, $req->{content}, $req->{mtime} );
}
elsif ( $action eq 'delete' )  { $result = action_delete( $path, $auth_user ) }
elsif ( $action eq 'acl-get' ) { $result = action_acl_get( $path, $auth_user ) }
elsif ( $action eq 'acl-set' ) {
    ( $result, $ACL_AUDIT_BEFORE, $ACL_AUDIT_AFTER ) = dispatch_acl_set();
}
elsif ( $action eq 'acl-remove' ) { $result = action_acl_remove( $path, $auth_user ) }
elsif ( $action eq 'protected-sections' ) {
    # SM267: read-only, and scoped - a confined manager is shown only the
    # sections inside their own scope, so the list cannot be used to discover
    # that content exists elsewhere.
    $result = action_protected_sections( $auth_user, \@REQUEST_SCOPES, $params{path} );
}
elsif ( $action eq 'mkdir' ) { $result = action_mkdir( $path, $auth_user ) }
elsif ( $action eq 'move' )  { $result = action_move( $path, $params{to}, $auth_user ) }
elsif ( $action eq 'copy' )  { $result = action_copy( $path, $params{to}, $auth_user ) }
elsif ( $action eq 'migrate-to-local' ) { $result = action_migrate_to_local( $path, $auth_user ) }
elsif ( $action eq 'aliases-list' ) {
    # SM976: the map listed is one domain's - the host named, else the domain
    # whose folder `path` is in, else the primary - and a confined caller reads
    # its own domains' maps only.
    my $ah = $params{host} // '';
    my ($aroot) = length $ah ? () : Lazysite::Manager::Domains::content_root_for_path(
        ( $params{path} // '' ) =~ s{^/+}{}r );
    _refuse_unreachable_domain( undef,
        ( length $ah ? ( host => $ah ) : ( root => ( $aroot // '' ) ) ) );
    $result = action_aliases_list( $params{host}, $params{path} );
}
elsif ( $action eq 'git-status' ) { $result = action_git_status() }
elsif ( $action eq 'git-history' ) { $result = action_git_history( $path, $auth_user, $params{limit} ) }
elsif ( $action eq 'git-history-summary' ) {
    # SM419: the summary is scope-confined like every per-file history op.
    # It carries no path, so _confine_scope never sees it - the scopes have to
    # be handed over explicitly, as action_protected_sections already does.
    $result = action_git_history_summary( \@REQUEST_SCOPES, $auth_user );
}
elsif ( $action eq 'git-show' ) { $result = action_git_show( $path, $auth_user, $params{sha} ) }
elsif ( $action eq 'git-restore' ) { $result = action_git_restore( $path, $auth_user, $params{sha} ) }
elsif ( $action eq 'git-init' )   { $result = action_git_init($auth_user) }
# SM992: a lock is taken, renewed and released only by a caller who may write
# the file under its rule (Files::lock_refusal).
elsif ( $action eq 'lock' ) { $result = lock_refusal( $path, $auth_user ) // acquire_lock( $path, $auth_user ) }
elsif ( $action eq 'unlock' ) { $result = lock_refusal( $path, $auth_user ) // release_lock( $path, $auth_user ) }
elsif ( $action eq 'renew-lock' ) { $result = lock_refusal( $path, $auth_user ) // renew_lock( $path, $auth_user ) }
elsif ( $action eq 'preview' )    { $result = action_preview($path) }
elsif ( $action eq 'cache-list' ) { $result = action_cache_list() }
elsif ( $action eq 'cache-invalidate' ) {
    # SM976: a host's own cached copy is that domain's.
    _refuse_unreachable_domain( undef, host => $params{host} )
        if defined $params{host} && length $params{host};
    $result = action_cache_invalidate( $path, $params{host} );
}

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
    my $req = _json_body();

    # SM1046 (ruled 2026-10-12, "Allow, own group only"): A TOKEN MAY CREATE A
    # DOMAIN FOR ITS OWN GROUP. A manage_domains token with no scope reached no
    # domain (SM975), and the only way to give it one was a domain naming its
    # group - so the grant could not be used for the action it is named after.
    # It may now add a domain whose allowed_groups names groups its account is
    # in BY NAME; a group it is not in is refused, so it can hand a new domain
    # only to itself or a group it already shares. The root must be new content
    # (Domains::creation_root_refusal): after the write the account reaches that
    # one domain through the group, and no other. Nothing about the domains that
    # exist changes, and the operator can still remove or reassign it.
    #
    # RECONCILED WITH SM975/SM976. For an UNSCOPED token naming its own group,
    # the rule above is the creation rule: SM975's no-scope refusal and SM976's
    # root-in-scope check (which answers no for every root to a caller with no
    # scope) are not asked, because both would refuse the very creation the
    # ruling allows. A SCOPED token keeps SM976's check, and naming a group adds
    # the own-group and new-root checks to it. A token naming no group is
    # refused as before, and told it may name one.
    my @own                = _domain_add_own_groups( $req->{allowed_groups} );
    my $own_group_creation = ( @own && $token_auth && !@REQUEST_SCOPES ) ? 1 : 0;
    unless ($own_group_creation) {
        _refuse_unscoped_token(    # SM975, and SM1046's way through it
            ' To create a new domain without a scope, name one of your own groups in '
                . "the request's allowed_groups: the domain is then reached through that "
                . 'group. Your groups: ' . ( join( ', ', _caller_direct_groups() ) || 'none' ) . '.' );
        # SM976: a new domain's content must lie inside the caller's scope.
        _refuse_unreachable_domain( undef, root => ( $req->{content_root} // '' ) );
    }
    if (@own) {
        my $r = Lazysite::Manager::Domains::creation_root_refusal( $req->{content_root} );
        _refuse( $r, 'api', 'denied: own-group domain root', $req->{host} // '' ) if $r;
    }
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
        allowed_groups => join( q{, }, @own ),        # SM1046: own groups, checked above
        seed           => ( $req->{seed} ? 1 : 0 ),
    );
}
elsif ( $action eq 'domain-alias-add' ) {
    my $req = _json_body();
    # Each parameter read BY NAME: lint 58 extracts what an action publishes by
    # scanning this branch, so a map over a qw() list would hide them from the
    # table a caller finds the action in.
    _refuse_unscoped_token();    # SM975
        # SM976: an alias serves the canonical domain's content, so it is a
        # reach of that domain.
    _refuse_unreachable_domain( undef, host => $req->{alias_of} );
    $result = domain_add_alias(
        $req->{host},
        $req->{alias_of},
        site_url       => $req->{site_url},
        site_name      => $req->{site_name},
        theme          => $req->{theme},
        layout         => $req->{layout},
        nav_file       => $req->{nav_file},
        search_default => $req->{search_default},
        lang           => $req->{lang},
        lang_group     => $req->{lang_group},
    );
}
elsif ( $action eq 'domain-set' ) {
    my $req = _json_body();

    # SM647: writing a domain's ACCESS keys is a conferral and a reach.
    #
    # Measured on edge 0.11.3 by the site agent, both claims proved with a
    # credential holding manage_domains and NOT manage_users, scoped to one
    # content root: it rewrote allowed_groups on a domain OUTSIDE its scope, and
    # it named a group it had no authority over. SM195's ceiling governs group
    # conferral in the users tool and never reached this path - allowed_groups
    # was validated for SHAPE only.
    #
    # Release manager's decision, 2026-08-28: both halves close.
    #
    #   allowed_groups / locked_users  ->  manage_domains AND manage_users
    #   every key                      ->  the host must be within the caller's
    #                                      content scope, when it has one
    #
    # Other keys keep manage_domains alone: setting a theme or a nav file is not
    # a conferral, and widening this would break domain management for a grant
    # that never touches access.
    {
        my $caps       = $token_auth ? \%token_caps : _user_caps($auth_user);
        my %ACCESS_KEY = ( allowed_groups => 1, locked_users => 1 );
        my $key        = $req->{key} // '';

        if ( $ACCESS_KEY{$key} && !$caps->{manage_users} ) {
            _refuse(
                { ok => 0, kind => 'forbidden',
                    error => "Setting '$key' decides WHO may reach this "
                        . "domain's content, so it requires the 'Users & "
                        . "groups' permission as well as domain management. "
                        . 'An administrator can grant it on the Groups page.' },
                ( $token_auth ? 'api' : 'ui' ), 'denied: capability' );
        }

        # The reach: a domain's content_root is the thing a scope confines, and
        # this action is addressed by HOST, so _confine_scope (which inspects
        # paths) never saw it. An empty scope skips the check below for the
        # cookie session only; a token naming no scope is refused (SM975).
        _refuse_unscoped_token();
        # SM976: the reach is caller_may_reach_domain's. This skipped a domain
        # with no content root of its own, so a scoped caller set keys on a
        # domain serving the primary's content, and it never asked about the
        # NEW content_root, so a caller confined to one domain repointed it at
        # another's content and its own scope moved there with it.
        my $root = domain_content_root( $req->{host} );
        my $names = join ', ', map { ( my $x = $_ ) =~ s{^/+|/+$}{}g; "$x/" } @REQUEST_SCOPES;
        _refuse_unreachable_domain(
            ( defined $root && length $root
                ? "Domain '" . ( $req->{host} // '' ) . "' serves content from '$root', "
                    . "which is outside your assigned scope ($names)."
                : undef ),
            host => $req->{host} );
        _refuse_unreachable_domain( undef, root => ( $req->{value} // '' ) )
            if ( $req->{key} // '' ) eq 'content_root';
    }

    $result = domain_set( $req->{host}, $req->{key}, $req->{value} );
}
elsif ( $action eq 'domain-remove' ) {
    my $req = _json_body();
    _refuse_unscoped_token();    # SM975

    # SM976: and the domain removed must be one the caller reaches.
    _refuse_unreachable_domain( undef, host => $req->{host} );
    $result = domain_remove( $req->{host}, purge => ( $req->{purge} ? 1 : 0 ) );
}
elsif ( $action eq 'remap-list' ) { $result = _remap_list() }    # SM802
elsif ( $action eq 'remap-save' ) {
    my $req = _json_body();
    $result = _remap_save( { host => $req->{host}, rules => $req->{rules} } );
}
elsif ( $action eq 'audit-trail-set' ) {
    my $req = _json_body();
    $result = _audit_trail_set( { state => $req->{state}, reason => $req->{reason} } );
}
elsif ( $action eq 'domain-preview' ) {
    _refuse_unreachable_domain( undef, host => $params{host} );    # SM976
    $result = domain_preview( $params{host} );
}
elsif ( $action eq 'domain-check' ) {
    _refuse_unreachable_domain( undef, host => $params{host} );    # SM976
    $result = action_domain_check( $params{host} );
}
elsif ( $action eq 'brief-read' ) {

    # SM245: a brief is ABOUT a path; the dispatcher's '/' default would read
    # the site root's brief on an omitted argument, which is only ever a
    # caller's mistake. Same reasoning as acl-set's SM306 guard, and the
    # explicit check is what t/lint/52 requires of a paired action whose MCP
    # twin declares the argument required.
    # SM657: `type=row` addresses an object with no path, so the path
    # requirement applies only when no typed reference was given.
    my %typed = map { $_ => $params{$_} }
        grep { defined $params{$_} && length $params{$_} } qw(type table key);
    if ( !$typed{type} && !( defined $params{path} && length $params{path} ) ) {
        $result = { ok => 0,
            error => 'brief-read needs an explicit path - the content file '
                . 'the brief is about - or a typed reference '
                . '(type=row&table=NAME&key=KEY).' };
    }
    else {
        _briefs();
        _refuse_unreachable_brief( $path, %typed );    # SM976 F2
        $result = Lazysite::Manager::Briefs::action_brief_read( $path, %typed );
    }
}
elsif ( $action eq 'brief-append' ) {

    # SM245: as brief-read - an appended entry must name its file explicitly.
    _briefs();
    my $req   = _json_body();
    my %typed = map { $_ => ( $params{$_} // $req->{$_} ) }
        grep { length( $params{$_} // $req->{$_} // '' ) } qw(type table key);
    if ( !$typed{type} && !( defined $params{path} && length $params{path} ) ) {
        $result = { ok => 0,
            error => 'brief-append needs an explicit path - the content file '
                . 'the entry is about - or a typed reference '
                . '(type=row&table=NAME&key=KEY).' };
    }
    else {
        _refuse_unreachable_brief( $path, %typed );    # SM976 F2
        $result = Lazysite::Manager::Briefs::action_brief_append(
            $path, $req->{entry}, %typed );
    }
}
elsif ( $action eq 'briefs-migrate' ) {
    _briefs();
    $result = Lazysite::Manager::Briefs::action_briefs_migrate();
}
elsif ( $action eq 'briefs-list' ) {
    _briefs();
    $result = Lazysite::Manager::Briefs::dispatch_briefs_list();
}
elsif ( $action eq 'brief-delete' ) {

    # SM508: as brief-read - a delete must name its entry explicitly. The
    # dispatcher's '/' default deleting the site root's brief on an omitted
    # argument is exactly the acl-set/SM306 shape, and the explicit check is
    # what t/lint/52 requires of a paired action whose MCP twin declares the
    # argument required.
    # SM696: accept the parts that CREATED the entry, as brief-append does.
    my $dreq   = _json_body();
    my %dtyped = map { $_ => ( $params{$_} // $dreq->{$_} ) }
        grep { length( $params{$_} // $dreq->{$_} // '' ) } qw(type table key);

    if ( !( defined $params{path} && length $params{path} ) && !$dtyped{type} ) {
        $result = { ok => 0,
            error => 'brief-delete needs an explicit path - the store entry '
                . 'to remove, as briefs-list reports it - or the typed '
                . 'reference it was added with (type=row&table=NAME&key=KEY).' };
    }
    else {
        _briefs();
        # SM976 F2: the entry the delete removes - the path when one is given,
        # else the typed reference (Briefs::action_brief_delete's order).
        if ( defined $params{path} && length $params{path} ) { _refuse_unreachable_brief($path) }
        else { _refuse_unreachable_brief( undef, %dtyped ) }
        $result = Lazysite::Manager::Briefs::action_brief_delete(
            ( defined $params{path} && length $params{path} ) ? $path : undef,
            %dtyped );
    }
}
elsif ( $action eq 'data-tables' ) {
    $result = Lazysite::Manager::Data::action_data_tables();
}
elsif ( $action eq 'data-safety-exports' ) {
    $result = Lazysite::Manager::Data::action_data_safety_exports();
}
elsif ( $action eq 'data-safety-export-read' ) {
    if ( !( defined $params{file} && length $params{file} ) ) {
        $result = { ok => 0,
            error => 'data-safety-export-read needs an explicit file - '
                . 'the export name as data-safety-exports reports it.' };
    }
    else {
        $result = Lazysite::Manager::Data::action_data_safety_export_read( $params{file} );
    }
}
elsif ( $action eq 'data-safety-export-restore' ) {
    my $req  = _json_body();
    my $file = $req->{file} // $params{file};
    if ( !( defined $file && length $file ) ) {
        $result = { ok => 0,
            error => 'data-safety-export-restore needs an explicit file - '
                . 'the export name as data-safety-exports reports it.' };
    }
    else {
        $result = Lazysite::Manager::Data::action_data_safety_export_restore( $file,
            ( $req->{apply} // $params{apply} // '' ) ? 1 : 0 );
    }
}
elsif ( $action eq 'data-safety-export-delete' ) {

    # SM512: as brief-delete - the delete names its file explicitly (the
    # t/lint/52 shape for a paired action whose MCP twin requires it).
    my $req  = _json_body();
    my $file = $req->{file} // $params{file};
    if ( !( defined $file && length $file ) ) {
        $result = { ok => 0,
            error => 'data-safety-export-delete needs an explicit file - '
                . 'the export name as data-safety-exports reports it.' };
    }
    else {
        $result = Lazysite::Manager::Data::action_data_safety_export_delete($file);
    }
}
elsif ( $action eq 'data-table-drop' ) {
    # The same shape as data-rebuild, deliberately: table from either, and the
    # CONFIRMATION from the body. Both destructive actions should be called the
    # same way, and SM479 is what happens when two neighbouring arguments take
    # different routes and one is silently ignored.
    my $req = _json_body();

    # SM605: A CONFIRMATION SENT THE OTHER WAY IS TOLD SO.
    #
    # `table` is read from the body OR the query string and `confirm` from the
    # body alone, which is the asymmetry the comment above warns about - and
    # both failures answered identically, so a caller who sent a perfectly good
    # confirmation in the query string was told it did not match. The obvious
    # next move is to retype the table name, and it cannot work. Two calls were
    # lost to that in the field.
    #
    # The body-only rule stays: a destructive confirmation in a URL is easier to
    # send by accident and ends up in logs and shell history. What changes is
    # that the silence does.
    # Read from the RAW query string rather than %params, deliberately. This is
    # not the action taking a second source for its confirmation - it is
    # noticing one that went to the wrong place. Reading it from the params
    # hash would make t/lint/58 extract it as a second ACCEPTED source and
    # publish `confirm: query_or_body` in the action reference, telling every
    # agent the query string works - which is the defect SM607 was filed for.
    #
    # The extraction reads the branch TEXT, comments included, so naming that
    # hash in the ordinary code form here would be extracted as a read of it -
    # which is how this comment first broke the lint it is explaining.
    if ( !defined $req->{confirm}
        && ( $ENV{QUERY_STRING} // '' ) =~ /(?:\A|&)confirm=/ )
    {
        $result = { ok => 0, kind => 'invalid', field => 'confirm',
            error => 'the confirmation must be sent in the request body, not '
                . 'the query string - {"table":"...","confirm":"..."}' };
    }
    else {
        $result = Lazysite::Manager::Data::action_data_table_drop(
            $req->{table} // $params{table},
            $req->{confirm} );
    }
}
elsif ( $action eq 'data-import' ) {
    # The CSV arrives as a multipart upload, the part named `file`, exactly as
    # site-backup-upload takes its tarball. A JSON body would have to carry
    # the whole file as a string inside a string, which is how a 5MB
    # spreadsheet becomes a 7MB request that times out.
    #
    # THE RAW BODY GOES IN, AND THE DATA MODULE PARSES IT. An earlier version
    # parsed the multipart here and handed the CSV across, and t/lint/77
    # refused it: a module named in a data-* branch is one that answers for
    # the plugin, and must consult its enabled state. The parser cannot
    # sensibly do that - so the whole path, parse included, lives behind the
    # one _gate() in Manager::Data, which is what SM469 wants anyway.
    #
    # SM1052 (P-6): and a bulk load is a row write - writable_by decides, as it
    # does for a row save, and the table's owner may import past it.
    my $imp_caps = $token_auth ? \%token_caps : _user_caps($auth_user);
    $result = Lazysite::Manager::Data::import_write_refusal( $params{table}, $imp_caps, $auth_user )
        // Lazysite::Manager::Data::action_data_import( $params{table},
        $body, $ENV{CONTENT_TYPE} // '', ( $params{apply} // '' ) eq '1' );
}
elsif ( $action eq 'data-export' ) {
    # DM-2: STREAMED, not returned. The action hands back the bytes and the
    # headers they need; sending them as a JSON field would make the sysop
    # extract their own download from a response body.
    $result = Lazysite::Manager::Data::action_data_export( $params{table},
        $params{format} );
    # Q16b: on the one streamed path - audited below, nothing after the body.
    if ( $result->{ok} && defined $result->{streamed_body} ) {
        ( my $safe = $result->{filename} // 'table.json' ) =~ s/[\r\n";\\]//g;
        stream_bytes( $result->{streamed_body},
            $result->{content_type}, $safe );
        $result = { ok => 1, streamed => 1 };
    }
}
elsif ( $action eq 'data-table' ) {
    $result = Lazysite::Manager::Data::action_data_table( $params{table} );
}
elsif ( $action eq 'data-table-source' ) {
    $result = Lazysite::Manager::Data::action_data_table_source( $params{table} );
}
elsif ( $action eq 'data-migrate-plan' ) {
    $result = Lazysite::Manager::Data::action_data_migrate_plan( $params{table} );
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
elsif ( $action eq 'data-table-acl-get' ) {
    $result = Lazysite::Manager::Data::action_table_acl_get( $params{table}, $auth_user );
}
elsif ( $action eq 'data-table-acl-set' ) {
    my $req = _json_body();
    $result = Lazysite::Manager::Data::action_table_acl_set(
        $req->{table} // $params{table}, $auth_user,
        owner => $req->{owner}, read => $req->{read}, write => $req->{write} );
}
elsif ( $action eq 'data-table-acl-remove' ) {
    $result = Lazysite::Manager::Data::action_table_acl_remove( $params{table}, $auth_user );
}
elsif ( $action eq 'data-table-save' ) {
    # The descriptor arrives as YAML TEXT in the body, not as a structure. The
    # file on disk is YAML and a human may edit it, so text is what
    # round-trips: comments and ordering survive, and what the author wrote is
    # what is stored.
    my $req   = _json_body();
    my $table = $req->{table} // $params{table};

    # SM682 second half: CHANGING `writable_by` decides who may write this
    # table's rows, so it requires authority over groups as well as over data.
    #
    # SM647 answered the identical question for a domain's allowed_groups
    # earlier today: writing an access list needs manage_users in addition to
    # the capability that owns the object. Without this, an agent holding
    # manage_data can widen a group the operator already trusted with
    # write_data elsewhere - the residual escalation SM682 recorded.
    #
    # Only a CHANGE is gated. Saving a descriptor whose writable_by is
    # untouched - which is most saves, since the field is rarely edited - is
    # unaffected, so a data admin adding a column does not suddenly need
    # manage_users.
    {
        my $caps = $token_auth ? \%token_caps : _user_caps($auth_user);
        unless ( $caps->{manage_users} ) {
            my $before = Lazysite::Manager::Data::writable_by_of($table);
            my $after  = Lazysite::Manager::Data::writable_by_in( $req->{descriptor} );
            if ( defined $after && ( $before // '' ) ne $after ) {
                _refuse(
                    { ok => 0, kind => 'forbidden',
                        error => "Changing 'writable_by' decides WHO may write "
                            . "this table's rows, so it requires the 'Users & "
                            . "groups' permission as well as data management. "
                            . 'The rest of the descriptor can be saved without '
                            . 'it.' },
                    ( $token_auth ? 'api' : 'ui' ), 'denied: capability' );
            }
        }
    }

    $result = Lazysite::Manager::Data::action_data_table_save( $table,
        $req->{descriptor} );
}
elsif ( $action eq 'data-rebuild' ) {
    my $req = _json_body();
    $result = Lazysite::Manager::Data::action_data_rebuild(
        $req->{table} // $params{table},
        $req->{confirm_lost} );
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
    my $req = _json_body();
    my $row = $req->{row};
    my $tbl = $req->{table} // $params{table};

    # SM682 round 2: HONOUR `writable_by` HERE TOO.
    #
    # This path carried the capability gate (manage_data OR write_data) and
    # nothing else, while the allow-list lived only in lazysite-data.pl. The
    # edge agent measured a write_data-only partner token writing a table
    # naming a group it was not in, a table with an empty list, and a table
    # with no list - three cases that must refuse. On this surface write_data
    # was therefore an instance-wide table write, which is the grant it exists
    # to avoid.
    #
    # One shared decision (Manager::Data::row_write_refusal), asked by both
    # surfaces, rather than a second copy of a rule that must agree.
    my $save_caps = $token_auth ? \%token_caps : _user_caps($auth_user);
    my $refusal   = Lazysite::Manager::Data::row_write_refusal(
        $tbl,
        $save_caps,

        Lazysite::Manager::Data::groups_for($auth_user),
    );

    # SM857: and WHOSE row. row_write_refusal answers the table question from the
    # same caps; this answers the row one. A write_data grant that reached a
    # table it is named in could still amend every other account's rows in it.
    $result
        = $refusal ? $refusal
        : ref $row eq 'HASH'
        ? Lazysite::Manager::Data::action_data_row_save(
        $tbl, $req->{key} // $params{key}, $row,
        as => Lazysite::Manager::Data::row_authority( $save_caps, $auth_user ) )
        : { ok => 0, error => 'row must be a JSON object' };
}
elsif ( $action eq 'data-row-delete' ) {
    my $req = _json_body();

    # SM682 round 2: a delete is a row write. Same rule, same shared decision -
    # gating the save and not the delete would leave write_data able to empty a
    # table it may not add to.
    my $del_caps    = $token_auth ? \%token_caps : _user_caps($auth_user);
    my $del_refusal = Lazysite::Manager::Data::row_write_refusal(
        ( $req->{table} // $params{table} ),
        $del_caps,
        Lazysite::Manager::Data::groups_for($auth_user),
    );
    $result
        = $del_refusal
        ? $del_refusal
        : Lazysite::Manager::Data::action_data_row_delete(
        $req->{table} // $params{table},
        $req->{key}   // $params{key},
        as => Lazysite::Manager::Data::row_authority( $del_caps, $auth_user ) );
}
elsif ( $action eq 'lang-status' ) {
    $result = action_lang_status( $params{group} );
}
elsif ( $action eq 'site-backup-create' ) {
    my $req = _json_body();
    # DP-6: `data_tables` is a LIST the sysop names, not a boolean. The
    # data store is instance-wide, so "this domain's data" does not exist and a
    # flag would sweep another domain's tables into an artefact that travels
    # between organisations.
    $result = action_site_backup_create( $req->{host} // $params{host},
        $req->{data_tables} );
}
elsif ( $action eq 'site-backup-upload' ) {
    $result = action_site_backup_upload($body);
}
elsif ( $action eq 'site-backup-apply' ) {
    my $req = _json_body();
    $result = action_site_backup_apply($req);
}
elsif ( $action eq 'site-export-primary' ) {
    my $req = _json_body();
    $result = action_site_export_primary( $req->{data_tables} );
}
elsif ( $action eq 'site-backup-inspect' ) {
    $result = action_site_backup_inspect( $params{name}, $params{host} );
}
elsif ( $action eq 'site-backup-delete' ) {
    my $req = _json_body();
    $result = action_site_backup_delete( $req->{name} // $params{name} );
}
elsif ( $action eq 'site-backup-download' ) {
    my $req = _json_body();
    $result = action_site_backup_download( $req->{name} // $params{name} ); # Q16b: streamed
}
elsif ( $action eq 'config-set' ) {
    my $req = _json_body();
    $result = action_config_set(
        ( defined $req->{key}   ? $req->{key}   : $params{key} ),
        ( defined $req->{value} ? $req->{value} : $params{value} ) );
}
elsif ( $action eq 'bad-url-blocks' ) { $result = { ok => 1, blocks => list_blocks($DOCROOT) } }
elsif ( $action eq 'bad-url-block' ) {

    # SM704: block an address by hand. The same store, the same shape and the
    # same unblock as an automatic entry - a manual block that behaved
    # differently would be a second kind of block to reason about.
    my $ip = defined $params{ip} ? $params{ip} : ( eval { decode_json($body) } || {} )->{ip};
    if ( !defined $ip || !length $ip ) {
        $result = { ok => 0, error => 'an address is required' };
    }
    elsif ( $ip =~ /[^0-9a-fA-F:.]/ ) {
        $result = { ok => 0,
            error => "'$ip' is not an address. Block one address at a time; "
                . 'this is not a pattern or a range.' };
    }
    else {
        my $added = block( $DOCROOT, $ip, by => $auth_user );
        log_event( 'INFO', 'bad-url-block', 'IP blocked by hand',
            ip => $ip, user => $auth_user );
        $result = { ok => 1,
            added => ( $added ? JSON::PP::true : JSON::PP::false ) };
    }
}
elsif ( $action eq 'bad-url-unblock' ) {
    my $ip = defined $params{ip} ? $params{ip} : ( eval { decode_json($body) } || {} )->{ip};
    my $removed = ( defined $ip && length $ip ) ? unblock( $DOCROOT, $ip ) : 0;
    log_event( 'INFO', 'bad-url-unblock', 'IP unblocked', ip => ( $ip // '' ), user => $auth_user );
    $result = { ok => 1, removed => ( $removed ? JSON::PP::true : JSON::PP::false ) };
}
elsif ( $action eq 'theme-list' )      { $result = action_theme_list() }
elsif ( $action eq 'themes-list-all' ) {
    $result = dispatch_themes_list_all();
}

# SM920: ONE NAME FOR THE THING BEING ACTIVATED - `theme=` and `layout=`.
#
# SM261 added the specific spelling because `path` is the file-ish parameter
# everywhere else on this surface, so a caller building from the action reference
# sends `theme=` or `layout=`; it kept `path` as well, and the pair has been
# residue rather than a design ever since. It had a cost: `path` TOOK PRECEDENCE,
# so a caller sending both - which is the natural thing to do when a reference
# lists both - had the more specific one DROPPED IN SILENCE. A live site sent
# `path=odcc&theme=odcc-b`, was answered ok:true, and went on serving the old
# theme, because `path` named the directory and `theme` named the theme.
#
# RULED 2026-09-30, on the prior question rather than on any of the three shapes
# the filing offered: "why do we have the option of both?" There was no reason.
# `path` is retired here rather than deprecated, which is what SM903 did for
# theme-rename four days earlier and what SM261 itself did - and the channel
# ladder is the mitigation: this lands on edge with a beta and a stable gate in
# front of it.
#
# Our own Appearance page was a `path=` caller and changes with this.
elsif ( $action eq 'theme-activate' ) {
    # SM976 F4 (ruled 2026-10-09, "Activate on its domain"): with `host`, the theme
    # is bound to that one configured domain - MCP activate_theme's host form,
    # which the control API did not have - and the instance's theme is untouched.
    # The domain must be one the caller reaches (a token naming no scope reaches
    # none, SM975). No manage_domains: the theme capability acts on a domain the
    # caller already reaches, which is how a scoped manager's Appearance page
    # activates a theme for its own site.
    if ( length( $params{host} // '' ) ) {
        _refuse_unscoped_token();
        _refuse_unreachable_domain( undef, host => $params{host} );
        $result = _domain_presentation_set( $params{host}, theme => $params{theme} // '' );
    }
    else { $result = action_theme_activate( $params{theme} // '', \%params ) }
}
elsif ( $action eq 'layout-activate' ) {
    # SM976 F4: the same host form, and as MCP's activate_layout does it - the
    # layout, then the theme if one was named, so the domain is left servable.
    if ( length( $params{host} // '' ) ) {
        _refuse_unscoped_token();
        _refuse_unreachable_domain( undef, host => $params{host} );
        $result = _domain_presentation_set( $params{host}, layout => $params{layout} // '' );
        $result = _domain_presentation_set( $params{host}, theme => $params{theme} )
            if $result->{ok} && length( $params{theme} // '' );
    }
    else { $result = action_layout_activate( $params{layout} // '', \%params ) }
}
elsif ( $action eq 'theme-delete' ) {
    # SM262: a token client may remove a theme it created; a cookie session (a
    # human in the manager) keeps the unrestricted delete. SM976 R1: unless that
    # human is domain-confined - the theme library is the instance's, so a
    # confined manager removes only what it created, as a token does. (Any
    # theme the primary or a domain serves is refused to everyone, SM177.)
    #
    # SM944 S33, held branch (3) (approved 2026-10-11): a token client is
    # $token_auth, Manager::Common's request fact. It replaces
    # $RESTRICT_THEME_DELETE, a flag set to 1 at the end of the token branch's
    # gates, which runs only when $token_auth is set and exits on each refusal
    # before it: the two were equal at this point in every request
    # (tmp/sm944-n348-equiv.sh, .out).
    my $restrict = ( $token_auth
            || Lazysite::Manager::Common::caller_is_confined() ) ? 1 : 0;
    $result = action_theme_delete( $path,
        { restrict_to_creator => $restrict, user => $auth_user } );
}
elsif ( $action eq 'layout-delete' ) {
    # SM911 LD2: `layout=` TOO, because that is what the family takes.
    #
    # This read only `path`, which is the dispatcher's generic parameter and the
    # one spelling nobody would try for a layout name. A partner tried eight -
    # layout, name, layout_name, id, dir, slug and two body forms - and got
    # "Layout name required" to every one, while `layouts-available` and
    # `layout-activate` both take `layout=` and work. From a token client the
    # action looked unreachable, and the workaround was a WebDAV DELETE.
    #
    # `path` still works, so nothing that calls it today changes.
    $result = action_layout_delete( $params{layout} // $path );
}
elsif ( $action eq 'artifact-backups-delete' ) { $result = action_artifact_backups_delete($path) }
elsif ( $action eq 'theme-copy' ) {
    my $req = _json_body();
    $result = action_theme_copy( $path, $req->{new_name}, { layout => $req->{layout} } );
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
    my $req = _json_body();
    $result = action_layouts_repo_set( $req->{value} );
}
elsif ( $action eq 'users' )      { $result = action_users( $body, \%params ) }
elsif ( $action eq 'principals' ) { $result = action_principals() }
elsif ( $action eq 'accounts-import-stage' ) {
    # SM1053 (P-5): a partner prepares an import - accounts, emails, groups, no
    # password - for the operator to review and apply.
    my $req = _json_body();
    $result = Lazysite::Manager::AccountImport::stage(
        { accounts => $req->{accounts}, csv => $req->{csv} }, actor => $auth_user );
}
elsif ( $action eq 'accounts-import-remove' ) {
    # n571 (SM1053): the account that staged an import removes it, either door
    # as staging is; the operator removes any, from a cookie session.
    my $req = _json_body();
    $result = Lazysite::Manager::AccountImport::remove( $req->{id}, actor => $auth_user,
        operator => ( !$token_auth && _operator() ) ? 1 : 0 );
}
elsif ( $action eq 'accounts-import-list' ) {
    $result = _import_operator_refusal() // Lazysite::Manager::AccountImport::list_staged();
}
elsif ( $action eq 'accounts-import-plan' ) {
    $result = _import_operator_refusal() // Lazysite::Manager::AccountImport::plan( $params{id} );
}
elsif ( $action eq 'accounts-import-apply' ) {
    my $req = _json_body();
    $result = _import_operator_refusal() // Lazysite::Manager::AccountImport::apply(
        $req->{id}, $req->{confirm}, actor => $auth_user, operator => 1,
        # n570: mail the claim links only when the operator says so - true, 1 or
        # "true"; anything else, absent included, is off.
        mail => ( ( defined $req->{mail} && "$req->{mail}" =~ /\A(?:1|true)\z/ ) ? 1 : 0 ),
        # n572: the changes to existing accounts the operator ticked (none if absent).
        ( defined $req->{updates} ? ( updates => $req->{updates} ) : () ) );
}
elsif ( $action eq 'groups-list' ) {
    # SM1050 (P-2): the groups, for any manage_users holder; a domain-confined
    # caller is shown the ones relevant to its domains (Manager::Groups).
    $result = Lazysite::Manager::Groups::groups_list( _groups_who() );
}
elsif ( $action eq 'group-set' ) {
    # SM1050 (P-1, P-3): create a group and set what it may do, within the
    # delegation limit; never the operator flag.
    my $req = _json_body();
    $result = Lazysite::Manager::Groups::group_set( $req->{group}, $req->{caps}, _groups_who() );
}
elsif ( $action eq 'display-names' ) {
    my $req = _json_body() || {};
    $result = action_display_names( $req->{logins} // $params{logins} );
}
elsif ( $action eq 'rotate-auth-secret' ) { $result = action_rotate_auth_secret($auth_user) }
elsif ( $action eq 'sessions-list' || $action eq 'session-revoke' || $action eq 'user-revoke'
    || $action eq 'keys-list' || $action eq 'key-revoke' ) {
    $result = dispatch_sessions_keys();
}
elsif ( $action eq 'plugin-list' ) { $result = action_plugin_list() }
elsif ( $action eq 'plugin-enable' ) {
    my $req = _json_body();
    $result = action_plugin_enable( $req->{script} );
}
elsif ( $action eq 'plugin-disable' ) {
    my $req = _json_body();
    $result = action_plugin_disable( $req->{script} );
}
elsif ( $action eq 'plugin-read' ) {
    my $req = _json_body();
    $result = action_plugin_read( $params{plugin}, $req->{script} );
}
elsif ( $action eq 'plugin-save' ) {
    my $req = _json_body();
    $result = action_plugin_save( $params{plugin}, $req->{script}, $req->{values} // {} );
}
elsif ( $action eq 'page-pdf' ) {
    # SM732: THE RENDER, WIRED. SM706 built convert() and shipped it with no
    # caller: the composed-document refusal, the per-part ACL check and the
    # cache were all reachable only from a unit test. This is the route.
    #
    # NOT A PLUGIN ACTION. plugin-action accepts only a `choice` from a declared
    # list, deliberately - "nothing request-controlled ever reaches the command
    # line". A page path is arbitrary, so it cannot travel that way. Calling
    # convert() IN PROCESS keeps the same guarantee for a different reason: the
    # path is a Perl argument and never sees a shell at all.
    #
    # manage_content, per the plugin's own reasoning: converting a page is
    # reading it in another format, so it rides on the capability that already
    # governs reading content rather than inventing one.
    $result = action_page_pdf( $params{path} );
}
elsif ( $action eq 'plugin-action' ) {
    my $req = _json_body();
    $result = action_plugin_action( $params{plugin}, $req->{script}, $req->{action_id},
        $req->{params} );
}
elsif ( $action eq 'nav-read' ) { $result = action_nav_read( $params{host} ) }
elsif ( $action eq 'pages' )    { $result = action_pages() }
elsif ( $action eq 'notices' ) {
    # Operator notifications require the 'notifications' capability (granted via
    # a group; seeded on user-managers). Same cookie-side gate pattern as audit;
    # the bell UI hides itself when this returns forbidden.
    $result = _notices_gate() // Lazysite::Manager::Notices::action_notices($auth_user);
}
elsif ( $action eq 'notices-seen' ) {
    # SM938 D3: its own branch now, because it reads parameters `notices` does
    # not - `id` marks one notice, `dismiss=1` takes it out of the panel, and
    # neither means mark-all. Sharing a branch made the action reference
    # (t/lint/58) attribute both to both.
    $result = _notices_gate()
        // Lazysite::Manager::Notices::action_notices_seen( $auth_user,
        id => $params{id}, dismiss => $params{dismiss} );
}
elsif ( $action eq 'nav-save' ) {
    my $req = _json_body();
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
elsif ( $action eq 'handler-list' ) {
    # SM1010 R5: the grant decides which handler types are listed.
    $result = Lazysite::Handlers::action_handler_list( _handler_who() );
    # SM1051: a confined caller is shown the instance's handlers and its own
    # domains' - not another domain's.
    if ( ref $result eq 'HASH' && ref $result->{handlers} eq 'ARRAY' ) {
        $result->{handlers}
            = [ grep { Lazysite::Manager::Common::caller_may_use_handler($_) } @{ $result->{handlers} } ];
    }
}
# SM1072 (SM1010 R3): the notification outbox - queued, held and failed events,
# and with `id` who one resolves to. It shows recipients, so it is
# manage_notifications' (%GATE), and a confined caller sees only its own
# domains' rules (Manager::Common::handler_reach_refusal).
elsif ( $action eq 'notify-outbox-list' ) {
    require Lazysite::Outbox;
    $result = Lazysite::Outbox::outbox_list( docroot => $DOCROOT, rule => $params{rule}, id => $params{id},
        may_see => sub {
            !Lazysite::Manager::Common::handler_reach_refusal( old => ( $_[0] ? $_[0]{domain} // '' : '' ) );
        } );
}
# SM1107 (0.15.6 U8): retry now - make a waiting entry (by id) or a rule's waiting
# entries due, so a mail fix is testable without posting fresh events. The job
# still sends, under the cap and the held folds; this only ends the backoff. It
# acts on the outbox, so it is manage_notifications' (%GATE) and a confined
# caller reaches only its own domains' rules, as notify-outbox-list does.
elsif ( $action eq 'notify-outbox-retry' ) {
    my $req = _json_body();
    require Lazysite::Outbox;
    $result = Lazysite::Outbox::outbox_retry( docroot => $DOCROOT, rule => $req->{rule}, id => $req->{id},
        may_see => sub {
            !Lazysite::Manager::Common::handler_reach_refusal( old => ( $_[0] ? $_[0]{domain} // '' : '' ) );
        } );
}
elsif ( $action eq 'schedule-list' ) { $result = Lazysite::Handlers::action_schedule_list() }
elsif ( $action eq 'version' )       { $result = action_version() }
elsif ( $action eq 'analyse_visitors' ) {
    $result = action_analyse_visitors(
        window => $params{window}, day   => $params{day},
        month  => $params{month},  index => $params{index},
        trails => $params{trails},
        # P15: one domain's traffic, and the requests per domain
        host    => $params{host},
        by_host => ( ( $params{by_host} // q{} ) =~ /\A(?:1|true|yes)\z/i ? 1 : 0 ) );
}
elsif ( $action eq 'whoami' ) { $result = action_whoami( $auth_user, $params{plugins} ) }
elsif ( $action eq 'start-page' ) { $result = action_start_page( $params{username} ) }
# SM1043: the member's own account. Every branch acts on $auth_user and reads no
# account from the request; Lazysite::Manager::Account says why.
elsif ( $action eq 'me' )                     { $result = action_me() }
elsif ( $action eq 'me-password' )            { $result = dispatch_me_password() }
elsif ( $action eq 'me-sessions' )            { $result = action_me_sessions() }
elsif ( $action eq 'me-session-revoke' )      { $result = dispatch_me_session_revoke() }
elsif ( $action eq 'me-sign-out-everywhere' ) { $result = action_me_sign_out_everywhere() }
elsif ( $action eq 'me-notices' )      { $result = action_me_notices() }       # SM1034 1b
elsif ( $action eq 'me-notices-seen' ) { $result = dispatch_me_notices_seen() }
elsif ( $action eq 'me-2fa-enrol' )    { $result = dispatch_me_2fa_enrol() }   # SM1042
elsif ( $action eq 'me-2fa-confirm' )  { $result = dispatch_me_2fa_confirm() }
elsif ( $action eq 'me-2fa-disable' )  { $result = dispatch_me_2fa_disable() }
elsif ( $action eq 'me-recovery-codes' ) { $result = dispatch_me_recovery_codes() }
elsif ( $action eq 'start-page-set' ) {
    $result = dispatch_start_page_set();
}
elsif ( $action eq 'connector-list' ) { $result = _connectors()->can('action_connector_list')->() } # SM579
elsif ( $action eq 'connector-calls' ) {
    $result = _connectors()->can('action_connector_calls')->(
        connector => $params{connector}, state => $params{state}, limit => $params{limit} );
}
elsif ( $action eq 'odoo-status' ) { $result = _odoo()->can('action_odoo_status')->() } # SM747
elsif ( $action eq 'odoo-calls' ) {
    $result = _odoo()->can('action_odoo_calls')->( binding => $params{binding}, limit => $params{limit} );
}
elsif ( $action eq 'odoo-secret-set' ) {
    my $req = _json_body();
    $result = _odoo()->can('action_odoo_secret_set')
        ->( $req->{secret}, grant => $req->{grant}, login => $req->{login} );
}
elsif ( $action eq 'odoo-secret-clear' ) {
    my $req = _json_body();
    $result = _odoo()->can('action_odoo_secret_clear')->( grant => $req->{grant} );
}
# SM747 E: a bound operation, run by a signed-in caller. The binding gates it
# (its modes, callers and caps) inside Lazysite::Odoo, as a connector gates
# connector-call; this door runs as the connection user.
elsif ( $action eq 'odoo-bindings' ) { $result = _odoo()->can('action_odoo_bindings')->( _odoo_who() ) }
elsif ( $action eq 'odoo-run' ) {
    my $req = _json_body();
    $result = _odoo()->can('action_odoo_run')->( $req->{binding}, $req->{params}, _odoo_who() );
}
elsif ( $action eq 'odoo-confirm' ) {
    my $req = _json_body();
    $result = _odoo()->can('action_odoo_confirm')->( $req->{plan}, _odoo_who() );
}
elsif ( $action eq 'connector-save' ) {
    my $req = _json_body();
    $result = _connectors()->can('action_connector_save')->( $req->{id}, $req->{connector} );
}
elsif ( $action eq 'connector-secret-set' ) {
    my $req = _json_body();
    $result = _connectors()->can('action_connector_secret_set')->( $req->{id}, $req->{secret} );
}
elsif ( $action eq 'connector-delete' ) {
    my $req = _json_body();
    $result = _connectors()->can('action_connector_delete')->( $req->{id} );
}
elsif ( $action eq 'connector-call' ) {
    # mode 2: a logged-in caller. The connector decides whether this account
    # may cause the call - its callers groups, or manage_connectors - and how
    # often (Connectors::may_call). Never a file: fields only.
    my $req     = _json_body();
    my $caps    = Lazysite::Auth::Settings::caps_for($auth_user);
    my @groups  = Lazysite::Auth::Settings::effective_groups($auth_user);
    my $payload = ref $req->{payload} eq 'HASH' ? $req->{payload} : {};

    # SM579 phase 2: A ROW-SOURCED CALL SENDS A KEY, NOT A PAYLOAD.
    #
    # `row` names a row of the connector's own row_table; the connector's
    # row_map decides which columns leave, and the read answers the data
    # store's own rules under THIS account. So a page action says "send order
    # 41" and cannot say what order 41 contains - which is the difference
    # between a button and an open relay under the operator's credential.
    #
    # SM804: the key is PASSED THROUGH, not resolved here. Resolving it in the
    # caller put every row-source refusal outside call(), which is the only
    # place that writes the connector's record - so those outcomes were
    # invisible, and a crash was the most invisible of all.
    my $row = $req->{row};
    $result = _connectors()->can('call')->(
        $req->{id}, $payload,
        mode  => 'authenticated', caps => $caps, groups => \@groups,
        actor => $auth_user,
        ( defined $row && length $row
            ? ( row => $row, as => { user => $auth_user, groups => \@groups } )
            : ()
        ),
        trigger => ( defined $row && length $row ) ? 'row' : 'api'
    );
}
elsif ( $action eq 'describe-capabilities' ) { $result = action_describe_capabilities($auth_user) }
elsif ( $action eq 'actions-list' ) { $result = action_actions_list($auth_user) }  # SM350
elsif ( $action eq 'preview-public' ) {                                            # SM282
    $result = preview_public( $params{path} );
}
elsif ( $action eq 'audit' ) {
    $result = dispatch_audit();
}
elsif ( $action eq 'recent-changes' ) { $result = action_recent_changes( $params{window} ) }
elsif ( $action eq 'channel-services' ) { $result = action_channel_services() }
elsif ( $action eq 'handler-save' ) {
    # The body IS the handler: the four keys every handler carries, and its
    # type's own fields beside them (handler-list returns each type's), which
    # the handler contract checks - one it does not declare is refused by name.
    my $req = _json_body();
    $req    = {} unless ref $req eq 'HASH';
    # SM1051 (P-4): a domain-confined caller saves only a handler of its own
    # domains, and changes only one that already is.
    _refuse_unreachable_handler( $req->{id}, new => $req->{domain} );
    $result = Lazysite::Handlers::action_handler_save(
        { %$req, id => $req->{id}, type => $req->{type}, name => $req->{name}, enabled => $req->{enabled},
            domain => $req->{domain} },
        _handler_who() );
}
elsif ( $action eq 'handler-delete' ) {
    my $req = _json_body();
    _refuse_unreachable_handler( $req->{id} );    # SM1051
    $result = Lazysite::Handlers::action_handler_delete( $req->{id}, _handler_who() );
}
elsif ( $action eq 'schedule-save' ) {
    my $req = _json_body();
    $result = Lazysite::Handlers::action_schedule_save(
        { id => $req->{id}, handler => $req->{handler}, every => $req->{every},
            payload => $req->{payload}, enabled => $req->{enabled} },
        _handler_who() );
}
elsif ( $action eq 'schedule-delete' ) {
    my $req = _json_body();
    $result = Lazysite::Handlers::action_schedule_delete( $req->{id}, _handler_who() );
}
elsif ( $action eq 'form-targets-read' ) {
    _refuse_unreachable_form( $params{form} );    # SM976 F2
    $result = Lazysite::Handlers::action_form_targets_read( $params{form} );
}
elsif ( $action eq 'form-submissions' ) {
    # SM862: `form` as well as `file`. MCP's twin takes a form name and this did
    # not, so the reasonable call answered "Invalid submissions file" about a
    # parameter that had never been sent.
    #
    # SM1047 (P-9's class): THE FORM CHECKED IS THE STORE READ. The reach check
    # read `form` when it was sent and the handler reads `file` when it is sent,
    # so form=<a form of mine>&file=<another domain's store> passed the check on
    # the one and returned the other's submissions (tmp/probe-form-split.pl).
    # The check now asks about what the handler reads: the store when one is
    # named (action_form_submissions ignores `form` then), the form otherwise.
    my $sf_file = $params{file} // '';
    _refuse_unreachable_form( length $sf_file ? _form_of_store($sf_file) : $params{form} ); # SM976 F2
    _refuse_beyond_account_requests( $params{file}, $params{form} );                        # SM979
    $result = action_form_submissions( $params{file}, $params{form} );
}
elsif ( $action eq 'form-submission' ) {
    # SM938 D5: one submission, by store and id - what a submission notice links to.
    _refuse_unreachable_form( _form_of_store( $params{file} ) );    # SM976 F2
    _refuse_beyond_account_requests( $params{file} );               # SM979
    $result = action_form_submission( $params{file}, $params{id} );
}
elsif ( $action eq 'form-list' ) { # SM214: PII-free form discovery (names + types + row counts)
    $result = dispatch_form_list();
    # SM979: an approve_accounts holder is shown the forms that request
    # accounts - the ones whose rows it may read - and no other.
    if ( ref $result eq 'HASH' && ref $result->{forms} eq 'ARRAY' && _approval_only() ) {
        $result->{forms} = [ grep { ref $_ eq 'HASH'
                    && Lazysite::Manager::Plugins::account_request_store( undef, $_->{name} ) }
                @{ $result->{forms} } ];
    }
}
elsif ( $action eq 'form-delete' ) {    # SM632: the inverse of bind_form
    my $req = _json_body();

    # SM605, same shape as data-table-drop: a confirmation sent in the query
    # string is not a confirmation, and saying nothing sends the caller round
    # again with the same value. Read from the RAW query string rather than the
    # params hash so t/lint/58 does not extract it as a second ACCEPTED source
    # and publish it as one.
    if ( !defined $req->{confirm}
        && ( $ENV{QUERY_STRING} // '' ) =~ /(?:\A|&)confirm=/ )
    {
        $result = { ok => 0, kind => 'invalid', field => 'confirm',
            error => 'the confirmation must be sent in the request body, not '
                . 'the query string - {"form":"...","confirm":"..."}' };
    }
    else {
        _refuse_unreachable_form( $req->{form} // $params{form} );    # SM976 F2
        $result = action_form_delete( $req->{form} // $params{form},
            $req->{confirm} );
    }
}
elsif ( $action eq 'form-submission-delete' ) {
    my $req = _json_body();
    _refuse_unreachable_form( _form_of_store( $req->{file} // $params{file} ) ); # SM976 F2
    $result = action_form_submission_delete( $req->{file} // $params{file}, $req->{id} );
}
elsif ( $action eq 'form-submission-confirm' ) {    # SM216: un-quarantine a row
    my $req = _json_body();
    _refuse_unreachable_form( _form_of_store( $req->{file} // $params{file} ) ); # SM976 F2
    $result = action_form_submission_confirm( $req->{file} // $params{file}, $req->{id} );
}
elsif ( $action eq 'form-submissions-delete-bulk' ) {    # SM187: delete several rows
    my $req = _json_body();
    _refuse_unreachable_form( _form_of_store( $req->{file} // $params{file} ) ); # SM976 F2
    $result = action_form_submissions_delete_bulk( $req->{file} // $params{file}, $req->{ids} );
}
elsif ( $action eq 'form-submission-approve' ) {    # SM858: an account from a submission
    my $req = _json_body();
    _refuse_unreachable_form( _form_of_store( $req->{file} // $params{file} ) ); # SM976 F2
    _refuse_beyond_account_requests( $req->{file} // $params{file} );            # SM979
    $result = action_form_submission_approve( $req->{file} // $params{file}, $req->{id},
        users => \&users_api, by => $auth_user );
}
elsif ( $action eq 'form-targets-save' ) {
    # SM842: handler ids only - `handlers` (a list of ids), or `targets` as the
    # manager has always sent them ({handler: id} each).
    my $req = _json_body();
    _refuse_unreachable_form( $req->{form} // $params{form} );    # SM976 F2
    if ( my $no = Lazysite::Manager::Common::handler_bind_refusal( $req->{handlers} // $req->{targets} ) ) {
        _refuse( $no, ( $token_auth ? 'api' : 'ui' ), 'denied: outside domain scope' ); # SM1051
    }
    $result = Lazysite::Handlers::action_form_targets_save( $req->{form} // $params{form},
        $req->{handlers} // $req->{targets} );
}
elsif ( $action eq 'form-uploads-save' ) {
    # SM905 U5: the three upload_* keys the form handler reads had no writer, so
    # an upload form could not be finished over the API at all.
    my $req = _json_body();
    _refuse_unreachable_form( $req->{form} // $params{form} );    # SM976 F2
    # Each parameter read by name, not through a qw() map: lint 58 extracts this
    # branch's parameters by scanning it, so a map hides three of them from the
    # table that publishes the action - and a parameter nobody publishes is one
    # no caller can find.
    $result = Lazysite::Handlers::action_form_uploads_save(
        $req->{form} // $params{form},
        $req->{uploads},
        { max_kb => $req->{max_kb},
            max_files => $req->{max_files},
            accept    => $req->{accept},
        },
    );
}
elsif ( $action eq 'form-notify-save' ) {
    # SM938 D4 / R17: the form's own notify: line, written as text.
    my $req = _json_body();
    _refuse_unreachable_form( $req->{form} // $params{form} );    # SM976 F2
    $result = Lazysite::Handlers::action_form_notify_save( $req->{form} // $params{form},
        $req->{notify} );
}
elsif ( $action eq 'file-upload' ) {
    # upload-budget (SM944 S34 finding F-1, built for review 2026-10-11): THE
    # HOURLY UPLOAD BUDGET IS SPENT HERE, after every gate. check_upload_rate
    # reserves a slot as it checks, and it ran in the body read, before the CSRF
    # gate, so a forged cross-site POST was refused 403 and still spent one: 60
    # of them locked the account out of uploads for the hour. A request reaching
    # this line has passed the CSRF, capability, scope and carve-out gates. The
    # check, its size argument and its refusal are unchanged (the 61st genuine
    # upload of an hour still answers 429 and is not audited); the body is now
    # read before it, at most the size gate's max_bytes.
    my $rate = check_upload_rate( $auth_user, $ENV{CONTENT_LENGTH} // 0 );
    _bail( { ok => 0, kind => 'rate', error => $rate->{error} } ) unless $rate->{ok};
    $result = action_file_upload( $path, $body );
}
elsif ( $action eq 'file-download' ) {
    $result = action_file_download($path);    # Q16b: streamed, or the refusal
}
elsif ( $action eq 'backup-list' ) {
    $result = dispatch_backup_list();
}
elsif ( $action eq 'backup-create' ) {
    # scope=full = a full-system snapshot (config + auth + content) for DR and
    # cross-domain migration; otherwise a content-only snapshot. These are
    # manager (cookie) actions - not in %need, so a token client cannot reach them.
    $result = action_backup_create(
        ( $params{scope} // '' ) eq 'full' ? 'full' : undef );
}
elsif ( $action eq 'backup-restore' ) {
    # SM874: `replace` is the undo-of-apply mode - clear the archive's own
    # folder first, so files the package added go too. Refused by the library
    # when the archive covers no single folder, which is the case where
    # clearing would mean clearing the docroot.
    $result = action_backup_restore( $params{name},
        replace => ( $params{replace} ? 1 : 0 ) );
}
elsif ( $action eq 'backup-delete' ) {
    my $req = _json_body();
    $result = action_backup_delete( $req->{name} // $params{name} );
}
elsif ( $action eq 'backup-download' ) {
    # SM976: the same reach the listing applies. A site package is one domain's
    # (the site-backup-download rule); any other backup is the whole instance,
    # which a domain-confined caller does not read (R1).
    my $name = $params{name} // '';
    if ( $name =~ /\A(?:lazysite-)?site-[A-Za-z0-9._-]*\z/ ) {
        my $pkg = Lazysite::Paths::lazysite_dir($DOCROOT) . "/backups/$name";
        if ( my $no = _package_scope_refusal($pkg) ) {
            _refuse( $no, 'ui', 'denied: outside domain scope', $name );
        }
    }
    elsif ( my $no = Lazysite::Manager::Common::instance_wide_refusal( action => 'backup-download' ) ) {
        _refuse( $no, 'ui', 'denied: instance-wide', $name );
    }
    $result = action_backup_download( $params{name} );    # Q16b: streamed, or the refusal
}
elsif ( $action eq 'file-zip-download' ) {
    $result = action_file_zip_download( \@REQUEST_SCOPES ); # F2: confine each path to scope
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
else {
    # SM670: an action that does not exist is not found - 404, not 400.
    $result = { ok => 0, kind => 'not-found', error => "Unknown action: $action" };
}
$DISPATCH_CRASH_GUARD = 0;    # P24: the chain finished

# Audit trail: record MATERIAL actions only - state changes and security grants
# (who did what, TO WHAT, when, from where, outcome). Reads/browsing are NOT
# audited; the access log and the stats plugin cover those, and the audit must
# not overlap with them. Read-ish POSTs (the UI POSTs everything) are skipped.
#
# SM943 RULING 1 (2026-10-09): "Audit is useful to see when a person or agent
# has made material behaviour changes, authentication events and errors." So a
# read's REFUSAL or ERROR is recorded, on GET as well as POST - a token client
# reads over GET, and its refused read was the one row this block never wrote.
# MCP applies the same rule to the same declaration (t/lint/23).
my $AUDIT_FAILED = ref $result eq 'HASH' && !$result->{ok};
if ( ( $ENV{REQUEST_METHOD} // '' ) eq 'POST' || $AUDIT_FAILED ) {

    my ( $aud_action, $aud_target ) =
        ( $action, $action eq 'config-set' ? ( $params{key} // '' ) : ( $path // '' ) );

    # N141B-C: what a SUCCESSFUL action wants to put on the record.
    #
    # $detail below is a failure channel - it is populated from the refusal and
    # is '' whenever $ok. That left the successes of several actions saying less
    # than their own failures, which is the wrong way round for a trail that
    # exists to answer "what changed". This carries the specifics a success
    # knows; it is folded into $detail only when nothing has gone wrong, so a
    # refusal's reason is never displaced by it.
    my $aud_extra   = '';
    my $aud_no_text = 0;    # P24: a failed account-store read records its class only
    # SM503: a data action's material object is the TABLE, not the dispatcher
    # path - the sysop's trail showed data-import and data-row-save rows
    # all targeting "/", which answers none of the questions a trail exists
    # for. The name rides the query for the migrate family and the body for
    # the row/import family, so both are consulted.
    if ( $action =~ /^data-/ ) {
        # SM512: a safety-export action's object is the FILE.
        my $t = $params{table} // $params{file};
        unless ( defined $t && length $t ) {
            my $b = _json_body();
            $t = ( ref $b eq 'HASH' ) ? $b->{table} : undef;
        }
        $aud_target = $t if defined $t && length $t;
    }

    # action=users carries its sub-action in the POST body; audit only the
    # material ones (add / remove / settings-set / token / ...), not the reads.
    if ( $action eq 'users' ) {
        my $b   = _json_body();
        my $sub = ( ref $b eq 'HASH' ) ? ( $b->{action} // '' ) : '';
        # P24 (under SM943's rule): a read sub-action - users-detail,
        # verify-credential and the rest of %uskip - is skipped when it
        # succeeds and recorded when it fails, as a read action is - by its
        # class, never its text: a read's error can echo what it was given (a
        # credential, a TOTP secret) or a die inside the tool.
        $sub = $params{sub} // 'list' if $sub eq '' && ( $ENV{REQUEST_METHOD} // '' ) ne 'POST';

        $aud_no_text = 1 if $uskip{$sub};
        if ( $sub eq '' || ( $uskip{$sub} && !$AUDIT_FAILED ) ) { $aud_action = undef }
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

            # N141B-C: NESTING A GROUP RECORDED NOTHING - target empty, detail
            # empty. The branch above looks for `group` and `username`, and the
            # UI sends neither for a nest: it sends `sub` and `parent`. So the
            # one change that alters what a whole group of people can do left an
            # audit row naming an action and no subject at all.
            #
            # The CLI has recorded this correctly since SM121 - cli_audit(
            # 'user-group-nest', "$sub\@$parent" ) - so the two surfaces
            # disagreed about the same event, and only the one an operator
            # actually uses was blank. Same spelling as the CLI, deliberately:
            # an audit reader filtering on a target should not have to know
            # which surface performed the change.
            if ( $sub eq 'group-nest' && ref $b eq 'HASH' ) {
                my ( $s, $p ) = ( $b->{sub} // '', $b->{parent} // '' );
                $aud_target = "$s\@$p"       if length $s && length $p;
                $aud_extra  = "nested in $p" if length $p;
            }

            # N141B-C: A CAPABILITY CHANGE NAMED THE GROUP AND NOT THE
            # CAPABILITY. user-group-settings-set recorded which group was
            # edited and neither which key changed nor what it became - so the
            # row says somebody altered a group's permissions, and an auditor
            # asking WHICH permission has to diff the store against a backup.
            #
            # A refusal already records why it was refused. A success recorded
            # less than its own failure, which is the wrong way round for the
            # record that exists to answer "what changed".
            #
            # The CLI again already does this (key $key=on, assignable=off,
            # registration=on), so this is the UI catching up to a spelling
            # that exists.
            if ( $sub eq 'group-settings-set' && ref $b eq 'HASH' ) {
                my $k = $b->{key} // '';
                if ( length $k ) {
                    my $v = $b->{value};
                    $aud_extra = "key $k="
                        . ( !defined $v ? '(cleared)'
                        : ref $v           ? 'set'
                        : $v =~ /\A[01]\z/ ? ( $v ? 'on' : 'off' )
                        :                    $v );
                }
            }
        }
    }

    # SM1043: a me-* action is about the caller's own account, and names no
    # other - the target is the account, never anything the request carried.
    $aud_target = $auth_user if $action =~ /\Ame(?:-|\z)/;

    # SM141/SM145: the revokes carry their target in the POST body - name it
    # (a sid prefix / the username) instead of the meaningless '/' path.
    # SM724: a start-page change is about an ACCOUNT, and the trail should say
    # whose - especially since a user may set their own.
    if ( $action eq 'start-page-set' ) {
        my $b = _json_body();
        my $u = ( ref $b eq 'HASH' ? $b->{username} : undef ) // $auth_user;
        $u =~ s/[^a-zA-Z0-9_.-]//g;
        $aud_target = $u;
    }
    if ( $action eq 'session-revoke' || $action eq 'user-revoke' || $action eq 'key-revoke' ) {
        my $b = _json_body();
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
    #
    # SM1090: ONLY WHEN IT HAPPENED. A save that failed at the write has created
    # nothing and edited nothing, and has no `created` flag, so this named every
    # refused new page an `edit` that failed: the 0.15.5 edge test plan could
    # not find the rows of its failed saves ("not audited at all") because it
    # looked for the act it had attempted, `save`, and the trail said `edit`
    # (and `create` never, for a page that was never made). A failed save keeps
    # the request's own action, and its detail below is the write's reason.
    if ( $action eq 'save' && ref $result eq 'HASH' && $result->{ok} ) {
        $aud_action = $result->{created} ? 'create' : 'edit';
    }

    # A read is skipped when it succeeds and recorded when it fails; a write the
    # declaration leaves unaudited (lock, cache-invalidate, ...) stays skipped.
    if ( defined $aud_action
        && ( !$skip{$aud_action} || ( $AUDIT_FAILED && !$MUTATING{$aud_action} ) ) )
    {
        my $ok = ref $result eq 'HASH' && $result->{ok};
        # On failure, record a short reason (kind, else the error text) as the
        # detail field so the audit can show WHY it failed.
        # SM711 half 2: audit_detail FIRST. `kind` names the class of
        # failure - `missing_deps` - and the class was never the question. The
        # release manager's complaint was that the log did not say WHICH
        # dependency was missing, while the banner beside it did, so the
        # information existed and only the record lacked it. A result that
        # knows the specifics says so; everything else keeps the old order.
        my $detail = $ok ? ''
            : ( ref $result eq 'HASH'
            ? ( $result->{audit_detail} || $result->{kind} || $result->{error} || '' )
            : '' );
        # P24: a failed account-store read is recorded by its class only.
        $detail = ( $result->{audit_detail} || $result->{kind} || 'failed' )
            if !$ok && $aud_no_text && ref $result eq 'HASH';

        # N141B-C: a success says what it did. Only when $ok, so the refusal
        # reason above always wins the field it was written for.
        $detail = $aud_extra if $ok && length $aud_extra;

        # SM1093: deleting a notify rule says how many queued notifications
        # went with it - the trail is where "where did my events go" is asked.
        if ( $ok && $aud_action eq 'handler-delete' && ref $result eq 'HASH' && defined $result->{outbox_removed} ) {
            $detail = "outbox_removed=$result->{outbox_removed}";
        }

        # SM858: an approval names the row and the account it became - who
        # approved is the trail's own `user` field, the store is the target.
        if ( $ok && $aud_action eq 'form-submission-approve' && ref $result eq 'HASH' ) {
            $detail = "id=$result->{id} account=$result->{user}";
            $detail .= _audit_unplaced($result);
        }

        # SM963: an approval through the Users API names the groups it could not
        # place the account in, as the CLI's own trail line does.
        if ( $ok && $aud_action eq 'user-account-approve' && ref $result eq 'HASH' ) {
            ( my $np = _audit_unplaced($result) ) =~ s/\A //;
            $detail = join ' ', grep { length } $detail, $np;
        }

        # SM465: an acl-set records WHAT THE RULE BECAME, and what it was.
        #
        # The trail recorded that a permission changed, who changed it and on
        # what path - and not what it changed to, so the one question an audit
        # of a permission change exists to answer was the one it could not.
        #
        # NAMES ARE INCLUDED, the release manager's decision, with the trade
        # stated and accepted: account and group names land in the audit log,
        # which may carry different retention from the account store. The
        # alternative - "read: 2 principals" - leaves an auditor unable to tell
        # whether the RIGHT people were named, which is the whole question.
        if ( $ok && $aud_action eq 'acl-set' ) {
            $detail = _acl_audit_detail( $ACL_AUDIT_BEFORE, $ACL_AUDIT_AFTER );
        }

        # SM1052: a list of paths is ONE AUDIT ROW PER PATH, each with what its
        # rule was and became - the trail is asked about a path, not a request.
        my $per_path = ( $aud_action eq 'acl-set' && ref $result eq 'HASH'
                && ref $result->{_acl_audit} eq 'ARRAY' ) ? delete $result->{_acl_audit} : undef;
        # SM1053: an account import's own rows - one per account it made - beside
        # the row for the import itself.
        my $acct_rows = ( ref $result eq 'HASH' && ref $result->{_audit_rows} eq 'ARRAY' )
            ? delete $result->{_audit_rows} : [];
        for my $row (@$acct_rows) {
            my ( $a_act, $a_target, $a_ok, $a_detail ) = @$row;
            audit_log( $auth_user, $a_act, $a_target, _request_ip(), ( $a_ok ? 'ok' : 'fail' ),
                ( $token_auth ? 'api' : 'ui' ), _audit_detail($a_detail) );
        }
        if ($per_path) {
            my $door = $token_auth ? 'api' : 'ui';
            for my $row (@$per_path) {
                my ( $p, $before, $after, $pok, $why ) = @$row;
                my $what = $pok ? _acl_audit_detail( $before, $after ) : $why;
                audit_log( $auth_user, 'acl-set', $p, _request_ip(), ( $pok ? 'ok' : 'fail' ),
                    $door, $what );
            }
        }

        # SM1046: a domain a token gave to its own group names the group. The
        # caller is the trail's `user` and the host its target; the group is
        # who reaches the new domain from now on, which is the question an
        # auditor of this write asks.
        if ( $ok && $aud_action eq 'domain-add' && ref $result eq 'HASH'
            && length( $result->{allowed_groups} // '' ) )
        {
            $detail = "allowed_groups=$result->{allowed_groups} (own group, SM1046)";
        }

        # SM1050: a group-set records what it did to the group - created, and
        # each capability granted (+) or revoked (-) - as acl-set records the rule.
        # SM1053: an account import's apply records what it did the same way,
        # and (n571) a removal whose import it was.
        if ( ( grep { $aud_action eq $_ } qw(group-set accounts-import-apply accounts-import-remove) )
            && ref $result eq 'HASH'
            && defined $result->{change} )
        {
            $detail = $ok ? $result->{change} : "$detail; $result->{change}";
        }

        # SM505: a row action's material object is the ROW - "someone edited
        # that table" is half an answer when the question the trail gets asked
        # is which row. The handler's result carries the authoritative key
        # (insert returns the ASSIGNED key, so an add names the row it
        # created). ROW KEYS LAND IN THE AUDIT LOG - the release manager's
        # decision, the SM465 trade accepted again: a key is a content
        # identifier, and "a row changed" leaves an auditor unable to tell
        # WHICH, which is the whole question.
        if ( $ok
            && $aud_action =~ /^data-row-/
            && ref $result eq 'HASH'
            && defined $result->{key}
            && length $result->{key} )
        {
            $detail = 'row=' . $result->{key};
        }

        # SM677: a table may switch its ROW audit off.
        #
        # SM505 and SM465 both decided the row key belongs in the trail, and
        # that stands as the default. What they could not weigh is volume: a
        # table with thousands of rows produces thousands of lines, and the
        # operator who has that table is the one who knows it. The switch is per
        # table, in the descriptor, where the volume is visible.
        #
        # THE TABLE-LEVEL EVENTS ARE NOT AFFECTED. data-table-save,
        # data-migrate, data-table-drop and data-import each remain one audited
        # event - so switching this off loses the per-row detail and never the
        # record that the table was restructured, emptied or bulk-loaded. That
        # is the line worth holding: an operator silencing a noisy table must
        # not thereby silence the events that matter most.
        my $skip_audit = 0;
        if ( $ok && $aud_action =~ /^data-row-/ ) {
            my $t = $params{table} // ( eval { _json_body()->{table} } // '' );
            if ( length $t && !_table_audits_rows($t) ) {
                $skip_audit = 1;
            }
        }
        audit_log( $auth_user, $aud_action, $aud_target, _request_ip(),
            ( $ok ? 'ok' : 'fail' ), ( $token_auth ? 'api' : 'ui' ),
            _audit_detail($detail) )
            unless $skip_audit || $per_path;
    }
}

# Q16b (ruled 2026-10-10, "Keep audit, print nothing"): A STREAMED RESPONSE HAS
# BEEN SENT. Every streaming download - file-download, file-zip-download,
# backup-download, site-backup-download, data-export, page-pdf - writes its body
# through Manager::Upload::stream_attachment/stream_bytes and returns
# { ok => 1, streamed => 1 }; it is audited above like any other action, and
# nothing is printed after it. page-pdf used to reach respond() here, which put
# a second header block and {"ok":true,"streamed":1} past the PDF's
# Content-Length; the others exited before the audit block, refused or not.
respond($result) unless ref $result eq 'HASH' && $result->{ok} && $result->{streamed};

# SM245: the brief store, wired to this request. Five branches asked for it
# with the same three lines; the module name stays in each branch through the
# action call it makes, which is what t/lint/77 reads.
sub _briefs {
    require Lazysite::Manager::Briefs;
    no warnings 'once';    # fully-qualified package vars, set here and read there
    $Lazysite::Manager::Briefs::DOCROOT   = $DOCROOT;
    $Lazysite::Manager::Briefs::auth_user = $auth_user;
    return;
}

# SM976 F4: bind a theme or layout to one domain - Domains::domain_set, which
# validates the name and mirrors the theme's assets for that host (SM241), with
# the scope the answer is about, as MCP's _domain_presentation_set says it.
sub _domain_presentation_set {
    my ( $host, $key, $value ) = @_;
    my $r = domain_set( $host, $key, $value );
    return $r unless ref $r eq 'HASH' && $r->{ok};
    return { %$r, scope => "domain:$host" };
}

# SM976 F2 (ruled 2026-10-09, "Confine both"): a form verb reaches only a form
# bound on pages inside the caller's scope (an unbound form is the primary's),
# asked before the form is looked at. Manager::Common::form_reach_refusal.
sub _refuse_unreachable_form {
    my ($name) = @_;
    my $r = Lazysite::Manager::Common::form_reach_refusal($name) or return;
    _refuse( $r, ( $token_auth ? 'api' : 'ui' ), 'denied: outside domain scope', $name // '' );
    return;
}

# SM979: a cookie caller who reaches the submission views through
# approve_accounts alone - without read_submissions, and not the operator
# (SM991: a member of the operator group, who passes every capability gate on
# this channel; manage_users alone no longer does).
sub _approval_only {
    return 0 if $token_auth || _operator();
    my $caps = _user_caps($auth_user);
    return ( $caps->{approve_accounts} && !$caps->{read_submissions} ) ? 1 : 0;
}

# SM979: such a caller reads, and approves from, the store of a form that
# declares account_email - the account requests - and no other. Refused as
# the capability gate refuses, naming the grant that reads every form.
sub _refuse_beyond_account_requests {
    my ( $file, $form ) = @_;
    return unless _approval_only();
    return if Lazysite::Manager::Plugins::account_request_store( $file, $form );
    _refuse(
        { ok => 0, kind => 'forbidden',
            error => 'This account approves account requests: it reads the submissions of a '
                . 'form that declares account_email, and this is not one. Reading other '
                . "forms' submissions requires the 'read_submissions' permission. An "
                . 'administrator can grant it on the Groups page.' },
        'ui', 'denied: capability', ( $file // $form // '' ) );
    return;
}

# SM1051 (P-4): refuse a handler write this caller may not make - a domain's
# handler it does not reach, or an instance handler (no domain) for a confined
# caller. The record as it stands is read for its domain; a store that cannot be
# read counts as an instance handler, so a confined caller is refused and the
# write itself names the unreadable store to everyone else.
sub _refuse_unreachable_handler {
    my ( $id, %new ) = @_;
    my $all = Lazysite::Handlers::read_handlers();
    my $old = ( defined $id && !ref $id && $all ) ? Lazysite::Handlers::find_handler( $all, $id ) : undef;
    my %a = ( %new, ( $old ? ( old => $old->{domain} // '' ) : $all ? () : ( old => '' ) ) );
    $a{new} //= '' if exists $a{new};
    my $r = Lazysite::Manager::Common::handler_reach_refusal(%a) or return;
    _refuse( $r, ( $token_auth ? 'api' : 'ui' ), 'denied: outside domain scope', $id // '' );
    return;
}

# SM1053: an import is reviewed and applied by the operator - a cookie session
# the operator holds - and by no token (the dispatcher's gate keeps these
# actions cookie-only; this is the operator half). undef when it may proceed.
sub _import_operator_refusal {
    return undef if !$token_auth && _operator();
    return { ok => 0, kind => 'forbidden',
        error => 'An account import is reviewed and applied by the operator, in the manager.' };
}

# SM1050: who is asking, as Lazysite::Manager::Groups takes it - the account,
# what it holds on this door, whether it is domain-confined, and whether it is
# the operator (never a token). The reach is the request's own, so `reach` is
# empty and caller_may_reach_domain reads the request.
sub _groups_who {
    return (
        actor    => $auth_user,
        held     => ( $token_auth ? \%token_caps : _user_caps($auth_user) ),
        confined => Lazysite::Manager::Common::request_domain_confined(),
        reach    => [],
        operator => ( $token_auth ? 0 : _operator() ),
    );
}

# The form a submissions store belongs to: its file name, which is the form's
# (<dir>/<form>.jsonl, whichever directory its file handler names).
sub _form_of_store {
    my ($file) = @_;
    ( my $leaf = $file // '' ) =~ s{.*/}{};
    $leaf =~ s/\.jsonl\z//;
    return $leaf;
}

# SM976 F2: a brief verb reaches only the brief of a page inside the caller's
# scope, or of a row of a table that passes the data rule.
sub _refuse_unreachable_brief {
    my ( $bpath, %typed ) = @_;
    my $r = Lazysite::Manager::Common::brief_reach_refusal( $bpath, %typed ) or return;
    _refuse( $r, ( $token_auth ? 'api' : 'ui' ), 'denied: outside domain scope', $bpath // '' );
    return;
}

# The dispatch branches' form: refuse and audit, or return. $more is appended
# to the refusal's sentence where an action has a way through it (SM1046).
sub _refuse_unscoped_token {
    my ($more) = @_;
    my $r = _no_scope_refusal() or return;
    $r->{error} .= $more if defined $more;
    _refuse( $r, 'api', 'denied: no dav_scope' );
    return;
}

# SM1046: the groups the calling account is in by name.
sub _caller_direct_groups {
    return Lazysite::Auth::Settings::direct_groups($auth_user);
}

# SM1046 (ruled 2026-10-12, "Allow, own group only"): the groups a domain-add
# names in allowed_groups, each one the calling token's own, or a refusal.
# Returns () when none is named. A list (JSON array) or a comma string; @name
# and name are the same group. Only a token may name them: a cookie session
# sets a domain's access keys with domain-set (Domains page), where SM647's
# manage_users rule and the group-existence check are asked, so a cookie
# request naming them is refused rather than taking a second, unchecked door.
sub _domain_add_own_groups {
    my ($raw) = @_;
    return () unless defined $raw;
    my @names = ref $raw eq 'ARRAY' ? @{$raw} : ( ref $raw ? () : split /,/, $raw );
    @names = grep { length } map { my $n = $_ // ''; $n =~ s/^\s+|\s+$//g; $n =~ s/\A\@//; $n } @names;
    _refuse( { ok => 0, kind => 'invalid',
            error => 'allowed_groups is a group name or a list of them (a JSON array, or '
                . 'names separated by commas).' },
        ( $token_auth ? 'api' : 'ui' ), 'denied: allowed_groups shape', $auth_user )
        if ref $raw && ref $raw ne 'ARRAY';
    return () unless @names;
    unless ($token_auth) {
        _refuse( { ok => 0, kind => 'invalid',
                error => "domain-add does not take allowed_groups from a signed-in session. "
                    . 'Add the domain, then set who reaches it with domain-set '
                    . '(the Domains page).' },
            'ui', 'denied: allowed_groups on domain-add' );
    }
    my %mine = map  { $_ => 1 } _caller_direct_groups();
    my @not  = grep { !$mine{$_} } @names;
    if (@not) {
        my @have = sort keys %mine;
        _refuse( { ok => 0, kind => 'forbidden',
                error => 'A new domain may be given only to a group your account is in, and '
                    . 'it is not in ' . join( ', ', map { "\@$_" } @not ) . '. '
                    . ( @have
                    ? 'Your groups: ' . join( ', ', map { "\@$_" } @have ) . '.'
                    : 'Your account is in no group by name.' ) },
            'api', 'denied: allowed_groups not own', join( ',', @not ) );
    }
    my %seen;
    return grep { !$seen{$_}++ } @names;
}

# SM976: the same form for the domain an action addresses - host => or root =>,
# asked of Lazysite::Manager::Common::caller_may_reach_domain. $why replaces the
# shared refusal's sentence where an action already had its own words.
sub _refuse_unreachable_domain {
    my ( $why, %a ) = @_;
    my $r = Lazysite::Manager::Common::domain_reach_refusal(%a) or return;
    $r->{error} = $why if defined $why;
    _refuse( $r, ( $token_auth ? 'api' : 'ui' ), 'denied: outside domain scope' );
    return;
}

# P24: the END block's half of the crash row (see the guard above the dispatch).
# $? is kept: the process still exits with the failure it was exiting with.
sub _audit_crashed_dispatch {
    return unless $DISPATCH_CRASH_GUARD && $?;
    my $status = $?;
    my $act    = $action // '';
    if ( $act eq 'users' ) {
        my $b   = eval { _json_body() };
        my $sub = ( ref $b eq 'HASH' ? $b->{action} : undef ) // $params{sub} // '';
        $sub =~ s/[^a-z0-9-]//g;
        $act = "user-$sub" if length $sub;
    }
    eval {
        audit_log( $auth_user // '', $act, ( $path // '' ), _request_ip(), 'fail',
            ( $token_auth ? 'api' : 'ui' ),
            _audit_detail('crashed: the handler failed - the error is in the error log') );
        1;
    };
    $? = $status;
    return;
}

# --- Request-pipeline helpers ------------------------------------------------

# SM579: the connectors module, loaded on first use and pointed at this
# request's docroot. Configuring is manage_connectors (the cap tables);
# connector-call is gated by the CONNECTOR inside Connectors::may_call.
sub _connectors {
    require Lazysite::Manager::Connectors;
    no warnings 'once';
    $Lazysite::Manager::Connectors::DOCROOT = $DOCROOT;
    return 'Lazysite::Manager::Connectors';
}

# SM747: the Odoo extension's engine, as the connectors' is reached.
sub _odoo {
    require Lazysite::Odoo;
    no warnings 'once';
    $Lazysite::Odoo::DOCROOT = $DOCROOT;
    return 'Lazysite::Odoo';
}

# SM747 E: who is asking, for a bound operation - the verified account, its
# capabilities and groups, and the request address. Never a visitor.
sub _odoo_who {
    return (
        user    => $auth_user,
        caps    => Lazysite::Auth::Settings::caps_for($auth_user) || {},
        groups  => [ Lazysite::Auth::Settings::effective_groups($auth_user) ],
        ip      => _request_ip(),
        channel => 'api',
        reach   => {},    # E-Q1: this request's own reach (Manager::Common)
    );
}

# SM516 MA-3: a gate refusal is three statements in one order - record it,
# answer it, end the request - repeated at six gates in the pipeline above.
# One helper, so the order cannot drift and an added gate cannot forget the
# exit and fall through into the dispatch it was meant to refuse. $target
# defaults to the request path, which is what five of the six record.
sub _refuse {
    my ( $resp, $origin, $reason, $target ) = @_;
    audit_log( $auth_user, $action, ( defined $target ? $target : ( $path // '' ) ),
        _request_ip(), 'fail', $origin, _audit_detail($reason) );
    respond($resp);
    exit 0;
}

# The same ending without an audit line: the pre-auth and parse-time refusals,
# which have no established identity, action or path to record yet.
sub _bail {
    my ($resp) = @_;
    respond($resp);
    exit 0;
}

# SM465: render an acl-set for the audit trail.
#
# ONE LINE, READABLE BY A PERSON, because the audit trail is read by an
# operator asking "who could reach what, and when" - not parsed. JSON would be
# faithful and unreadable at the width an audit page renders.
#
# BOTH SIDES when there was a prior rule, because the interesting case is what
# changed: "read: alice -> alice, bob" answers a question that "read: alice,
# bob" does not. A path with no prior rule says `new`, so an operator can tell
# a first grant from a widening.
sub _acl_audit_fmt {
    my ($acl) = @_;
    return 'none' unless ref $acl eq 'HASH';
    my @bits;
    for my $k (qw(read write)) {
        my $v = $acl->{$k};
        next unless ref $v eq 'ARRAY';

        # An EMPTY list is not nothing: an empty write list means NO
        # restriction (SM462), so recording it as absent would make the trail
        # disagree with enforcement about the most misread rule in the system.
        push @bits, @{$v} ? "$k: " . join( ', ', @{$v} ) : "$k: (unrestricted)";
    }
    push @bits, "owner: $acl->{owner}"
        if defined $acl->{owner} && length $acl->{owner};
    push @bits, 'draft' if $acl->{draft};
    return @bits ? join( '; ', @bits ) : 'no restriction';
}

# SM963: " not-placed=a,b" for an account-approve result that could not place
# the account in every group it was meant to join; '' when everything took.
sub _audit_unplaced {
    my ($result) = @_;
    my $u        = ref $result eq 'HASH' ? $result->{unplaced} : undef;
    my @np       = map { ref $_ eq 'HASH' && defined $_->{group} ? $_->{group} : () }
        ( ref $u eq 'ARRAY' ? @$u : () );
    return @np ? ' not-placed=' . join( ',', @np ) : '';
}

sub _acl_audit_detail {
    my ( $before, $after ) = @_;
    my $to = _acl_audit_fmt($after);
    return "new -> $to" unless ref $before eq 'HASH';
    my $from = _acl_audit_fmt($before);
    return "unchanged: $to" if $from eq $to;
    return "$from -> $to";
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

# SM677: does this table audit its row writes? Default YES - only an explicit
# `audit_rows: off` in the descriptor turns it off, and a descriptor that cannot
# be read audits, because losing the trail must never be the failure mode of a
# missing or broken file.
sub _table_audits_rows {
    my ($table) = @_;
    return 1 unless defined $table && length $table;
    my $d = eval { Lazysite::Manager::Data::load_table_for_audit($table) };
    return 1 unless ref $d eq 'HASH' && $d->{ok};
    return ( exists $d->{audit_rows} && !$d->{audit_rows} ) ? 0 : 1;
}

# SM097: the public-page URL list, for the nav editor's autocomplete. Walks the
# docroot for .md/.url pages and maps each to its clean URL (about.md -> /about,
# index.md -> /, foo/index.md -> /foo/), skipping internal trees.
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
