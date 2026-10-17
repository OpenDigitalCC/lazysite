package LazysiteTest::OdooOps::Nomax;

# Test pack (SM1166): a rows parameter that declares no `max` - OOM 0.32 says
# max is always present, so this is the declaration a binding must refuse (R2).
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }

sub op_name    { 'shop.nomax' }
sub summary    { 'A rows parameter with no cap' }
sub params     { return { lines => { type => 'rows', row => { qty => 'int' } } } }
sub read_scope { return { 'x.basket' => ['search_read'] } }
sub report     { return { rows => [] } }

1;
