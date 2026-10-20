package Odoo::Ops::Helpdesk::Reopen;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Ops::Helpdesk::Common qw(ready move_tickets);

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::Reopen - reopen closed tickets

=head1 SYNOPSIS

    oom-ops run helpdesk.reopen --conf ops.conf --set ticket=HT00012

=head1 DESCRIPTION

C<helpdesk.reopen>: moves each named closed ticket to an open stage: the stage named by C<stage> (which must be an
open one), else the first open stage the ticket's team may use, in Odoo's order, which is the stage Odoo gives a
new ticket. The stage rule of C<helpdesk.stage> applies. A ticket already open is C<unchanged>. Odoo does not clear
the ticket's C<closed_date> when it reopens; the report says what it holds. Series 16 and 18.

=cut

sub op_name ($class) { 'helpdesk.reopen' }
sub summary ($class) { 'Reopen closed tickets: to the team\'s first open stage, or the one named' }
sub pack    ($class) { 'helpdesk' }

sub buckets ($class) {
    return [
        { name => 'reopen',    meaning => 'the ticket is moved to an open stage' },
        { name => 'unchanged', meaning => 'the ticket is already open' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-ticket',  meaning => 'no ticket of that id or number that this login can read' },
        { name => 'unknown-stage',   meaning => 'no stage of that id or name' },
        { name => 'ambiguous-stage', meaning => 'several stages carry the name and the ticket\'s team does not single one out' },
        { name => 'wrong-stage',     meaning => 'the stage named is not an open one' },
        { name => 'no-stage',        meaning => 'the ticket\'s team may use no open stage' },
        { name => 'missing-fields',  meaning => 'the stage requires fields (helpdesk_mgmt_stage_validation) that the ticket leaves empty' },
        { name => 'invalid',         meaning => 'the ticket is named twice' },
    ];
}

sub params ($class) {
    {   ticket => { type => 'list', required => 1, help => 'ticket ids or numbers, comma separated' },
        stage  => { type => 'str',  help => 'an open stage (an id or a name); the default is the first the ticket\'s team may use' },
    };
}
sub read_scope ($class) { { ticket => [qw(search_read read)], stage => [qw(search_read read)] } }
sub write_scope ($class) { { ticket => ['write'] } }

sub plan ($self) {
    ready($self);
    my $plan = $self->new_plan( input_count => scalar @{ $self->param('ticket') } );
    move_tickets( $self, $plan, 0 );
    return $plan;
}

1;
