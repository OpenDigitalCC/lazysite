package Odoo::Ops::Helpdesk::Categories;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Ops::Helpdesk::Common qw(ready flag name_of text fields_block fields_list);

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::Categories - the ticket categories

=head1 DESCRIPTION

C<helpdesk.categories>: one row per category in Odoo's order: C<id>, C<name>, C<active>,
C<company> and what the series gives a category: on 16 C<default_team> (a ticket made with the
category and no team belongs to it), on 18 C<parent>, C<complete_name> and C<show_in_portal>.
A field the series does not have reads empty. C<text> keeps the categories whose name holds
it; C<all> adds the archived ones. C<< { count, rows, fields } >>. Series 16 and 18.

=cut

sub op_name ($class) { 'helpdesk.categories' }
sub summary ($class) { 'Read the helpdesk ticket categories' }
sub pack    ($class) { 'helpdesk' }

my @COLS = (
    [ id => 'integer', 'Id' ], [ name => 'text', 'Name' ], [ complete_name => 'text', 'Parent / name (18)' ], [ active => 'boolean', 'Not archived' ],
    [ company => 'text', 'Company' ], [ default_team => 'text', 'The team a ticket of the category belongs to when it names none (16)' ],
    [ parent => 'text', 'Parent category (18)' ], [ show_in_portal => 'boolean', 'Offered on the portal form (18)' ],
);
sub fields ($class) { fields_list( \@COLS ) }

sub params ($class) {
    {   text => { type => 'str',  help => 'only categories whose name contains this' },
        all  => { type => 'bool', default => 0, help => 'include archived categories' },
    };
}
sub read_scope ($class) { { category => [qw(search_read)] } }

sub report ($self) {
    my $p = ready($self);
    my $f = sub ($lf) { $p->field( category => $lf ) };
    my @dom;
    push @dom, [ $f->('name'), 'ilike', $self->param('text') ] if defined $self->param('text');
    my @lf = grep { defined $f->($_) } qw(name complete_name active company default_team parent show_in_portal);
    my $rows = $self->model('category')->search_read( \@dom, [ map { $f->($_) } @lf ], order => 'sequence, id',
        ( $self->param('all') ? ( context => { active_test => JSON::PP::false } ) : () ) );
    my @out = map { my $c = $_; +{
        id => $c->{id}, name => $c->{ $f->('name') }, complete_name => ( defined $f->('complete_name') ? text( $c->{ $f->('complete_name') } ) : undef ),
        active => flag( $c->{ $f->('active') } ), company => name_of( $c->{ $f->('company') } ) || undef,
        default_team => ( defined $f->('default_team') ? name_of( $c->{ $f->('default_team') } ) || undef : undef ),
        parent => ( defined $f->('parent') ? name_of( $c->{ $f->('parent') } ) || undef : undef ),
        show_in_portal => ( defined $f->('show_in_portal') ? flag( $c->{ $f->('show_in_portal') } ) : undef ),
    } } @$rows;
    return { count => scalar @out, rows => \@out, fields => fields_block( \@COLS ) };
}

1;
