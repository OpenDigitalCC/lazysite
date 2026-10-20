package Odoo::Ops::Helpdesk::Close;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Ops::Helpdesk::Common qw(ready move_tickets);

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::Close - close tickets

=head1 SYNOPSIS

    oom-ops run helpdesk.close --conf ops.conf --set ticket=HT00012
    oom-ops run helpdesk.close --conf ops.conf --set ticket=HT00012,HT00013 --set stage=Cancelled

=head1 DESCRIPTION

C<helpdesk.close>: moves each named ticket (C<ticket>, ids or numbers, comma separated) to a closed stage: the
stage named by C<stage> (which must be a closed one), else the first closed stage the ticket's team may use, in
Odoo's order (the stages with no team and the stages that name the team, by sequence). There is no close method
in the module: closing is the stage write, so it goes through the stage rule of C<helpdesk.stage> (a stage that
requires fields the ticket lacks is held C<missing-fields>) and Odoo mails the stage's template to the
ticket's partner, which the plan line says. A ticket already closed is C<unchanged>. The revert writes the stage the ticket had. Series 16 and 18.

=cut

sub op_name ($class) { 'helpdesk.close' }
sub summary ($class) { 'Close tickets: to the team\'s first closed stage, or the one named' }
sub pack    ($class) { 'helpdesk' }

sub buckets ($class) {
    return [
        { name => 'close',     meaning => 'the ticket is moved to a closed stage' },
        { name => 'unchanged', meaning => 'the ticket is already closed' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-ticket',  meaning => 'no ticket of that id or number that this login can read' },
        { name => 'unknown-stage',   meaning => 'no stage of that id or name' },
        { name => 'ambiguous-stage', meaning => 'several stages carry the name and the ticket\'s team does not single one out' },
        { name => 'wrong-stage',     meaning => 'the stage named is not a closed one' },
        { name => 'no-stage',        meaning => 'the ticket\'s team may use no closed stage' },
        { name => 'missing-fields',  meaning => 'the stage requires fields (helpdesk_mgmt_stage_validation) that the ticket leaves empty' },
        { name => 'invalid',         meaning => 'the ticket is named twice' },
    ];
}

sub params ($class) {
    {   ticket => { type => 'list', required => 1, help => 'ticket ids or numbers, comma separated' },
        stage  => { type => 'str',  help => 'a closed stage (an id or a name); the default is the first the ticket\'s team may use' },
    };
}
sub read_scope ($class) { { ticket => [qw(search_read read)], stage => [qw(search_read read)] } }
sub write_scope ($class) { { ticket => ['write'] } }

sub plan ($self) {
    ready($self);
    my $plan = $self->new_plan( input_count => scalar @{ $self->param('ticket') } );
    move_tickets( $self, $plan, 1 );
    return $plan;
}

1;
