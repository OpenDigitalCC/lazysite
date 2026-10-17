package Odoo::Ops::Documents::SaleCancel;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Documents::Common;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Documents::SaleCancel - cancel a sale order, and optionally make it a draft again

=head1 SYNOPSIS

    oom-ops run sale.cancel --conf ops.conf --set order=12
    oom-ops run sale.cancel --conf ops.conf --set order=name=NUMBER
    oom-ops run sale.cancel --conf ops.conf --set order=12 --set draft=1

=head1 DESCRIPTION

C<sale.cancel> plans C<action_cancel> on a sale order that is C<draft>,
C<sent> or C<sale>, with the context that skips the confirmation wizard Odoo
16 and 18 open for a confirmed order (C<disable_cancel_warning>; 19 has no
wizard). The order ends in C<cancel>, which is the state Odoo deletes an
order from. With C<draft=1> the plan adds C<action_draft> so the order is
editable again (a cancelled order goes straight to C<draft>). A revert of a
plain cancel runs C<action_draft>; it cannot make the order a confirmed one
again.

The record is an id or C<name=> with the number Odoo shows. One change is
planned, in bucket C<transition>, with the state before and the state it must
read afterwards; a record that is already there, or in a state Odoo's
action does not work from, is a hold that says which and what gets there.
The steps, the states each works from and the context come from
F<profiles/sale/E<lt>seriesE<gt>.yaml>, so a series without a profile
is refused by name (C<series>).

Series: 16, 18 and 19 have a profile; another series is refused by name
until it is probed.

=cut

my $SPEC = {
    pack => 'sale', model => 'order', param => 'order', verb => 'cancel',
    uses => [qw(cancel draft)],
    draft => 1,
    undo => { cancel => ['draft'], draft => ['cancel'], 'cancel,draft' => 'the order is a draft again; confirming it is a new sale.confirm' },
};

sub op_name ($class) { 'sale.cancel' }
sub summary ($class) { 'Plan cancelling a sale order through Odoo\'s own action; draft=1 makes it editable again' }
sub pack    ($class) { 'sale' }
sub params ($class) {
    {   order => { type => 'str', required => 1, help => 'the record: an id, or name=<number>' },
        draft => { type => 'bool', default => 0, help => '1 adds the way back to draft after the cancel (the record is then editable again)' },
    };
}
sub buckets ($class) {
    [ { name => 'transition', meaning => 'the record goes to its new state through Odoo\'s own action' } ];
}
sub holds ($class) {
    [
        { name => 'already', meaning => 'the order is already cancelled (or, with draft=1, already a draft)' },
        { name => 'state', meaning => 'Odoo\'s action does not work from this state (a locked order, state done, or on 19 locked=true, is unlocked in Odoo first); the reason names it' },
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
