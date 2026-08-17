#!/usr/bin/perl
# lazysite-auth.pl - lightweight built-in auth wrapper
# Sets X-Remote-* headers from signed cookie, then execs the processor
use strict;
use warnings;
use Digest::SHA    qw(sha256_hex hmac_sha256_hex);
use Fcntl          qw(:flock O_RDWR O_WRONLY O_APPEND O_CREAT);
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use POSIX          qw(strftime);
use IPC::Open2     qw(open2);

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
use Lazysite::Util             qw(log_event const_eq);
use Lazysite::Paths            ();
use Lazysite::Audit            qw(audit_log);
use Lazysite::Auth::Credential qw(generate_random_hex hash_password verify_password);
use Lazysite::Auth::Settings   qw(groups_grant_cap);
use Lazysite::I18n             qw(chrome_string);    # SM179 P8: engine-chrome i18n
$Lazysite::Util::COMPONENT = 'auth';

if ( grep { $_ eq '--describe' } @ARGV ) {
    require JSON::PP;
    print JSON::PP::encode_json( {
            id          => 'auth',
            name        => 'Built-in Auth',
            description => 'Cookie-based authentication with user and group management',
            version     => '1.0',
            # Wired in the web-server config (FallbackResource), not toggled via
            # the plugins list - the manager renders core plugins as "always on".
            core        => 1,
            config_file => '',
            config_keys => [ qw(auth_default auth_redirect auth_header_user
                    auth_header_name auth_header_email auth_header_groups) ],
            config_schema => [
                { key => 'auth_default', label => 'Default auth requirement', type => 'select',
                    options => [ 'none', 'optional', 'required' ], default => 'none' },
                { key => 'auth_redirect', label => 'Login page path', type => 'text', default => '/login' },
                { key => 'auth_header_user', label => 'User header name', type => 'text', default => 'X-Remote-User' },
                { key => 'auth_header_name', label => 'Display name header', type => 'text', default => 'X-Remote-Name' },
                { key => 'auth_header_email', label => 'Email header name', type => 'text', default => 'X-Remote-Email' },
                { key => 'auth_header_groups', label => 'Groups header name', type => 'text', default => 'X-Remote-Groups' },
            ],
            actions => [
                { id => 'manage-users', label => 'Manage users', link => '/manager/users' },
            ],
    } );
    exit 0;
}

my $DOCROOT = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT}
    or die "DOCUMENT_ROOT not set\n";
my $LAZYSITE_DIR = Lazysite::Paths::lazysite_dir($DOCROOT);    # SM293
my $AUTH_DIR     = "$LAZYSITE_DIR/auth";
$Lazysite::Audit::LAZYSITE_DIR      = $LAZYSITE_DIR;
$Lazysite::Auth::Settings::AUTH_DIR = $AUTH_DIR;

# Record a material authentication event in the audit trail (login/logout, claim,
# token exchange/rotate), in addition to the application log. Origin defaults to
# 'ui' (interactive browser); credential-API flows pass 'api'.
sub _audit_auth {
    my ( $user, $act, $status, $detail, $origin ) = @_;
    # Record WHICH site (Host) the auth event happened on, so the audit says
    # where a login/logout/claim occurred rather than a bare blank target.
    my $host = lc( $ENV{HTTP_HOST} // '' );
    $host =~ s/:\d+\z//;          # strip port
    $host =~ s/[^a-z0-9.-]//g;    # keep it audit-safe
    audit_log( $user, $act, $host, $ENV{REMOTE_ADDR} // '', $status,
        $origin // 'ui', $detail // '' );
}

# SM128: the bad-URL auto-blocker enforcement. One pass over lazysite.conf for
# the bad_url_* settings (enabled by default); a blocked IP is refused, and a
# probe path counts toward a block. The module is loaded lazily and only when
# enabled, so a site with the blocker off pays nothing.
sub _bad_url_guard {
    my ($path) = @_;
    my %c;
    if ( open my $fh, '<:utf8', "$LAZYSITE_DIR/lazysite.conf" ) {
        while (<$fh>) {
            if (/^\s*(bad_url_\w+)\s*:\s*(.+?)\s*$/) { $c{$1} = $2 }
        }
        close $fh;
    }
    return if ( $c{bad_url_block} // 'enabled' ) eq 'disabled';
    my $ip = $ENV{REMOTE_ADDR} // '';
    return unless length $ip;

    require Lazysite::BadUrl;
    _bad_url_deny() if Lazysite::BadUrl::is_blocked( $DOCROOT, $ip );

    my @extra = grep { length } map { s/^\s+|\s+$//gr } split /,/, ( $c{bad_url_extra} // '' );
    return unless Lazysite::BadUrl::is_bad_url( $path, \@extra );

    my $threshold = ( $c{bad_url_threshold} || 10 ) + 0;
    my $window    = ( $c{bad_url_window}    || 3600 ) + 0;
    if ( Lazysite::BadUrl::record_and_check( $DOCROOT, $ip, $path,
            threshold => $threshold, window => $window ) ) {
        _audit_auth( 'system', 'ip-auto-blocked', 'ok',
            'path=' . substr( $path, 0, 120 ), 'auth' );
        log_event( 'WARN', '-', 'IP auto-blocked (bad-url scanner)', ip => $ip );
        _bad_url_deny();
    }
    return;
}

sub _bad_url_deny {
    print "Status: 403 Forbidden\r\n";
    print "Content-Type: text/plain; charset=utf-8\r\n\r\n";
    print "403 Forbidden\n";
    exit 0;
}
my $COOKIE_NAME = 'lazysite_auth';
my $COOKIE_MAX  = 86400;             # 24 hours

# H-3: login rate limiting (per-IP, sliding window)
my $LOGIN_RATE_DB = "$AUTH_DIR/.login-rate.db";
my $LOGIN_MAX     = 5;                            # attempts per window
my $LOGIN_WINDOW  = 300;                          # seconds (5 minutes)
my $LOGIN_DELAY   = 2;                            # seconds sleep on failure

# --- Main ---

my $method = $ENV{REQUEST_METHOD} // 'GET';
my $uri    = $ENV{REDIRECT_URL}   // '/';
my $query  = $ENV{QUERY_STRING}   // '';
my $action = '';
# Capture the FULL action token (including hyphens) so a short action like
# `rotate` does not shadow a longer one such as `rotate-auth-secret`.
$action = $1 if $query =~ /action=([a-z][a-z-]*)/;

# SM128: bad-URL auto-blocker. Refuse a blocked IP outright and count scanner
# probes toward a block. Enabled by default; runs before the auth dispatch so it
# covers every request through the wrapper (a blocked IP cannot even try to log in).
_bad_url_guard($uri);

if ( $action eq 'login' && $method eq 'POST' ) {
    handle_login();
}
elsif ( $action eq 'logout' ) {
    handle_logout();
}
elsif ( $action eq 'claim' && $method eq 'POST' ) {
    handle_claim();
}
elsif ( $action eq 'exchange' && $method eq 'POST' ) {
    _require_token_exchange();
    handle_exchange();
}
elsif ( $action eq 'rotate' && $method eq 'POST' ) {
    _require_token_exchange();
    handle_rotate();
}
elsif ( $action eq 'forgot' && $method eq 'POST' ) {
    handle_forgot();
}
else {
    handle_request();
}

# --- Handlers ---

sub handle_login {
    my %form = parse_post();

    my $username = $form{username} // '';
    $username =~ s/[^a-zA-Z0-9_.-]//g;
    $username = substr( $username, 0, 64 ) if length($username) > 64;

    my $password = $form{password} // '';
    my $next     = sanitise_next( $form{next} // '/' );

    my $auth_redirect = read_conf_key('auth_redirect') || '/login';
    my $ip            = $ENV{REMOTE_ADDR} // '';

    # H-3: per-IP rate limit before checking credentials (fail-closed on ok).
    unless ( check_login_rate($ip) ) {
        log_event( 'WARN', $username, 'login rate limit exceeded', ip => $ip );
        _audit_auth( $username, 'login', 'fail', 'rate-limited' );
        sleep $LOGIN_DELAY;
        redirect("$auth_redirect?error=rate");
        return;
    }

    unless ( length $username ) {
        log_event( 'WARN', $username, 'login failed', ip => $ip );
        _audit_auth( $username, 'login', 'fail', 'invalid-credentials' );
        sleep $LOGIN_DELAY;
        redirect("$auth_redirect?error=1");
        return;
    }

    my $users    = load_users();
    my $expected = $users->{$username};

    unless ( defined $expected ) {
        log_event( 'WARN', $username, 'login failed', ip => $ip );
        _audit_auth( $username, 'login', 'fail', 'invalid-credentials' );
        sleep $LOGIN_DELAY;
        redirect("$auth_redirect?error=1");
        return;
    }

    if ( !length $expected ) {
        # No-password account: only allowed from localhost
        my $addr = $ENV{REMOTE_ADDR} // '';
        unless ( $addr eq '127.0.0.1' || $addr eq '::1' ) {
            log_event( 'WARN', $username, 'no-password login refused (not localhost)', ip => $addr );
            _audit_auth( $username, 'login', 'fail', 'no-password-remote' );
            reject_no_password();
            return;
        }
        log_event( 'INFO', $username, 'no-password login (localhost)', ip => $addr );
        _audit_auth( $username, 'login', 'ok', 'no-password' );
    }
    else {
        # H-2: verify_password handles both legacy (unsalted) and new
        # (sha256iter) formats. Legacy hashes are auto-rehashed on
        # successful login.
        unless ( length $password && verify_password( $password, $expected ) ) {
            log_event( 'WARN', $username, 'login failed', ip => $ip );
            _audit_auth( $username, 'login', 'fail', 'invalid-credentials' );
            sleep $LOGIN_DELAY;
            redirect("$auth_redirect?error=1");
            return;
        }
        if ( $expected =~ /\A[0-9a-f]{64}\z/ ) {
            my $new_hash = hash_password($password);
            if ( update_user_hash( $username, $new_hash ) ) {
                log_event( 'INFO', $username, 'password rehashed to salted format' );
            }
        }
    }

    # SM070: enforce the per-user `ui` access mechanism. Placed after
    # credential verification (both the verified-password and the
    # localhost no-password branches converge here), so it leaks
    # nothing to a password guesser - an attacker without the password
    # never reaches it. A ui-disabled account never receives a cookie,
    # which keeps it out of the manager UI, the manager API, and
    # auth-protected pages alike.
    # SM071 Phase 2: a disabled account fails authentication outright,
    # ahead of the ui mechanism check. After credential verification, so
    # it leaks nothing to a password guesser.
    if ( account_disabled($username) ) {
        log_event( 'WARN', $username, 'login refused: account disabled', ip => $ip );
        _audit_auth( $username, 'login', 'fail', 'account-disabled' );
        redirect("$auth_redirect?error=1");
        return;
    }

    # SM071 Phase 2: an expired access-token credential cannot start a
    # session (a human password has no expiry, so this never affects them).
    if ( token_expired($username) ) {
        log_event( 'WARN', $username, 'login refused: credential expired', ip => $ip );
        _audit_auth( $username, 'login', 'fail', 'credential-expired' );
        redirect("$auth_redirect?error=1");
        return;
    }

    # SM072: account-level expiry (time-boxed access)
    if ( account_expired($username) ) {
        log_event( 'WARN', $username, 'login refused: account expired', ip => $ip );
        _audit_auth( $username, 'login', 'fail', 'account-expired' );
        redirect("$auth_redirect?error=1");
        return;
    }

    unless ( ui_enabled($username) ) {
        log_event( 'WARN', $username, 'interactive login disabled for account', ip => $ip );
        _audit_auth( $username, 'login', 'fail', 'ui-disabled' );
        reject_ui_disabled();
        return;
    }

    # SM072 batch 4: second factor. If TOTP is enrolled, a valid code (or a
    # single-use recovery code) is required before a cookie issues. After
    # password + ui verification, so it leaks nothing to a password guesser.
    if ( mfa_enrolled($username) ) {
        my $code = $form{code} // '';
        $code =~ s/[^0-9A-Za-z-]//g;
        my $v = users_tool_api( { action => 'mfa-verify', username => $username, code => $code } );
        unless ( ref $v eq 'HASH' && $v->{ok} ) {
            log_event( 'WARN', $username, 'login refused: 2FA required or invalid', ip => $ip );
            _audit_auth( $username, 'login', 'fail', 'mfa' );
            sleep $LOGIN_DELAY;
            redirect("$auth_redirect?error=mfa");
            return;
        }
    }

    # Load groups for user
    my $groups_str = load_user_groups($username);

    # Generate signed cookie. SM141: the payload carries a short random
    # session id (user:ts:sid:groups) so this session can be listed and
    # revoked individually. Legacy 3-field cookies (user:ts:groups) minted
    # before SM141 stay valid until natural expiry - see handle_request.
    my $ts      = time();
    my $sid     = generate_random_hex(8);                  # 16 hex chars
    my $secret  = load_auth_secret();
    my $payload = "$username:$ts:$sid:$groups_str";
    my $sig     = hmac_sha256_hex( $payload, $secret );
    my $cookie  = uri_encode_simple($payload) . ":$sig";

    # SM141: record the session in the registry (listing metadata only -
    # losing the file degrades the Sessions page, never authentication).
    # A registry failure must NEVER block a valid login: eval-guard + WARN.
    eval { _session_register( $username, $ts, $sid ); 1 }
        or log_event( 'WARN', $username, 'session registry write failed', error => "$@" );

    my $secure = $ENV{HTTPS} ? '; Secure' : '';

    log_event( 'INFO', $username, 'login success', ip => $ENV{REMOTE_ADDR} // '' );
    _audit_auth( $username, 'login', 'ok', '' );

    # Manager-aware landing: a recognised manager who did not come from a specific
    # page (next defaulted to home) lands in the manager UI instead of the public
    # home, so they always have a way in. Only when the manager UI is enabled.
    if ( $next eq '/'
        && ( read_conf_key('manager') // '' ) eq 'enabled'
        && _login_is_manager($groups_str) )
    {
        $next = '/manager/';
    }

    binmode( STDOUT, ':utf8' );
    print "Status: 302 Found\r\n";
    print "Content-Type: text/html; charset=utf-8\r\n";    # SM353
    print "Set-Cookie: $COOKIE_NAME=$cookie; HttpOnly; SameSite=Lax; Path=/; Max-Age=$COOKIE_MAX$secure\r\n";
    # SM099: a non-HttpOnly display-only marker so client JS can show the right
    # sign-in/out control without trusting cached HTML. Carries no authority - the
    # HttpOnly cookie above remains the gate.
    print "Set-Cookie: lzs_session=1; SameSite=Lax; Path=/; Max-Age=$COOKIE_MAX$secure\r\n";
    print "Location: $next\r\n\r\n";
    return;
}

# The user of a VALID session cookie, or '' if there is no valid session. auth.pl
# handles ?action=logout directly (not behind the wrapper), so HTTP_X_REMOTE_USER
# is not set here - validate the cookie ourselves.
sub _session_user { return ( _session_identity() )[0] }

# Verify the session cookie and return ( $user, $sid ) - $sid is '' for a
# legacy (pre-SM141) user:ts:groups cookie. Returns ( '', '' ) if the cookie is
# absent, unsigned, tampered, or expired.
sub _session_identity {
    my $cookie = read_cookie($COOKIE_NAME);
    return ( '', '' ) unless $cookie;
    my ( $payload, $sig ) = $cookie =~ /^(.+):([a-f0-9]{64})$/;
    return ( '', '' ) unless $payload && $sig;
    $payload = uri_decode_simple($payload);
    my $secret = load_auth_secret();
    return ( '', '' ) unless const_eq( $sig, hmac_sha256_hex( $payload, $secret ) );
    # SM141: user and ts lead BOTH payload shapes (user:ts:sid:groups and the
    # legacy user:ts:groups); the sid is the 3rd field ONLY in the 4-field shape
    # (exactly 16 hex), else it is the legacy groups field and not a sid.
    my ( $user, $ts, $third ) = split /:/, $payload, 4;
    return ( '', '' )
        unless defined $ts && $ts =~ /^\d+$/ && ( time() - $ts ) < $COOKIE_MAX;
    my $sid = ( defined $third && $third =~ /\A[0-9a-f]{16}\z/ ) ? $third : '';
    return ( $user // '', $sid );
}

sub handle_logout {
    my ( $user, $sid ) = _session_identity();
    # Only audit a real logout (a valid session). An unauthenticated hit on
    # ?action=logout - common from vulnerability scanners - must write no audit
    # noise; and a genuine logout now records the actual username (not the empty
    # HTTP_X_REMOTE_USER it used to read on this direct call).
    if ( length $user ) {
        log_event( 'INFO', $user, 'logout', ip => $ENV{REMOTE_ADDR} // '' );
        _audit_auth( $user, 'logout', 'ok', '' );

        # SEC-2026-07 (M4): actually invalidate the session server-side, not just
        # clear the browser cookie - otherwise a cookie captured before logout
        # keeps authenticating for the full 24h TTL. Add this sid to the revoked
        # set (the same mechanism an operator's session-revoke uses; enforced in
        # the cookie-verify path above). A legacy cookie carries no sid, so it
        # cannot be revoked individually - it still ages out at COOKIE_MAX.
        if ( length $sid ) {
            require Lazysite::Manager::Sessions;
            local $Lazysite::Manager::Sessions::LAZYSITE_DIR = $LAZYSITE_DIR;
            local $Lazysite::Manager::Sessions::auth_user    = $user;
            my $r = Lazysite::Manager::Sessions::action_session_revoke($sid);
            log_event( 'WARN', $user, 'logout: session revoke failed',
                error => $r->{error} )
                if ref $r eq 'HASH' && !$r->{ok};
        }
    }

    my $secure = $ENV{HTTPS} ? '; Secure' : '';

    binmode( STDOUT, ':utf8' );
    print "Status: 302 Found\r\n";
    print "Content-Type: text/html; charset=utf-8\r\n";    # SM353
    print "Set-Cookie: $COOKIE_NAME=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0$secure\r\n";
    print "Set-Cookie: lzs_session=; SameSite=Lax; Path=/; Max-Age=0$secure\r\n"; # SM099 marker
    print "Location: /logout\r\n\r\n";
}

# SM072: public claim redemption. The holder of a single-use setup/reset
# claim sets their own credential here - the operator never sees it. The
# claim token IS the authentication; we shell to the (tested) users-tool
# claim-redeem, which returns ONE generic error on any failure.
sub handle_claim {
    my %form     = parse_post();
    my $username = $form{username} // '';
    $username =~ s/[^a-zA-Z0-9_.-]//g;
    $username = substr( $username, 0, 64 ) if length($username) > 64;
    my $claim = $form{claim} // '';
    $claim =~ s/[^a-zA-Z0-9_]//g;
    my $password = $form{password}   // '';
    my $ip       = $ENV{REMOTE_ADDR} // '';

    # HTTPS-only (setting a secret); localhost allowed for dev/CLI.
    unless ( $ENV{HTTPS} || $ip eq '127.0.0.1' || $ip eq '::1' ) {
        log_event( 'WARN', $username, 'claim over plaintext refused', ip => $ip );
        redirect("/claim?u=$username&error=1");
        return;
    }

    # H-3: reuse the per-IP login rate limiter.
    unless ( check_login_rate($ip) ) {
        sleep $LOGIN_DELAY;
        redirect("/claim?u=$username&error=1");
        return;
    }

    my $r = users_tool_api( {
            action => 'claim-redeem', username => $username,
            claim  => $claim,         password => $password,
    } );

    unless ( ref $r eq 'HASH' && $r->{ok} ) {
        sleep $LOGIN_DELAY;
        log_event( 'WARN', $username, 'claim redeem failed', ip => $ip );
        _audit_auth( $username, 'claim-redeem', 'fail', '' );
        redirect("/claim?u=$username&error=1");
        return;
    }

    log_event( 'INFO', $username, 'claim redeemed', ip => $ip );
    _audit_auth( $username, 'claim-redeem', 'ok', '' );
    if ( $r->{token} ) {
        claim_token_page( $username, $r->{token} );    # machine: show token once
    }
    else {
        my $auth_redirect = read_conf_key('auth_redirect') || '/login';
        redirect("$auth_redirect?claimed=1");          # human: go sign in
    }
    return;
}

# Show a freshly-minted token once (a mint-token claim was redeemed).
sub claim_token_page {
    my ( $user, $token ) = @_;
    $user  =~ s/[^a-zA-Z0-9_.-]//g;
    $token =~ s/[^a-zA-Z0-9_]//g;
    binmode( STDOUT, ':utf8' );
    print "Status: 200 OK\r\n";
    print "Content-Type: text/html; charset=utf-8\r\n\r\n";
    print <<"HTML";
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Credential</title></head>
<body style="font-family:system-ui,sans-serif;max-width:560px;margin:3em auto;padding:0 1em;">
<h1 style="font-size:1.3rem;">Your credential for $user</h1>
<p>Store this now &mdash; it is shown once and cannot be retrieved again. Use it
as the password for WebDAV / API requests (username: <code>$user</code>).</p>
<p style="font-family:ui-monospace,Menlo,Consolas,monospace;background:#f0f0f0;padding:0.6em 0.8em;border-radius:4px;word-break:break-all;">$token</p>
</body></html>
HTML
    return;
}

# Locate the users tool (same candidates as the manager API).
sub _users_tool_path {
    for my $c (
        $ENV{LAZYSITE_USERS_TOOL},
        dirname($0) . "/../tools/lazysite-users.pl",
        "$DOCROOT/../tools/lazysite-users.pl",
    ) {
        return $c if defined $c && -f $c;
    }
    return undef;
}

# Invoke the users tool in --api mode with a JSON payload; return the
# decoded response (or undef on any failure).
sub users_tool_api {
    my ($payload) = @_;
    my $tool = _users_tool_path() or return undef;
    require JSON::PP;
    my ( $out, $in );
    my $pid = eval { open2( $out, $in, $^X, $tool, '--api', '--docroot', $DOCROOT ) };
    return undef unless $pid;
    print $in JSON::PP::encode_json($payload);
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return eval { JSON::PP::decode_json( $resp // '{}' ) };
}

# Service killswitch (0.9.0): the AI-partner token surface (pairing-key exchange
# + token rotation) is OFF unless the operator enables it in lazysite.conf
# (token_exchange_enabled: true), mirroring webdav_enabled. Default off; opt in
# from the Services page.
sub _require_token_exchange {
    return if Lazysite::Util::service_enabled( $DOCROOT, 'token_exchange_enabled' );
    # NOT 404: a 404 reads as "endpoint absent / not deployed" and sent a real
    # field diagnosis down the wrong path (redeploy, re-check routing) when the
    # feature was merely switched off. Match the control API's shape - a 200 body
    # with ok:0 + a stable machine-readable code - so a client branches on the
    # payload, never on a misleading status.
    json_response( { ok => 0, code => 'service_disabled',
            error => 'Token exchange is not enabled on this site '
                . '(ask the operator to enable it: Services -> AI partner tokens).' }, 200 );
    exit 0;
}

# Emit a JSON body with an HTTP status (the control token-lifecycle paths).
sub json_response {
    my ( $data, $code ) = @_;
    $code ||= 200;
    require JSON::PP;
    binmode( STDOUT, ':utf8' );
    print "Status: $code\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print JSON::PP::encode_json($data);
    return;
}

# SM072 Flow C: public pairing-key -> access-token exchange. The agent
# presents its single-use pairing key and receives {token, expires_at}.
sub handle_exchange {
    my %form     = parse_post();
    my $username = $form{username} // '';
    $username =~ s/[^a-zA-Z0-9_.-]//g;
    my $key = $form{pairing_key} // $form{key} // '';
    $key =~ s/[^a-zA-Z0-9_]//g;
    my $ip = $ENV{REMOTE_ADDR} // '';

    unless ( $ENV{HTTPS} || $ip eq '127.0.0.1' || $ip eq '::1' ) {
        json_response( { ok => 0, error => 'HTTPS required' }, 403 );
        return;
    }
    unless ( check_login_rate($ip) ) {
        sleep $LOGIN_DELAY;
        json_response( { ok => 0, error => 'Too many attempts' }, 429 );
        return;
    }

    my $r = users_tool_api( {
            action => 'token-exchange', username => $username, pairing_key => $key,
    } );
    unless ( ref $r eq 'HASH' && $r->{ok} ) {
        sleep $LOGIN_DELAY;
        log_event( 'WARN', $username, 'pairing exchange failed', ip => $ip );
        json_response( { ok => 0, error => 'Invalid or expired pairing key' }, 401 );
        return;
    }
    log_event( 'INFO', $username, 'access token issued (HTTP exchange)', ip => $ip );
    _audit_auth( $username, 'token-exchange', 'ok', '', 'api' );
    json_response( { ok => 1, token => $r->{token}, expires_at => $r->{expires_at} }, 200 );
    return;
}

# SM072 Flow C: rotate the access token. The agent authenticates with its
# CURRENT token (Basic auth) and receives a fresh {token, expires_at}.
sub handle_rotate {
    my $ip = $ENV{REMOTE_ADDR} // '';
    unless ( $ENV{HTTPS} || $ip eq '127.0.0.1' || $ip eq '::1' ) {
        json_response( { ok => 0, error => 'HTTPS required' }, 403 );
        return;
    }
    my ( $u, $token );
    if ( ( $ENV{HTTP_AUTHORIZATION} // '' ) =~ /^Basic\s+(\S+)/ ) {
        require MIME::Base64;
        ( $u, $token ) = split /:/, ( MIME::Base64::decode_base64($1) // '' ), 2;
    }
    unless ( defined $u && length $u && defined $token && $token =~ /^lzs_/ ) {
        json_response( { ok => 0, error => 'Token authentication required' }, 401 );
        return;
    }
    $u =~ s/[^a-zA-Z0-9_.-]//g;
    unless ( check_login_rate($ip) ) {
        sleep $LOGIN_DELAY;
        json_response( { ok => 0, error => 'Too many attempts' }, 429 );
        return;
    }
    my $v = users_tool_api( { action => 'verify-credential', username => $u, secret => $token } );
    unless ( ref $v eq 'HASH' && $v->{ok} ) {
        sleep $LOGIN_DELAY;
        # An EXPIRED (but correct) token can't rotate itself - the agent must
        # re-exchange a fresh pairing key. Give that guidance instead of a bare
        # "Invalid token" (the diagnosis a partner agent had to do by hand).
        if ( ref $v eq 'HASH' && ( $v->{reason} // '' ) eq 'expired' ) {
            log_event( 'INFO', $u, 'token rotation: token expired', ip => $ip );
            json_response( {
                    ok     => 0,
                    reason => 'expired',
                    error  => 'Your access token has expired and cannot be rotated. '
                        . 'Ask the operator for a new pairing key and exchange it '
                        . '(POST action=exchange with the pairing key).',
            }, 401 );
            return;
        }
        log_event( 'WARN', $u, 'token rotation: invalid current token', ip => $ip );
        json_response( { ok => 0, error => 'Invalid token' }, 401 );
        return;
    }
    my $r = users_tool_api( { action => 'token-rotate', username => $u } );
    unless ( ref $r eq 'HASH' && $r->{ok} ) {
        json_response( { ok => 0, error => 'Rotation failed' }, 500 );
        return;
    }
    log_event( 'INFO', $u, 'access token rotated (HTTP)', ip => $ip );
    _audit_auth( $u, 'token-rotate', 'ok', '', 'api' );
    json_response( { ok => 1, token => $r->{token}, expires_at => $r->{expires_at} }, 200 );
    return;
}

# SM072 batch 2: forgot-password. Mint a set-password claim and email the
# link to the account's registered address - gated on SMTP being configured
# and the account having an email. ALWAYS a generic response, so it cannot
# enumerate accounts or emails.
sub handle_forgot {
    my %form  = parse_post();
    my $ident = $form{identifier} // $form{username} // $form{email} // '';
    $ident =~ s/^\s+|\s+$//g;
    my $ip            = $ENV{REMOTE_ADDR} // '';
    my $auth_redirect = read_conf_key('auth_redirect') || '/login';

    if ( check_login_rate($ip) ) {
        eval { _forgot_dispatch( $ident, $ip ); 1 };
    }
    else { sleep $LOGIN_DELAY }

    redirect("$auth_redirect?reset=1");    # generic, always
    return;
}

sub _forgot_dispatch {
    my ( $ident, $ip ) = @_;
    return unless length $ident;

    # SM136: without SMTP the self-service email can't go out, so this request
    # would otherwise dead-end silently while a person waits. Tell the operators
    # (bell + XMPP if configured) so a human can respond. Real accounts only -
    # an unknown identifier stays generic (no notice, no enumeration signal).
    unless ( -f "$LAZYSITE_DIR/forms/smtp.conf" ) {
        my ($user) = _resolve_account($ident);
        if ( $user && !account_disabled($user) ) {
            require Lazysite::Notify;
            Lazysite::Notify::notify( $DOCROOT, {
                    type    => 'reset-request',
                    message => "Password reset requested for '$user' - no SMTP is "
                        . 'configured, so no email was sent. Issue them a setup link '
                        . 'from the Users page.',
                    target => $user,
                    url    => "/manager/users?user=$user",
            } );
            _audit_auth( $user, 'forgot', 'ok', 'reset requested; no SMTP - operators notified', 'ui' );
        }
        return;
    }

    my ( $user, $email ) = _resolve_account($ident);
    return unless $user && $email;
    return if account_disabled($user);
    return unless ui_enabled($user);    # interactive accounts only

    my $r = users_tool_api( { action => 'claim-create', username => $user } );
    return unless ref $r eq 'HASH' && $r->{ok} && $r->{claim};

    my $scheme = $ENV{HTTPS} ? 'https' : 'http';
    my $host   = $ENV{HTTP_HOST} // '';
    _send_setup_email( $email, $user, "$scheme://$host/claim?u=$user&c=$r->{claim}" );
    log_event( 'INFO', $user, 'forgot-password claim emailed', ip => $ip );
    # SM072: a real reset link was issued - a material auth event. (The HTTP
    # response stays generic; only the internal audit trail records the match.)
    _audit_auth( $user, 'forgot', 'ok', 'reset link emailed', 'ui' );
    return;
}

# Resolve a username or email to (username, email) from user-settings.json.
sub _resolve_account {
    my ($ident) = @_;
    my $path = "$AUTH_DIR/user-settings.json";
    return () unless -f $path;
    # ALL user-settings.json readers in this file open :raw - decode_json
    # takes octets, and a :utf8 handle made it die on any non-ASCII byte,
    # silently failing every gate below OPEN (2026-07-10 review, D1).
    open my $fh, '<:raw', $path or return ();
    my $raw = do { local $/; <$fh> };
    close $fh;
    require JSON::PP;
    my $data = eval { JSON::PP::decode_json( $raw // '{}' ) } || {};
    return () unless ref $data eq 'HASH';
    if ( $ident =~ /\@/ ) {
        for my $u ( sort keys %$data ) {
            my $s = $data->{$u};
            return ( $u, $s->{email} )
                if ref $s eq 'HASH' && lc( $s->{email} // '' ) eq lc($ident);
        }
        return ();
    }
    $ident =~ s/[^a-zA-Z0-9_.-]//g;
    my $s = $data->{$ident};
    return () unless ref $s eq 'HASH' && $s->{email};
    return ( $ident, $s->{email} );
}

# Send the setup link by invoking the form-smtp plugin (--pipe).
sub _send_setup_email {
    my ( $to, $user, $link ) = @_;
    my $smtp;
    for my $c ( dirname($0) . "/../plugins/form-smtp.pl",
        "$DOCROOT/../plugins/form-smtp.pl",
        "$DOCROOT/plugins/form-smtp.pl" ) {
        if ( -f $c ) { $smtp = $c; last }
    }
    return unless $smtp;
    require JSON::PP;
    my $payload = JSON::PP::encode_json( {
            config => { to => $to, subject_prefix => 'Set your password - ' },
            form   => { message =>
                    "A password setup link was requested for '$user'.\n\n"
                    . "Open this one-time link (it expires in 24 hours) to set your password:\n\n"
                    . "$link\n\n"
                    . "If you did not request this, you can ignore this email." },
    } );
    my ( $out, $in );
    my $pid = eval { open2( $out, $in, $^X, $smtp, '--pipe' ) };
    return unless $pid;
    print $in $payload;
    close $in;
    do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    return;
}

sub handle_request {
    my $cookie = read_cookie($COOKIE_NAME);

    if ( !$cookie ) {
        log_event( 'INFO', $uri, 'auth: no cookie' );
    }
    else {
        my ( $payload, $sig ) = $cookie =~ /^(.+):([a-f0-9]{64})$/;
        if ( !( $payload && $sig ) ) {
            log_event( 'WARN', $uri, 'auth: cookie malformed' );
        }
        else {
            $payload = uri_decode_simple($payload);
            my $secret   = load_auth_secret();
            my $expected = hmac_sha256_hex( $payload, $secret );

            # M-5: constant-time signature comparison
            unless ( const_eq( $sig, $expected ) ) {
                log_event( 'WARN', $uri, 'auth: signature mismatch' );
            }
            else {
                # SM141: two payload shapes are valid. Current cookies are
                # user:ts:sid:groups (sid exactly 16 hex); legacy cookies
                # minted before the session registry are user:ts:groups and
                # stay valid until natural expiry. Groups can contain commas
                # but never colons, so a limit-4 split plus the sid shape
                # check disambiguates.
                my @f = split /:/, $payload, 4;
                my ( $user, $ts, $sid, $groups );
                if ( @f == 4 && defined $f[2] && $f[2] =~ /\A[0-9a-f]{16}\z/ ) {
                    ( $user, $ts, $sid, $groups ) = @f;
                }
                else {
                    ( $user, $ts, $groups ) = split /:/, $payload, 3;
                    $sid = '';
                }
                $groups //= '';

                if ( !defined $ts || $ts !~ /^\d+$/ || ( time() - $ts ) >= $COOKIE_MAX ) {
                    log_event( 'WARN', $uri, 'auth: cookie expired or malformed ts', ts => $ts // 'undef' );
                }
                elsif ( account_disabled($user) ) {
                    # SM071: reject an existing cookie for a now-disabled
                    # account; no trusted headers are set, so the request is
                    # treated as unauthenticated.
                    log_event( 'WARN', $uri, 'auth: account disabled', user => $user );
                }
                elsif ( _session_revoked( $user, $ts, $sid ) ) {
                    # SM141: an operator signed this session out (revoked
                    # sid) or signed the user out everywhere (not_before).
                    # No trusted headers are set, so the request is treated
                    # as unauthenticated. Legacy cookies carry no sid but do
                    # carry ts, so not_before kills them too.
                    log_event( 'WARN', $uri, 'auth: session revoked', user => $user );
                }
                else {
                    # C-1: these headers come from our HMAC-verified cookie,
                    # not from the client. Set LAZYSITE_AUTH_TRUSTED=1 so
                    # the processor accepts them.
                    $ENV{HTTP_X_REMOTE_USER} = $user;

                    # SEC-2026-07 (M5): re-resolve the account's CURRENT group
                    # membership per request rather than trusting the (HMAC-
                    # signed but possibly stale) groups baked into the cookie at
                    # login - otherwise a demoted admin keeps privileged groups
                    # until the cookie expires (up to 24h). The groups file is
                    # the same source of truth login reads, so a promotion also
                    # takes effect immediately.
                    $ENV{HTTP_X_REMOTE_GROUPS}  = load_user_groups($user);
                    $ENV{LAZYSITE_AUTH_TRUSTED} = '1';

                    # SM141: pass the caller's session id to the children
                    # (processor / manager-api) so the Sessions page can mark
                    # "this session". A legacy cookie has none.
                    $ENV{LAZYSITE_AUTH_SID} = $sid if length $sid;

                    # Flag passwordless accounts so the admin bar can warn.
                    # Checked per-request so setting a password clears it immediately.
                    my $users = load_users();
                    $ENV{LAZYSITE_AUTH_NO_PASSWORD} = '1'
                        if exists $users->{$user} && !length $users->{$user};

                    log_event( 'INFO', $uri, 'auth: cookie valid', user => $user, groups => $groups );
                }
            }
        }
    }

    # Exec processor. LAZYSITE_PROCESSOR names the real CGI target (the
    # dev server and the Apache cgi-bin->auth rewrite thread it through so
    # the manager-api etc. run behind the wrapper). Apache may surface a
    # mod_rewrite [E=] var REDIRECT_-prefixed after a passthrough, so accept
    # either spelling before falling back to the processor.
    my $processor = $ENV{LAZYSITE_PROCESSOR}
        // $ENV{REDIRECT_LAZYSITE_PROCESSOR}
        // "$DOCROOT/../cgi-bin/lazysite-processor.pl";

    # SEC-2026-07 (H7): never exec ourselves. A direct request to
    # lazysite-auth.pl with no ?action (notably a bare POST) reaches this
    # passthrough with LAZYSITE_PROCESSOR pointing back at this wrapper; exec'ing
    # it would re-enter with the same env and loop forever, wedging a
    # single-threaded server. Refuse with a 400 instead.
    my $self      = Cwd::abs_path(__FILE__)   // '';
    my $proc_real = Cwd::abs_path($processor) // $processor;
    if ( length $self && $proc_real eq $self ) {
        log_event( 'WARN', $uri, 'auth: refusing self-exec (no action)',
            method => $method );
        print "Status: 400 Bad Request\r\n";
        print "Content-Type: text/plain; charset=utf-8\r\n\r\n";
        print "lazysite-auth: no action. Use ?action=login or ?action=logout.\n";
        exit 0;
    }

    exec $^X, $processor;
    die "exec failed: $!\n";
}

# --- Data ---

sub load_users {
    my $path = "$AUTH_DIR/users";
    return {} unless -f $path;

    open( my $fh, '<:utf8', $path ) or return {};
    my %users;
    while (<$fh>) {
        chomp;
        s/^\s+|\s+$//g;
        next if /^#/ || !length;
        my ( $user, $hash ) = split /:/, $_, 2;
        $users{$user} = $hash if defined $user && defined $hash;
    }
    close $fh;
    return \%users;
}

# SM070: per-user `ui` access mechanism. Defaults to on (accounts with
# no settings row behave exactly as before SM070). A corrupt settings
# file fails open for ui - matching pre-SM070 behaviour so a damaged
# file cannot lock the operator out of the manager - and the WARN
# surfaces the problem. The settings file is written only by
# tools/lazysite-users.pl; this is a read-only consumer.
sub ui_enabled {
    my ($username) = @_;
    my $path = "$AUTH_DIR/user-settings.json";
    return 1 unless -f $path;

    open my $fh, '<:raw', $path or return 1;
    my $raw = do { local $/; <$fh> };
    close $fh;

    require JSON::PP;
    my $data = eval { JSON::PP::decode_json( $raw // '{}' ) };
    if ( !$data || ref $data ne 'HASH' ) {
        log_event( 'WARN', $username, 'user-settings.json unparseable; ui defaults on' );
        return 1;
    }
    my $s = $data->{$username};
    return 1 unless ref $s eq 'HASH' && exists $s->{ui};
    return $s->{ui} ? 1 : 0;
}

# SM071 Phase 2: a disabled account fails authentication everywhere.
# Read-only consumer of user-settings.json (written by
# tools/lazysite-users.pl). Fails open (not disabled) on a missing or
# corrupt file, matching ui_enabled, so a damaged file cannot lock the
# operator out.
sub account_disabled {
    my ($username) = @_;
    my $path = "$AUTH_DIR/user-settings.json";
    return 0 unless -f $path;
    open my $fh, '<:raw', $path or return 0;
    my $raw = do { local $/; <$fh> };
    close $fh;
    require JSON::PP;
    my $data = eval { JSON::PP::decode_json( $raw // '{}' ) };
    return 0 unless ref $data eq 'HASH';
    my $s = $data->{$username};
    return ( ref $s eq 'HASH' && $s->{disabled} ) ? 1 : 0;
}

# SM071 Phase 2: a credential with an access-token expiry in the past is
# treated as invalid. Read-only consumer; fails open (not expired) on a
# missing/corrupt file, matching the other settings consumers here.
sub token_expired {
    my ($username) = @_;
    my $path = "$AUTH_DIR/user-settings.json";
    return 0 unless -f $path;
    open my $fh, '<:raw', $path or return 0;
    my $raw = do { local $/; <$fh> };
    close $fh;
    require JSON::PP;
    my $data = eval { JSON::PP::decode_json( $raw // '{}' ) };
    return 0 unless ref $data eq 'HASH';
    my $s = $data->{$username};
    return 0 unless ref $s eq 'HASH' && $s->{token_expires_at};
    return time() > $s->{token_expires_at} ? 1 : 0;
}

# SM072: account-level expiry (time-boxed access). After expires_at the
# whole account fails authentication, whatever credential it holds.
sub account_expired {
    my ($username) = @_;
    my $path = "$AUTH_DIR/user-settings.json";
    return 0 unless -f $path;
    open my $fh, '<:raw', $path or return 0;
    my $raw = do { local $/; <$fh> };
    close $fh;
    require JSON::PP;
    my $data = eval { JSON::PP::decode_json( $raw // '{}' ) };
    return 0 unless ref $data eq 'HASH';
    my $s = $data->{$username};
    return 0 unless ref $s eq 'HASH' && $s->{expires_at};
    return time() > $s->{expires_at} ? 1 : 0;
}

# SM072 batch 4: is TOTP enrolled for this account?
sub mfa_enrolled {
    my ($username) = @_;
    my $path = "$AUTH_DIR/user-settings.json";
    return 0 unless -f $path;
    open my $fh, '<:raw', $path or return 0;
    my $raw = do { local $/; <$fh> };
    close $fh;
    require JSON::PP;
    my $data = eval { JSON::PP::decode_json( $raw // '{}' ) };
    return 0 unless ref $data eq 'HASH';
    my $s = $data->{$username};
    # SM148: a PENDING (unconfirmed) enrolment does not enforce 2FA - the user
    # has not yet proved their authenticator works, so it must not gate login.
    return ( ref $s eq 'HASH' && $s->{totp_secret} && !$s->{mfa_pending} ) ? 1 : 0;
}

# SM141: attacker-controlled field -> safe registry string (control chars
# stripped against log injection, length-capped). The wrapper's own small
# copy of the SM140 recorder's sanitisation pattern (_access_field in
# lazysite-processor.pl) - kept local so the wrapper stays self-contained;
# JSON escaping is JSON::PP's job here, so no _json_str step.
sub _session_field {
    my ( $s, $cap ) = @_;
    $s //= '';
    $s =~ s/[\x00-\x1f\x7f]//g;
    $s = substr( $s, 0, $cap ) if length($s) > $cap;
    return $s;
}

# SM141: append one {sid, user, t, ip, ua} line to the session registry
# (lazysite/auth/sessions.jsonl - advisory listing metadata, never on the
# per-request path). Self-prunes on write: entries older than COOKIE_MAX are
# dead by definition, so when any line has aged out the file is rewritten
# keeping only fresh lines (atomic temp+rename, 0660) and stays tiny
# (~ logins per day). Dies on IO failure; the caller eval-guards.
sub _session_register {
    my ( $user, $ts, $sid ) = @_;
    my $path = "$AUTH_DIR/sessions.jsonl";
    require JSON::PP;
    my $line = JSON::PP::encode_json( {
            sid  => $sid,
            user => $user,
            t    => $ts + 0,
            ip   => _session_field( $ENV{REMOTE_ADDR},     45 ),
            ua   => _session_field( $ENV{HTTP_USER_AGENT}, 120 ),
    } ) . "\n";

    my $cutoff = $ts - $COOKIE_MAX;
    my ( @keep, $stale );
    if ( open my $rfh, '<:raw', $path ) {
        while ( my $l = <$rfh> ) {
            my ($t) = $l =~ /"t":(\d+)/;
            if ( defined $t && $t <= $cutoff ) { $stale = 1; next }
            push @keep, $l;
        }
        close $rfh;
    }

    if ($stale) {
        my $tmp = "$path.tmp.$$";
        open my $wfh, '>:raw', $tmp or die "cannot write $tmp: $!\n";
        chmod 0o660, $tmp;
        print {$wfh} @keep, $line;
        close $wfh or die "cannot finish $tmp: $!\n";
        rename $tmp, $path or do { my $e = $!; unlink $tmp; die "cannot replace $path: $e\n" };
        return 1;
    }

    my $is_new = !-e $path;
    sysopen( my $afh, $path, O_WRONLY | O_APPEND | O_CREAT, 0o660 )
        or die "cannot append $path: $!\n";
    binmode $afh;
    syswrite( $afh, $line );
    close $afh;
    chmod 0o660, $path if $is_new;    # sysopen's mode is umask-masked
    return 1;
}

# SM141: is this (user, ts, sid) revoked? FAST PATH: no revoked.json = a
# single -f stat and nothing is revoked (the bad-url-blocker precedent);
# a present file is one tiny JSON read. Reject when the sid is in the
# revoked set, or the cookie was issued before the user's not_before (which
# also kills legacy pre-sid cookies - they carry ts). Unreadable/corrupt
# file = treat as EMPTY but WARN loudly (the spec's fail-open-with-alarm
# decision: a corrupt file must not lock everyone out; lazysite-check
# probes the file so the alarm is actionable).
sub _session_revoked {
    my ( $user, $ts, $sid ) = @_;
    my $path = "$AUTH_DIR/revoked.json";
    return 0 unless -f $path;

    my $data;
    if ( open my $fh, '<:raw', $path ) {
        my $raw = do { local $/; <$fh> };
        close $fh;
        require JSON::PP;
        $data = eval { JSON::PP::decode_json( $raw // '' ) };
    }
    unless ( ref $data eq 'HASH' ) {
        log_event( 'WARN', $user,
            'revoked.json unreadable or corrupt - treating as empty (NO session is revoked); '
                . 'run lazysite-check and repair or remove the file' );
        return 0;
    }

    my $sids = ref $data->{sids} eq 'HASH' ? $data->{sids} : {};
    return 1 if length($sid) && exists $sids->{$sid};

    my $nb = ref $data->{not_before} eq 'HASH' ? $data->{not_before} : {};
    return 1
        if defined $nb->{$user}
        && $nb->{$user} =~ /^\d+$/
        && $ts < $nb->{$user};
    return 0;
}

sub load_user_groups {
    my ($username) = @_;
    my $path = "$AUTH_DIR/groups";
    return '' unless -f $path;

    open( my $fh, '<:utf8', $path ) or return '';
    my @groups;
    while (<$fh>) {
        chomp;
        s/^\s+|\s+$//g;
        next if /^#/ || !length;
        my ( $group, $members ) = split /:\s*/, $_, 2;
        next unless defined $members;
        my @m = map { s/^\s+|\s+$//gr } split /,/, $members;
        push @groups, $group if grep { $_ eq $username } @m;
    }
    close $fh;
    return join( ',', @groups );
}

sub load_auth_secret {
    my $path = "$AUTH_DIR/.secret";
    make_path($AUTH_DIR) unless -d $AUTH_DIR;

    if ( -f $path ) {
        open( my $fh, '<', $path ) or die "Cannot read auth secret\n";
        chomp( my $s = <$fh> );
        close $fh;
        return $s if $s;
    }

    # M-6: fail closed if CSPRNG unavailable rather than falling back to rand()
    my $s = generate_random_hex(32);

    open( my $fh, '>', $path ) or die "Cannot write auth secret\n";
    # 0660, not 0600: the secret is shared between the two identities that
    # legitimately run this code on a group-shared docroot (the site user's
    # CLI/setup context and the www-data CGI, joined by the setgid auth dir's
    # group). An owner-only file minted from the CLI 500s every CGI cookie
    # verification. Never any world bits.
    chmod 0o660, $path;
    print $fh "$s\n";
    close $fh;
    return $s;
}

# M-6: CSPRNG helper - fail closed, never fall back to rand().

# M-5: constant-time byte comparison (length-preserving).

# H-2: salted iterated SHA-256 password hashing. Format:
#   sha256iter:SALT(32 hex):ITERATIONS:HASH(64 hex)
# Legacy format (64-hex-char unsalted SHA-256) still accepted; login
# handler rehashes legacy hashes on success.


# Rewrite one user's hash in the users file, preserving other lines.
sub update_user_hash {
    my ( $user, $new_hash ) = @_;
    my $path = "$AUTH_DIR/users";
    return 0 unless -f $path;

    # Hold ONE exclusive lock across the whole read-modify-write. The old code
    # released the read lock before reopening for write, so a concurrent writer
    # (another password change, or the users tool) could slip in and be clobbered
    # by our stale copy. The shared store lock (.consume.lock) also makes us
    # mutually exclusive with lazysite-users.pl's mutations. Write atomically
    # (temp + rename) so a login reading the store never sees it truncated; mode
    # 0660 in the setgid auth dir keeps CLI + www-data both able to write.
    open my $lk, '>', "$AUTH_DIR/.consume.lock" or return 0;
    flock( $lk, LOCK_EX ) or do { close $lk; return 0 };

    open my $fh, '<:utf8', $path or do { close $lk; return 0 };
    my @lines = <$fh>;
    close $fh;
    for my $line (@lines) {
        next unless $line =~ /^\Q$user\E:/;
        $line = "$user:$new_hash\n";
    }

    my $tmp = "$path.tmp.$$";
    open my $wfh, '>:utf8', $tmp or do { close $lk; return 0 };
    print $wfh @lines;
    unless ( close $wfh ) { unlink $tmp; close $lk; return 0 }
    chmod 0o660, $tmp;
    unless ( rename $tmp, $path ) { unlink $tmp; close $lk; return 0 }
    close $lk;    # release the store lock
    return 1;
}

# H-3: per-IP login rate limit. Fails open if DB_File tie fails so a
# broken rate-limit store cannot lock out all logins.
sub check_login_rate {
    my ($ip) = @_;
    return 1             unless $ip;
    make_path($AUTH_DIR) unless -d $AUTH_DIR;

    # SM022: do not capture the tie return value. A lexical holding
    # a reference to the tied object triggers "untie attempted
    # while inner references still exist" on the untie below.
    my %db;
    eval { require DB_File; 1 } or return 1;    # fail open
    eval {
        tie %db, 'DB_File', $LOGIN_RATE_DB, O_CREAT | O_RDWR, 0o600;
    };
    return 1 if $@ || !tied %db;                # fail open

    my $window = int( time() / $LOGIN_WINDOW );
    my $key    = "$ip:$window";
    my $count  = ( $db{$key} // 0 ) + 1;
    $db{$key} = $count;

    # Opportunistic cleanup of stale windows
    for my $k ( keys %db ) {
        delete $db{$k} if $k =~ /:(\d+)\z/ && $1 < $window - 1;
    }
    untie %db;

    return $count <= $LOGIN_MAX;
}

sub read_conf_key {
    my ($key) = @_;
    my $path = "$LAZYSITE_DIR/lazysite.conf";
    return '' unless -f $path;
    open( my $fh, '<:utf8', $path ) or return '';
    while (<$fh>) {
        if (/^\Q$key\E\s*:\s*(.+)$/) {
            close $fh;
            my $v = $1;
            $v =~ s/^\s+|\s+$//g;
            return $v;
        }
    }
    close $fh;
    return '';
}

# Does a user with these (comma-separated) groups have manager access? Mirrors
# the processor's _is_manager: the `ui` capability granted through a group
# (SM095), else the unsecured/dev mode where NO group grants manager access and
# any authenticated user has it. SM138: the conf manager_groups fallback is
# retired (the migration granted those groups their capabilities explicitly).
sub _login_is_manager {
    my ($groups_str) = @_;
    my @ug = grep { length } split /\s*,\s*/, ( $groups_str // '' );
    return 1 if groups_grant_cap( 'ui', @ug );
    return Lazysite::Auth::Settings::site_grants_manager() ? 0 : 1;
}

# --- Utilities ---

sub parse_post {
    my $len  = $ENV{CONTENT_LENGTH} || 0;
    my $data = '';
    if ( $len > 0 ) {
        read( STDIN, $data, $len );
    }
    else {
        local $/;
        $data = <STDIN> // '';
    }

    my %form;
    for my $pair ( split /&/, $data ) {
        my ( $k, $v ) = split /=/, $pair, 2;
        next unless defined $k;
        $k =~ s/\+/ /g;
        $k =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
        $v //= '';
        $v =~ s/\+/ /g;
        $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
        $v =~ s/[\r\n]/ /g;
        $form{$k} = $v;
    }
    return %form;
}

sub read_cookie {
    my ($name) = @_;
    my $cookies = $ENV{HTTP_COOKIE} // '';
    for my $pair ( split /;\s*/, $cookies ) {
        my ( $k, $v ) = split /=/, $pair, 2;
        $k =~ s/^\s+|\s+$//g if defined $k;
        return $v            if defined $k && $k eq $name;
    }
    return '';
}

sub sanitise_next {
    my ($next) = @_;
    return '/' unless defined $next && length $next;
    # H-1: reject protocol-relative URLs (//host) and backslash forms
    # before the permissive character-class check below - otherwise
    # //evil.com matches \A/[\w/.-]*\z.
    return '/' if $next     =~ m{\A(?://|\\)};
    return '/' unless $next =~ m{\A/[\w/.-]*\z};
    return $next;
}

sub redirect {
    my ($url) = @_;
    binmode( STDOUT, ':utf8' );
    print "Status: 302 Found\r\n";
    print "Content-Type: text/html; charset=utf-8\r\n";    # SM353
    print "Location: $url\r\n\r\n";
}

# SM179 P8: the requesting host's language (conf `lang:`, or alias.<host>.lang),
# sanitised to a bare code; 'en' when unset. Display-only - it selects the text
# of the reject pages below and NEVER gates an auth decision.
sub _host_lang {
    my $host = lc( $ENV{HTTP_HOST} // '' );
    $host =~ s/:.*//;    # strip any port
    my ( $base, $alias ) = ( '', '' );
    if ( open my $fh, '<:raw', "$LAZYSITE_DIR/lazysite.conf" ) {
        while ( my $line = <$fh> ) {
            if    ( $line =~ /^lang\h*:\h*(\S+)/ ) { $base = $1 }
            elsif ( length $host
                && $line =~ /^alias\.\Q$host\E\.lang\h*:\h*(\S+)/ )
            {
                $alias = $1;
            }
        }
        close $fh;
    }
    my $lang = length $alias ? $alias : $base;
    $lang =~ s/[^A-Za-z-]//g;
    return length $lang ? $lang : 'en';
}

sub reject_no_password {
    binmode( STDOUT, ':utf8' );
    my $lang  = _host_lang();
    my $pt    = chrome_string( $DOCROOT, $lang, 'signin.title' );
    my $title = chrome_string( $DOCROOT, $lang, 'auth.nopw.title' );
    my $body  = chrome_string( $DOCROOT, $lang, 'auth.nopw.body' );
    print "Status: 403 Forbidden\r\n";
    print "Content-Type: text/html; charset=utf-8\r\n\r\n";
    print <<"HTML";
<!DOCTYPE html>
<html lang="$lang"><head><meta charset="utf-8"><title>$pt</title></head>
<body style="font-family:system-ui,sans-serif;max-width:480px;margin:3em auto;padding:0 1em;">
<h1 style="font-size:1.3rem;">$title</h1>
<p>$body</p>
</body></html>
HTML
}

# SM070: a credential-valid account whose `ui` mechanism is disabled.
# No Set-Cookie is emitted, so the account cannot reach the manager or
# auth-protected pages through the browser. These accounts are for
# WebDAV / automation; point the operator there.
sub reject_ui_disabled {
    binmode( STDOUT, ':utf8' );
    my $lang  = _host_lang();
    my $pt    = chrome_string( $DOCROOT, $lang, 'signin.title' );
    my $title = chrome_string( $DOCROOT, $lang, 'auth.uidisabled.title' );
    my $body  = chrome_string( $DOCROOT, $lang, 'auth.uidisabled.body' );
    print "Status: 403 Forbidden\r\n";
    print "Content-Type: text/html; charset=utf-8\r\n\r\n";
    print <<"HTML";
<!DOCTYPE html>
<html lang="$lang"><head><meta charset="utf-8"><title>$pt</title></head>
<body style="font-family:system-ui,sans-serif;max-width:480px;margin:3em auto;padding:0 1em;">
<h1 style="font-size:1.3rem;">$title</h1>
<p>$body</p>
</body></html>
HTML
}

sub uri_encode_simple {
    my ($str) = @_;
    $str =~ s/([^a-zA-Z0-9_.~:-])/sprintf('%%%02X', ord($1))/ge;
    return $str;
}

sub uri_decode_simple {
    my ($str) = @_;
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $str;
}

# --- Logging ---


