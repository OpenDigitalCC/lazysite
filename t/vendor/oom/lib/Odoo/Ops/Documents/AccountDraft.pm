package Odoo::Ops::Documents::AccountDraft;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Documents::Common;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Documents::AccountDraft - return a posted or cancelled journal entry to draft

=head1 SYNOPSIS

    oom-ops run account.draft --conf ops.conf --set move=12
    oom-ops run account.draft --conf ops.conf --set move=name=NUMBER

=head1 DESCRIPTION

C<account.draft> plans C<button_draft> on an account move that is C<posted>
or C<cancel>: it ends in C<draft>. The number a posted move consumed stays
consumed (the move keeps its name, so posting it again does not take a new
one); the journal entries are unposted and reconciliations are removed. Odoo
refuses it for a journal in strict (hash) mode and, on 19, for a locked
entry; the apply reports what Odoo says. A revert runs C<action_post> for a
move that was posted and C<button_cancel> for one that was cancelled.

The record is an id or C<name=> with the number Odoo shows. One change is
planned, in bucket C<transition>, with the state before and the state it must
read afterwards; a record that is already there, or in a state Odoo's
action does not work from, is a hold that says which and what gets there.
The steps, the states each works from and the context come from
F<profiles/account/E<lt>seriesE<gt>.yaml>, so a series without a profile
is refused by name (C<series>).

Series: 16, 18 and 19 have a profile; another series is refused by name
until it is probed.

=cut

my $SPEC = {
    pack => 'account', model => 'move', param => 'move', verb => 'draft',
    uses => [qw(draft post cancel)],
    undo => { draft => { posted => ['post'], cancel => ['cancel'] } },
};

sub op_name ($class) { 'account.draft' }
sub summary ($class) { 'Plan returning a posted or cancelled account move to draft through Odoo\'s own action' }
sub pack    ($class) { 'account' }
sub params ($class) {
    {   move => { type => 'str', required => 1, help => 'the record: an id, or name=<number>' },
    };
}
sub buckets ($class) {
    [ { name => 'transition', meaning => 'the record goes to its new state through Odoo\'s own action' } ];
}
sub holds ($class) {
    [
        { name => 'already', meaning => 'the move is already a draft' },
        { name => 'state', meaning => 'Odoo\'s action does not work from this state; the reason names it' },
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
