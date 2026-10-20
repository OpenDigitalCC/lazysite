package Odoo::Ops::Helpdesk::Teams;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::Helpdesk::Common qw(ready flag name_of text fields_block fields_list);

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::Teams - the helpdesk teams, with their members

=head1 SYNOPSIS

    oom-ops run helpdesk.teams --conf ops.conf
    oom-ops run helpdesk.teams --conf ops.conf --set text=support

=head1 DESCRIPTION

C<helpdesk.teams>: one row per team the login can read, by Odoo's order (sequence):
C<id>, C<name>, C<active>, C<company>, C<leader>, C<members> (C<< [ { id, name } ] >>,
the users C<helpdesk.assign> may name for the team), C<categories> (names), C<show_in_portal>,
C<alias> (the name of the team's mail alias, empty when it has none and is inactive),
C<open> (Odoo's count of the team's open tickets) and, with C<helpdesk_mgmt_sla>, C<use_sla>
and C<calendar> (the working hours the SLA runs on). C<text> keeps the teams whose name
holds it; C<all> adds the archived ones. The report is C<< { count, rows, fields } >>.
Series: 16 and 18; any other is refused C<not-applicable>.

=cut

sub op_name ($class) { 'helpdesk.teams' }
sub summary ($class) { 'Read the helpdesk teams with their members, categories and mail alias' }
sub pack    ($class) { 'helpdesk' }

my @COLS = (
    [ id => 'integer', 'Id' ], [ name => 'text', 'Name' ], [ active => 'boolean', 'Not archived' ],
    [ company => 'text', 'Company' ], [ leader => 'text', 'Team leader' ],
    [ members => 'json', 'Members: [ { id, name } ], the users a ticket of the team may be assigned to' ],
    [ categories => 'json', 'Names of the categories the team takes' ],
    [ show_in_portal => 'boolean', 'Offered on the portal form' ], [ alias => 'text', 'The mail alias name, empty when the alias is inactive' ],
    [ open => 'integer', 'Open tickets (Odoo\'s count)' ], [ use_sla => 'boolean', 'The team uses SLA (helpdesk_mgmt_sla)' ],
    [ calendar => 'text', 'Working hours the SLA runs on (helpdesk_mgmt_sla)' ],
);
sub fields ($class) { fields_list( \@COLS ) }

sub params ($class) {
    {   text => { type => 'str',  help => 'only teams whose name contains this' },
        all  => { type => 'bool', default => 0, help => 'include archived teams' },
    };
}
sub read_scope ($class) { { team => [qw(search_read read)], user => ['search_read'], category => ['read'] } }

sub report ($self) {
    my $p = ready($self);
    my $f = sub ($lf) { $p->field( team => $lf ) };
    my @dom;
    push @dom, [ $f->('name'), 'ilike', $self->param('text') ] if defined $self->param('text');
    my @lf = grep { defined $f->($_) } qw(name active company leader members categories show_in_portal alias open_count use_sla calendar);
    my $rows = $self->model('team')->search_read( \@dom, [ map { $f->($_) } @lf ],
        order => 'sequence, id', ( $self->param('all') ? ( context => { active_test => JSON::PP::false } ) : () ) );
    my ( %users, %cats );
    my @uids = keys %{ { map { $_ => 1 } map { @{ $_->{ $f->('members') } // [] } } @$rows } };
    if (@uids) { %users = map { $_->{id} => $_->{ $p->field( user => 'name' ) } } @{ $self->model('user')->search_read( [ [ 'id', 'in', \@uids ] ], [ $p->field( user => 'name' ) ], context => { active_test => JSON::PP::false } ) } }
    my @cids = keys %{ { map { $_ => 1 } map { @{ $_->{ $f->('categories') } // [] } } @$rows } };
    if (@cids) { %cats = map { $_->{id} => $_->{ $p->field( category => 'name' ) } } @{ $self->model('category')->read( \@cids, [ $p->field( category => 'name' ) ] ) } }
    my @out;
    for my $t (@$rows) {
        push @out, {
            id             => $t->{id},
            name           => $t->{ $f->('name') },
            active         => flag( $t->{ $f->('active') } ),
            company        => name_of( $t->{ $f->('company') } ),
            leader         => name_of( $t->{ $f->('leader') } ),
            members        => [ map { { id => $_, name => $users{$_} } } @{ $t->{ $f->('members') } // [] } ],
            categories     => [ map { $cats{$_} } @{ $t->{ $f->('categories') } // [] } ],
            show_in_portal => flag( $t->{ $f->('show_in_portal') } ),
            alias          => text( $t->{ $f->('alias') } ),
            open           => $t->{ $f->('open_count') } // 0,
            use_sla        => defined $f->('use_sla') ? flag( $t->{ $f->('use_sla') } ) : undef,
            calendar       => defined $f->('calendar') ? name_of( $t->{ $f->('calendar') } ) : undef,
        };
    }
    return { count => scalar @out, rows => \@out, fields => fields_block( \@COLS ) };
}

1;
