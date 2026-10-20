package LazysiteTest::OdooFail::Timeout;

# Test pack (SM1218): a write whose one change is SENT and gets NO ANSWER (a read
# timeout: an Odoo::Error of kind `transport`, sent and write), the case OOM 0.38's
# Runner records as `unknown`, not `failed`. Nothing is written anywhere.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; require Odoo::Error; 1 } } # absent: the file still compiles

sub op_name { 'test.timeout' }
sub summary { 'A change whose request is sent and never answered, for tests' }
sub pack    { undef }
sub params { return { why => { type => 'str', default => 'Timed out while waiting for socket to become ready for reading' } } }
sub read_scope  { return {} }
sub write_scope { return {} }
sub writes      { 1 }
sub buckets { return [ { name => 'submit', meaning => 'a change whose answer never comes' } ] }
sub holds { return [] }

sub plan {
    my ($self) = @_;
    my $plan = $self->new_plan( input_count => 1 );
    $plan->add( bucket => 'submit', action => 'custom', handler => $self->op_name, kind => 'submit',
        model => 'hr_timesheet.sheet', id => 81, key => 'submit:81', vals => { why => $self->param('why') } );
    return $plan;
}

sub apply_custom {
    my ( $class, $client, $c ) = @_;
    Odoo::Error->throw( kind => 'transport', sent => 1, write => 1, message => $c->{vals}{why} );
}

1;
