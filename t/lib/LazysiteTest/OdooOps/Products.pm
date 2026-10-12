package LazysiteTest::OdooOps::Products;

# Test pack (SM747): a public listing - a read operation with one plain
# parameter. Fake model names: this is fixture, in the shape an OOM pack takes.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name    { 'shop.products' }
sub summary    { 'The products on sale' }
sub params     { return { limit       => { type => 'int', default => 20 } } }
sub read_scope { return { 'x.product' => ['search_read'] } }

sub report {
    my ($self) = @_;
    my $rows = $self->model('x.product')
        ->search_read( [], [ 'name', 'price' ], limit => $self->param('limit') );
    my $f = $self->model('x.product')->fields;
    return { rows => $rows, fields => { map { ( $_ => $f->{$_} ) } qw(name price) } };
}

1;
