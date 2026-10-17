package Odoo::Transport;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use HTTP::Tiny;

our $VERSION = '0.24';

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
