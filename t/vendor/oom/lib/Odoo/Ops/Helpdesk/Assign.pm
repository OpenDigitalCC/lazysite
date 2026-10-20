package Odoo::Ops::Helpdesk::Assign;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::Helpdesk::Common qw(ready id_of rows_of look user_row reason_text ticket_row members_of_team);

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::Assign - give a ticket to a user, a team, or both

=head1 SYNOPSIS

    oom-ops run helpdesk.assign --conf ops.conf --set ticket=HT00012 --set user=ann@support.example
    oom-ops run helpdesk.assign --conf ops.conf --set ticket=HT00012 --set team=Support --set user=ann@support.example
    oom-ops run helpdesk.assign --conf ops.conf --set ticket=HT00012 --set unassign=1

=head1 DESCRIPTION

C<helpdesk.assign>: writes the ticket's user and/or team (one ticket, or C<rows> of C<ticket>, C<user>, C<team>).
A user is an id, a login or a name; a team an id or a name. A user who is not active, not found, or ambiguous is
held (C<unknown-user>), and a user who is not a member of the team the ticket will be in (the team named, else its
own) is held C<not-a-member>, naming the user and the team: Odoo's form offers only a team's members, and
the server accepts any user. C<unassign> clears the user. Odoo emails the new user "you have been assigned" from
the acting user unless C<notify> is off (the default; the plan carries C<mail_auto_subscribe_no_notify>).
A change of team has the effects of the series (16 puts the ticket back in the team's first stage;
18 removes a user who is not in the new team); the plan shows them.

    assign           the user and/or team are written
    unchanged        the ticket already has them
    unknown-ticket, unknown-team, unknown-user, not-a-member, invalid   a row waits for a person

Series 16 and 18.

=cut

sub op_name ($class) { 'helpdesk.assign' }
sub summary ($class) { 'Give a ticket to a user and/or a team; a non-member user is refused, naming them' }
sub pack    ($class) { 'helpdesk' }

sub buckets ($class) {
    return [
        { name => 'assign',    meaning => 'the ticket\'s user and/or team are written' },
        { name => 'unchanged', meaning => 'the ticket already has them' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-ticket', meaning => 'no ticket of that id or number that this login can read' },
        { name => 'unknown-team',   meaning => 'no team of that id or name' },
        { name => 'unknown-user',   meaning => 'no active user of that id, login or name, or the name matches several' },
        { name => 'not-a-member',   meaning => 'the user is not a member of the team the ticket will be in' },
        { name => 'invalid',        meaning => 'the row names neither a user nor a team, or both a user and unassign' },
    ];
}

my %ROW = ( ticket => 'str', user => 'str?', team => 'str?', unassign => 'bool?' );

sub params ($class) {
    {   ticket   => { type => 'str',  help => 'the ticket id or number (HT00012)' },
        user     => { type => 'str',  help => 'the user: an id, a login or a name' },
        team     => { type => 'str',  help => 'the team: an id or a name' },
        unassign => { type => 'bool', default => 0, help => 'clear the ticket\'s user' },
        notify   => { type => 'bool', default => 0, help => 'let Odoo email "you have been assigned" to the new user' },
        rows     => { type => 'rows', max => 100, row => {%ROW}, help => 'many tickets: ticket and user and/or team (or unassign) each' },
    };
}
sub read_scope ($class) { { ticket => [qw(search_read read)], team => [ 'search_read', 'read' ], user => [ 'search_read', 'read' ] } }
sub write_scope ($class) { { ticket => ['write'] } }

sub plan ($self) {
    my $p = ready($self);
    my $f = sub ($lf) { $p->field( ticket => $lf ) };
    my $rows = $self->param('rows');
    Odoo::Error->throw( kind => 'usage', message => 'helpdesk.assign: give rows or one ticket with a user and/or team, not both' )
        if $rows && ( defined $self->param('ticket') || defined $self->param('user') || defined $self->param('team') || $self->param('unassign') );
    Odoo::Error->throw( kind => 'usage', message => 'helpdesk.assign: give a ticket and a user and/or team, or rows' ) if !$rows && !defined $self->param('ticket');
    $rows ||= [ { ticket => $self->param('ticket'), ( map { $_ => $self->param($_) } grep { defined $self->param($_) } qw(user team) ), ( $self->param('unassign') ? ( unassign => 1 ) : () ) } ];
    my $plan = $self->new_plan( input_count => scalar @$rows );
    my $n = 0;
    my %seen;
    for my $r (@$rows) {
        $n++;
        my $key = "ticket:$r->{ticket}";
        my $hold = sub ( $bucket, $why ) { $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => ( @$rows > 1 ? "row $n: " : '' ) . $why ); 1 };
        next if ( !defined $r->{user} && !defined $r->{team} && !$r->{unassign} ) && $hold->( 'invalid', 'the row names a user, a team, or unassign' );
        next if defined $r->{user} && $r->{unassign} && $hold->( 'invalid', 'a user and unassign together' );
        my ( $t, $why ) = ticket_row( $self, $r->{ticket}, qw(user team) );
        next if !$t && $hold->( 'unknown-ticket', reason_text( $why, 'ticket', $r->{ticket} ) );
        next if $seen{ $t->{id} }++ && $hold->( 'invalid', "ticket $t->{id} is named by an earlier row; one row for each ticket" );
        my ( %vals, %before );
        my $team_id = id_of( $t->{f}{team} );
        my $team_name = Odoo::Ops::Helpdesk::Common::name_of( $t->{f}{team} );
        if ( defined $r->{team} ) {
            my ( $row, $why2, @many ) = look( $self, team => $r->{team}, fields => ['name'] );
            next if !$row && $hold->( 'unknown-team', reason_text( $why2, 'team', $r->{team}, @many ) );
            ( $team_id, $team_name ) = ( $row->{id}, $row->{ $p->field( team => 'name' ) } );
            if ( ( id_of( $t->{f}{team} ) // 0 ) != $row->{id} ) { $vals{ $f->('team') } = $row->{id}; $before{ $f->('team') } = $t->{f}{team} }
        }
        my $user_id = id_of( $t->{f}{user} );
        if ( defined $r->{user} ) {
            my ( $row, $why2, @many ) = user_row( $self, $r->{user} );
            next if !$row && $hold->( 'unknown-user', reason_text( $why2, 'user', $r->{user}, @many ) );
            if ($team_id) {
                my $members = members_of_team( $self, $team_id );
                next if !exists $members->{ $row->{id} } && $hold->( 'not-a-member', "user '$r->{user}' is not a member of team '$team_name'"
                    . ( %$members ? ' (members: ' . join( ', ', map { $members->{$_} } sort { $a <=> $b } keys %$members ) . ')' : ' (it has no members)' ) );
            }
            $user_id = $row->{id};
            if ( ( id_of( $t->{f}{user} ) // 0 ) != $row->{id} ) { $vals{ $f->('user') } = $row->{id}; $before{ $f->('user') } = $t->{f}{user} }
        }
        elsif ( $r->{unassign} && defined id_of( $t->{f}{user} ) ) {
            $vals{ $f->('user') } = undef;
            $before{ $f->('user') } = $t->{f}{user};
        }
        if (%vals) {
            $plan->add( bucket => 'assign', action => 'write', model => $p->model_name('ticket'), id => $t->{id}, key => $key, vals => \%vals, before => \%before,
                ( $self->param('notify') ? () : ( context => { mail_auto_subscribe_no_notify => 1 } ) ) );
        }
        else {
            $plan->add( bucket => 'unchanged', action => 'skip', id => $t->{id}, key => $key, reason => "ticket $t->{id} already has this user and team" );
        }
    }
    return $plan;
}

1;
