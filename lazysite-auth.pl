#!/usr/bin/perl
# lazysite-auth.pl - lightweight built-in auth wrapper
# Sets X-Remote-* headers from signed cookie, then execs the processor
use strict;
use warnings;
use Digest::SHA qw(sha256_hex hmac_sha256_hex);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use POSIX qw(strftime);

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
            { id => 'manage-users', label => 'Manage users', link => '/editor/users' },
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

    unless ( length $username && length $password ) {
        redirect("$auth_redirect?error=1");
        return;
    }

    # Verify credentials
    my $users = load_users();
    my $expected = $users->{$username};
    unless ( defined $expected && $expected eq sha256_hex($password) ) {
        redirect("$auth_redirect?error=1");
        return;
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

    binmode( STDOUT, ':utf8' );
    print "Status: 302 Found\r\n";
    print "Set-Cookie: $COOKIE_NAME=$cookie; HttpOnly; SameSite=Lax; Path=/; Max-Age=$COOKIE_MAX$secure\r\n";
    print "Location: $next\r\n\r\n";
}

sub handle_logout {
    my $secure = $ENV{HTTPS} ? '; Secure' : '';

    binmode( STDOUT, ':utf8' );
    print "Status: 302 Found\r\n";
    print "Set-Cookie: $COOKIE_NAME=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0$secure\r\n";
    print "Location: /\r\n\r\n";
}

sub handle_request {
    my $cookie = read_cookie($COOKIE_NAME);

    if ( $cookie ) {
        my ( $payload, $sig ) = $cookie =~ /^(.+):([a-f0-9]{64})$/;
        if ( $payload && $sig ) {
            $payload = uri_decode_simple($payload);
            my $secret = load_auth_secret();
            my $expected = hmac_sha256_hex( $payload, $secret );

            if ( $sig eq $expected ) {
                my ( $user, $ts, $groups ) = split /:/, $payload, 3;
                $groups //= '';

                # Check timestamp
                if ( defined $ts && $ts =~ /^\d+$/ && ( time() - $ts ) < $COOKIE_MAX ) {
                    $ENV{HTTP_X_REMOTE_USER}   = $user;
                    $ENV{HTTP_X_REMOTE_GROUPS} = $groups;
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

    my $s;
    if ( open( my $rand, '<', '/dev/urandom' ) ) {
        read( $rand, my $bytes, 32 );
        close $rand;
        $s = unpack( 'H*', $bytes );
    }
    else {
        $s = hmac_sha256_hex( time() . $$ . rand(), 'lazysite-auth' );
    }

    open( my $fh, '>', $path ) or die "Cannot write auth secret\n";
    chmod 0600, $path;
    print $fh "$s\n";
    close $fh;
    return $s;
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
    $next //= '/';
    return '/' unless $next =~ m{\A/[\w/.-]*\z};
    return $next;
}

sub redirect {
    my ($url) = @_;
    binmode( STDOUT, ':utf8' );
    print "Status: 302 Found\r\n";
    print "Location: $url\r\n\r\n";
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
