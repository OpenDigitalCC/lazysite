package Odoo::Ops::Helpdesk::Tags;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Ops::Helpdesk::Common qw(ready flag fields_block fields_list);

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::Tags - the ticket tags

=head1 DESCRIPTION

C<helpdesk.tags>: one row per tag in Odoo's order: C<id>, C<name>, C<color>, C<active>. C<text> keeps
the tags whose name holds it; C<all> adds the archived ones. A login that may not read tags
(a portal login) is refused by Odoo in its words. C<< { count, rows, fields } >>. Series 16 and 18.

=cut

sub op_name ($class) { 'helpdesk.tags' }
sub summary ($class) { 'Read the helpdesk ticket tags' }
sub pack    ($class) { 'helpdesk' }

my @COLS = ( [ id => 'integer', 'Id' ], [ name => 'text', 'Name' ], [ color => 'integer', 'Colour index' ], [ active => 'boolean', 'Not archived' ] );
sub fields ($class) { fields_list( \@COLS ) }

sub params ($class) {
    {   text => { type => 'str',  help => 'only tags whose name contains this' },
        all  => { type => 'bool', default => 0, help => 'include archived tags' },
    };
}
sub read_scope ($class) { { tag => [qw(search_read)] } }

sub report ($self) {
    my $p = ready($self);
    my $f = sub ($lf) { $p->field( tag => $lf ) };
    my @dom;
    push @dom, [ $f->('name'), 'ilike', $self->param('text') ] if defined $self->param('text');
    my $rows = $self->model('tag')->search_read( \@dom, [ map { $f->($_) } qw(name color active) ], order => 'sequence, id',
        ( $self->param('all') ? ( context => { active_test => JSON::PP::false } ) : () ) );
    my @out = map { +{ id => $_->{id}, name => $_->{ $f->('name') }, color => $_->{ $f->('color') } // 0, active => flag( $_->{ $f->('active') } ) } } @$rows;
    return { count => scalar @out, rows => \@out, fields => fields_block( \@COLS ) };
}

1;
