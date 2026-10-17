package Odoo::Ops::Mailing::Send;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Mailing::Common;
use Odoo::Ops::Runs;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Mailing::Send - send a draft mailing

=head1 SYNOPSIS

    oom-ops run mailing.send --conf ops.conf --set mailing=7 --set now=1
    oom-ops approve --plan <run>/plan.json
    oom-ops apply --conf ops.conf --plan <run>/plan.json

=head1 DESCRIPTION

C<mailing.send> plans the send of mailing C<mailing>. Planning refuses,
by name, a send that should not go:

    not-draft      the mailing is not a draft (already queued, sending or sent)
    not-a-list-mailing  the mailing is to a model other than mailing lists
    no-recipients  nobody would be mailed: the lists are empty, or everyone is opted out
                   or blacklisted (the refusal says how many of each)
    over-max       more than C<max> (default 500) would be mailed; raise it deliberately

"Would be mailed" is worked out as Odoo's send does it (distinct
addresses, subscribed to some list, not blacklisted); Odoo's own
C<expected> is 0 on a draft and its C<total> counts opted-out and blacklisted contacts.

The plan is one C<custom> change (kind C<send>) with the state and the
C<total> read at planning as its before-image, so a mailing edited, or
whose lists changed, between plan and apply is stale. With C<now> apply
sends the draft at once: C<action_send_mail> makes a trace and a mail per
recipient, hands the mails to the mail server and ends in state C<done>,
and the mails it left C<outgoing> (a server that was down) are pushed.
It deliberately does not put the mailing in the queue first: on Odoo 16
C<action_put_in_queue> makes a cron trigger due at once, and a running
cron worker then sends the same mailing in its own transaction while
this one does - proved on demo16, where one recipient was mailed twice.
Without C<now> apply puts the mailing in the queue and Odoo's cron worker
sends it within seconds (at its schedule date, for a scheduled mailing);
the daily interval of the mass-mailing queue cron matters only when no
cron worker runs, and C<mailing.process> pushes it from here. The
after-image is C<state>, C<sent>, C<failed>, C<scheduled>, C<canceled>
and C<expected>, read back; a queued mailing may already read
C<sending> or C<done>, and a state other than the one asked for is not
verified.

Whether the mailing was tested first is a workflow rule, not a fact about
Odoo, so it is not enforced here: this operation sends (or queues) what it
is given. C<oom-mailshot> (the tools package) enforces the test-before-send
rule from the run registry, with
C<< Odoo::Ops::Runs->find( op => 'mailing.test', param => { mailing => $id },
since => $write_date, state => 'applied', ok => 1 ) >>, where C<$write_date>
is the mailing's C<write_date> as C<mailing.status> or a read gives it.

The push of the leftover mails reads C<mail.mail>, which only
Administration/Settings opens. For a user with the mass-mailing group alone
(a mailing operator) Odoo refuses that read with its access text. That does
not fail the change: the send was made. The refused push is dropped, the
change is applied but B<not verified>, and what it returns carries C<note>
(C<mail.mail needs Administration/Settings> and that Odoo's cron sends what
was left). The change fails only when Odoo refuses the send itself
(C<action_send_mail>, or C<action_put_in_queue> without C<now>); any other
fault of the push is also the change's.

A send cannot be taken back (a mail that left is gone), so a revert
holds it.

Series: written for Odoo 16; another series is refused by name until its
profile is probed.

=cut

sub op_name ($class) { 'mailing.send' }
sub summary ($class) { 'Plan sending a draft mailing to its lists (now, or into Odoo\'s queue)' }
sub pack    ($class) { 'mailing' }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'send', meaning => 'the mailing is sent now (now=1) or put in the queue for the cron worker; this cannot be taken back' },
    ];
}
sub holds ($class) { [] }

sub params ($class) {
    {   mailing      => { type => 'int',  required => 1, help => 'the mailing id' },
        now          => { type => 'bool', default => 0, help => 'send in this apply, not at Odoo\'s next queue run' },
        max          => { type => 'int',  default => 500, help => 'refuse to send to more recipients than this' },
    };
}
sub read_scope ($class) {
    {   mailing      => [qw(read)],
        subscription => ['search_read'],
        contact      => ['search_read'],
        cron         => ['read'],
        'ir.model.data' => ['search_read'],
    };
}
sub write_scope ($class) {
    {   mailing => [qw(read &put_in_queue &send_mail)],
        mail    => [qw(search_read &process_mail_queue)],
    };
}

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

my @AFTER = qw(state sent failed scheduled canceled expected);

sub plan ($self) {
    my $p = Odoo::Ops::Mailing::Common::ready($self);
    my $f = sub ($lf) { $p->field( mailing => $lf ) };
    my $id = $self->param('mailing');
    # total is a computed field: refused to this user it is left out of the before-image, not a fault
    my ( $mrows, $info ) = Odoo::Ops::Mailing::Common::read_named( $self, 'mailing', [$id], [ map { $f->($_) } qw(subject state lists model_real total updated) ],
        required => [ map { $f->($_) } qw(subject state lists model_real updated) ] );
    my $m = $mrows->[0]
        or Odoo::Error->throw( kind => 'refused', code => 'unknown-mailing', message => "mailing.send: no mailing $id",
            fix => q(oom-ops run mailing.status --conf <conf> lists the mailings) );
    my $state = $m->{ $f->('state') };
    Odoo::Error->throw( kind => 'refused', code => 'not-draft',
        message => "mailing $id is $state, not draft: only a draft is sent (mailing.cancel returns a queued one to draft)" )
        if $state ne 'draft';
    Odoo::Error->throw( kind => 'refused', code => 'not-a-list-mailing',
        message => "mailing $id is to " . $m->{ $f->('model_real') } . ', not to mailing lists; mailing.send does lists only' )
        if $m->{ $f->('model_real') } ne $p->model_name('contact');

    my @lists = @{ $m->{ $f->('lists') } // [] };
    my $aud = Odoo::Ops::Mailing::Common::audience( $self, \@lists );
    Odoo::Error->throw( kind => 'refused', code => 'no-recipients',
        message => "mailing $id has no one to mail: $aud->{subscriptions} subscription(s) on its lists, $aud->{opted_out} address(es) opted out, $aud->{blacklisted} blacklisted, $aud->{no_email} contact(s) without an address" )
        if !$aud->{reachable};
    Odoo::Error->throw( kind => 'refused', code => 'over-max',
        message => "mailing $id would mail $aud->{reachable} addresses, over max=" . $self->param('max') . '; raise max deliberately' )
        if $aud->{reachable} > $self->param('max');

    my $plan = $self->new_plan( input_count => 1 );
    $plan->note("mailing $id ('$m->{ $f->('subject') }') to $aud->{reachable} address(es): $aud->{subscriptions} subscription(s), $aud->{opted_out} opted out, $aud->{blacklisted} blacklisted, $aud->{no_email} without an address");
    # information, not a hold: the rule that a test comes first lives in oom-mailshot
    if ( my $dir = $self->ctx->config->get('runs_dir') ) {
        my $written = $m->{ $f->('updated') };
        my $ctx  = $self->ctx;
        my $runs = Odoo::Ops::Runs->new( dir => $dir, ttl => $ctx->plan_ttl, now => sub { $ctx->now } );
        my $tested = $runs->find( op => 'mailing.test', param => { mailing => $id }, state => 'applied', ok => 1,
            ( defined $written && length $written ? ( since => $written ) : () ) );
        $plan->note("no applied mailing.test of mailing $id since it was last written is in this registry (oom-mailshot send refuses to send untested; this primitive does not)")
            if !$tested;
    }
    if ( $self->param('now') ) {
        $plan->note('now: the mailing is sent and its mails handed to the mail server in this apply; a send cannot be taken back');
    }
    else {
        my ( $due, $why ) = Odoo::Ops::Mailing::Common::denied( sub { $self->_next_call($p) }, 'the next scheduled call' );
        $plan->note( 'the mailing is put in the queue. Odoo makes a one-off cron trigger for it at once (at its schedule date, if it has one), so a running cron worker sends it within seconds; '
            . 'with no cron worker it waits for the mass-mailing queue cron' . ( $due ? " (next scheduled call $due UTC)" : defined $why ? " ($why)" : '' ) . '. mailing.process pushes it from here' );
    }
    $plan->add(
        bucket => 'send', action => 'custom', handler => $self->op_name, kind => 'send',
        model => $p->model_name('mailing'), id => $id, key => "send:mailing $id",
        before => { $f->('state') => $state, ( $info->{unreadable}{$id}{ $f->('total') } ? () : ( $f->('total') => $m->{ $f->('total') } ) ) },
        vals => {
            now            => $self->param('now') ? JSON::PP::true : JSON::PP::false,
            put_in_queue   => $p->action('put_in_queue'),
            send_mail      => $p->action('send_mail'),
            mail_model     => $p->model_name('mail'),
            mail_queue     => $p->action('process_mail_queue'),
            mail_mailing   => $p->field( mail => 'mailing' ),
            mail_state     => $p->field( mail => 'state' ),
            state_field    => $f->('state'),
            after_fields   => { map { $_ => $f->($_) } @AFTER },
            reachable      => $aud->{reachable},
        },
        reason => $self->param('now') ? 'send now' : 'put in the queue',
    );
    return $plan;
}

sub _next_call ($self, $p) {
    my $cid = Odoo::Ops::Mailing::Common::xmlid_id( $self, $p->action('mass_queue_cron') ) or return undef;
    my $n = $p->field( cron => 'next_call' );
    my $r = $self->model('cron')->read( [$cid], [$n] )->[0];
    return $r ? $r->{$n} : undef;
}

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "mailing.send cannot apply kind '" . ( $c->{kind} // '' ) . "'" ) if ( $c->{kind} // '' ) ne 'send';
    my $v  = $c->{vals};
    my $mm = $client->model( $c->{model} );
    my $push_note;
    if ( $v->{now} ) {
        # Not put in the queue first, as one would expect: action_put_in_queue makes a cron trigger due at
        # once, and a running cron worker then sends the same mailing in its own transaction while this one
        # does (live 2026-10-15: one recipient was mailed twice and a serialisation error was logged). A
        # draft is not in the queue the cron reads, so a direct send has the mailing to itself.
        $mm->call( $v->{send_mail}, [ [ $c->{id} ] ] );
        # action_send_mail hands the mails to the mail server itself; this takes what it left outgoing
        # (a server that was down), this mailing's own mails and not every one on the instance
        # A mailing operator may not read mail.mail (Administration/Settings): the send above was theirs to make
        # and has been made, so a refused push is not a failed change. It degrades to a note, as a send without
        # now does, and the cron worker takes whatever was left outgoing. Only an access refusal is let through
        # as such; any other fault of the push is still the change's.
        my $mail = $client->model( $v->{mail_model} );
        ( undef, $push_note ) = Odoo::Ops::Mailing::Common::denied( sub {
            my $ids = [ map { $_->{id} } @{ $mail->search_read( [ [ $v->{mail_mailing}, '=', $c->{id} ], [ $v->{mail_state}, '=', 'outgoing' ] ], ['id'] ) } ];
            $mail->call( $v->{mail_queue}, [$ids] ) if @$ids;
            return 1;
        }, 'the push of the mails left outgoing', q(the mailing was sent; queued mails are sent by Odoo's cron) );
    }
    else {
        $mm->call( $v->{put_in_queue}, [ [ $c->{id} ] ] );
    }
    my $row = $mm->read_one( $c->{id}, [ values %{ $v->{after_fields} } ] );
    my %after = map { $_ => $row->{ $v->{after_fields}{$_} } } keys %{ $v->{after_fields} };
    # queued, Odoo's cron worker may already have it (sending) or have sent it (done)
    my $ok = $v->{now} ? $after{state} eq 'done' : $after{state} =~ /^(?:in_queue|sending|done)\z/;
    # not verified, with the reason: whether every mail left cannot be said without reading mail.mail
    $ok = 0 if defined $push_note;
    return { returned => { %after, ( defined $push_note ? ( note => $push_note ) : () ) }, after => $ok ? { %after } : undef };
}

sub undo_custom ($class, $entry) {
    return ( undef, 'a mailing that was sent cannot be taken back (an unsent one is returned to draft by mailing.cancel)' );
}

1;
