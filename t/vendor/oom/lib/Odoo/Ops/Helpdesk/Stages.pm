package Odoo::Ops::Helpdesk::Stages;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::Helpdesk::Common qw(ready flag name_of fields_block fields_list look stage_wants);

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::Stages - the stages a ticket moves through, with what each asks of it

=head1 SYNOPSIS

    oom-ops run helpdesk.stages --conf ops.conf
    oom-ops run helpdesk.stages --conf ops.conf --set team="Support"

=head1 DESCRIPTION

C<helpdesk.stages>: one row per stage, in Odoo's order (sequence): C<id>, C<name>, C<sequence>,
C<closed> (a ticket in it is closed), C<unattended>, C<fold>, C<close_from_portal> (the
stage a customer may close a ticket to), C<template> (the name of the email Odoo sends the
ticket's partner when a ticket reaches it, empty when none), C<teams> (the teams that use
it; empty means every team) and, with C<helpdesk_mgmt_stage_validation>, C<requires> (the
fields a ticket must hold to reach it, as C<< [ { name, label } ] >>). C<team> (an id or
a name) keeps the stages that team may use: those with no team and those that name it.
C<all> adds the archived stages. C<< { count, rows, fields } >>.

=cut

sub op_name ($class) { 'helpdesk.stages' }
sub summary ($class) { 'Read the helpdesk stages: closed flag, portal close, email template, the fields each requires' }
sub pack    ($class) { 'helpdesk' }

my @COLS = (
    [ id => 'integer', 'Id' ], [ name => 'text', 'Name' ], [ sequence => 'integer', 'Order' ], [ closed => 'boolean', 'A ticket in it is closed' ],
    [ unattended => 'boolean', 'A ticket in it is unattended' ], [ fold => 'boolean', 'Folded in the kanban' ],
    [ close_from_portal => 'boolean', 'A customer may close a ticket to this stage' ],
    [ template => 'text', 'The email template Odoo sends the ticket\'s partner when a ticket reaches the stage' ],
    [ teams => 'json', 'Teams that use the stage: [ { id, name } ]; empty means every team' ],
    [ requires => 'json', 'Fields a ticket must hold to reach the stage (helpdesk_mgmt_stage_validation): [ { name, label } ]' ],
    [ active => 'boolean', 'Not archived' ],
);
sub fields ($class) { fields_list( \@COLS ) }

sub params ($class) {
    {   team => { type => 'str',  help => 'only the stages this team may use (an id or a name)' },
        all  => { type => 'bool', default => 0, help => 'include archived stages' },
    };
}
sub read_scope ($class) { { stage => [qw(search_read read)], team => [ 'search_read', 'read' ] } }

sub report ($self) {
    my $p = ready($self);
    my $f = sub ($lf) { $p->field( stage => $lf ) };
    my @dom;
    my $tid;
    if ( defined( my $t = $self->param('team') ) ) {
        my ( $row, $why, @many ) = look( $self, 'team', $t );
        Odoo::Error->throw( kind => 'refused', code => 'unknown-record', message => "team '$t' " . ( $why eq 'none' ? 'is not a team this login can read' : 'names several teams; give the id' ),
            fix => 'oom-ops run helpdesk.teams lists them' ) if !$row;
        $tid = $row->{id};
        push @dom, '|', [ $f->('teams'), '=', JSON::PP::false ], [ $f->('teams'), 'in', [$tid] ];
    }
    my @lf = grep { defined $f->($_) } qw(name sequence closed unattended fold close_from_portal template teams validate active);
    my $rows = $self->model('stage')->search_read( \@dom, [ map { $f->($_) } @lf ], order => 'sequence, id',
        ( $self->param('all') ? ( context => { active_test => JSON::PP::false } ) : () ) );
    my %team;
    my @tids = keys %{ { map { $_ => 1 } map { @{ $_->{ $f->('teams') } // [] } } @$rows } };
    if (@tids) { %team = map { $_->{id} => $_->{ $p->field( team => 'name' ) } } @{ $self->model('team')->read( \@tids, [ $p->field( team => 'name' ) ] ) } }
    my @out;
    for my $s (@$rows) {
        my $want = defined $f->('validate') ? stage_wants( $self, $s->{id} ) : [];
        push @out, {
            id => $s->{id}, name => $s->{ $f->('name') }, sequence => $s->{ $f->('sequence') },
            closed => flag( $s->{ $f->('closed') } ), unattended => flag( $s->{ $f->('unattended') } ), fold => flag( $s->{ $f->('fold') } ),
            close_from_portal => flag( $s->{ $f->('close_from_portal') } ), active => flag( $s->{ $f->('active') } ),
            template => name_of( $s->{ $f->('template') } ) || undef,
            teams    => [ map { { id => $_, name => $team{$_} } } @{ $s->{ $f->('teams') } // [] } ],
            requires => [ map { { name => $_->{name}, label => $_->{label} } } @$want ],
        };
    }
    return { count => scalar @out, rows => \@out, fields => fields_block( \@COLS ) };
}

1;
