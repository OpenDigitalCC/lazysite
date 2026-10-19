package LazysiteTest::OdooOps::Photo;

# Test pack (SM1162): a READ that takes files - one `photo` and a list `shots` -
# and reports what it was given by name, size, type and the sha256 of the bytes
# IT saw, never the bytes. `sink` is a plain string a test sends to prove a
# plain value still travels beside a file.
use strict;
use warnings;
use Digest::SHA ();
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name { 'shop.photo' }
sub summary { 'Report the files given' }

sub params {
    return {
        photo => { type => 'file',  max_bytes => 5000 },
        shots => { type => 'files', max => 3, max_bytes => 5000 },
        sink  => { type => 'str' },
    };
}
sub read_scope { return { 'x.basket' => ['search_read'] } }

sub report {
    my ($self) = @_;
    my @all = ( ( grep { defined } $self->param('photo') ), @{ $self->param('shots') // [] } );
    return {
        sink => $self->param('sink'),
        rows => [ map { { name => $_->{name}, bytes => length $_->{bytes}, mimetype => $_->{mimetype},
                    seen => Digest::SHA::sha256_hex( $_->{bytes} ) } } @all ],
    };
}

1;
