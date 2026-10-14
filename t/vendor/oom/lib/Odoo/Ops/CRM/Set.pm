package Odoo::Ops::CRM::Set;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops::CRM::Select;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::CRM::Set - set plain (non-relational) fields on selected leads

=head1 DESCRIPTION

C<crm.set>: C<values> is a JSON object of logical lead fields to plain
values, e.g. C<{"probability": 0}> or C<{"priority": "1"}>. Relational
fields are refused here (use C<crm.assign> or C<crm.tag>, which resolve
names). Leads already holding the values are C<unchanged>; each write
carries its before-image, so C<revert> restores what was there.

=cut

my %PLAIN = map { $_ => 1 } qw(char text html selection integer float monetary boolean date datetime);

sub op_name ($class) { 'crm.set' }
sub summary ($class) { 'Set plain fields (probability, priority, ...) on selected leads' }
sub pack    ($class) { 'crm' }
sub params ($class) {
    +{  Odoo::Ops::CRM::Select->params,
        values => { type => 'json', required => 1, help => 'JSON object: logical lead field -> value' },
    };
}
sub read_scope  ($class) { { lead => ['search_read'], tag => ['search_read'] } }
sub write_scope ($class) { { lead => ['write'] } }

sub plan ($self) {
    my $p = $self->profile;
    my $v = $p->validate( $self->client );
    Odoo::Error->throw( kind => 'refused', code => 'profile', message => 'crm profile does not match: '
            . join( '; ', @{ $v->{missing} } ) ) if !$v->{ok};
    my $want = $self->param('values');
    Odoo::Error->throw( kind => 'usage', message => 'values must be a JSON object' ) if ref $want ne 'HASH' || !%$want;
    my %set;
    for my $lf ( sort keys %$want ) {
        my $d = $p->descriptor( lead => $lf )
            // Odoo::Error->throw( kind => 'usage', message => "lead.$lf is not in the crm profile" );
        Odoo::Error->throw( kind => 'usage', message => "lead.$lf is $d->{type}; use crm.assign or crm.tag" )
            if !$PLAIN{ $d->{type} // '' };
        Odoo::Error->throw( kind => 'usage', message => "lead.$lf is read-only" ) if $d->{readonly};
        $set{ $d->{name} } = $want->{$lf};
    }
    my $leads = $self->model('lead')->all( Odoo::Ops::CRM::Select->domain_for($self), [ sort keys %set ] );
    my $plan  = $self->new_plan( input_count => scalar @$leads );
    for my $lead (@$leads) {
        my %vals = map { $_ => $set{$_} } grep { !_same( $lead->{$_}, $set{$_} ) } keys %set;
        if (%vals) {
            $plan->add( bucket => 'set', action => 'write', model => $p->model_name('lead'), id => $lead->{id},
                vals => \%vals, before => { map { $_ => $lead->{$_} } keys %vals } );
        }
        else {
            $plan->add( bucket => 'unchanged', action => 'skip', id => $lead->{id} );
        }
    }
    return $plan;
}

sub _same ($have, $want) {
    return 1 if !defined $have && !defined $want;
    return 0 if !defined $have || !defined $want;
    no warnings 'numeric';
    return $have =~ /^-?[\d.]+\z/ && $want =~ /^-?[\d.]+\z/ ? $have == $want : "$have" eq "$want";
}

1;
