package Odoo::Transport::JSONRPC;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Odoo::JSON ();

use Odoo::Error;
use Odoo::Transport;

=head1 NAME

Odoo::Transport::JSONRPC - Odoo external API over /jsonrpc

=head1 DESCRIPTION

Speaks Odoo's JSON-RPC 2.0 endpoint, which exposes the same
C<(service, method, args)> surface as C</xmlrpc/2/>. Core modules
only. Server booleans are decoded to plain C<1>/C<0> so results look
identical to what the XML-RPC transport returns.

The interface is C<call($service, $method, @params)>; failures die
with an L<Odoo::Error> of kind C<fault> or C<transport>.

Note some proxied deployments (Cloudient) gate C</jsonrpc> while
leaving C</xmlrpc/2/> open; if every call dies with an HTML page in
the transport error, switch the client to the xmlrpc transport.

=cut

sub new ($class, %args) {
    my $url = $args{url}
        or Odoo::Error->throw(kind => 'config', message => 'url required');
    $url =~ s{/+\z}{};
    return bless {
        url  => $url,
        id   => 0,
        json => Odoo::JSON->new( plain_bools => 1 ),
        http => Odoo::Transport::http_client(
            timeout            => $args{timeout},
            max_response_bytes => $args{max_response_bytes},
            ssl_ca_file        => $args{ssl_ca_file},
            ssl_verify         => $args{ssl_verify},
        ),
    }, $class;
}

sub name ($self) { 'jsonrpc' }

# the HTTP client (timeout, CA, size cap), for a web session that must
# trust the same peer
sub http ($self) { $self->{http} }

sub call ($self, $service, $method, @params) {
    my $body = $self->encode_request($service, $method, @params);
    my $res  = $self->{http}->post(
        "$self->{url}/jsonrpc",
        {
            content => $body,
            headers => { 'content-type' => 'application/json' },
        },
    );
    Odoo::Transport::refuse_by_policy($res, "jsonrpc $service.$method");
    if (!$res->{success}) {
        my $detail =
            ($res->{status} // 0) == 599
            ? ($res->{content} // 'internal HTTP::Tiny error')
            : "HTTP $res->{status} $res->{reason}";
        Odoo::Error->throw(
            kind    => 'transport',
            message => "jsonrpc $service.$method: $detail",
        );
    }
    return $self->decode_response($res->{content});
}

sub encode_request ($self, $service, $method, @params) {
    return $self->{json}->encode({
        jsonrpc => '2.0',
        method  => 'call',
        params  => {
            service => $service,
            method  => $method,
            args    => \@params,
        },
        id => ++$self->{id},
    });
}

sub decode_response ($self, $content) {
    my $data = eval { $self->{json}->decode($content) };
    if (!$data || ref $data ne 'HASH') {
        # A proxy interception page arrives here as unparseable HTML.
        my $peek = substr($content // '', 0, 120);
        Odoo::Error->throw(
            kind    => 'transport',
            message => "unparseable JSON-RPC response: $peek",
        );
    }
    if (my $err = $data->{error}) {
        my $msg = $err->{message} // 'unknown fault';
        my $class;
        if (ref $err->{data} eq 'HASH') {
            $msg .= ': ' . $err->{data}{message} if defined $err->{data}{message};
            $class = $err->{data}{name};
        }
        Odoo::Error->throw(
            kind        => 'fault',
            message     => $msg,
            code        => $err->{code},
            fault_class => $class,
        );
    }
    return $data->{result};
}

1;
