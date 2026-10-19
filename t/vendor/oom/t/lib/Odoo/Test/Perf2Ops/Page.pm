package Odoo::Test::Perf2Ops::Page;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use parent 'Odoo::Ops::Operation';

# The fixed read of the latency test (t/70-latency-live.t): four queries an ordinary login may make, the shape of a
# page (a few partners, two lists, the partners counted by company). ODOO_OPS_NAMESPACES=Odoo::Test::Perf2Ops.
# QUERIES lists them for the raw JSON-RPC baseline, which makes exactly these calls and no others.

use constant QUERIES => (
    [ 'res.partner',  'search_read', [ [] ],  { fields => [qw(id name)], limit => 5 } ],
    [ 'res.country',  'search_read', [ [] ],  { fields => [qw(id name)], limit => 5 } ],
    [ 'res.currency', 'search_read', [ [] ],  { fields => [qw(id name)], limit => 5 } ],
    [ 'res.partner',  'read_group',  [ [], ['id'], ['company_id'] ], {} ],
);

sub op_name ($class) { 'perf2.page' }
sub summary ($class) { 'Four reads an ordinary login may make, for the latency test' }
sub pack ($class) { undef }
sub params ($class) { return {} }
sub read_scope ($class) { { 'res.partner' => [ 'search_read', 'read_group' ], 'res.country' => ['search_read'], 'res.currency' => ['search_read'] } }

sub report ($self) {
    my $c = $self->client;
    my $p = $c->model('res.partner')->search_read( [], [qw(id name)], limit => 5 );
    my $k = $c->model('res.country')->search_read( [], [qw(id name)], limit => 5 );
    my $u = $c->model('res.currency')->search_read( [], [qw(id name)], limit => 5 );
    my $g = $c->model('res.partner')->read_group( [], ['id'], ['company_id'] );
    return { count => 4, rows => [ { partners => scalar @$p, countries => scalar @$k, currencies => scalar @$u, groups => scalar @$g } ] };
}

1;
