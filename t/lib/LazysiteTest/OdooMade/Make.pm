package LazysiteTest::OdooMade::Make;

# Test pack (SM1214, SM1215): a write against OOM's own test world (res.partner,
# the one oomd's CliFake holds) that makes one partner and holds one change for a
# reason, so the same test can run through oomd and in-process.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name     { 'test.make' }
sub summary     { 'Make a partner and hold a change, for tests' }
sub pack        { undef }
sub params      { return { name => { type => 'str', required => 1 } } }
sub read_scope  { return { 'res.partner' => ['search_read'] } }
sub write_scope { return { 'res.partner' => ['create'] } }
sub writes      { 1 }
sub buckets     { return [ { name => 'made', meaning => 'a partner made' }, { name => 'short', meaning => 'a change held' } ] }
sub holds       { return [ { bucket => 'short', meaning => 'held for a reason' } ] }

sub plan {
    my ($self) = @_;
    my $plan = $self->new_plan( input_count => 2 );
    $plan->add( bucket => 'short', action => 'hold', key => 'make:hold',
        reason => 'the sheet is locked', vals => {} );
    $plan->add( bucket => 'made', action => 'create', model => 'res.partner', key => 'make:new', ref => 'new', unique_by => 'name', vals => { name => $self->param('name') } );
    return $plan;
}

1;
