package Odoo::Ops::CRM::Lost;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::CRM::Select;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::CRM::Lost - mark selected leads Lost through Odoo's own action

=head1 DESCRIPTION

C<crm.lost>: calls C<action_set_lost> on each selected lead - Odoo 16
archives it (probability 0, and predictive lead scoring counts it as a
loss) and, with C<reason>, records the lost reason. A reason must
already exist; creating one needs Sales Manager rights. Leads already
archived are C<unchanged>. At apply, a lead whose stage or active flag
changed since planning makes the plan stale.

C<< restore => 1 >> does the inverse through Odoo's C<action_unarchive>
for selected archived leads (active ones are C<unchanged>). Odoo then
clears the lost reason and re-scores the lead - with little scoring
history that means ~99% - so set the probability again straight after
(C<crm.set> or C<crm.update>).

Neither direction is undone by C<revert>: the calls are journalled as
irreversible holds; run the opposite direction instead.

=cut

sub op_name ($class) { 'crm.lost' }
sub summary ($class) { 'Mark selected leads Lost (Odoo action_set_lost)' }
sub pack    ($class) { 'crm' }
sub params ($class) {
    +{  Odoo::Ops::CRM::Select->params,
        reason  => { type => 'str', help => 'existing lost reason name (optional)' },
        restore => { type => 'bool', default => 0, help => 'restore archived leads instead (action_unarchive)' },
    };
}
sub read_scope  ($class) { { lead => [qw(search_read read)], tag => ['search_read'], stage => ['search_read'], 'crm.lost.reason' => ['search_read'] } }
sub write_scope ($class) { { lead => [qw(action_set_lost action_unarchive)] } }

sub plan ($self) {
    my $p = $self->profile;
    my %kw;
    if ( defined( my $r = $self->param('reason') ) ) {
        my $hits = $self->model('crm.lost.reason')->search_read( [ [ 'name', '=ilike', $r ] ], ['name'] );
        Odoo::Error->throw( kind => 'usage', message => "lost reason '$r' matches " . scalar(@$hits)
                . ' (creating one needs Sales Manager rights)' ) if @$hits != 1;
        $kw{lost_reason_id} = $hits->[0]{id};
    }
    my ( $act, $stage ) = ( $p->field( lead => 'active' ), $p->field( lead => 'stage' ) );
    my $leads = $self->model('lead')->all(
        [ @{ Odoo::Ops::CRM::Select->domain_for($self) }, [ $act, 'in', [ JSON::PP::true, JSON::PP::false ] ] ],
        [ $act, $stage ] );
    my $restore = $self->param('restore');
    Odoo::Error->throw( kind => 'usage', message => 'restore takes no reason' ) if $restore && %kw;
    my $plan = $self->new_plan( input_count => scalar @$leads );
    for my $l (@$leads) {
        if ( $restore ? $l->{$act} : !$l->{$act} ) {
            $plan->add( bucket => 'unchanged', action => 'skip', id => $l->{id},
                reason => $restore ? 'already active' : 'already archived' );
            next;
        }
        $plan->add(
            bucket => $restore ? 'restore' : 'lost', action => 'call', model => $p->model_name('lead'),
            id => $l->{id}, ids => [ $l->{id} ],
            method => $restore ? 'action_unarchive' : 'action_set_lost', kwargs => $restore ? {} : \%kw,
            before => { $act => $l->{$act}, $stage => $l->{$stage} },
        );
    }
    return $plan;
}

1;
