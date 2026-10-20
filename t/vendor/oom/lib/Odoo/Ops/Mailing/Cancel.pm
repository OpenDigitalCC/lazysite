package Odoo::Ops::Mailing::Cancel;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Mailing::Common;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Mailing::Cancel - take a queued mailing back to draft

=head1 SYNOPSIS

    oom-ops run mailing.cancel --conf ops.conf --set mailing=7

=head1 DESCRIPTION

C<mailing.cancel> plans C<action_cancel> on a mailing that is C<in_queue>
(put there by C<mailing.send> without C<now>, waiting for Odoo's cron):
it goes back to C<draft> and its schedule is cleared. A mailing in any
other state refuses by name (C<not-queued>): a draft has nothing to
cancel, and a mailing that is sending or done has gone. The change is a
verified call (state reads C<draft> afterwards). A revert holds it as a
method call; queue the mailing again with C<mailing.send>.

Series: Odoo 16 and 18; another series is refused by name until its
profile is probed.

=cut

sub op_name ($class) { 'mailing.cancel' }
sub summary ($class) { 'Plan taking a queued mailing back to draft' }
sub pack    ($class) { 'mailing' }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'cancel', meaning => 'a queued mailing goes back to draft and its schedule is cleared' },
    ];
}
sub holds ($class) { [] }

sub params ($class) {
    {   mailing => { type => 'int', required => 1, help => 'the mailing id' } };
}
sub read_scope  ($class) { { mailing => ['read'] } }
sub write_scope ($class) { { mailing => [qw(read &cancel)] } }

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

sub plan ($self) {
    my $p = Odoo::Ops::Mailing::Common::ready($self);
    my $f = sub ($lf) { $p->field( mailing => $lf ) };
    my $id = $self->param('mailing');
    my $m  = $self->model('mailing')->read( [$id], [ $f->('subject'), $f->('state') ] )->[0]
        or Odoo::Error->throw( kind => 'refused', code => 'unknown-mailing', message => "mailing.cancel: no mailing $id",
            fix => q(oom-ops run mailing.status --conf <conf> lists the mailings) );
    my $state = $m->{ $f->('state') };
    Odoo::Error->throw( kind => 'refused', code => 'not-queued',
        message => "mailing $id is $state, not in_queue: only a queued mailing can be cancelled" )
        if $state ne 'in_queue';
    my $plan = $self->new_plan( input_count => 1 );
    $plan->add(
        bucket => 'cancel', action => 'call', model => $p->model_name('mailing'), id => $id, ids => [$id],
        method => $p->action('cancel'), key => "cancel:mailing $id", before => { $f->('state') => 'in_queue' },
        verify => { model => $p->model_name('mailing'), ids => [$id], fields => { $f->('state') => 'draft' } },
        reason => "mailing $id ('$m->{ $f->('subject') }') returns to draft",
    );
    return $plan;
}

1;
