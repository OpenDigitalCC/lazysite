#!/usr/bin/perl
# lazysite-auth.pl - lightweight built-in auth wrapper
# Sets X-Remote-* headers from signed cookie, then execs the processor
use strict;
use warnings;
use Digest::SHA qw(sha256_hex hmac_sha256_hex);
use Fcntl qw(:flock O_RDWR O_CREAT);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use POSIX qw(strftime);
use IPC::Open2 qw(open2);

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
use Lazysite::Audit qw(audit_log);
use Lazysite::Auth::Credential qw(generate_random_hex hash_password verify_password);
$Lazysite::Util::COMPONENT = 'auth';

if ( grep { $_ eq '--describe' } @ARGV ) {
    require JSON::PP;
    print JSON::PP::encode_json({
        id          => 'auth',
        name        => 'Built-in Auth',
        description => 'Cookie-based authentication with user and group management',
        version     => '1.0',
        # Wired in the web-server config (FallbackResource), not toggled via
        # the plugins list - the manager renders core plugins as "always on".
        core        => 1,
        config_file => '',
        config_keys => [qw(auth_default auth_redirect auth_header_user
                           auth_header_name auth_header_email auth_header_groups)],
        config_schema => [
            { key => 'auth_default', label => 'Default auth requirement', type => 'select',
              options => ['none','optional','required'], default => 'none' },
            { key => 'auth_redirect', label => 'Login page path', type => 'text', default => '/login' },
            { key => 'auth_header_user', label => 'User header name', type => 'text', default => 'X-Remote-User' },
            { key => 'auth_header_name', label => 'Display name header', type => 'text', default => 'X-Remote-Name' },
            { key => 'auth_header_email', label => 'Email header name', type => 'text', default => 'X-Remote-Email' },
            { key => 'auth_header_groups', label => 'Groups header name', type => 'text', default => 'X-Remote-Groups' },
        ],
        actions => [
            { id => 'manage-users', label => 'Manage users', link => '/manager/users' },
        ],
    });
    exit 0;
}

my $DOCROOT      = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT}
    or die "DOCUMENT_ROOT not set\n";
my $LAZYSITE_DIR = "$DOCROOT/lazysite";
my $AUTH_DIR     = "$LAZYSITE_DIR/auth";
$Lazysite::Audit::LAZYSITE_DIR = $LAZYSITE_DIR;

# Record a material authentication event in the audit trail (login/logout, claim,
# token exchange/rotate), in addition to the application log. Origin defaults to
# 'ui' (interactive browser); credential-API flows pass 'api'.
sub _audit_auth {
    my ( $user, $act, $status, $detail, $origin ) = @_;
    audit_log( $user, $act, '', $ENV{REMOTE_ADDR} // '', $status,
        $origin // 'ui', $detail // '' );
}
my $COOKIE_NAME  = 'lazysite_auth';
my $COOKIE_MAX   = 86400;    # 24 hours

# H-3: login rate limiting (per-IP, sliding window)
my $LOGIN_RATE_DB  = "$AUTH_DIR/.login-rate.db";
my $LOGIN_MAX      = 5;      # attempts per window
my $LOGIN_WINDOW   = 300;    # seconds (5 minutes)
my $LOGIN_DELAY    = 2;      # seconds sleep on failure

# --- Main ---

my $method  = $ENV{REQUEST_METHOD} // 'GET';
my $uri     = $ENV{REDIRECT_URL}   // '/';
my $query   = $ENV{QUERY_STRING}   // '';
my $action  = '';
# Capture the FULL action token (including hyphens) so a short action like
# `rotate` does not shadow a longer one such as `rotate-auth-secret`.
$action = $1 if $query =~ /action=([a-z][a-z-]*)/;

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
    handle_exchange();
}
elsif ( $action eq 'rotate' && $method eq 'POST' ) {
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
    my $ip = $ENV{REMOTE_ADDR} // '';

    # H-3: per-IP rate limit before checking credentials (fail-closed on ok).
    unless ( check_login_rate($ip) ) {
        log_event('WARN', $username, 'login rate limit exceeded', ip => $ip);
        _audit_auth( $username, 'login', 'fail', 'rate-limited' );
        sleep $LOGIN_DELAY;
        redirect("$auth_redirect?error=rate");
        return;
    }

    unless ( length $username ) {
        log_event('WARN', $username, 'login failed', ip => $ip);
        _audit_auth( $username, 'login', 'fail', 'invalid-credentials' );
        sleep $LOGIN_DELAY;
        redirect("$auth_redirect?error=1");
        return;
    }

    my $users = load_users();
    my $expected = $users->{$username};

    unless ( defined $expected ) {
        log_event('WARN', $username, 'login failed', ip => $ip);
        _audit_auth( $username, 'login', 'fail', 'invalid-credentials' );
        sleep $LOGIN_DELAY;
        redirect("$auth_redirect?error=1");
        return;
    }

    if ( !length $expected ) {
        # No-password account: only allowed from localhost
        my $addr = $ENV{REMOTE_ADDR} // '';
        unless ( $addr eq '127.0.0.1' || $addr eq '::1' ) {
            log_event('WARN', $username, 'no-password login refused (not localhost)', ip => $addr);
            _audit_auth( $username, 'login', 'fail', 'no-password-remote' );
            reject_no_password();
            return;
        }
        log_event('INFO', $username, 'no-password login (localhost)', ip => $addr);
        _audit_auth( $username, 'login', 'ok', 'no-password' );
    }
    else {
        # H-2: verify_password handles both legacy (unsalted) and new
        # (sha256iter) formats. Legacy hashes are auto-rehashed on
        # successful login.
        unless ( length $password && verify_password($password, $expected) ) {
            log_event('WARN', $username, 'login failed', ip => $ip);
            _audit_auth( $username, 'login', 'fail', 'invalid-credentials' );
            sleep $LOGIN_DELAY;
            redirect("$auth_redirect?error=1");
            return;
        }
        if ( $expected =~ /\A[0-9a-f]{64}\z/ ) {
            my $new_hash = hash_password($password);
            if ( update_user_hash($username, $new_hash) ) {
                log_event('INFO', $username, 'password rehashed to salted format');
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
        log_event('WARN', $username, 'login refused: account disabled', ip => $ip);
        _audit_auth( $username, 'login', 'fail', 'account-disabled' );
        redirect("$auth_redirect?error=1");
        return;
    }

    # SM071 Phase 2: an expired access-token credential cannot start a
    # session (a human password has no expiry, so this never affects them).
    if ( token_expired($username) ) {
        log_event('WARN', $username, 'login refused: credential expired', ip => $ip);
        _audit_auth( $username, 'login', 'fail', 'credential-expired' );
        redirect("$auth_redirect?error=1");
        return;
    }

    # SM072: account-level expiry (time-boxed access)
    if ( account_expired($username) ) {
        log_event('WARN', $username, 'login refused: account expired', ip => $ip);
        _audit_auth( $username, 'login', 'fail', 'account-expired' );
        redirect("$auth_redirect?error=1");
        return;
    }

    unless ( ui_enabled($username) ) {
        log_event('WARN', $username, 'interactive login disabled for account', ip => $ip);
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
        my $v = users_tool_api({ action => 'mfa-verify', username => $username, code => $code });
        unless ( ref $v eq 'HASH' && $v->{ok} ) {
            log_event('WARN', $username, 'login refused: 2FA required or invalid', ip => $ip);
            _audit_auth( $username, 'login', 'fail', 'mfa' );
            sleep $LOGIN_DELAY;
            redirect("$auth_redirect?error=mfa");
            return;
        }
    }

    # Load groups for user
    my $groups_str = load_user_groups($username);

    # Generate signed cookie
    my $ts     = time();
    my $secret = load_auth_secret();
    my $payload = "$username:$ts:$groups_str";
    my $sig     = hmac_sha256_hex( $payload, $secret );
    my $cookie  = uri_encode_simple($payload) . ":$sig";

    my $secure = $ENV{HTTPS} ? '; Secure' : '';

    log_event('INFO', $username, 'login success', ip => $ENV{REMOTE_ADDR} // '');
    _audit_auth( $username, 'login', 'ok', '' );

    binmode( STDOUT, ':utf8' );
    print "Status: 302 Found\r\n";
    print "Set-Cookie: $COOKIE_NAME=$cookie; HttpOnly; SameSite=Lax; Path=/; Max-Age=$COOKIE_MAX$secure\r\n";
    print "Location: $next\r\n\r\n";
    return;
}

sub handle_logout {
    my $user = $ENV{HTTP_X_REMOTE_USER} // '';
    log_event('INFO', $user, 'logout', ip => $ENV{REMOTE_ADDR} // '');
    _audit_auth( $user, 'logout', 'ok', '' );

    my $secure = $ENV{HTTPS} ? '; Secure' : '';

    binmode( STDOUT, ':utf8' );
    print "Status: 302 Found\r\n";
    print "Set-Cookie: $COOKIE_NAME=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0$secure\r\n";
    print "Location: /logout\r\n\r\n";
}

# SM072: public claim redemption. The holder of a single-use setup/reset
# claim sets their own credential here - the operator never sees it. The
# claim token IS the authentication; we shell to the (tested) users-tool
# claim-redeem, which returns ONE generic error on any failure.
sub handle_claim {
    my %form = parse_post();
    my $username = $form{username} // '';
    $username =~ s/[^a-zA-Z0-9_.-]//g;
    $username = substr( $username, 0, 64 ) if length($username) > 64;
    my $claim    = $form{claim} // '';
    $claim =~ s/[^a-zA-Z0-9_]//g;
    my $password = $form{password} // '';
    my $ip = $ENV{REMOTE_ADDR} // '';

    # HTTPS-only (setting a secret); localhost allowed for dev/CLI.
    unless ( $ENV{HTTPS} || $ip eq '127.0.0.1' || $ip eq '::1' ) {
        log_event('WARN', $username, 'claim over plaintext refused', ip => $ip);
        redirect("/claim?u=$username&error=1");
        return;
    }

    # H-3: reuse the per-IP login rate limiter.
    unless ( check_login_rate($ip) ) {
        sleep $LOGIN_DELAY;
        redirect("/claim?u=$username&error=1");
        return;
    }

    my $r = users_tool_api({
        action => 'claim-redeem', username => $username,
        claim  => $claim, password => $password,
    });

    unless ( ref $r eq 'HASH' && $r->{ok} ) {
        sleep $LOGIN_DELAY;
        log_event('WARN', $username, 'claim redeem failed', ip => $ip);
        _audit_auth( $username, 'claim-redeem', 'fail', '' );
        redirect("/claim?u=$username&error=1");
        return;
    }

    log_event('INFO', $username, 'claim redeemed', ip => $ip);
    _audit_auth( $username, 'claim-redeem', 'ok', '' );
    if ( $r->{token} ) {
        claim_token_page( $username, $r->{token} );   # machine: show token once
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
    my %form = parse_post();
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

    my $r = users_tool_api({
        action => 'token-exchange', username => $username, pairing_key => $key,
    });
    unless ( ref $r eq 'HASH' && $r->{ok} ) {
        sleep $LOGIN_DELAY;
        log_event('WARN', $username, 'pairing exchange failed', ip => $ip);
        json_response( { ok => 0, error => 'Invalid or expired pairing key' }, 401 );
        return;
    }
    log_event('INFO', $username, 'access token issued (HTTP exchange)', ip => $ip);
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
    my $v = users_tool_api({ action => 'verify-credential', username => $u, secret => $token });
    unless ( ref $v eq 'HASH' && $v->{ok} ) {
        sleep $LOGIN_DELAY;
        log_event('WARN', $u, 'token rotation: invalid current token', ip => $ip);
        json_response( { ok => 0, error => 'Invalid token' }, 401 );
        return;
    }
    my $r = users_tool_api({ action => 'token-rotate', username => $u });
    unless ( ref $r eq 'HASH' && $r->{ok} ) {
        json_response( { ok => 0, error => 'Rotation failed' }, 500 );
        return;
    }
    log_event('INFO', $u, 'access token rotated (HTTP)', ip => $ip);
    _audit_auth( $u, 'token-rotate', 'ok', '', 'api' );
    json_response( { ok => 1, token => $r->{token}, expires_at => $r->{expires_at} }, 200 );
    return;
}

# SM072 batch 2: forgot-password. Mint a set-password claim and email the
# link to the account's registered address - gated on SMTP being configured
# and the account having an email. ALWAYS a generic response, so it cannot
# enumerate accounts or emails.
sub handle_forgot {
    my %form = parse_post();
    my $ident = $form{identifier} // $form{username} // $form{email} // '';
    $ident =~ s/^\s+|\s+$//g;
    my $ip = $ENV{REMOTE_ADDR} // '';
    my $auth_redirect = read_conf_key('auth_redirect') || '/login';

    if ( check_login_rate($ip) ) {
        eval { _forgot_dispatch( $ident, $ip ); 1 };
    }
    else { sleep $LOGIN_DELAY }

    redirect("$auth_redirect?reset=1");   # generic, always
    return;
}

sub _forgot_dispatch {
    my ( $ident, $ip ) = @_;
    return unless length $ident;
    return unless -f "$LAZYSITE_DIR/forms/smtp.conf";   # SMTP must be configured

    my ( $user, $email ) = _resolve_account($ident);
    return unless $user && $email;
    return if account_disabled($user);
    return unless ui_enabled($user);                    # interactive accounts only

    my $r = users_tool_api({ action => 'claim-create', username => $user });
    return unless ref $r eq 'HASH' && $r->{ok} && $r->{claim};

    my $scheme = $ENV{HTTPS} ? 'https' : 'http';
    my $host   = $ENV{HTTP_HOST} // '';
    _send_setup_email( $email, $user, "$scheme://$host/claim?u=$user&c=$r->{claim}" );
    log_event( 'INFO', $user, 'forgot-password claim emailed', ip => $ip );
    return;
}

# Resolve a username or email to (username, email) from user-settings.json.
sub _resolve_account {
    my ($ident) = @_;
    my $path = "$AUTH_DIR/user-settings.json";
    return () unless -f $path;
    open my $fh, '<:utf8', $path or return ();
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
    my $payload = JSON::PP::encode_json({
        config => { to => $to, subject_prefix => 'Set your password - ' },
        form   => { message =>
              "A password setup link was requested for '$user'.\n\n"
            . "Open this one-time link (it expires in 24 hours) to set your password:\n\n"
            . "$link\n\n"
            . "If you did not request this, you can ignore this email." },
    });
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
        log_event('INFO', $uri, 'auth: no cookie');
    }
    else {
        my ( $payload, $sig ) = $cookie =~ /^(.+):([a-f0-9]{64})$/;
        if ( !( $payload && $sig ) ) {
            log_event('WARN', $uri, 'auth: cookie malformed');
        }
        else {
            $payload = uri_decode_simple($payload);
            my $secret = load_auth_secret();
            my $expected = hmac_sha256_hex( $payload, $secret );

            # M-5: constant-time signature comparison
            unless ( const_eq($sig, $expected) ) {
                log_event('WARN', $uri, 'auth: signature mismatch');
            }
            else {
                my ( $user, $ts, $groups ) = split /:/, $payload, 3;
                $groups //= '';

                if ( !defined $ts || $ts !~ /^\d+$/ || ( time() - $ts ) >= $COOKIE_MAX ) {
                    log_event('WARN', $uri, 'auth: cookie expired or malformed ts', ts => $ts // 'undef');
                }
                elsif ( account_disabled($user) ) {
                    # SM071: reject an existing cookie for a now-disabled
                    # account; no trusted headers are set, so the request is
                    # treated as unauthenticated.
                    log_event('WARN', $uri, 'auth: account disabled', user => $user);
                }
                else {
                    # C-1: these headers come from our HMAC-verified cookie,
                    # not from the client. Set LAZYSITE_AUTH_TRUSTED=1 so
                    # the processor accepts them.
                    $ENV{HTTP_X_REMOTE_USER}    = $user;
                    $ENV{HTTP_X_REMOTE_GROUPS}  = $groups;
                    $ENV{LAZYSITE_AUTH_TRUSTED} = '1';

                    # Flag passwordless accounts so the admin bar can warn.
                    # Checked per-request so setting a password clears it immediately.
                    my $users = load_users();
                    $ENV{LAZYSITE_AUTH_NO_PASSWORD} = '1'
                        if exists $users->{$user} && !length $users->{$user};

                    log_event('INFO', $uri, 'auth: cookie valid', user => $user, groups => $groups);
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

    open my $fh, '<:utf8', $path or return 1;
    my $raw = do { local $/; <$fh> };
    close $fh;

    require JSON::PP;
    my $data = eval { JSON::PP::decode_json( $raw // '{}' ) };
    if ( !$data || ref $data ne 'HASH' ) {
        log_event('WARN', $username, 'user-settings.json unparseable; ui defaults on');
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
    open my $fh, '<:utf8', $path or return 0;
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
    open my $fh, '<:utf8', $path or return 0;
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
    open my $fh, '<:utf8', $path or return 0;
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
    open my $fh, '<:utf8', $path or return 0;
    my $raw = do { local $/; <$fh> };
    close $fh;
    require JSON::PP;
    my $data = eval { JSON::PP::decode_json( $raw // '{}' ) };
    return 0 unless ref $data eq 'HASH';
    my $s = $data->{$username};
    return ( ref $s eq 'HASH' && $s->{totp_secret} ) ? 1 : 0;
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
    chmod 0o600, $path;
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
    open my $fh, '<:utf8', $path or return 0;
    flock( $fh, LOCK_EX );
    my @lines = <$fh>;
    for my $line (@lines) {
        next unless $line =~ /^\Q$user\E:/;
        $line = "$user:$new_hash\n";
    }
    seek $fh, 0, 0;
    # Reopen for write: the read-lock pattern here is a read handle; use a
    # separate write to avoid races with readers using the same handle.
    flock( $fh, LOCK_UN );
    close $fh;

    open my $wfh, '>:utf8', $path or return 0;
    flock( $wfh, LOCK_EX );
    print $wfh @lines;
    flock( $wfh, LOCK_UN );
    close $wfh;
    chmod 0o640, $path;
    return 1;
}

# H-3: per-IP login rate limit. Fails open if DB_File tie fails so a
# broken rate-limit store cannot lock out all logins.
sub check_login_rate {
    my ($ip) = @_;
    return 1 unless $ip;
    make_path($AUTH_DIR) unless -d $AUTH_DIR;

    # SM022: do not capture the tie return value. A lexical holding
    # a reference to the tied object triggers "untie attempted
    # while inner references still exist" on the untie below.
    my %db;
    eval { require DB_File; 1 } or return 1;    # fail open
    eval {
        tie %db, 'DB_File', $LOGIN_RATE_DB, O_CREAT | O_RDWR, 0o600;
    };
    return 1 if $@ || !tied %db;    # fail open

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
        if ( /^\Q$key\E\s*:\s*(.+)$/ ) {
            close $fh;
            my $v = $1;
            $v =~ s/^\s+|\s+$//g;
            return $v;
        }
    }
    close $fh;
    return '';
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
        return $v if defined $k && $k eq $name;
    }
    return '';
}

sub sanitise_next {
    my ($next) = @_;
    return '/' unless defined $next && length $next;
    # H-1: reject protocol-relative URLs (//host) and backslash forms
    # before the permissive character-class check below - otherwise
    # //evil.com matches \A/[\w/.-]*\z.
    return '/' if $next =~ m{\A(?://|\\)};
    return '/' unless $next =~ m{\A/[\w/.-]*\z};
    return $next;
}

sub redirect {
    my ($url) = @_;
    binmode( STDOUT, ':utf8' );
    print "Status: 302 Found\r\n";
    print "Location: $url\r\n\r\n";
}

sub reject_no_password {
    binmode( STDOUT, ':utf8' );
    print "Status: 403 Forbidden\r\n";
    print "Content-Type: text/html; charset=utf-8\r\n\r\n";
    print <<'HTML';
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Sign in</title></head>
<body style="font-family:system-ui,sans-serif;max-width:480px;margin:3em auto;padding:0 1em;">
<h1 style="font-size:1.3rem;">Sign in unavailable</h1>
<p>Password not configured - contact your administrator.</p>
</body></html>
HTML
}

# SM070: a credential-valid account whose `ui` mechanism is disabled.
# No Set-Cookie is emitted, so the account cannot reach the manager or
# auth-protected pages through the browser. These accounts are for
# WebDAV / automation; point the operator there.
sub reject_ui_disabled {
    binmode( STDOUT, ':utf8' );
    print "Status: 403 Forbidden\r\n";
    print "Content-Type: text/html; charset=utf-8\r\n\r\n";
    print <<'HTML';
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Sign in</title></head>
<body style="font-family:system-ui,sans-serif;max-width:480px;margin:3em auto;padding:0 1em;">
<h1 style="font-size:1.3rem;">Interactive login is disabled for this account</h1>
<p>This account does not have interactive (browser) access. If it is
used for publishing, connect over WebDAV instead.</p>
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


