package LazysiteTest::OdooOps::PhotoDie;

# Test pack (SM1162): a READ that takes a file and dies once it has it.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }

sub op_name { 'shop.photo_die' }
sub summary { 'Take a photo and fail' }

sub params { return { photo => { type => 'file', required => 1, max_bytes => 5000 } } }
sub read_scope { return { 'x.basket' => ['search_read'] } }
sub report { die "the operation fell over\n" }

1;
