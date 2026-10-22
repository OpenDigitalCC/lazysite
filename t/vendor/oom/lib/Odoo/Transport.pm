package Odoo::Transport;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use HTTP::Tiny;
use Scalar::Util ();

our $VERSION = '0.42';

use Odoo::Error;

=head1 NAME

Odoo::Transport - HTTP policy shared by the Odoo transports

=head1 DESCRIPTION

Both transports build their HTTP client here, so the outbound
discipline is identical whichever wire is in use:

=over

=item * no redirect is ever followed. A 3xx answer dies as kind
C<refused>, naming the status and target, because the credential in
the request body would otherwise travel to wherever the redirect
points.

=item * TLS peer verification is on. C<ssl_ca_file> names a private
CA to trust; C<ssl_verify =E<gt> 0> switches verification off (lab use).

=item * C<max_response_bytes>, when set, caps the answer. An oversized
answer dies as kind C<refused> - by name, not as a retryable transport
failure.

=back

=cut

sub http_client (%args) {
    return HTTP::Tiny->new(
        timeout      => $args{timeout} // 120,
        # peer verification stays on; a private CA (an internal
        # certificate authority in front of a test Odoo) is named,
        # never bypassed: ssl_verify => 0 exists for a lab only
        verify_SSL   => $args{ssl_verify} // 1,
        ( $args{ssl_ca_file} ? ( SSL_options => { SSL_ca_file => $args{ssl_ca_file} } ) : () ),
        max_redirect => 0,
        agent        => "odoo-oom-perl/$Odoo::Transport::VERSION",
        ( defined $args{max_response_bytes}
            ? ( max_size => $args{max_response_bytes} )
            : () ),
    );
}

=head2 shared_http(\%store, %args)

One kept-alive HTTP client per Odoo URL and TLS setting, for a resident
program (a C<oomd> worker) whose every request reuses the same connection.
C<%store> is the hash the program keeps; C<%args> are those of
C<http_client> plus C<url>. The handle holds no cookie jar and no credential:
a request carries its own cookies and keys in its own headers, so whoever the
request runs as, the connection carries nothing of anyone else's.

=cut

sub shared_http ($store, %args) {
    my $key = join "\0", map { $_ // '' } @args{qw(url timeout ssl_verify ssl_ca_file max_response_bytes)};
    return $store->{$key} //= http_client(%args);
}

=head2 post($http, $url, \%args, idempotent =E<gt> 0|1)

A POST through C<$http>. When the kept-alive connection was closed by Odoo or
a proxy between two requests (HTTP::Tiny says C<Socket closed>, C<Unexpected
end> or C<SSL read error>), a call that C<idempotent> marks as a read is made
once more on a new connection. Anything else, and every write, is made once
and the failure is the caller's answer: whether a write happened is for the
journal to say.

=cut

sub post ($http, $url, $args, %opt) {
    my $res = $http->post( $url, $args );
    return $res if !$opt{idempotent};
    return $res if ( $res->{status} // 0 ) != 599;
    return $res if ( $res->{content} // '' ) !~ /\A(?:Socket closed|Unexpected end|SSL read error)/;
    return $http->post( $url, $args );
}

=head2 request_sent($res)

Whether the request of a failed HTTP::Tiny response may have reached Odoo: true or
false. Odoo cannot have acted on a request that was never connected, never passed
TLS, or never finished writing (Odoo reads the whole body before it runs anything),
so these are false: C<Could not connect>, C<SSL connection failed>, a timeout or an
error C<writing> the request, a refused header. Anything else is true, because the
request had been written whole and Odoo may have made the change: a timeout waiting
to read, a connection closed or reset after the request, an unreadable answer, and
any HTTP answer that is not Odoo's own (a 502 or 504 from a proxy in front of it).
Where the kind of failure is not known, the answer is true.

=cut

my $NOT_SENT = qr/\A(?:Could not connect to|SSL connection failed|Error halting prior SSL|Could not set SO_KEEPALIVE|Could not binmode|Cannot parse URL|Unsupported URL scheme|Timed out while waiting for socket to become ready for writing|Socket closed by remote server|Could not write to|Wide character|Invalid HTTP header|Content-Length mismatch)/;

sub request_sent ($res) {
    return 1 if ( $res->{status} // 0 ) != 599;
    return ( $res->{content} // '' ) =~ $NOT_SENT ? 0 : 1;
}

=head2 transport_error($res, $label, idempotent =E<gt> 0|1, detail =E<gt> TEXT)

The L<Odoo::Error> (kind C<transport>) of a failed HTTP::Tiny response, worded
C<LABEL: DETAIL> (the detail is HTTP::Tiny's own words for a 599, else
C<HTTP status reason>), carrying C<sent> (see C<request_sent>) and C<write>
(true unless the call was marked C<idempotent>). Returns the error; the caller
throws it.

=cut

sub transport_error ($res, $label, %opt) {
    my $detail = $opt{detail} // (
        ( $res->{status} // 0 ) == 599
        ? ( $res->{content} // 'internal HTTP::Tiny error' )
        : "HTTP $res->{status} " . ( $res->{reason} // '' ) );
    $detail =~ s/\s+\z//;
    return Odoo::Error->new(
        kind    => 'transport',
        message => "$label: $detail",
        sent    => request_sent($res) ? 1 : 0,
        write   => $opt{idempotent} ? 0 : 1,
    );
}

=head2 answered_unusably($error, idempotent =E<gt> 0|1)

Marks a transport error raised after a whole answer arrived but could not be
read (not JSON, not XML, no result) as C<sent>, and as a C<write> unless the
call was a read: the request was made, so Odoo may have acted on it. Returns the
error, to be rethrown. Other errors pass through unchanged.

=cut

sub answered_unusably ($err, %opt) {
    return $err if !( Scalar::Util::blessed($err) && $err->isa('Odoo::Error') && $err->kind eq 'transport' ) || defined $err->{sent};
    $err->{sent}  = 1;
    $err->{write} = $opt{idempotent} ? 0 : 1;
    return $err;
}

=head2 is_read_method($method)

True for an Odoo method that only reads, so a call of it may be made again
after a closed connection.

=cut

my %READ = map { $_ => 1 } qw(search_read read search search_count fields_get read_group name_search name_get
    default_get check_access_rights check_access_rule version_info
    search_fetch web_search_read web_read web_read_group onchange);

sub is_read_method ($method) { return $READ{ $method // '' } ? 1 : 0 }

=head2 refuse_by_policy($response, $label)

Dies with kind C<refused> if the HTTP::Tiny response is a redirect or
tripped the size cap; returns otherwise.

=cut

sub refuse_by_policy ($res, $label) {
    my $status = $res->{status} // 0;
    if ( $status =~ /^3\d\d\z/ ) {
        my $to = $res->{headers}{location} // 'no location';
        Odoo::Error->throw(
            kind    => 'refused',
            code    => 'redirect',
            message => "$label: redirect refused (HTTP $status to $to)",
        );
    }
    if ( $status == 599 && ( $res->{content} // '' ) =~ /exceeds the maximum allowed/ ) {
        Odoo::Error->throw(
            kind    => 'refused',
            code    => 'oversize',
            message => "$label: response over the configured size cap",
        );
    }
    return;
}

1;
