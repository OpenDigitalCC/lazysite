#!/usr/bin/perl
# lazysite-payment-demo.pl - DEMO ONLY payment simulator
# Simulates payment via signed cookie. NOT for production use.
# In production, use an upstream x402 payment proxy that sets
# X-Payment-Verified after on-chain validation.
use strict;
use warnings;
use Digest::SHA qw(hmac_sha256_hex);
use File::Path qw(make_path);

my $DOCROOT      = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT}
    or die "DOCUMENT_ROOT not set\n";
my $LAZYSITE_DIR = "$DOCROOT/lazysite";
my $AUTH_DIR     = "$LAZYSITE_DIR/auth";
my $COOKIE_NAME  = 'lazysite_payment_demo';
my $COOKIE_MAX   = 3600;  # 1 hour - demo payments expire

# --- Main ---

my $method = $ENV{REQUEST_METHOD} // 'GET';
my $uri    = $ENV{REDIRECT_URL}   // '/';
my $query  = $ENV{QUERY_STRING}   // '';

my %params;
for my $pair ( split /&/, $query ) {
    my ( $k, $v ) = split /=/, $pair, 2;
    next unless defined $k;
    $k =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    $v //= '';
    $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    $params{$k} = $v;
}

my $action = $params{action} // '';

if ( $action eq 'pay' ) {
    handle_pay();
}
elsif ( $action eq 'unpay' ) {
    handle_unpay();
}
else {
    handle_request();
}

# --- Handlers ---

sub handle_pay {
    my $page   = $params{page} // '/';
    $page = '/' unless $page =~ m{\A/[\w/.-]*\z};

    my $ts     = time();
    my $secret = load_secret();
    my $payload = "$page:$ts";
    my $sig     = hmac_sha256_hex( $payload, $secret );
    my $cookie  = uri_encode("$payload:$sig");

    my $secure = $ENV{HTTPS} ? '; Secure' : '';

    binmode( STDOUT, ':utf8' );
    print "Status: 302 Found\r\n";
    print "Set-Cookie: $COOKIE_NAME=$cookie; HttpOnly; SameSite=Lax; Path=/; Max-Age=$COOKIE_MAX$secure\r\n";
    print "Location: $page\r\n\r\n";
}

sub handle_unpay {
    my $page = $params{page} // '/';
    $page = '/' unless $page =~ m{\A/[\w/.-]*\z};

    my $secure = $ENV{HTTPS} ? '; Secure' : '';

    binmode( STDOUT, ':utf8' );
    print "Status: 302 Found\r\n";
    print "Set-Cookie: $COOKIE_NAME=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0$secure\r\n";
    print "Location: $page\r\n\r\n";
}

sub handle_request {
    # Check demo payment cookie for current page
    my $cookie = read_cookie($COOKIE_NAME);

    if ( $cookie ) {
        my $decoded = uri_decode($cookie);
        if ( $decoded =~ /^(.+):(\d+):([a-f0-9]{64})$/ ) {
            my ( $page, $ts, $sig ) = ( $1, $2, $3 );
            my $secret   = load_secret();
            my $expected = hmac_sha256_hex( "$page:$ts", $secret );

            if ( $sig eq $expected && ( time() - $ts ) < $COOKIE_MAX ) {
                # Check if cookie page matches current URI
                if ( $uri eq $page ) {
                    $ENV{HTTP_X_PAYMENT_VERIFIED} = '1';
                    $ENV{HTTP_X_PAYMENT_PAYER}    = 'demo-wallet';
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

# --- Utilities ---

sub load_secret {
    my $path = "$AUTH_DIR/.secret";
    make_path($AUTH_DIR) unless -d $AUTH_DIR;

    if ( -f $path ) {
        open( my $fh, '<', $path ) or return 'demo-fallback-secret';
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
        $s = hmac_sha256_hex( time() . $$ . rand(), 'lazysite-payment-demo' );
    }

    open( my $fh, '>', $path ) or return $s;
    chmod 0600, $path;
    print $fh "$s\n";
    close $fh;
    return $s;
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

sub uri_encode {
    my ($str) = @_;
    $str =~ s/([^a-zA-Z0-9_.~:-])/sprintf('%%%02X', ord($1))/ge;
    return $str;
}

sub uri_decode {
    my ($str) = @_;
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $str;
}
