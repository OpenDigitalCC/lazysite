package Odoo::Ops::Documents::AccountPost;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Documents::Common;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Documents::AccountPost - post a draft journal entry or invoice

=head1 SYNOPSIS

    oom-ops run account.post --conf ops.conf --set move=12
    oom-ops run account.post --conf ops.conf --set move=name=NUMBER

=head1 DESCRIPTION

C<account.post> plans C<action_post> on an account move that is C<draft>: it
becomes C<posted>, takes its number from the journal's sequence and writes
its accounting entries. The number is read back after apply (C<returned.name>
in the journal). A revert runs C<button_draft>, which does not give the
number back: the move keeps its name and the sequence stays consumed, and
Odoo then deletes a move that was posted once only if the audit trail allows
it.

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
    pack => 'account', model => 'move', param => 'move', verb => 'post',
    uses => [qw(post draft)],
    numbered => 1,
    undo => { post => ['draft'] },
};

sub op_name ($class) { 'account.post' }
sub summary ($class) { 'Plan posting a draft account move (entry, invoice, bill) through Odoo\'s own action' }
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
        { name => 'already', meaning => 'the move is already posted' },
        { name => 'state', meaning => 'Odoo\'s action does not work from this state (a cancelled move goes back to draft with account.draft first); the reason names it' },
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
