package Odoo::Ops::Helpdesk::MyTickets;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Ops::Helpdesk::Common qw(ready fields_block fields_list);
use Odoo::Ops::Helpdesk::TicketList;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::MyTickets - the tickets Odoo lets a customer's login see

=head1 SYNOPSIS

    oom-ops run helpdesk.my_tickets --conf customer.conf --set state=open

=head1 DESCRIPTION

C<helpdesk.my_tickets>: run as the customer's own Odoo login (a portal user). OOM adds no
rule of its own to what the customer sees: the tickets are the ones Odoo's record rules give the
login, which on 16 and 18 are the tickets whose partner is the login's company (the commercial
partner) or one of its contacts, and the tickets whose followers include the company.
The rows are C<id>, C<number>, C<title>, C<partner>, C<team>, C<user> (the name of whoever the
ticket is assigned to), C<stage>, C<closed>, C<category>, C<priority>, C<priority_name>, C<created>,
C<last_stage_update> and C<closed_date>. Tags, channel, SLA and the internal notes of 18 are not
read: a portal login cannot read tags or channels, and the internal fields are an operator's.
Filters (ANDed): C<team>, C<stage>, C<category>, C<priority>, C<state> (C<open>, C<closed>,
C<all>), C<text>, C<ids>; C<order>, C<limit> and C<offset> as C<helpdesk.tickets>.
C<< { count, total, limit, offset, rows, fields } >>. Series 16 and 18.

=cut

sub op_name ($class) { 'helpdesk.my_tickets' }
sub summary ($class) { 'The tickets Odoo\'s rules let the customer\'s login see (as the customer)' }
sub pack    ($class) { 'helpdesk' }
sub fields ($class) { fields_list( \@Odoo::Ops::Helpdesk::TicketList::COLS_CUSTOMER ) }

sub params ($class) {
    {   team     => { type => 'str',  help => 'a team (an id or a name)' },
        stage    => { type => 'str',  help => 'a stage (an id or a name)' },
        category => { type => 'str',  help => 'a category (an id or a name)' },
        priority => { type => 'str',  help => 'a priority: 0 to 3 or Low, Medium, High, Very High' },
        state    => { type => 'str',  default => 'all', help => 'open, closed or all' },
        text     => { type => 'str',  help => 'in the ticket number or the subject' },
        ids      => { type => 'list', help => 'ticket ids, comma separated' },
        Odoo::Ops::Helpdesk::TicketList::order_params(),
    };
}
sub read_scope ($class) { { ticket => [qw(search_read search_count)], team => ['search_read'], stage => [qw(search search_read)], category => ['search_read'] } }

sub report ($self) {
    my $p = ready($self);
    my $dom = Odoo::Ops::Helpdesk::TicketList::domain( $self, customer => 1 );
    my ( $order, $limit, $offset ) = Odoo::Ops::Helpdesk::TicketList::page($self);
    my $m = $self->model('ticket');
    my @lf = Odoo::Ops::Helpdesk::TicketList::fields_to_read( $self, customer => 1 );
    my $rows = $m->search_read( $dom, [ map { $p->field( ticket => $_ ) } @lf ], limit => $limit, offset => $offset, ( defined $order ? ( order => $order ) : () ) );
    return {
        count => scalar @$rows, total => $m->count($dom), limit => $limit, offset => $offset,
        rows => Odoo::Ops::Helpdesk::TicketList::shape( $self, $rows, customer => 1 ),
        fields => fields_block( \@Odoo::Ops::Helpdesk::TicketList::COLS_CUSTOMER ),
    };
}

1;
