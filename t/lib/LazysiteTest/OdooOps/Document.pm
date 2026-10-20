package LazysiteTest::OdooOps::Document;

# Test pack (SM1225): a READ that returns a document the way OOM's core.report does
# with inline=1 (0.32+): report.rows[0] holds content_base64, name, mimetype, bytes.
# `name` and `mimetype` are what a test wants the document called and typed (a hostile
# name is the point), `size` is how long its bytes are, `rows` how many documents.
use strict;
use warnings;
use MIME::Base64 ();
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name { 'shop.document' }
sub summary { 'Return a document as a report does' }

sub params {
    return {
        name     => { type => 'str' },
        mimetype => { type => 'str' },
        size     => { type => 'int', default => 100 },
        rows     => { type => 'int', default => 1 },
    };
}
sub read_scope { return { 'x.product' => ['search_read'] } }

sub report {
    my ($self) = @_;
    my $size  = $self->param('size');
    # binary on purpose: a NUL, high bytes and a blank line, which a header/body split must not trip on
    my $tail  = "\x00\xFF\x80\r\n\r\n\x1a";
    my $bytes = "%PDF-1.4\n" . ( 'p' x ( $size > 17 ? $size - 17 : 0 ) ) . $tail;
    my $row   = {
        name           => $self->param('name') // 'quotation.pdf',
        mimetype       => $self->param('mimetype') // 'application/pdf',
        bytes          => length $bytes,
        content_base64 => MIME::Base64::encode_base64( $bytes, '' ),
    };
    return { inline => 1, count => $self->param('rows'), rows => [ map { {%$row} } 1 .. $self->param('rows') ] };
}

1;
