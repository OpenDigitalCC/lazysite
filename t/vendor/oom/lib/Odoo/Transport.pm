package Odoo::Transport;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use HTTP::Tiny;

our $VERSION = '0.36';

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

=head2 is_read_method($method)

True for an Odoo method that only reads, so a call of it may be made again
after a closed connection.

=cut

my %READ = map { $_ => 1 } qw(search_read read search search_count fields_get read_group name_search name_get
    default_get check_access_rights check_access_rule version_info);

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
