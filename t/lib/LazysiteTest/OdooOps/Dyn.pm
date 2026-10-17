package LazysiteTest::OdooOps::Dyn;

# Test pack (SM1166): a rows parameter whose `row` is a string, as core.make's
# `lines.<field>` is - the keys are known only at plan, so it is operator-only.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }

sub op_name { 'shop.dyn' }
sub summary { 'A rows parameter whose row keys are known only at plan' }
sub params {
    return { lines => { type => 'rows', max => 20, row => "the fields of the one2many's comodel" } };
}
sub read_scope { return { 'x.basket' => ['search_read'] } }
sub report     { return { rows => [] } }

1;
