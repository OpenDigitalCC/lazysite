package Odoo::Ops::Helpdesk::Tickets;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Ops::Helpdesk::Common qw(ready fields_block fields_list);
use Odoo::Ops::Helpdesk::TicketList;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::Tickets - the tickets, filtered and paged

=head1 SYNOPSIS

    oom-ops run helpdesk.tickets --conf ops.conf --set state=open --set team=Support
    oom-ops run helpdesk.tickets --conf ops.conf --set sla_expired=1 --set order=oldest
    oom-ops run helpdesk.tickets --conf ops.conf --set text=printer --set limit=20 --set offset=20

=head1 DESCRIPTION

C<helpdesk.tickets>: the tickets the login can read, one row each, with the filters ANDed:
C<team>, C<stage> (an id or a name), C<user> (an id, a login or a name; C<unassigned> keeps
the tickets with none), C<partner> (an id, an email address or a name; the partner and its
contacts), C<category>, C<tag>, C<priority> (the value or Odoo's label), C<state> (C<open>,
C<closed> or C<all>, the default), C<text> (in the number or the subject), C<ids>,
C<sla_expired> and C<sla_due_before> (a UTC date or date and time; the open tickets whose
SLA deadline is earlier; needs C<helpdesk_mgmt_sla>). C<order> is one of C<default> (Odoo's
own), C<newest>, C<oldest>, C<number>, C<updated>, C<priority>; C<limit> (default 50, at most
500) and C<offset> page it. The answer is C<< { count (the rows returned), total (the tickets
that match), limit, offset, rows, fields } >>. A name that matches nothing is refused
C<unknown-team>, C<unknown-stage> and so on, naming it. Series 16 and 18.

Each row has C<id>, C<number>, C<title>, C<partner> (C<< { id, name } >>), C<partner_email>,
C<team>, C<user>, C<stage>, C<closed>, C<category>, C<tags>, C<channel>, C<priority>,
C<priority_name>, C<created>, C<last_stage_update>, C<closed_date>, C<assigned_date>,
C<sla_deadline> and C<sla_expired>. On 18 the deadline is the earliest deadline of the ticket's
running SLA rows (C<helpdesk.ticket> shows the rows); on 16 it is the field the SLA cron writes.

=cut

sub op_name ($class) { 'helpdesk.tickets' }
sub summary ($class) { 'Read tickets by team, stage, user, partner, category, tag, priority, open or closed, SLA, text' }
sub pack    ($class) { 'helpdesk' }
sub fields ($class) { fields_list( \@Odoo::Ops::Helpdesk::TicketList::COLS_OPERATOR ) }

sub params ($class) {
    {   team     => { type => 'str',  help => 'a team (an id or a name)' },
        stage    => { type => 'str',  help => 'a stage (an id or a name)' },
        user     => { type => 'str',  help => 'the assigned user (an id, a login or a name)' },
        unassigned => { type => 'bool', default => 0, help => 'only tickets with no user' },
        partner  => { type => 'str',  help => 'the ticket\'s partner or one of its contacts (an id, an email address or a name)' },
        category => { type => 'str',  help => 'a category (an id or a name)' },
        tag      => { type => 'str',  help => 'a tag (an id or a name)' },
        priority => { type => 'str',  help => 'a priority: 0 to 3 or Low, Medium, High, Very High' },
        state    => { type => 'str',  default => 'all', help => 'open, closed or all' },
        text     => { type => 'str',  help => 'in the ticket number or the subject' },
        ids      => { type => 'list', help => 'ticket ids, comma separated' },
        sla_expired    => { type => 'bool', default => 0, help => 'only tickets whose SLA has expired (helpdesk_mgmt_sla)' },
        sla_due_before => { type => 'str',  help => 'open tickets whose SLA deadline is before this UTC date or date and time (helpdesk_mgmt_sla)' },
        Odoo::Ops::Helpdesk::TicketList::order_params(),
    };
}
sub read_scope ($class) {
    { ticket => [qw(search_read search_count)], team => ['search_read'], stage => [qw(search search_read)], category => ['search_read'], tag => [qw(search_read read)],
      user => ['search_read'], partner => ['search_read'], 'helpdesk.ticket.sla' => ['search_read'] };
}

sub report ($self) {
    my $p = ready($self);
    my $dom = Odoo::Ops::Helpdesk::TicketList::domain($self);
    my ( $order, $limit, $offset ) = Odoo::Ops::Helpdesk::TicketList::page($self);
    my $m = $self->model('ticket');
    my @lf = Odoo::Ops::Helpdesk::TicketList::fields_to_read($self);
    my $rows = $m->search_read( $dom, [ map { $p->field( ticket => $_ ) } @lf ], limit => $limit, offset => $offset, ( defined $order ? ( order => $order ) : () ) );
    return {
        count => scalar @$rows, total => $m->count($dom), limit => $limit, offset => $offset,
        rows => Odoo::Ops::Helpdesk::TicketList::shape( $self, $rows ),
        fields => fields_block( \@Odoo::Ops::Helpdesk::TicketList::COLS_OPERATOR ),
    };
}

1;
