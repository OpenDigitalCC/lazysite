package Odoo::Ops::Documents::SaleConfirm;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Documents::Common;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Documents::SaleConfirm - confirm a quotation into a sales order

=head1 SYNOPSIS

    oom-ops run sale.confirm --conf ops.conf --set order=12
    oom-ops run sale.confirm --conf ops.conf --set order=name=NUMBER

=head1 DESCRIPTION

C<sale.confirm> plans C<action_confirm> on a sale order that is C<draft> or
C<sent>: it becomes a sales order (C<sale>, or C<done> where the company
locks on confirmation). The state is never written; Odoo's action runs, so
the delivery, the analytic account and the follow-up the behaviour file names
happen as they do from the form. A revert takes it back through
C<action_cancel> then C<action_draft>: the order is a draft again, but what
confirm did is not undone (a delivery it made stays, cancelled).

The record is an id or C<name=> with the number Odoo shows. One change is
planned, in bucket C<transition>, with the state before and the state it must
read afterwards; a record that is already there, or in a state Odoo's
action does not work from, is a hold that says which and what gets there.
The steps, the states each works from and the context come from
F<profiles/sale/E<lt>seriesE<gt>.yaml>, so a series without a profile
is refused by name (C<series>).

After the action, in the same run, the result's change reports what the confirm reserved
(C<< returned.reservation >>), read through the operation's own client and only where the server has
the moves of a sale (C<sale_stock>): per order line C<product_id>, C<demand> (the product's unit of measure), C<reserved>
(what its moves have reserved), C<state> (of its moves; C<mixed> when they differ) and C<lines> (C<lot>, C<location>,
C<quantity> of its move lines), and per order C<fully_reserved> (C<1> or C<0>) and C<moves>. An order with no move
reads C<fully_reserved> 0 and C<moves> 0. A confirm that left a line short is still a confirm: the report says it, and
what to do with a short order is the caller's. If the read fails it is said (C<returned.reservation_not_read>) and the
confirm stands.

Series: 16, 18 and 19 have a profile; another series is refused by name
until it is probed.

=cut

my $SPEC = {
    pack => 'sale', model => 'order', param => 'order', verb => 'confirm',
    uses => [qw(confirm cancel draft)],
    reservation => 1,
    undo => { confirm => [qw(cancel draft)] },
};

sub op_name ($class) { 'sale.confirm' }
sub summary ($class) { 'Plan confirming a quotation (draft or sent) into a sales order through Odoo\'s own action' }
sub pack    ($class) { 'sale' }
sub params ($class) {
    {   order => { type => 'str', required => 1, help => 'the record: an id, or name=<number>' },
    };
}
sub buckets ($class) {
    [ { name => 'transition', meaning => 'the record goes to its new state through Odoo\'s own action' } ];
}
sub holds ($class) {
    [
        { name => 'already', meaning => 'the order is already confirmed (state sale or done)' },
        { name => 'state', meaning => 'Odoo\'s action does not work from this state (a cancelled order is returned to draft by sale.cancel with draft=1); the reason names the state and what gets there' },
        { name => 'ambiguous', meaning => 'name= matches more than one record; give the id' },
        { name => 'unknown-<model>', meaning => 'no record matches the id or name' },
    ];
}
sub read_scope  ($class) { Odoo::Ops::Documents::Common::read_scope($SPEC) }
sub write_scope ($class) { Odoo::Ops::Documents::Common::write_scope($SPEC) }

sub scope_for ($self, $phase) { Odoo::Ops::Documents::Common::scope($self, $phase, $self->SUPER::scope_for($phase) ) }

sub plan ($self) { Odoo::Ops::Documents::Common::plan_state($self, $SPEC) }

sub apply_custom ($class, $client, $c) { Odoo::Ops::Documents::Common::apply_state($class, $client, $c) }
sub undo_custom ($class, $entry) { Odoo::Ops::Documents::Common::undo_state($class, $entry) }

1;
