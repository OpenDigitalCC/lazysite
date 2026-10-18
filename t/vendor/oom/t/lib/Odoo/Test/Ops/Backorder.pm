package Odoo::Test::Ops::Backorder;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops::Profile;
use Odoo::Ops::Stock::Validate;
use parent 'Odoo::Ops::Operation';

# A write that validates one staged picking through Odoo::Ops::Stock::Validate, for the tests of
# the backorder choice and of the plan-time scope check (ODOO_OPS_NAMESPACES=Odoo::Test::Ops).
# backorder is create, cancel or absent; calls is the JSON list of [model, method] the change declares.

sub op_name ($class) { 'test.backorder' }
sub summary ($class) { 'Validate one staged picking, with or without a backorder choice, for tests' }
sub pack    ($class) { 'stock' }
sub params  ($class) {
    {   picking   => { type => 'int', required => 1, help => 'the staged picking' },
        backorder => { type => 'str', help => 'create or cancel; absent: no choice' },
        calls     => { type => 'json', help => 'the [model, method] pairs the change declares' },
    };
}
sub read_scope  ($class) { { picking => ['read'], move => ['search_read'], move_line => ['search_read'] } }
sub write_scope ($class) { { picking => ['button_validate'] } }
sub buckets ($class) { [ { name => 'validate', meaning => 'a staged picking is validated' } ] }
sub holds   ($class) { [] }

sub scope_for ($self, $phase) {
    my $s = $self->SUPER::scope_for($phase);
    $s->{'stock.backorder.confirmation'} = [qw(create process process_cancel_backorder)] if $phase eq 'apply';
    return $s;
}

sub plan ($self) {
    my $plan = $self->new_plan( input_count => 1 );
    $plan->add( bucket => 'validate', action => 'custom', handler => $self->op_name, kind => 'validate',
        model => 'stock.picking', id => $self->param('picking'), key => 'validate:' . $self->param('picking'),
        vals => { backorder => $self->param('backorder') },
        ( $self->param('calls') ? ( calls => $self->param('calls') ) : () ) );
    return $plan;
}

sub apply_custom ($class, $client, $c) {
    my $p = Odoo::Ops::Profile->load( pack => 'stock', series => $client->server_series );
    my $w = Odoo::Ops::Stock::Validate->run( $client, $p, $c->{id}, backorder => $c->{vals}{backorder} );
    return { id => $c->{id}, after => { wizards => $w }, returned => scalar @$w };
}

1;
