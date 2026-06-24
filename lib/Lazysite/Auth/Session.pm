package Lazysite::Auth::Session;

# Manager CSRF tokens (SM079): an HMAC over "csrf:$user:$hourbucket" keyed by
# the site secret, with a one-hour grace window and constant-time compare. The
# secret reuses lazysite/auth/.secret if present, else a dedicated minted
# manager secret. Context is $LAZYSITE_DIR, set by the script.

use strict;
use warnings;
use Digest::SHA qw(hmac_sha256_hex);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Lazysite::Util qw(const_eq);
use Exporter 'import';

our @EXPORT_OK = qw(generate_csrf_token verify_csrf_token);

our $LAZYSITE_DIR;    # "$DOCROOT/lazysite", set by the script

sub _csrf_secret {
    my $path = "$LAZYSITE_DIR/auth/.secret";
    if ( -f $path && open my $fh, '<', $path ) {
        chomp( my $s = <$fh> );
        close $fh;
        return $s if length $s;
    }
    # Dedicated manager secret (only used if the auth secret is missing).
    my $mpath = "$LAZYSITE_DIR/manager/.csrf-secret";
    if ( -f $mpath && open my $mfh, '<', $mpath ) {
        chomp( my $s = <$mfh> );
        close $mfh;
        return $s if length $s;
    }
    # Mint one - fail closed if the CSPRNG is unavailable (M-6).
    make_path( dirname($mpath) ) unless -d dirname($mpath);
    open my $rand, '<:raw', '/dev/urandom'
        or die "Cannot open /dev/urandom - no CSPRNG available: $!\n";
    my $raw = '';
    my $got = read( $rand, $raw, 32 );
    close $rand;
    die "Short read from /dev/urandom\n" unless $got == 32;
    my $s = unpack( 'H*', $raw );
    open my $wfh, '>', $mpath or die "Cannot write $mpath: $!\n";
    chmod 0o600, $mpath;
    print {$wfh} "$s\n";
    close $wfh;
    return $s;
}

sub generate_csrf_token {
    my ($user) = @_;
    my $ts = int( time() / 3600 );    # rotates hourly
    return hmac_sha256_hex( "csrf:$user:$ts", _csrf_secret() );
}

sub verify_csrf_token {
    my ( $token, $user ) = @_;
    return 0 unless defined $token && length $token;
    return 0 unless defined $user  && length $user;
    my $secret = _csrf_secret();
    for my $ts ( int( time() / 3600 ), int( time() / 3600 ) - 1 ) {
        my $expected = hmac_sha256_hex( "csrf:$user:$ts", $secret );
        return 1 if const_eq( $token, $expected );
    }
    return 0;
}

1;
