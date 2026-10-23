package LazysiteTest::OdooFail::Settle;

# Test pack (SM1275): a write whose one change is SENT and gets NO ANSWER, as
# Timeout's, but whose handler CAN say afterwards whether it was made: OOM 0.42's
# resume asks a custom change's handler (`unknown_outcome`) when the change names no
# `verify`. `made` says what it answers. Nothing is written anywhere.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; require Odoo::Error; 1 } } # absent: the file still compiles

sub op_name { 'test.settle' }
sub summary { 'A change whose answer never comes and whose handler can read it back, for tests' }
sub pack    { undef }
sub params  { return { made => { type => 'bool', default => 1 } } }
sub read_scope  { return {} }
sub write_scope { return {} }
sub writes      { 1 }
sub buckets { return [ { name => 'submit', meaning => 'a change whose answer never comes' } ] }
sub holds { return [] }

sub plan {
    my ($self) = @_;
    my $plan = $self->new_plan( input_count => 1 );
    $plan->add( bucket => 'submit', action => 'custom', handler => $self->op_name, kind => 'submit',
        model => 'hr_timesheet.sheet', id => 82, key => 'submit:82', vals => { made => $self->param('made') ? 1 : 0 } );
    return $plan;
}

sub apply_custom {
    my ( $class, $client, $c ) = @_;
    Odoo::Error->throw( kind => 'transport', sent => 1, write => 1, message => 'Timed out while waiting for socket to become ready for reading' );
}

sub unknown_outcome {
    my ( $class, $client, $c ) = @_;
    return $c->{vals}{made} ? ( 1, 'the test handler reads it as made' ) : ( 0, 'the test handler reads it as not made' );
}

1;
