package LazysiteTest::OdooOps::Stock;

# Test pack (SM747 R wiring): a display read in the shape OOM agreed (0.02) -
# `rows` beside `fields`, the descriptors carrying `portable_type`. Four fields
# lazysite can draw (text, integer, a decimal with its places, an enum) and two
# it must refuse by name: one with no portable type, one decimal with no places.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name    { 'shop.stock' }
sub summary    { 'Stock, with the descriptors of what it shows' }
sub read_scope { return { 'x.product' => ['search_read'] } }

sub report {
    my ($self) = @_;
    my $rows = [
        { name => 'Tea', qty => 4, price => '3.50', kind => 'drink', note => 'one', ratio => '0.5' },
        { name => 'Cake', qty => 0, price => '2.25', kind => 'food', note => 'two', ratio => '0.25' },
    ];
    return {
        rows   => $rows,
        fields => {
            name => { portable_type => 'text',    string => 'Name', required => 1 },
            qty  => { portable_type => 'integer', string => 'On hand' },
            price => { portable_type => 'decimal', string => 'Price', digits => 10, places => 2 },
            kind => { portable_type => 'enum', string => 'Kind', values => [qw(drink food)] },
            note  => { string        => 'A field with no portable type' },
            ratio => { portable_type => 'decimal', string => 'A decimal with no places' },
        },
    };
}

1;
