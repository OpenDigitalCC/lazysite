package LazysiteTest::OdooFail::Refuse;

# Test pack (SM1198): a write whose one change Odoo's side REFUSES WITH A CODE (an
# Odoo::Error of kind `refused`), the shape OOM's Runner journals as error.code. It
# is OOM's Odoo::Test::Ops::Fail with a code, which that one does not have (its
# error is a plain fault).
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; require Odoo::Error; 1 } }    # absent: the file still compiles

sub op_name     { 'test.refuse' }
sub summary     { 'A change that is refused with a code, for tests' }
sub pack        { undef }
sub params      { return { why => { type => 'str', default => 'Not allowed.' } } }
sub read_scope  { return {} }
sub write_scope { return {} }
sub writes      { 1 }
sub buckets     { return [ { name => 'refuse', meaning => 'a change that is refused with a code' } ] }
sub holds       { return [] }

sub plan {
    my ($self) = @_;
    my $plan = $self->new_plan( input_count => 1 );
    $plan->add( bucket => 'refuse', action => 'custom', handler => $self->op_name, kind => 'refuse',
        model => 'purchase.order', id => 7, key => 'refuse:7', vals => { why => $self->param('why') } );
    return $plan;
}

sub apply_custom {
    my ( $class, $client, $c ) = @_;
    Odoo::Error->throw( kind => 'refused', code => 'not-yours', message => $c->{vals}{why} );
}

1;
