package Odoo::Ops::Helpdesk::TicketList;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::Helpdesk::Common qw(id_of name_of flag text look partner_row user_row reason_text spec_list);

=head1 NAME

Odoo::Ops::Helpdesk::TicketList - the filters and the rows of the ticket lists

=head1 DESCRIPTION

Not an operation: the one place C<helpdesk.tickets> and C<helpdesk.my_tickets> build their domain
from the caller's filters and shape a ticket row, so the two lists name the same things the same
way. A filter that names a team, stage, category, tag, user or partner that does not exist is
refused C<unknown-team>, C<unknown-stage> and so on, naming the value; an ambiguous name is refused
and says which ids it matches.

=cut

our %ORDER = (
    default => undef,                                  # Odoo's own order: priority desc, sequence, number desc
    newest  => 'create_date desc, id desc',
    oldest  => 'create_date, id',
    number  => 'number desc, id desc',
    updated => 'last_stage_update desc, id desc',
    priority => 'priority desc, create_date desc, id desc',
);

sub order_params () {
    return (
        order  => { type => 'str', default => 'default', help => 'default (Odoo\'s: priority, then newest number), newest, oldest, number, updated or priority' },
        limit  => { type => 'int', default => 50, help => 'rows to return (1 to 500)' },
        offset => { type => 'int', default => 0,  help => 'rows to skip' },
    );
}

=head2 page($op)

C<< ( $order, $limit, $offset ) >> from the operation's parameters, checked.

=cut

sub page ($op) {
    my $o = $op->param('order') // 'default';
    Odoo::Error->throw( kind => 'usage', message => $op->op_name . ": order '$o' is not one of " . join( ', ', sort keys %ORDER ), fix => 'oom-ops describe ' . $op->op_name )
        if !exists $ORDER{$o};
    my $limit = $op->param('limit') // 50;
    Odoo::Error->throw( kind => 'usage', message => $op->op_name . ': limit must be 1 to 500', fix => 'page with offset' ) if $limit < 1 || $limit > 500;
    my $offset = $op->param('offset') // 0;
    Odoo::Error->throw( kind => 'usage', message => $op->op_name . ': offset must be 0 or more' ) if $offset < 0;
    return ( $ORDER{$o}, $limit, $offset );
}

sub _one ( $op, $lm, $spec, $code, %o ) {
    my ( $row, $why, @many ) = look( $op, $lm, $spec, %o );
    Odoo::Error->throw( kind => 'refused', code => ( $code eq 'tag' ? 'unknown-tag' : 'unknown-record' ), message => ucfirst( reason_text( $why, $code, $spec, @many ) ),
        fix => 'oom-ops run helpdesk.' . ( $code eq 'team' ? 'teams' : $code eq 'stage' ? 'stages' : $code eq 'category' ? 'categories' : 'tags' ) . ' lists them' ) if !$row;
    return $row->{id};
}

=head2 priority_value($op, $word)

The selection value of a priority given as a value (C<2>) or as Odoo's label (C<High>), or a C<usage> error listing them.

=cut

sub priority_value ( $op, $word ) {
    my @sel = @{ $op->model('ticket')->selections( $op->profile->field( ticket => 'priority' ) ) };
    for my $s (@sel) { return $s->[0] if lc $word eq lc $s->[0] || lc $word eq lc $s->[1] }
    Odoo::Error->throw( kind => 'usage', message => $op->op_name . ": priority '$word' is not one of " . join( ', ', map { "$_->[0] ($_->[1])" } @sel ) );
}

=head2 domain($op, %o)

The domain of the filters the operation was given. C<customer> 1 leaves out the filters a customer's
login cannot use (user, partner, tag, SLA).

=cut

sub domain ( $op, %o ) {
    my $p = $op->profile;
    my $f = sub ($lf) { $p->field( ticket => $lf ) };
    my @d;
    push @d, [ $f->('team'), '=', _one( $op, team => $op->param('team'), 'team' ) ] if defined $op->param('team');
    if ( defined( my $s = $op->param('stage') ) ) {
        if ( $s =~ /\A[1-9]\d*\z/ ) { push @d, [ $f->('stage'), '=', 0 + $s ] }
        else {
            my $ids = $op->model('stage')->search( [ [ $p->field( stage => 'name' ), '=ilike', $s ] ] );
            Odoo::Error->throw( kind => 'refused', code => 'unknown-record', message => "No stage '$s' that this login can read", fix => 'oom-ops run helpdesk.stages lists them' ) if !@$ids;
            push @d, [ $f->('stage'), 'in', $ids ];
        }
    }
    push @d, [ $f->('category'), '=', _one( $op, category => $op->param('category'), 'category' ) ] if defined $op->param('category');
    push @d, [ $f->('priority'), '=', priority_value( $op, $op->param('priority') ) ] if defined $op->param('priority');
    if ( defined( my $st = $op->param('state') ) ) {
        Odoo::Error->throw( kind => 'usage', message => $op->op_name . ": state '$st' is not open, closed or all" ) if $st !~ /\A(?:open|closed|all)\z/;
        push @d, [ $p->field( ticket => 'stage' ) . '.' . $p->field( stage => 'closed' ), '=', $st eq 'closed' ? JSON::PP::true : JSON::PP::false ] if $st ne 'all';
    }
    if ( defined( my $t = $op->param('text') ) ) {
        push @d, '|', [ $f->('number'), 'ilike', $t ], [ $f->('title'), 'ilike', $t ];
    }
    push @d, [ 'id', 'in', [ map { 0 + $_ } @{ $op->param('ids') } ] ] if $op->param('ids') && @{ $op->param('ids') };
    return \@d if $o{customer};

    if ( defined( my $u = $op->param('user') ) ) {
        my ( $row, $why, @many ) = user_row( $op, $u );
        Odoo::Error->throw( kind => 'refused', code => 'unknown-record', message => ucfirst( reason_text( $why, 'user', $u, @many ) ), fix => 'give the id, the login or the exact name' ) if !$row;
        push @d, [ $f->('user'), '=', $row->{id} ];
    }
    push @d, [ $f->('user'), '=', JSON::PP::false ] if $op->param('unassigned');
    if ( defined( my $pa = $op->param('partner') ) ) {
        my ( $row, $why, @many ) = partner_row( $op, $pa );
        Odoo::Error->throw( kind => 'refused', code => 'unknown-record', message => ucfirst( reason_text( $why, 'partner', $pa, @many ) ), fix => 'give the id, the email address or the exact name' ) if !$row;
        push @d, [ $f->('partner'), 'child_of', $row->{id} ];
    }
    if ( defined( my $tg = $op->param('tag') ) ) {
        push @d, [ $f->('tags'), '=', _one( $op, tag => $tg, 'tag' ) ];
    }
    push @d, [ $f->('sla_expired'), '=', JSON::PP::true ] if $op->param('sla_expired') && defined $f->('sla_expired');
    if ( defined( my $due = $op->param('sla_due_before') ) ) {
        Odoo::Error->throw( kind => 'refused', code => 'not-applicable', message => 'helpdesk.tickets: sla_due_before needs helpdesk_mgmt_sla, which is not installed here' ) if !defined $f->('sla_deadline');
        Odoo::Error->throw( kind => 'usage', message => "helpdesk.tickets: sla_due_before '$due' is not a date (YYYY-MM-DD or YYYY-MM-DD HH:MM:SS, UTC)" )
            if $due !~ /\A\d{4}-\d\d-\d\d(?: \d\d:\d\d:\d\d)?\z/;
        if ( $p->series == 18 ) {
            # 18 holds the deadline per rule: the open tickets with a rule still running that is due before the date
            my $sf = sub ($lf) { $p->field( ticket_sla => $lf ) };
            my $rows = $op->model('ticket_sla')->search_read( [ [ $sf->('state'), '=', 'in_progress' ], [ $sf->('deadline'), '<', $due ] ], [ $sf->('ticket') ] );
            push @d, [ 'id', 'in', [ keys %{ { map { id_of( $_->{ $sf->('ticket') } ) => 1 } @$rows } } ] ];
        }
        else {
            push @d, [ $f->('sla_deadline'), '<', $due ], [ $p->field( ticket => 'stage' ) . '.' . $p->field( stage => 'closed' ), '=', JSON::PP::false ];
        }
    }
    return \@d;
}

=head2 shape($op, \@rows, %o)

The rows as the operations return them: logical keys, the names of the records they point at, the
tag names. C<customer> 1 returns only what a customer's login may read.

=cut

sub fields_to_read ( $op, %o ) {
    my $p = $op->profile;
    my @lf = $o{customer}
        ? qw(number title partner team user stage closed category priority created last_stage_update closed_date)
        : qw(number title partner partner_email team user stage closed category tags channel priority created last_stage_update closed_date assigned_date sla_deadline sla_expired);
    return grep { defined $p->field( ticket => $_ ) } @lf;
}

sub shape ( $op, $rows, %o ) {
    my $p = $op->profile;
    my $f = sub ($lf) { $p->field( ticket => $lf ) };
    my %tag;
    if ( !$o{customer} && defined $f->('tags') ) {
        my @ids = keys %{ { map { $_ => 1 } map { @{ $_->{ $f->('tags') } // [] } } @$rows } };
        %tag = map { $_->{id} => $_->{ $p->field( tag => 'name' ) } } @{ $op->model('tag')->read( \@ids, [ $p->field( tag => 'name' ) ] ) } if @ids;
    }
    my %plabel = map { $_->[0] => $_->[1] } @{ $op->model('ticket')->selections( $f->('priority') ) };
    my $date = sub ($v) { defined $v && !ref $v && length $v ? $v : undef };
    return [ map {
        my $r = $_;
        my %o_ = (
            id => $r->{id}, number => text( $r->{ $f->('number') } ), title => $r->{ $f->('title') },
            partner => ( id_of( $r->{ $f->('partner') } ) ? { id => id_of( $r->{ $f->('partner') } ), name => name_of( $r->{ $f->('partner') } ) } : undef ),
            team => name_of( $r->{ $f->('team') } ) || undef, user => name_of( $r->{ $f->('user') } ) || undef,
            stage => name_of( $r->{ $f->('stage') } ) || undef, closed => flag( $r->{ $f->('closed') } ),
            category => name_of( $r->{ $f->('category') } ) || undef,
            priority => $r->{ $f->('priority') }, priority_name => $plabel{ $r->{ $f->('priority') } // '' },
            created => $date->( $r->{ $f->('created') } ), last_stage_update => $date->( $r->{ $f->('last_stage_update') } ),
            closed_date => $date->( $r->{ $f->('closed_date') } ),
        );
        if ( !$o{customer} ) {
            %o_ = ( %o_,
                partner_email => text( $r->{ $f->('partner_email') } ),
                tags    => [ map { $tag{$_} } @{ $r->{ $f->('tags') } // [] } ],
                channel => name_of( $r->{ $f->('channel') } ) || undef,
                assigned_date => $date->( $r->{ $f->('assigned_date') } ),
                sla_deadline => ( defined $f->('sla_deadline') ? $date->( $r->{ $f->('sla_deadline') } ) : undef ),
                sla_expired  => ( defined $f->('sla_expired') ? flag( $r->{ $f->('sla_expired') } ) : undef ),
            );
        }
        \%o_;
    } @$rows ];
}

our @COLS_CUSTOMER = (
    [ id => 'integer', 'Id' ], [ number => 'text', 'Ticket number (HT00012)' ], [ title => 'text', 'Subject' ],
    [ partner => 'json', 'The ticket\'s contact: { id, name }' ], [ team => 'text', 'Team' ], [ user => 'text', 'Assigned to' ],
    [ stage => 'text', 'Stage' ], [ closed => 'boolean', 'The stage is a closed one' ], [ category => 'text', 'Category' ],
    [ priority => 'text', 'Priority value: 0 Low, 1 Medium, 2 High, 3 Very High' ], [ priority_name => 'text', 'Priority label' ],
    [ created => 'datetime', 'Made (UTC)' ], [ last_stage_update => 'datetime', 'Last stage change (UTC)' ], [ closed_date => 'datetime', 'When it was last closed (UTC)' ],
);
our @COLS_OPERATOR = (
    @COLS_CUSTOMER,
    [ partner_email => 'text', 'The email address on the ticket' ], [ tags => 'json', 'Tag names' ], [ channel => 'text', 'Channel' ],
    [ assigned_date => 'datetime', 'When the user was set (UTC)' ],
    [ sla_deadline => 'datetime', 'SLA deadline (UTC; helpdesk_mgmt_sla)' ], [ sla_expired => 'boolean', 'SLA expired (helpdesk_mgmt_sla)' ],
);

1;
