package Odoo::Ops::CRM::Tag;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops::CRM::Select;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::CRM::Tag - add or remove tags on selected leads

=head1 DESCRIPTION

C<crm.tag>: plans, per selected lead, the tag additions and removals
that would change it (C<tag> bucket) or not (C<unchanged>). Tags named
in C<add> that do not exist are planned as support creates; a tag named
in C<remove> that does not exist is simply absent from every lead.

=cut

sub op_name ($class) { 'crm.tag' }
sub summary ($class) { 'Add/remove tags on selected leads' }
sub pack    ($class) { 'crm' }
sub params ($class) {
    +{  Odoo::Ops::CRM::Select->params,
        add    => { type => 'list', help => 'tag names to add' },
        remove => { type => 'list', help => 'tag names to remove' },
    };
}
sub read_scope  ($class) { { lead => ['search_read'], tag => ['search_read'] } }
sub write_scope ($class) { { lead => ['write'], tag => ['create'] } }

sub plan ($self) {
    my @add    = @{ $self->param('add')    // [] };
    my @remove = @{ $self->param('remove') // [] };
    Odoo::Error->throw( kind => 'usage', message => 'crm.tag needs add or remove' ) if !@add && !@remove;

    my $p      = $self->profile;
    my $domain = Odoo::Ops::CRM::Select->domain_for($self);
    my $tf     = $p->field( lead => 'tags' );
    my $name_f = $p->field( tag => 'name' );
    my %tag    = map { lc $_->{$name_f} => $_->{id} } @{ $self->model('tag')->search_read( [], [$name_f] ) };
    my $leads  = $self->model('lead')->all( $domain, [$tf] );

    my $plan = $self->new_plan( input_count => scalar @$leads );
    my %ref_for;
    for my $name (@add) {
        next if $tag{ lc $name };
        my $ref = 'tag:' . lc $name;
        $plan->add( bucket => 'new-tag', action => 'create', model => $p->model_name('tag'),
            vals => { $name_f => $name }, ref => $ref, support => 1, unique_by => $name_f );
        $ref_for{ lc $name } = { '$ref' => $ref };
    }
    my @rm_ids = grep {defined} map { $tag{ lc $_ } } @remove;
    for my $lead (@$leads) {
        my %have = map { $_ => 1 } @{ $lead->{$tf} // [] };
        my @cmd;
        for my $name (@add) {
            my $id = $tag{ lc $name };
            push @cmd, [ 4, $id // $ref_for{ lc $name }, 0 ] if !$id || !$have{$id};
        }
        push @cmd, map { [ 3, $_, 0 ] } grep { $have{$_} } @rm_ids;
        if (@cmd) {
            $plan->add( bucket => 'tag', action => 'write', model => $p->model_name('lead'),
                id => $lead->{id}, vals => { $tf => \@cmd }, before => { $tf => $lead->{$tf} } );
        }
        else {
            $plan->add( bucket => 'unchanged', action => 'skip', id => $lead->{id} );
        }
    }
    return $plan;
}

1;
