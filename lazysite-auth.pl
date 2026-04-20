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

my $LOG_COMPONENT = 'auth';

if ( grep { $_ eq '--describe' } @ARGV ) {
    require JSON::PP;
    print JSON::PP::encode_json({
        id          => 'auth',
        name        => 'Built-in Auth',
        description => 'Cookie-based authentication with user and group management',
        version     => '1.0',
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
$action = $1 if $query =~ /action=([a-z]+)/;

if ( $action eq 'login' && $method eq 'POST' ) {
    handle_login();
}
elsif ( $action eq 'logout' ) {
    handle_logout();
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
        sleep $LOGIN_DELAY;
        redirect("$auth_redirect?error=rate");
        return;
    }

    unless ( length $username ) {
        log_event('WARN', $username, 'login failed', ip => $ip);
        sleep $LOGIN_DELAY;
        redirect("$auth_redirect?error=1");
        return;
    }

    my $users = load_users();
    my $expected = $users->{$username};

    unless ( defined $expected ) {
        log_event('WARN', $username, 'login failed', ip => $ip);
        sleep $LOGIN_DELAY;
        redirect("$auth_redirect?error=1");
        return;
    }

    if ( !length $expected ) {
        # No-password account: only allowed from localhost
        my $addr = $ENV{REMOTE_ADDR} // '';
        unless ( $addr eq '127.0.0.1' || $addr eq '::1' ) {
            log_event('WARN', $username, 'no-password login refused (not localhost)', ip => $addr);
            reject_no_password();
            return;
        }
        log_event('INFO', $username, 'no-password login (localhost)', ip => $addr);
    }
    else {
        # H-2: verify_password handles both legacy (unsalted) and new
        # (sha256iter) formats. Legacy hashes are auto-rehashed on
        # successful login.
        unless ( length $password && verify_password($password, $expected) ) {
            log_event('WARN', $username, 'login failed', ip => $ip);
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

    binmode( STDOUT, ':utf8' );
    print "Status: 302 Found\r\n";
    print "Set-Cookie: $COOKIE_NAME=$cookie; HttpOnly; SameSite=Lax; Path=/; Max-Age=$COOKIE_MAX$secure\r\n";
    print "Location: $next\r\n\r\n";
    return;
}

sub handle_logout {
    my $user = $ENV{HTTP_X_REMOTE_USER} // '';
    log_event('INFO', $user, 'logout', ip => $ENV{REMOTE_ADDR} // '');

    my $secure = $ENV{HTTPS} ? '; Secure' : '';

    binmode( STDOUT, ':utf8' );
    print "Status: 302 Found\r\n";
    print "Set-Cookie: $COOKIE_NAME=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0$secure\r\n";
    print "Location: /logout\r\n\r\n";
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

    # Exec processor
    my $processor = $ENV{LAZYSITE_PROCESSOR}
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
sub generate_random_hex {
    my ($bytes) = @_;
    open my $fh, '<:raw', '/dev/urandom'
        or die "Cannot open /dev/urandom - no CSPRNG available: $!\n";
    my $raw = '';
    my $got = read( $fh, $raw, $bytes );
    close $fh;
    die "Short read from /dev/urandom ($got of $bytes bytes)\n"
        unless defined $got && $got == $bytes;
    return unpack( 'H*', $raw );
}

# M-5: constant-time byte comparison (length-preserving).
sub const_eq {
    my ( $a, $b ) = @_;
    return 0 unless defined $a && defined $b;
    return 0 if length($a) != length($b);
    my $r = 0;
    $r |= ord( substr( $a, $_, 1 ) ) ^ ord( substr( $b, $_, 1 ) )
        for 0 .. length($a) - 1;
    return $r == 0;
}

# H-2: salted iterated SHA-256 password hashing. Format:
#   sha256iter:SALT(32 hex):ITERATIONS:HASH(64 hex)
# Legacy format (64-hex-char unsalted SHA-256) still accepted; login
# handler rehashes legacy hashes on success.
sub hash_password {
    my ($password) = @_;
    my $salt  = generate_random_hex(16);   # 32 hex chars = 16 bytes
    my $iters = 100_000;
    my $hash  = $password;
    $hash = sha256_hex( $salt . $hash ) for 1 .. $iters;
    return "sha256iter:$salt:$iters:$hash";
}

sub verify_password {
    my ( $password, $stored ) = @_;
    return 0 unless defined $password && defined $stored && length $stored;
    if ( $stored =~ /\Asha256iter:([0-9a-f]{32}):(\d+):([0-9a-f]{64})\z/ ) {
        my ( $salt, $iters, $expected ) = ( $1, $2, $3 );
        return 0 if $iters < 1 || $iters > 1_000_000;  # sanity cap
        my $hash = $password;
        $hash = sha256_hex( $salt . $hash ) for 1 .. $iters;
        return const_eq( $hash, $expected );
    }
    elsif ( $stored =~ /\A[0-9a-f]{64}\z/ ) {
        # Legacy unsalted SHA-256 - accept, caller rehashes on success.
        return const_eq( sha256_hex($password), $stored );
    }
    return 0;
}

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

    my %db;
    my $tied = eval {
        require DB_File;
        tie %db, 'DB_File', $LOGIN_RATE_DB, O_CREAT | O_RDWR, 0o600;
    };
    return 1 if $@ || !$tied;    # fail open

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

sub log_event {
    my ($level, $context, $message, %extra) = @_;
    my $min_level = $ENV{LAZYSITE_LOG_LEVEL} // 'INFO';
    my %rank = ( DEBUG => 0, INFO => 1, WARN => 2, ERROR => 3 );
    return if ( $rank{$level} // 1 ) < ( $rank{$min_level} // 1 );
    use POSIX qw(strftime);
    my $ts = strftime( '%Y-%m-%d %H:%M:%S', localtime );
    my $format = $ENV{LAZYSITE_LOG_FORMAT} // 'text';
    if ( $format eq 'json' ) {
        my $pairs = join ',',
            map  { '"' . _json_str($_) . '":"' . _json_str($extra{$_}) . '"' }
            keys %extra;
        my $json = '{"ts":"' . $ts . '"'
            . ',"level":"'     . _json_str($level)          . '"'
            . ',"component":"' . _json_str($LOG_COMPONENT)  . '"'
            . ',"context":"'   . _json_str($context)        . '"'
            . ',"message":"'   . _json_str($message)        . '"'
            . ( $pairs ? ",$pairs" : '' )
            . '}';
        print STDERR "$json\n";
    }
    else {
        my $extras = join ' ',
            map { "$_=" . $extra{$_} } keys %extra;
        my $line = "[$ts] [$level] [$LOG_COMPONENT] [$context] $message";
        $line   .= " $extras" if $extras;
        print STDERR "$line\n";
    }
}

sub _json_str {
    my ($s) = @_;
    $s //= '';
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return $s;
}
