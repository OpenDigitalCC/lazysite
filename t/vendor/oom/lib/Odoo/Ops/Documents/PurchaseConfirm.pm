package Odoo::Ops::Documents::PurchaseConfirm;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Documents::Common;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Documents::PurchaseConfirm - confirm a request for quotation into a purchase order

=head1 SYNOPSIS

    oom-ops run purchase.confirm --conf ops.conf --set order=12
    oom-ops run purchase.confirm --conf ops.conf --set order=name=NUMBER

=head1 DESCRIPTION

C<purchase.confirm> plans C<button_confirm> on a purchase order that is
C<draft> or C<sent>. It ends in C<purchase> (or C<done> where the company
locks confirmed orders). With double validation on, Odoo leaves the order in
C<to approve>: the change is then reported unverified and the state it
reached is in the result; approval is Odoo's. A receipt is made when stock is
installed. A revert runs C<button_cancel> then C<button_draft>; a receipt
that was made stays, cancelled.

The record is an id or C<name=> with the number Odoo shows. One change is
planned, in bucket C<transition>, with the state before and the state it must
read afterwards; a record that is already there, or in a state Odoo's
action does not work from, is a hold that says which and what gets there.
The steps, the states each works from and the context come from
F<profiles/purchase/E<lt>seriesE<gt>.yaml>, so a series without a profile
is refused by name (C<series>).

Series: 16, 18 and 19 have a profile; another series is refused by name
until it is probed.

=cut

my $SPEC = {
    pack => 'purchase', model => 'order', param => 'order', verb => 'confirm',
    uses => [qw(confirm cancel draft)],
    undo => { confirm => [qw(cancel draft)] },
};

sub op_name ($class) { 'purchase.confirm' }
sub summary ($class) { 'Plan confirming a request for quotation (draft or sent) into a purchase order through Odoo\'s own action' }
sub pack    ($class) { 'purchase' }
sub params ($class) {
    {   order => { type => 'str', required => 1, help => 'the record: an id, or name=<number>' },
    };
}
sub buckets ($class) {
    [ { name => 'transition', meaning => 'the record goes to its new state through Odoo\'s own action' } ];
}
sub holds ($class) {
    [
        { name => 'already', meaning => 'the order is already confirmed (state purchase or done)' },
        { name => 'state', meaning => 'Odoo\'s action does not work from this state (a cancelled order is returned to draft by purchase.cancel with draft=1; one in to approve waits for approval in Odoo); the reason names it' },
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
