package Odoo::Ops::CRM::Assign;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops::CRM::Select;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::CRM::Assign - set stage, team, salesperson or source on selected leads

=head1 DESCRIPTION

C<crm.assign>: sets many2one fields on the selected leads. Stage, team
and salesperson are resolved against what exists - one that does not
exist is an error, never created. Source, medium and campaign are
free-form marketing labels: one that does not exist yet is planned as
a support create. Leads already carrying the value are C<unchanged>.

=cut

my %CREATABLE = map { $_ => 1 } qw(source medium campaign);
my @FIELDS    = qw(stage team salesperson source medium campaign);

sub op_name ($class) { 'crm.assign' }
sub summary ($class) { 'Set stage / team / salesperson / source on selected leads' }
sub pack    ($class) { 'crm' }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'assign', meaning => 'the lead\'s stage, team, salesperson, source, medium or campaign is written' },
        { name => 'new-source', meaning => 'a source, medium or campaign that does not exist yet is made first (a support row)' },
        { name => 'unchanged', meaning => 'the lead already has the value' },
    ];
}
sub holds ($class) { [] }

sub params ($class) {
    +{  Odoo::Ops::CRM::Select->params,
        stage       => { type => 'str', help => 'stage name (must exist)' },
        team        => { type => 'str', help => 'sales team name (must exist)' },
        salesperson => { type => 'str', help => 'user login or name (must exist)' },
        source      => { type => 'str', help => 'source name (created if missing)' },
        medium      => { type => 'str', help => 'medium name (created if missing)' },
        campaign    => { type => 'str', help => 'campaign name (created if missing)' },
        notify      => { type => 'bool', default => 0,
            help => 'let Odoo email "you have been assigned" to a new salesperson' },
    };
}
sub read_scope ($class) {
    {   lead        => ['search_read'],
        tag         => ['search_read'],
        stage       => ['search_read'],
        team        => ['search_read'],
        source      => ['search_read'],
        medium      => ['search_read'],
        campaign    => ['search_read'],
        'res.users' => ['search_read'],
    };
}
sub write_scope ($class) {
    { lead => ['write'], source => ['create'], medium => ['create'], campaign => ['create'] };
}

sub plan ($self) {
    my $p = $self->profile;
    my ( %set, @support );
    for my $lf (@FIELDS) {
        my $name = $self->param($lf) // next;
        my $v    = $self->_id_for( $lf, $name );
        if ( !defined $v ) {
            my $ref = "$lf:" . lc $name;
            push @support, { bucket => "new-$lf", action => 'create', model => $p->model_name($lf),
                vals => { $p->field( $lf => 'name' ) => $name }, ref => $ref, support => 1,
                unique_by => $p->field( $lf => 'name' ) };
            $v = { '$ref' => $ref };
        }
        $set{ $p->field( lead => $lf ) } = $v;
    }
    Odoo::Error->throw( kind => 'usage', message => 'crm.assign needs one of ' . join( ', ', @FIELDS ) ) if !%set;

    my $leads = $self->model('lead')->all( Odoo::Ops::CRM::Select->domain_for($self), [ sort keys %set ] );
    my $plan  = $self->new_plan( input_count => scalar @$leads );
    my $used  = 0;
    my @rows;
    for my $lead (@$leads) {
        my %vals = map { $_ => $set{$_} } grep {
            ref $set{$_} || ( ref $lead->{$_} eq 'ARRAY' ? $lead->{$_}[0] : 0 ) != $set{$_}
        } keys %set;
        if (%vals) {
            $used ||= grep { ref $vals{$_} } keys %vals;
            push @rows, { bucket => 'assign', action => 'write', model => $p->model_name('lead'),
                id => $lead->{id}, vals => \%vals, before => { map { $_ => $lead->{$_} } keys %vals },
                ( $self->param('notify') ? () : ( context => { mail_auto_subscribe_no_notify => 1 } ) ) };
        }
        else {
            push @rows, { bucket => 'unchanged', action => 'skip', id => $lead->{id} };
        }
    }
    $plan->add(%$_) for ( $used ? @support : () ), @rows;
    return $plan;
}

# id of the named record; undef when it does not exist and may be created.
sub _id_for ($self, $lf, $name) {
    if ( $lf eq 'salesperson' ) {
        my $u = $self->model('res.users')->search_read(
            [ '|', [ 'login', '=ilike', $name ], [ 'name', '=ilike', $name ] ], ['login'] );
        Odoo::Error->throw( kind => 'usage', message => "salesperson '$name' matches " . scalar(@$u) . ' users' )
            if @$u != 1;
        return $u->[0]{id};
    }
    my $p      = $self->profile;
    my $name_f = $p->field( $lf => 'name' );
    my $rows   = $self->model($lf)->search_read( [ [ $name_f, '=ilike', $name ] ], [$name_f] );
    return undef if !@$rows && $CREATABLE{$lf};
    Odoo::Error->throw( kind => 'usage', message => "$lf '$name' matches " . scalar(@$rows) . ' records' )
        if @$rows != 1;
    return $rows->[0]{id};
}

1;
