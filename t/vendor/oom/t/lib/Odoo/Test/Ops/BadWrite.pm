package Odoo::Test::Ops::BadWrite;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use parent 'Odoo::Ops::Operation';

# A write that Odoo refuses with its own words: a selection field given a value it does not have (live tests of what an
# apply that stops on a failed change answers; ODOO_OPS_NAMESPACES=Odoo::Test::Ops). The partner is the caller's.

sub op_name ($class) { 'test.badwrite' }
sub summary ($class) { 'A write Odoo refuses, for tests' }
sub pack    ($class) { undef }
sub params  ($class) { { partner => { type => 'int', required => 1, help => 'the res.partner to write' } } }
sub read_scope  ($class) { { 'res.partner' => [ 'read' ] } }
sub write_scope ($class) { { 'res.partner' => [ 'write' ] } }
sub buckets ($class) { [ { name => 'bad', meaning => 'a write Odoo will refuse' } ] }
sub holds   ($class) { [] }

sub plan ($self) {
    my $plan = $self->new_plan( input_count => 1 );
    my $id   = $self->param('partner');
    my $row  = $self->client->model('res.partner')->read_one( $id, ['type'] ) or die "no partner $id\n";
    $plan->add( bucket => 'bad', action => 'write', model => 'res.partner', id => $id, key => "partner:$id",
        vals => { type => 'no-such-type' }, before => { type => $row->{type} } );
    return $plan;
}

1;
