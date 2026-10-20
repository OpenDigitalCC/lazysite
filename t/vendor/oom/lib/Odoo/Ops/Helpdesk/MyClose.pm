package Odoo::Ops::Helpdesk::MyClose;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops::Helpdesk::Common qw(ready id_of name_of ticket_row reason_text applicable_stages stage_change_row);

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::MyClose - a customer closes their company's ticket

=head1 SYNOPSIS

    oom-ops run helpdesk.my_close --conf customer.conf --set ticket=HT00012

=head1 DESCRIPTION

C<helpdesk.my_close>: closes a ticket of the customer's company where the module lets a customer do so: the
stages with C<close_from_portal> on (the module's "close from portal" setting of a stage; there is no setting
on the team). The ticket must be one whose partner is the customer's company or one of its contacts
(C<commercial_partner_id>, checked by C<own>): a ticket that is not, or is not there, is refused C<not-yours>
in the same words, and a ticket the customer only follows is not closed by them. The stage is the first closable
one the ticket's team may use, or C<stage> (an id or a name) when it is one of those; a stage that is not closable from
the portal is held C<not-closable>. A portal login cannot write a ticket, so the service login named in the config
(C<act_as_conf>) writes the stage; the stage rule of C<helpdesk.stage> applies (a stage that requires fields the
ticket lacks is held C<missing-fields>) and Odoo mails the stage's template. A ticket already closed is
C<unchanged>. Odoo's own portal route for this (C</ticket/close>) checks no ownership; this operation does.
Series 16 and 18.

=cut

sub op_name ($class) { 'helpdesk.my_close' }
sub summary ($class) { 'A customer closes their company\'s ticket to a stage the portal may close to' }
sub pack    ($class) { 'helpdesk' }
sub acts_for ($class) { 1 }

sub buckets ($class) {
    return [
        { name => 'close',     meaning => 'the ticket is moved to a stage a customer may close it to' },
        { name => 'unchanged', meaning => 'the ticket is already closed' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-ticket', meaning => 'the customer\'s login can read no ticket of that id or number' },
        { name => 'not-closable',   meaning => 'the stage named is not one a customer may close a ticket to, or the ticket\'s team has none' },
        { name => 'missing-fields', meaning => 'the stage requires fields (helpdesk_mgmt_stage_validation) that the ticket leaves empty' },
    ];
}

sub params ($class) {
    {   ticket => { type => 'str', required => 1, help => 'the ticket id or number (HT00012)' },
        stage  => { type => 'str', help => 'a stage a customer may close to (an id or a name); the default is the first the ticket\'s team may use' },
    };
}
sub read_scope ($class) { { ticket => [qw(search_read read)], stage => [qw(search_read read)] } }
sub write_scope ($class) { { ticket => ['write'] } }

sub plan ($self) {
    my $p = ready($self);
    my $plan = $self->new_plan( input_count => 1 );
    my $spec = $self->param('ticket');
    my $key = "ticket:$spec";
    my $hold = sub ( $bucket, $why ) { $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => $why ); return $plan };
    my ( $t, $why ) = ticket_row( $self, $spec, qw(title stage team closed) );
    return $hold->( 'unknown-ticket', "no ticket '$spec' that this login can read" ) if !$t;
    $self->own( model => 'ticket', ids => [ $t->{id} ], field => $p->field( ticket => 'commercial_partner' ) );
    if ( $t->{f}{closed} ) {
        $plan->add( bucket => 'unchanged', action => 'skip', id => $t->{id}, key => $key, reason => "ticket $t->{id} is already closed" );
        return $plan;
    }
    my @ok = @{ applicable_stages( $self, id_of( $t->{f}{team} ), close_from_portal => 1 ) };
    return $hold->( 'not-closable', 'no stage the ticket\'s team may use can be closed to from the portal' ) if !@ok;
    my $pick;
    if ( defined $self->param('stage') ) {
        my $s = $self->param('stage');
        ($pick) = $s =~ /\A[1-9]\d*\z/ ? grep { $_->{id} == $s } @ok : grep { lc $_->{name} eq lc $s } @ok;
        return $hold->( 'not-closable', "stage '$s' is not one a customer may close a ticket to (" . join( ', ', map { $_->{name} } @ok ) . ')' ) if !$pick;
    }
    else { $pick = $ok[0] }
    stage_change_row( $self, $plan, { ticket => $t, stage => $pick->{id}, stage_name => $pick->{name}, key => $key, bucket => 'close' } );
    return $plan;
}

1;
