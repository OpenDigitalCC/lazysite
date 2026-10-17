package Odoo::Test::Ops::Echo;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use parent 'Odoo::Ops::Operation';

# A read that touches no server and returns rows with a fields block, for the
# tests of what the command line prints (ODOO_OPS_NAMESPACES=Odoo::Test::Ops).

sub op_name ($class) { 'test.echo' }
sub summary ($class) { 'Rows and a descriptor block, for tests' }
sub fields  ($class) { [ { name => 'n', meaning => 'the row number' } ] }
sub params  ($class) { { wide => { type => 'bool', default => 0, help => 'rows and an html string with non-ASCII text and control characters' } } }
sub report ($self) {
    # characters, as an operation reads them from Odoo: a middle dot, e acute, a no-break space,
    # a tab, a form feed, an em dash outside Latin-1 and a character outside the BMP
    return { count => 1, rows => [ { n => "caf\x{e9} \x{b7} tab\t ff\f" } ], html => "<p>caf\x{e9}\x{a0}\x{b7}\tx\fy \x{2014} \x{1F600}</p>\n" }
        if $self->param('wide');
    return {
        count  => 2,
        fields => { n => { portable_type => 'integer', string => 'Row number' } },
        rows   => [ { n => 1 }, { n => 2 } ],
    };
}

1;
