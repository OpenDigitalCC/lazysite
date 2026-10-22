package Odoo::Ops::Mailing::Send;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Mailing::Common;
use Odoo::Ops::Mailing::Plaintext;
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
A mailing with its own domain (one region of its lists, see
C<mailing.create>) is counted over the contacts that domain gives, so
C<over-max> and the plan note are about that part and not the whole of
its lists; a domain OOM cannot read leaves the count over the lists and
the plan says so.

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

B<chunk.> With C<chunk=N> the plan sends the next N of the mailing's
remaining recipients now and leaves the rest, for a caller that keeps under
a mail server's hourly limit. Who remains is what Odoo's own
C<_get_remaining_recipients> gives (it is private, so it is worked out the
same way): the contacts the mailing's domain gives, less those with a trace
of this mailing. The N are the first by contact id. The plan names the count
of the chunk and how many remain before and after; apply passes exactly those
contacts to C<action_send_mail(res_ids)> (public on 16 and 18), reads the new
traces back and reports C<traces_made>, C<traces_by_status> and C<remaining>.
A chunk is sent from a draft, or from a done mailing that still has
recipients (C<not-draft> otherwise). Odoo sets the mailing C<done> after every
send, whatever remains, and the mass-mailing queue job takes mailings in
C<in_queue> and C<sending> only (C<_process_mass_mailing_queue>,
C<mass_mailing.ir_cron_mass_mailing_queue>), so a chunked mailing is never
picked up by it: nothing but the next chunk sends the rest. A mailing already
C<in_queue> or C<sending> is refused C<queued>, because the job would race
the chunk. Other refusals: C<nothing-remaining>, C<ab-testing> (Odoo picks a
random share of an A/B test's recipients), C<unreadable-domain> (a
domain OOM cannot read), C<over-max> (the chunk is over C<max>), and a plan
applied after its contacts were given traces is C<stale>. Chunks of more than
Odoo's C<mail.mail.force.send.limit> (18; default 100) are left C<outgoing>
by Odoo for the mail queue cron, and the apply pushes them as C<now> does.
Without C<chunk> the operation behaves as before.

A send cannot be taken back (a mail that left is gone), so a revert
holds it.

When the plain-text part Odoo will make from the body keeps the generic
unsubscribe or view link (Odoo makes it before it swaps the recipient's own link
into the HTML part, so the link answers 404 there), the plan carries one note
saying so and that the HTML part and the C<List-Unsubscribe> header work. It is a
warning, never a refusal: the send is the caller's decision. A user who may not
read the body or the base URL gets no such note.

Series: Odoo 16 and 18; another series is refused by name until its
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
        max          => { type => 'int',  default => 500, help => 'refuse to send to more recipients than this (with chunk, than the chunk)' },
        chunk        => { type => 'int',  help => 'send the next N of the mailing\'s remaining recipients now, and leave the rest; the mailing is a draft, or done with recipients left' },
    };
}
sub read_scope ($class) {
    {   mailing      => [qw(read &base_url)],
        subscription => ['search_read'],
        contact      => ['search_read'],
        trace        => ['search_read'],
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
    my ( $mrows, $info ) = Odoo::Ops::Mailing::Common::read_named( $self, 'mailing', [$id], [ map { $f->($_) } qw(subject state lists model_real total updated domain) ],
        required => [ map { $f->($_) } qw(subject state lists model_real updated) ] );
    my $m = $mrows->[0]
        or Odoo::Error->throw( kind => 'refused', code => 'unknown-mailing', message => "mailing.send: no mailing $id",
            fix => q(oom-ops run mailing.status --conf <conf> lists the mailings) );
    my $state = $m->{ $f->('state') };
    Odoo::Error->throw( kind => 'refused', code => 'not-draft',
        message => "mailing $id is $state, not draft: only a draft is sent (mailing.cancel returns a queued one to draft)" )
        if $state ne 'draft' && !defined $self->param('chunk');
    Odoo::Error->throw( kind => 'refused', code => 'not-a-list-mailing',
        message => "mailing $id is to " . $m->{ $f->('model_real') } . ', not to mailing lists; mailing.send does lists only' )
        if $m->{ $f->('model_real') } ne $p->model_name('contact');

    return $self->_plan_chunk( $p, $id, $m, $info ) if defined $self->param('chunk');
    my @lists = @{ $m->{ $f->('lists') } // [] };
    # a mailing to one region of its lists mails the contacts its own domain gives, not every contact of the lists
    my $dom_text = Odoo::Ops::Mailing::Common::text( $m->{ $f->('domain') } );
    my $filtered = length $dom_text && !Odoo::Ops::Mailing::Common::same_domain( $dom_text, Odoo::Ops::Mailing::Common::list_domain( $self, \@lists ) );
    my $parsed   = $filtered ? Odoo::Ops::Mailing::Common::parse_domain($dom_text) : undef;
    my $aud = Odoo::Ops::Mailing::Common::audience( $self, \@lists, ( $parsed ? ( domain => $parsed ) : () ) );
    Odoo::Error->throw( kind => 'refused', code => 'no-recipients',
        message => "mailing $id has no one to mail: $aud->{subscriptions} subscription(s) on its lists, $aud->{opted_out} address(es) opted out, $aud->{blacklisted} blacklisted, $aud->{no_email} contact(s) without an address" )
        if !$aud->{reachable};
    Odoo::Error->throw( kind => 'refused', code => 'over-max',
        message => "mailing $id would mail $aud->{reachable} addresses, over max=" . $self->param('max') . '; raise max deliberately' )
        if $aud->{reachable} > $self->param('max');

    my $plan = $self->new_plan( input_count => 1 );
    $plan->note("mailing $id ('$m->{ $f->('subject') }') to $aud->{reachable} address(es): $aud->{subscriptions} subscription(s), $aud->{opted_out} opted out, $aud->{blacklisted} blacklisted, $aud->{no_email} without an address");
    $plan->note("the mailing has its own domain, $dom_text: the counts are of the contacts it gives, not of every contact of its lists") if $parsed;
    $plan->note("the mailing has its own domain, $dom_text, which OOM cannot read: the counts above are of every contact of its lists, so they can be more than Odoo will mail") if $filtered && !$parsed;
    $self->_text_part_note($plan, $p, $id);
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
        calls => [
            [ $p->model_name('mailing'), 'read' ],
            ( $self->param('now')
                ? ( [ $p->model_name('mailing'), $p->action('send_mail') ], [ $p->model_name('mail'), 'search_read' ], [ $p->model_name('mail'), $p->action('process_mail_queue') ] )
                : ( [ $p->model_name('mailing'), $p->action('put_in_queue') ] ) ),
        ],
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

# The next N of the mailing's remaining recipients, sent now. Odoo's action_send_mail takes the recipients to
# send (res_ids) on 16 and 18 and sets the mailing done whatever it was given, so a mailing sent in chunks is
# done between them; the queue job takes in_queue and sending only, so it does not send the rest.
sub _plan_chunk ($self, $p, $id, $m, $info) {
    my $f = sub ($lf) { $p->field( mailing => $lf ) };
    my $n = $self->param('chunk');
    Odoo::Error->throw( kind => 'usage', message => "mailing.send: chunk must be a whole number of at least 1, not $n", fix => 'pass --set chunk=<how many recipients to send now>' )
        if $n < 1;
    my $state = $m->{ $f->('state') };
    Odoo::Error->throw( kind => 'refused', code => 'queued',
        message => "mailing $id is $state: Odoo's queue job sends every recipient that remains of a mailing in that state, so a chunk would race it",
        fix => 'mailing.cancel returns it to draft; then chunk sends the next recipients' )
        if $state =~ /^(?:in_queue|sending)\z/;
    Odoo::Error->throw( kind => 'refused', code => 'not-draft',
        message => "mailing $id is $state: a chunk is sent from a draft, or from a done mailing that still has recipients" )
        if $state !~ /^(?:draft|done)\z/;
    Odoo::Error->throw( kind => 'refused', code => 'over-max',
        message => "chunk $n is over max=" . $self->param('max') . '; raise max deliberately' )
        if $n > $self->param('max');
    my $ab = $self->model('mailing')->read( [$id], [ $f->('ab_testing') ] )->[0];
    Odoo::Error->throw( kind => 'refused', code => 'ab-testing',
        message => "mailing $id is an A/B test: Odoo picks a random share of its recipients, so who remains is not the mailing's domain less its traces",
        fix => 'send it whole with mailing.send' )
        if $ab && $ab->{ $f->('ab_testing') };

    my $dom_text = Odoo::Ops::Mailing::Common::text( $m->{ $f->('domain') } );
    my $rem = Odoo::Ops::Mailing::Common::remaining( $self, $id, $dom_text )
        or Odoo::Error->throw( kind => 'refused', code => 'unreadable-domain',
            message => "mailing $id has a domain OOM cannot read ($dom_text), so who remains cannot be worked out",
            fix => 'mailing.send without chunk sends what Odoo works out; or set the domain to the lists\' default (mailing.create writes it)' );
    my @all = @{ $rem->{ids} };
    Odoo::Error->throw( kind => 'refused', code => 'nothing-remaining',
        message => "mailing $id has no recipient left: its domain gives $rem->{candidates} contact(s) and $rem->{traced} already have a trace" )
        if !@all;
    my @pick = @all[ 0 .. ( $n > @all ? $#all : $n - 1 ) ];
    my $left = @all - @pick;
    my @lists = @{ $m->{ $f->('lists') } // [] };
    my $aud = Odoo::Ops::Mailing::Common::audience( $self, \@lists, domain => [ [ 'id', 'in', \@pick ] ] );

    my $plan = $self->new_plan( input_count => 1 );
    $plan->note("mailing $id ('$m->{ $f->('subject') }'): a chunk of " . scalar(@pick) . " of its $rem->{candidates} recipient(s); " . scalar(@all) . " remain now, $left will remain after");
    $self->_text_part_note( $plan, $p, $id );
    $plan->note("the chunk is the next " . scalar(@pick) . " contact(s) by id; Odoo mails $aud->{reachable} address(es) of them and cancels the opted-out ($aud->{opted_out}), the blacklisted ($aud->{blacklisted}) and any address it has already mailed as cancelled traces, with no mail sent");
    $plan->note("the mailing is $state and Odoo ends the send in state done, whatever remains; its queue job takes in_queue and sending mailings only (mass_mailing.ir_cron_mass_mailing_queue, _process_mass_mailing_queue), so nothing else is sent until the next chunk");
    if ( my $dir = $self->ctx->config->get('runs_dir') ) {
        my $written = $m->{ $f->('updated') };
        my $ctx  = $self->ctx;
        my $runs = Odoo::Ops::Runs->new( dir => $dir, ttl => $ctx->plan_ttl, now => sub { $ctx->now } );
        my $tested = $runs->find( op => 'mailing.test', param => { mailing => $id }, state => 'applied', ok => 1,
            ( defined $written && length $written ? ( since => $written ) : () ) );
        $plan->note("no applied mailing.test of mailing $id since it was last written is in this registry (oom-mailshot send refuses to send untested; this primitive does not)")
            if !$tested && $state eq 'draft';
    }
    my $parsed = $dom_text =~ /\S/ ? Odoo::Ops::Mailing::Common::parse_domain($dom_text) : [];
    $plan->add(
        bucket => 'send', action => 'custom', handler => $self->op_name, kind => 'send',
        model => $p->model_name('mailing'), id => $id, key => "send:mailing $id chunk " . scalar(@pick),
        calls => [
            [ $p->model_name('mailing'), 'read' ], [ $p->model_name('mailing'), $p->action('send_mail') ],
            [ $p->model_name('trace'), 'search_read' ], [ $p->model_name('contact'), 'search_read' ],
            [ $p->model_name('mail'), 'search_read' ], [ $p->model_name('mail'), $p->action('process_mail_queue') ],
        ],
        before => { $f->('state') => $state, ( $info->{unreadable}{$id}{ $f->('total') } ? () : ( $f->('total') => $m->{ $f->('total') } ) ) },
        vals => {
            now            => JSON::PP::true,
            chunk          => scalar(@pick),
            res_ids        => \@pick,
            domain         => $parsed // [],
            send_mail      => $p->action('send_mail'),
            mail_model     => $p->model_name('mail'),
            mail_queue     => $p->action('process_mail_queue'),
            mail_mailing   => $p->field( mail => 'mailing' ),
            mail_state     => $p->field( mail => 'state' ),
            contact_model  => $p->model_name('contact'),
            trace_model    => $p->model_name('trace'),
            trace_mailing  => $p->field( trace => 'mailing' ),
            trace_res_id   => $p->field( trace => 'res_id' ),
            trace_model_f  => $p->field( trace => 'model' ),
            trace_status   => $p->field( trace => 'status' ),
            state_field    => $f->('state'),
            after_fields   => { map { $_ => $f->($_) } @AFTER },
            reachable      => $aud->{reachable},
        },
        reason => 'send a chunk of ' . scalar(@pick) . " ($left will remain)",
    );
    return $plan;
}

# the plain-text part Odoo makes keeps the generic unsubscribe and view links (Odoo fault 001): one line, never a refusal
sub _text_part_note ($self, $plan, $p, $id) {
    my $links = Odoo::Ops::Mailing::Common::text_part_links( $self, $p, $id ) or return;
    my $w = Odoo::Ops::Mailing::Plaintext::warning($links) or return;
    $plan->note($w);
    return;
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
    return _apply_chunk( $client, $c ) if defined $v->{chunk};
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

sub _apply_chunk ($client, $c) {
    my $v  = $c->{vals};
    my $mm = $client->model( $c->{model} );
    my $tm = $client->model( $v->{trace_model} );
    my $ids = $v->{res_ids};
    my @tdom = ( [ $v->{trace_mailing}, '=', $c->{id} ], [ $v->{trace_model_f}, '=', $v->{contact_model} ] );
    # a plan applied after another chunk went (or after Odoo made traces for these contacts) would send them twice
    my $had = $tm->search_read( [ @tdom, [ $v->{trace_res_id}, 'in', $ids ] ], [ $v->{trace_res_id} ] );
    Odoo::Error->throw( kind => 'refused', code => 'stale',
        message => scalar(@$had) . " of the " . scalar(@$ids) . " recipients of this chunk already have a trace of mailing $c->{id}; plan the chunk again" )
        if @$had;
    $mm->call( $v->{send_mail}, [ [ $c->{id} ] ], res_ids => $ids );
    # what a mail server that took the mails only partly leaves outgoing is pushed once, as a send now does
    my $mail = $client->model( $v->{mail_model} );
    my ( undef, $push_note ) = Odoo::Ops::Mailing::Common::denied( sub {
        my $out = [ map { $_->{id} } @{ $mail->search_read( [ [ $v->{mail_mailing}, '=', $c->{id} ], [ $v->{mail_state}, '=', 'outgoing' ] ], ['id'] ) } ];
        $mail->call( $v->{mail_queue}, [$out] ) if @$out;
        return 1;
    }, 'the push of the mails left outgoing', q(the chunk was sent; queued mails are sent by Odoo's cron) );
    my $row = $mm->read_one( $c->{id}, [ values %{ $v->{after_fields} } ] );
    my %after = map { $_ => $row->{ $v->{after_fields}{$_} } } keys %{ $v->{after_fields} };
    my $made = $tm->search_read( [ @tdom, [ $v->{trace_res_id}, 'in', $ids ] ], [ $v->{trace_status} ] );
    my %by;
    $by{ $_->{ $v->{trace_status} } // 'unknown' }++ for @$made;
    # who remains, as Odoo works it out (the domain less the traces), read after the send
    my $dom = @{ $v->{domain} } ? $v->{domain} : [ [ 'id', 'in', [] ] ];
    my $cands = $client->model( $v->{contact_model} )->all( $dom, ['id'] );
    my %seen;
    my @cid = map { $_->{id} } @$cands;
    for ( my $i = 0 ; $i < @cid ; $i += 1000 ) {
        my @slice = @cid[ $i .. ( $i + 999 < $#cid ? $i + 999 : $#cid ) ];
        $seen{ $_->{ $v->{trace_res_id} } } = 1 for @{ $tm->all( [ @tdom, [ $v->{trace_res_id}, 'in', \@slice ] ], [ $v->{trace_res_id} ] ) };
    }
    my $remaining = scalar grep { !$seen{$_} } @cid;
    my $sent = scalar @$made;
    my $ok = $sent == @$ids && $after{ $v->{state_field} } eq 'done';
    $ok = 0 if defined $push_note;
    my %ret = ( %after, chunk => scalar(@$ids), traces_made => $sent, traces_by_status => \%by, remaining => $remaining, ( defined $push_note ? ( note => $push_note ) : () ) );
    return { returned => \%ret, after => $ok ? { %after, traces_made => $sent, remaining => $remaining } : undef };
}

sub undo_custom ($class, $entry) {
    return ( undef, 'a mailing that was sent cannot be taken back (an unsent one is returned to draft by mailing.cancel)' );
}

1;
