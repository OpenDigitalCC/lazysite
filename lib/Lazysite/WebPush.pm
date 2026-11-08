package Lazysite::WebPush;

# SM1363: A NOTICE TO THE INSTALLED APP, BY WEB PUSH - THE SIMPLE WAY (ruling 187).
#
# The filing says a notice carries nothing - only that something is waiting -
# so a push here carries NO PAYLOAD. That removes the whole of RFC 8291 (the
# payload encryption, and with it the subscription's p256dh and auth keys): what
# is left is an empty POST to the subscription's endpoint, signed with the site's
# own VAPID key (RFC 8292). The app's worker (lazysite-processor/app.pm) shows
# "something is waiting" and opens the account's notices when it is tapped.
#
# THE KEY lives under lazysite/ (lazysite/auth/webpush-vapid.pem, 0660), made on
# first use: one P-256 key per site, whose public half the browser is given when
# a device subscribes. CryptX signs with it (Lazysite::Crypto); without CryptX
# nothing here runs and the caller says so.
#
# THE ENDPOINT is a URL the person's browser handed over, so it is held to the
# rules for a destination nobody vetted: https only, and at send time not a
# private, loopback or link-local address (Lazysite::Fetch::is_safe_url, the
# SSRF guard), no redirect followed, a short timeout. $LOOPBACK_OK lets a test's
# 127.0.0.1 fixture stand in; nothing sets it outside t/.
#
# Index
#   endpoint_fault   why an endpoint may not be stored, or undef
#   vapid_key        the site's key (made on first use), or ( undef, $why )
#   public_key       the key's public half, base64url (the applicationServerKey)
#   vapid_header     the Authorization header for one endpoint
#   deliver          one empty, signed push; ( $ok, $status, $why )

use strict;
use warnings;
use JSON::PP         ();
use MIME::Base64     ();
use Fcntl            qw(O_WRONLY O_CREAT O_EXCL);
use Lazysite::Crypto ();
use Lazysite::Paths  ();

our $LOOPBACK_OK = 0;     # a test's 127.0.0.1 fixture; never set outside t/
our $TIMEOUT     = 10;    # seconds a push service may take to answer
our $TTL = 86400;    # seconds the push service may hold a notice for an offline device

sub _b64u { return MIME::Base64::encode_base64url( $_[0] ) }

sub _loopback { return $_[0] =~ m{\Ahttp://127\.0\.0\.1(?::\d+)?/} }

# Why this endpoint may not be stored, or undef. Shape only - no DNS - so a
# subscription is accepted or refused the same whatever the resolver says today;
# the address is checked when a push is sent.
sub endpoint_fault {
    my ($ep) = @_;
    return 'an endpoint is required' unless defined $ep && !ref $ep && length $ep;
    return 'the endpoint is too long' if length $ep > 1024;
    return undef                      if $LOOPBACK_OK && _loopback($ep);
    return 'the endpoint must be an https:// address'
        unless $ep =~ m{\Ahttps://[A-Za-z0-9.-]+(?::\d{1,5})?/[\x21-\x7e]*\z};
    return undef;
}

sub _key_file { return Lazysite::Paths::lazysite_dir( $_[0] ) . '/auth/webpush-vapid.pem' }

# The site's VAPID key as a Crypt::PK::ECC object, made on first use. Two
# processes making it at once: the second's O_EXCL fails and it reads the first's.
sub vapid_key {
    my ($docroot) = @_;
    if ( my $m = Lazysite::Crypto::cryptx_missing() ) { return ( undef, $m ) }
    require Crypt::PK::ECC;
    my $f = _key_file($docroot);
    unless ( -e $f ) {
        my $k = Crypt::PK::ECC->new;
        $k->generate_key('secp256r1');
        if ( sysopen my $fh, $f, O_WRONLY | O_CREAT | O_EXCL, 0o660 ) {
            print {$fh} $k->export_key_pem('private');
            close $fh;
            chmod 0o660, $f;
        }
    }
    my $k = eval { Crypt::PK::ECC->new($f) };
    return ( undef, "the site's web push key (lazysite/auth/webpush-vapid.pem) could not be read" )
        unless $k && $k->is_private;
    return ($k);
}

sub public_key {
    my ($docroot) = @_;
    my ( $k, $why ) = vapid_key($docroot);
    return ( undef, $why ) unless $k;
    return ( _b64u( $k->export_key_raw('public') ) );
}

# The Authorization header for one endpoint: a JWT whose audience is the
# endpoint's origin, valid for twelve hours, signed ES256 (raw r||s, RFC 7518),
# and the public key it is checked with.
sub vapid_header {
    my ( $k, $endpoint, $subject ) = @_;
    my ($aud) = $endpoint =~ m{\A(https?://[^/]+)};
    my $head = _b64u( JSON::PP->new->canonical->encode( { typ => 'JWT', alg => 'ES256' } ) );
    my $claims = _b64u( JSON::PP->new->canonical->encode( {
                aud => $aud, exp => time + 12 * 3600,
                ( defined $subject && length $subject ? ( sub => $subject ) : () ) } ) );
    my $sig = _b64u( $k->sign_message_rfc7518( "$head.$claims", 'SHA256' ) );
    return 'vapid t=' . "$head.$claims.$sig" . ', k=' . _b64u( $k->export_key_raw('public') );
}

# One push: an empty body, signed. Returns ( $ok, $http_status, $why ). A 404 or
# 410 means the device has unsubscribed; the caller says so.
sub deliver {
    my ( $docroot, $endpoint, %o ) = @_;
    if     ( my $f = endpoint_fault($endpoint) ) { return ( 0, 0, $f ) }
    unless ( $LOOPBACK_OK && _loopback($endpoint) ) {
        require Lazysite::Fetch;
        return ( 0, 0, 'the endpoint is not a public address' )
            unless Lazysite::Fetch::is_safe_url($endpoint);
    }
    my ( $k, $why ) = vapid_key($docroot);
    return ( 0, 0, $why ) unless $k;
    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new( timeout => $TIMEOUT, agent => 'lazysite-webpush/1', max_redirect => 0,
        max_size => 4096 );
    my $res = $ua->post( $endpoint,
        Authorization    => vapid_header( $k, $endpoint, $o{subject} ),
        TTL              => $TTL,
        Urgency          => 'normal',
        'Content-Length' => 0,
        Content          => '' );
    my $code = $res->code;
    return ( 1, $code, '' ) if $res->is_success;
    return ( 0, $code, 'the device has unsubscribed (the push service answered ' . $code . ')' )
        if $code == 404 || $code == 410;
    my $msg = $res->message // '';
    $msg =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*\z//;
    return ( 0, $code, "the push service answered $code" . ( length $msg ? " ($msg)" : '' ) );
}

1;
