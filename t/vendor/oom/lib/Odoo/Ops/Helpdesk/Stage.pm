package Odoo::Ops::Helpdesk::Stage;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::Helpdesk::Common qw(ready id_of rows_of reason_text ticket_row pick_stage stage_change_row);

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::Stage - move tickets to a stage

=head1 SYNOPSIS

    oom-ops run helpdesk.stage --conf ops.conf --set ticket=HT00012 --set stage="In Progress"
    oom-ops run helpdesk.stage --conf ops.conf --rows rows=moves.json

=head1 DESCRIPTION

C<helpdesk.stage>: writes the ticket's stage (one ticket, or C<rows> of C<ticket> and C<stage>). The stage is an id
or a name; a name several stages carry is narrowed to those the ticket's team may use, and still several is
held C<ambiguous-stage>. A ticket already there is C<unchanged>.

With C<helpdesk_mgmt_stage_validation> a stage can require fields; Odoo refuses to put a ticket in it while they
are empty. The plan reads what the stage requires and the ticket holds and holds the row
C<missing-fields>, naming the fields in Odoo's words ("Ticket T can't be moved to the stage S until the following
fields are set: Category, Tags."): set them first (C<helpdesk.update>) and plan again. If the plan missed a
case Odoo refuses at apply, and the refusal is reported in Odoo's own words. A stage with an email template makes
Odoo mail the ticket's partner when a ticket reaches it; the plan line says so. Closing and reopening are
C<helpdesk.close> and C<helpdesk.reopen>, which choose the stage. Series 16 and 18.

=cut

sub op_name ($class) { 'helpdesk.stage' }
sub summary ($class) { 'Move tickets to a stage; a stage that requires fields the ticket lacks is refused, naming them' }
sub pack    ($class) { 'helpdesk' }

sub buckets ($class) {
    return [
        { name => 'stage',     meaning => 'the ticket\'s stage is written' },
        { name => 'unchanged', meaning => 'the ticket is already in the stage' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-ticket',   meaning => 'no ticket of that id or number that this login can read' },
        { name => 'unknown-stage',    meaning => 'no stage of that id or name' },
        { name => 'ambiguous-stage',  meaning => 'several stages carry the name and the ticket\'s team does not single one out' },
        { name => 'missing-fields',   meaning => 'the stage requires fields (helpdesk_mgmt_stage_validation) that the ticket leaves empty' },
        { name => 'invalid',          meaning => 'the ticket is named twice' },
    ];
}

my %ROW = ( ticket => 'str', stage => 'str' );

sub params ($class) {
    {   ticket => { type => 'str', help => 'the ticket id or number (HT00012)' },
        stage  => { type => 'str', help => 'the stage: an id or a name' },
        rows   => { type => 'rows', max => 100, row => {%ROW}, help => 'many tickets: ticket and stage each' },
    };
}
sub read_scope ($class) { { ticket => [qw(search_read read)], stage => [qw(search_read read)] } }
sub write_scope ($class) { { ticket => ['write'] } }

sub plan ($self) {
    my $p = ready($self);
    my $rows = rows_of( $self, { ticket => 'ticket', stage => 'stage' } );
    my $plan = $self->new_plan( input_count => scalar @$rows );
    my $n = 0;
    my %seen;
    for my $r (@$rows) {
        $n++;
        my $key = "ticket:$r->{ticket}";
        my $hold = sub ( $bucket, $why ) { $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => ( @$rows > 1 ? "row $n: " : '' ) . $why ); 1 };
        next if ( !defined $r->{stage} ) && $hold->( 'unknown-stage', 'the row names no stage' );
        my ( $t, $why ) = ticket_row( $self, $r->{ticket}, qw(title stage team) );
        next if !$t && $hold->( 'unknown-ticket', reason_text( $why, 'ticket', $r->{ticket} ) );
        next if $seen{ $t->{id} }++ && $hold->( 'invalid', "ticket $t->{id} is named by an earlier row; one row for each ticket" );
        my ( $row, $why2, @many ) = pick_stage( $self, $r->{stage}, id_of( $t->{f}{team} ) );
        next if !$row && $hold->( $why2 eq 'none' ? 'unknown-stage' : 'ambiguous-stage', reason_text( $why2, 'stage', $r->{stage}, @many ) );
        my $name = $row->{ $p->field( stage => 'name' ) } // $r->{stage};
        stage_change_row( $self, $plan, { ticket => $t, stage => $row->{id}, stage_name => $name, key => $key, bucket => 'stage' } );
    }
    return $plan;
}

1;
