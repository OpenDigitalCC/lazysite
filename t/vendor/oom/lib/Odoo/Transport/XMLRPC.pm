package Odoo::Transport::XMLRPC;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';
use builtin qw(is_bool created_as_number);
no warnings 'experimental::builtin';

use XML::LibXML;
use MIME::Base64 qw(decode_base64);
use Scalar::Util qw(blessed);

use Odoo::Error;
use Odoo::JSON ();
use Odoo::Transport;

=head1 NAME

Odoo::Transport::XMLRPC - Odoo external API over /xmlrpc/2/

=head1 DESCRIPTION

Speaks the classic Odoo XML-RPC endpoints (C</xmlrpc/2/common>,
C</xmlrpc/2/object>). The codec is deliberately small - only the
types Odoo actually uses - and is built on XML::LibXML rather than
RPC::XML, which is not packaged on this host.

Type mapping on encode follows how the Perl scalar was created
(C<builtin::created_as_number>), so a database name like C<"12345">
goes out as a string, not an integer - the class of bug OpenERP-OOM
0.48 existed to fix. C<undef> is encoded as boolean false, which is
the Odoo idiom for null.

The interface is C<call($service, $method, @params)>; failures die
with an L<Odoo::Error> of kind C<fault> or C<transport>.

=cut

use constant INT32_MAX => 2**31 - 1;

sub new ($class, %args) {
    my $url = $args{url}
        or Odoo::Error->throw(kind => 'config', message => 'url required');
    $url =~ s{/+\z}{};
    return bless {
        url  => $url,
        http => $args{http} // Odoo::Transport::http_client(
            timeout            => $args{timeout},
            max_response_bytes => $args{max_response_bytes},
            ssl_ca_file        => $args{ssl_ca_file},
            ssl_verify         => $args{ssl_verify},
        ),
    }, $class;
}

sub name ($self) { 'xmlrpc' }

# the HTTP client (timeout, CA, size cap), for a web session that must
# trust the same peer
sub http ($self) { $self->{http} }

sub call ($self, $service, $method, @params) {
    my $body = encode_request($method, @params);
    my $res  = Odoo::Transport::post(
        $self->{http},
        "$self->{url}/xmlrpc/2/$service",
        {
            content => $body,
            headers => { 'content-type' => 'text/xml; charset=utf-8' },
        },
        idempotent => ( $service eq 'object' && $method eq 'execute_kw' ? Odoo::Transport::is_read_method($params[4]) : $service eq 'common' ),
    );
    Odoo::Transport::refuse_by_policy($res, "xmlrpc $service.$method");
    if (!$res->{success}) {
        my $detail =
            ($res->{status} // 0) == 599
            ? ($res->{content} // 'internal HTTP::Tiny error')
            : "HTTP $res->{status} $res->{reason}";
        Odoo::Error->throw(
            kind    => 'transport',
            message => "xmlrpc $service.$method: $detail",
        );
    }
    return decode_response($res->{content});
}

#--- request encoding ---------------------------------------------------------

sub encode_request ($method, @params) {
    my $doc  = XML::LibXML::Document->new('1.0', 'UTF-8');
    my $call = $doc->createElement('methodCall');
    $doc->setDocumentElement($call);

    my $mn = $doc->createElement('methodName');
    $mn->appendText($method);
    $call->appendChild($mn);

    my $ps = $doc->createElement('params');
    $call->appendChild($ps);
    for my $p (@params) {
        my $param = $doc->createElement('param');
        $param->appendChild(_value_node($doc, $p));
        $ps->appendChild($param);
    }
    return $doc->toString(0);
}

sub _typed ($doc, $type, $text) {
    my $v = $doc->createElement('value');
    my $t = $doc->createElement($type);
    $t->appendText("$text");
    $v->appendChild($t);
    return $v;
}

sub _value_node ($doc, $v) {
    # Odoo has no null on this wire; false is its stand-in.
    return _typed($doc, 'boolean', 0) if !defined $v;

    if (my $ref = ref $v) {
        if (blessed($v)) {
            return _typed($doc, 'boolean', $v ? 1 : 0)
                if Odoo::JSON::is_bool($v);
            Odoo::Error->throw(
                kind    => 'usage',
                message => 'cannot XML-RPC-encode a ' . ref($v) . ' object',
            );
        }
        if ($ref eq 'ARRAY') {
            my $value = $doc->createElement('value');
            my $array = $doc->createElement('array');
            my $data  = $doc->createElement('data');
            $data->appendChild(_value_node($doc, $_)) for @$v;
            $array->appendChild($data);
            $value->appendChild($array);
            return $value;
        }
        if ($ref eq 'HASH') {
            my $value  = $doc->createElement('value');
            my $struct = $doc->createElement('struct');
            for my $k (sort keys %$v) {
                my $member = $doc->createElement('member');
                my $name   = $doc->createElement('name');
                $name->appendText($k);
                $member->appendChild($name);
                $member->appendChild(_value_node($doc, $v->{$k}));
                $struct->appendChild($member);
            }
            $value->appendChild($struct);
            return $value;
        }
        # \1 and \0 as boolean literals, matching the JSON::PP convention.
        return _typed($doc, 'boolean', $$v ? 1 : 0) if $ref eq 'SCALAR';
        Odoo::Error->throw(
            kind    => 'usage',
            message => "cannot XML-RPC-encode a $ref reference",
        );
    }

    return _typed($doc, 'boolean', $v ? 1 : 0) if is_bool($v);
    if (created_as_number($v)) {
        if ($v == int($v) && $v !~ /[eE.]/) {
            return _typed($doc, abs($v) > INT32_MAX ? 'i8' : 'int', $v);
        }
        return _typed($doc, 'double', $v);
    }
    return _typed($doc, 'string', $v);
}

#--- response decoding --------------------------------------------------------

sub decode_response ($xml) {
    my $doc = eval { XML::LibXML->load_xml(string => $xml, no_network => 1) };
    if (!$doc) {
        Odoo::Error->throw(
            kind    => 'transport',
            message => "unparseable XML-RPC response: $@",
        );
    }
    if (my ($fault) = $doc->findnodes('/methodResponse/fault/value')) {
        my $f = _decode_value($fault);
        my ($msg, $code) =
            ref $f eq 'HASH'
            ? ($f->{faultString} // 'unknown fault', $f->{faultCode})
            : ("$f", undef);
        # The wire has no exception-name slot; Odoo puts the traceback
        # in faultString and the message in faultCode.
        Odoo::Error->throw(
            kind        => 'fault',
            message     => $msg,
            code        => $code,
            fault_class => Odoo::Error::fault_class_from_text($msg)
                // Odoo::Error::fault_class_from_text($code),
        );
    }
    my ($value) = $doc->findnodes('/methodResponse/params/param/value');
    if (!$value) {
        Odoo::Error->throw(
            kind    => 'transport',
            message => 'XML-RPC response has neither value nor fault',
        );
    }
    return _decode_value($value);
}

sub _decode_value ($node) {
    my ($child) = grep { $_->isa('XML::LibXML::Element') } $node->childNodes;
    return $node->textContent if !$child;    # untyped <value> means string

    my $tag = $child->nodeName;
    if ($tag eq 'string' || $tag eq 'dateTime.iso8601') {
        return $child->textContent;
    }
    if ($tag eq 'int' || $tag eq 'i4' || $tag eq 'i8' || $tag eq 'double') {
        my $t = $child->textContent;
        $t =~ s/^\s+|\s+\z//g;
        return 0 + $t;
    }
    if ($tag eq 'boolean') {
        my $t = $child->textContent;
        $t =~ s/^\s+|\s+\z//g;
        return $t eq '1' ? 1 : 0;
    }
    if ($tag eq 'nil') { return undef }
    if ($tag eq 'base64') { return decode_base64($child->textContent) }
    if ($tag eq 'array') {
        my ($data) = $child->findnodes('./data');
        return [] if !$data;
        return [
            map { _decode_value($_) }
            grep { $_->isa('XML::LibXML::Element') && $_->nodeName eq 'value' }
                $data->childNodes,
        ];
    }
    if ($tag eq 'struct') {
        my %h;
        for my $member ($child->findnodes('./member')) {
            my ($name)  = $member->findnodes('./name');
            my ($value) = $member->findnodes('./value');
            next if !$name || !$value;
            $h{ $name->textContent } = _decode_value($value);
        }
        return \%h;
    }
    Odoo::Error->throw(
        kind    => 'transport',
        message => "unknown XML-RPC value type <$tag>",
    );
}

1;
