package Odoo::Test::Ops::Fail;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use parent 'Odoo::Ops::Operation';

# A write whose one change Odoo refuses, for the tests of what apply prints when a
# change fails (ODOO_OPS_NAMESPACES=Odoo::Test::Ops). The reason is a parameter.

sub op_name ($class) { 'test.fail' }
sub summary ($class) { 'A change Odoo refuses, for tests' }
sub pack    ($class) { undef }
sub params  ($class) { { why => { type => 'str', default => 'No can do.\nSecond line.', help => 'the message Odoo gives' }, code => { type => 'str', help => 'a refusal code: the change is refused with it' } } }
sub read_scope  ($class) { {} }
sub write_scope ($class) { {} }
sub writes      ($class) { 1 }
sub buckets ($class) { [ { name => 'refuse', meaning => 'a change Odoo will refuse' } ] }
sub holds   ($class) { [] }

sub plan ($self) {
    my $plan = $self->new_plan( input_count => 1 );
    $plan->add( bucket => 'refuse', action => 'custom', handler => $self->op_name, kind => 'refuse',
        model => 'purchase.order', id => 7, key => 'refuse:7', vals => { why => $self->param('why') =~ s/\\n/\n/gr, ( defined $self->param('code') ? ( code => $self->param('code') ) : () ) } );
    return $plan;
}

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'refused', code => $c->{vals}{code}, message => $c->{vals}{why} ) if defined $c->{vals}{code};
    Odoo::Error->throw( kind => 'fault', message => $c->{vals}{why} );
}

1;
