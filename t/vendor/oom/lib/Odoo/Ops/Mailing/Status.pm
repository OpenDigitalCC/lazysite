package Odoo::Ops::Mailing::Status;

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

Odoo::Ops::Mailing::Status - how a mailing is getting on, from Odoo's own counters

=head1 SYNOPSIS

    oom-ops run mailing.status --conf ops.conf --set mailing=7
    oom-ops run mailing.status --conf ops.conf --set subject="October news" --set traces=1 --set queue=1

=head1 DESCRIPTION

C<mailing.status> is the "check progress" read. One row per mailing
(C<mailing> an id, C<subject> a part of the subject, neither for the
latest 20): C<id>, C<subject>, C<state> (draft, in_queue, sending,
done), C<lists>, C<schedule_date>, C<sent_date>, C<recipients>, C<recipients_now> and
every counter exactly as Odoo computes it - C<expected>, C<scheduled>,
C<sent>, C<delivered>, C<opened>, C<clicked>, C<replied>, C<bounced>,
C<failed>, C<canceled>, C<received_ratio>, C<opened_ratio>. C<write_date>
and C<create_date> are Odoo's own, UTC, in the form of the other datetimes:
a caller that must know whether a mailing changed since something (the
mailshot tool's tested-since rule) reads them here and needs no scope of
its own on the model. No number
is made up here: a counter Odoo does not hold is not shown.

Two things that read as bugs and are not (Odoo 16, proved on demo16):
C<expected> is the number of traces, which a send makes, so it is 0 on
a draft; C<recipients> (Odoo's C<total>) is the contacts of the lists,
opted-out and blacklisted ones included, so it can be more than
C<sent>: opt-outs, blacklisted addresses and duplicate addresses are
cancelled as traces (C<canceled>, with C<failure_type> C<mail_optout>,
C<mail_bl> or C<mail_dup>).

C<recipients_now> is the contacts of the lists today: after the contacts are
deleted (a cleanup) a done mailing reads C<recipients> 0 and C<recipients_now> 0
while C<sent> and C<expected> keep the record of who was mailed.

C<queue_due> says when Odoo will next move a queued mailing by itself:
for the mass-mailing queue cron and the mail queue cron, the interval
(a day and an hour on a fresh instance), the next scheduled call and any
pending one-off C<triggers> (queueing a mailing makes one, due at once
or at its schedule date, which is why a running cron worker sends it
within seconds whatever the interval). It is on a mailing row when the
mailing is C<in_queue> or C<sending> and at the top of the report always,
so a reader can tell why C<in_queue> is not moving - and C<mailing.process>
pushes both.

One shape: C<rows> is a list with one entry per mailing, and what a
mailing has more of is inside its own row, never in a map beside it.
With C<traces> the row holds C<traces>, one entry per recipient: C<id>
(the trace), C<mail_id> (the C<mail.mail>, absent once Odoo deleted it),
C<contact_id> (the C<mailing.contact>, when the trace is of one), C<email>,
C<status>, C<failure_type>, and C<sent>, C<opened>, C<clicked>, C<replied>
as the datetimes Odoo recorded, or absent; C<bounced> is true on a bounce
(Odoo keeps no bounce time). The row also gets C<traces_total> and, when
the read stopped short, C<traces_note>. With C<queue> the row holds
C<queue>: C<mail.mail> counts by C<state>, as C<< { state, count,
failure_reason? } >> (one entry for each state and reason); a delivered
mass mail deletes its row, so what is left there is waiting, failed or
C<cancel> (an opted-out, blacklisted or duplicate recipient: not a stuck mail).
C<queue_due> is the one thing kept at the top of the report, because it
belongs to the instance and not to a mailing.

C<queue_due> is a convenience read: the cron records come through
C<ir.model.data> and C<ir.cron>, which only an administrator may read. For a
user without those rights (a mailing operator) it is C<null>, with
C<queue_due_note> saying which model needs which group, and the mailing's own
counters are returned all the same; the same for C<queue>, whose
C<mail.mail> rows an administrator reads (C<queue> is null, with C<queue_note>). Every read of this operation names the
fields it reports, so a module installed beside C<mass_mailing> (C<mass_mailing_sale>
adds a compute over C<account.move>) cannot add a field this user may not
compute.

A field this user may not compute does not fault the read. C<recipients>
(Odoo's C<total>) is computed by searching the mailing's target model with
its domain, so a mailing on partners whose domain reaches invoices makes
Odoo check the user's access to C<account.move>, which a mailing operator
has not. That row's C<recipients> is C<null> and the row carries
C<unreadable> (C<< { recipients => "recipients not readable by this user:
its compute reads account.move (needs ...)" } >>); the other rows are read
in full and the report's C<unreadable_fields> lists the fields. A refused
counter is null with the same note, never 0; C<recipients_now>, which OOM
counts from the subscriptions, is still given. A refusal of C<subject> or
C<state> is a fault, with a C<fix> line naming the model and the groups.

C<archived> includes archived mailings (and C<active> on each row says
which they are), as C<mailing.lists> does for lists; naming an archived
mailing by C<mailing> without it is refused with that advice.

=cut

sub op_name ($class) { 'mailing.status' }
sub summary ($class) { 'Read mailing progress from Odoo\'s counters: state, sent, opened, bounced, per recipient' }
sub pack    ($class) { 'mailing' }
# The keys of the descriptors this read returns in its fields block.
sub fields ($class) {
    return [
        { name => 'id', meaning => 'Id' },
        { name => 'subject', meaning => 'Subject' },
        { name => 'state', meaning => 'State' },
        { name => 'schedule_date', meaning => 'Scheduled for' },
        { name => 'sent_date', meaning => 'Sent on' },
        { name => 'write_date', meaning => 'Last written (Odoo\'s, UTC)' },
        { name => 'create_date', meaning => 'Made on (Odoo\'s, UTC)' },
        { name => 'recipients', meaning => 'Odoo\'s total: every contact of the lists, opted-out included; 0 once the lists or their contacts are gone, while sent keeps the count' },
        { name => 'recipients_now', meaning => 'Contacts of the lists today, after any deletes (opted-out included)' },
        { name => 'expected', meaning => 'Traces made' },
        { name => 'scheduled', meaning => 'Waiting to go' },
        { name => 'sent', meaning => 'Sent' },
        { name => 'delivered', meaning => 'Delivered' },
        { name => 'opened', meaning => 'Opened' },
        { name => 'clicked', meaning => 'Clicked' },
        { name => 'replied', meaning => 'Replied' },
        { name => 'bounced', meaning => 'Bounced' },
        { name => 'failed', meaning => 'Failed' },
        { name => 'canceled', meaning => 'Cancelled (opted out, blacklisted, duplicate)' },
        { name => 'received_ratio', meaning => 'Received %' },
        { name => 'opened_ratio', meaning => 'Opened %' },
        { name => 'queue_due', meaning => 'When Odoo next moves a queued mailing by itself; null when this user may not read the cron records' },
        { name => 'queue_due_note', meaning => 'Present when queue_due is null: what this user may not read and which group would' },
        { name => 'unreadable', meaning => 'On a row: { field => why } for each field this user may not compute (that field is null on the row)' },
        { name => 'unreadable_fields', meaning => 'At the top: the fields that are null on some row because this user may not compute them' },
    ];
}

sub params ($class) {
    {   mailing => { type => 'int',  help => 'a mailing by id' },
        subject => { type => 'str',  help => 'mailings whose subject contains this' },
        traces  => { type => 'bool', default => 0, help => 'one row per recipient' },
        queue   => { type => 'bool', default => 0, help => 'the mail.mail rows of the mailing, by state' },
        archived => { type => 'bool', default => 0, help => 'include archived mailings' },
    };
}
sub read_scope ($class) {
    {   mailing => [qw(search_read search_count read)],
        list    => ['read'],
        trace   => [qw(search_read search_count)],
        contact => ['search_count'],
        mail    => ['search_read'],
        cron    => ['read'],
        cron_trigger => ['search_read'],
        'ir.model.data' => ['search_read'],
    };
}

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

my @COUNTERS = qw(expected scheduled sent delivered opened clicked replied bounced failed canceled received_ratio opened_ratio);
my $TRACE_LIMIT = 2000;

sub report ($self) {
    my $p = Odoo::Ops::Mailing::Common::ready($self);
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    my $mm = $self->model('mailing');
    my @read = map { $f->( mailing => $_ ) } qw(subject state lists schedule_date sent_date updated created total active), @COUNTERS;
    my @dom;
    push @dom, [ 'id', '=', $self->param('mailing') ] if defined $self->param('mailing');
    push @dom, [ $f->( mailing => 'subject' ), 'ilike', $self->param('subject') ] if defined $self->param('subject');
    push @dom, [ $f->( mailing => 'active' ), 'in', [ JSON::PP::true, JSON::PP::false ] ] if $self->param('archived');
    # a computed field this user may not run (total, over a partner domain that reaches account.move) is
    # named and read per row, not a fault of the whole read; subject and state cannot be done without
    my ( $rows, $info ) = Odoo::Ops::Mailing::Common::search_read_named( $self, 'mailing', \@dom, \@read,
        order => 'id desc', limit => ( @dom ? 100 : 20 ), required => [ map { $f->( mailing => $_ ) } qw(subject state) ] );
    my %rowkey = ( $f->( mailing => 'total' ) => 'recipients', map { $f->( mailing => $_ ) => $_ } @COUNTERS );
    if ( defined $self->param('mailing') && !@$rows ) {
        my $gone = !$self->param('archived')
            && $mm->count( [ [ 'id', '=', $self->param('mailing') ], [ $f->( mailing => 'active' ), 'in', [ JSON::PP::true, JSON::PP::false ] ] ] );
        Odoo::Error->throw( kind => 'refused', code => 'archived', message => 'mailing.status: mailing ' . $self->param('mailing') . ' is archived; pass archived=1 to read it', fix => 'pass --set archived=1' ) if $gone;
        Odoo::Error->throw( kind => 'refused', code => 'unknown-mailing', message => 'mailing.status: no mailing ' . $self->param('mailing'),
            fix => 'oom-ops run mailing.status --conf <conf> lists the mailings' );
    }

    # a convenience: Odoo's cron records are read through ir.model.data, which only an access-rights
    # administrator may read; a mailing operator gets the mailing's own counters and a null here
    my ( $due, $due_note ) = Odoo::Ops::Mailing::Common::denied( sub { $self->_queue_due }, 'queue_due', q(the counters are Odoo's own) );
    my %lname;
    my @lids = keys %{ { map { $_ => 1 } map { @{ $_->{ $f->( mailing => 'lists' ) } // [] } } @$rows } };
    %lname = map { $_->{id} => $_->{ $f->( list => 'name' ) } } @{ $self->model('list')->read( [ sort { $a <=> $b } @lids ], [ $f->( list => 'name' ) ] ) } if @lids;

    my ( @out, %unreadable );
    for my $r (@$rows) {
        my $state = $r->{ $f->( mailing => 'state' ) };
        my $unread = $info->{unreadable}{ $r->{id} } // {};
        my %row = (
            id            => $r->{id},
            subject       => $r->{ $f->( mailing => 'subject' ) },
            state         => $state,
            lists         => [ map { $lname{$_} // "list $_" } @{ $r->{ $f->( mailing => 'lists' ) } // [] } ],
            active        => $r->{ $f->( mailing => 'active' ) } ? JSON::PP::true : JSON::PP::false,
            schedule_date => _when( $r->{ $f->( mailing => 'schedule_date' ) } ),
            sent_date     => _when( $r->{ $f->( mailing => 'sent_date' ) } ),
            write_date    => _when( $r->{ $f->( mailing => 'updated' ) } ),
            create_date   => _when( $r->{ $f->( mailing => 'created' ) } ),
            # a field this user may not compute is null with the reason, never 0
            recipients    => $unread->{ $f->( mailing => 'total' ) } ? undef : $r->{ $f->( mailing => 'total' ) } // 0,
            recipients_now => $self->_contacts_now( $r->{ $f->( mailing => 'lists' ) } ),
            ( map { $_ => $unread->{ $f->( mailing => $_ ) } ? undef : $r->{ $f->( mailing => $_ ) } // 0 } @COUNTERS ),
        );
        if (%$unread) {
            $row{unreadable} = { map { $rowkey{$_} => Odoo::Ops::Mailing::Common::unreadable_note( $rowkey{$_}, $unread->{$_} ) } keys %$unread };
            $unreadable{ $rowkey{$_} } = 1 for keys %$unread;
        }
        if ( $state eq 'in_queue' || $state eq 'sending' ) {
            $row{queue_due} = $due;
            $row{queue_due_note} = $due_note if defined $due_note;
        }
        push @out, \%row;
    }
    my %rep = ( count => scalar @out, queue_due => $due, ( defined $due_note ? ( queue_due_note => $due_note ) : () ), rows => \@out, unreadable_fields => [ sort keys %unreadable ], fields => $self->_fields );
    my %by_id = map { $_->{id} => $_ } @out;
    my @ids = map { $_->{id} } @out;
    if ( $self->param('traces') && @ids ) {
        my %t = map { $_ => $f->( trace => $_ ) } qw(mailing email status failure_type sent opened clicked replied mail res_id model);
        my $tm = $self->model('trace');
        for my $id (@ids) {
            my $dom = [ [ $t{mailing}, '=', $id ] ];
            my $all = $tm->count($dom);
            my $tr  = $tm->search_read( $dom, [ values %t ], order => 'id asc', limit => $TRACE_LIMIT );
            my $row = $by_id{$id};
            $row->{traces} = [ map { $self->_trace( $_, \%t ) } @$tr ];
            $row->{traces_total} = $all;
            $row->{traces_note} = "showing the first $TRACE_LIMIT of $all traces" if $all > @$tr;
        }
    }
    if ( $self->param('queue') && @ids ) {
        my %m = map { $_ => $f->( mail => $_ ) } qw(mailing state failure_reason);
        # mail.mail is an administration model (Administration/Settings): a mailing operator asks for the queue
        # and gets a null with the reason, not a fault, and the counters above stay Odoo's own
        my ( $mails, $queue_note ) = Odoo::Ops::Mailing::Common::denied(
            sub { $self->model('mail')->search_read( [ [ $m{mailing}, 'in', \@ids ] ], [ values %m ], order => 'id asc', limit => 5000 ) },
            'queue', q(scheduled, sent and failed above are Odoo's own counters) );
        if ( defined $queue_note ) {
            @{ $by_id{$_} }{qw(queue queue_note)} = ( undef, $queue_note ) for @ids;
            $rep{queue_note} = $queue_note;
            return \%rep;
        }
        my %q;
        for my $x (@$mails) {
            my $mid = Odoo::Ops::Mailing::Common::id_of( $x->{ $m{mailing} } );
            my $st  = Odoo::Ops::Mailing::Common::text( $x->{ $m{state} } ) || 'unknown';
            my $why = Odoo::Ops::Mailing::Common::text( $x->{ $m{failure_reason} } );
            $q{$mid}{"$st\0$why"}++;
        }
        for my $id (@ids) {
            $by_id{$id}{queue} = [ map {
                my ( $st, $why ) = split /\0/, $_, 2;
                +{ state => $st, count => $q{$id}{$_}, ( length( $why // '' ) ? ( failure_reason => $why ) : () ) }
            } sort keys %{ $q{$id} // {} } ];
        }
    }
    return \%rep;
}

# Distinct contacts on the mailing's lists today, counted here beside Odoo's
# own total, so a reader sees both after a cleanup removed the contacts or the
# lists (second try-out, item 5). Cached per set of lists.
sub _contacts_now ($self, $list_ids) {
    my @ids = sort { $a <=> $b } @{ $list_ids // [] };
    return 0 if !@ids;
    return $self->{_now}{ join ',', @ids } //= $self->model('contact')->count( [ [ $self->profile->field( contact => 'lists' ), 'in', \@ids ] ] );
}

sub _when ($v) { my $t = Odoo::Ops::Mailing::Common::text($v); length $t ? $t : undef }

sub _trace ($self, $r, $t) {
    my %o = (
        id      => $r->{id},
        email   => Odoo::Ops::Mailing::Common::text( $r->{ $t->{email} } ),
        status  => $r->{ $t->{status} },
    );
    # the mail goes when Odoo deletes a delivered mass mail; the contact is only named when the trace is of one
    my $mail = Odoo::Ops::Mailing::Common::id_of( $r->{ $t->{mail} } );
    $o{mail_id} = $mail if $mail;
    $o{contact_id} = 0 + $r->{ $t->{res_id} }
        if $r->{ $t->{res_id} } && ( $r->{ $t->{model} } // '' ) eq $self->profile->model_name('contact');
    my $ft = Odoo::Ops::Mailing::Common::text( $r->{ $t->{failure_type} } );
    $o{failure_type} = $ft if length $ft;
    for my $k (qw(sent opened clicked replied)) {
        my $v = Odoo::Ops::Mailing::Common::text( $r->{ $t->{$k} } );
        $o{$k} = $v if length $v;
    }
    $o{bounced} = JSON::PP::true if ( $r->{ $t->{status} } // '' ) eq 'bounce';
    return \%o;
}

# the next call of the two crons that move a queued mailing
sub _queue_due ($self) {
    my $p = $self->profile;
    my %due;
    for my $k ( [ mass_mailing => 'mass_queue_cron' ], [ mail => 'mail_queue_cron' ] ) {
        my $xml = $p->action( $k->[1] );
        my $id  = Odoo::Ops::Mailing::Common::xmlid_id( $self, $xml );
        if ( !$id ) { $due{ $k->[0] } = { cron => $xml, found => JSON::PP::false }; next }
        my %c = map { $_ => $p->field( cron => $_ ) } qw(interval_number interval_type next_call active);
        my $r = $self->model('cron')->read( [$id], [ values %c ] )->[0];
        # a one-off trigger (made when a mailing is queued) fires before the interval does
        my $call_at = $p->field( cron_trigger => 'call_at' );
        my @tr = map { $_->{$call_at} }
            @{ $self->model('cron_trigger')->search_read( [ [ $p->field( cron_trigger => 'cron' ), '=', $id ] ], [$call_at], order => 'id asc' ) };
        $due{ $k->[0] } = {
            cron      => $xml,
            ( @tr ? ( triggers => [ sort @tr ] ) : () ),
            next_call => $r->{ $c{next_call} },
            every     => "$r->{$c{interval_number}} $r->{$c{interval_type}}",
            active    => $r->{ $c{active} } ? JSON::PP::true : JSON::PP::false,
        };
    }
    return \%due;
}

sub _fields ($self) {
    my $int = sub ($s) { { portable_type => 'integer', string => $s } };
    return {
        id            => $int->('Id'),
        subject       => { portable_type => 'text',     string => 'Subject' },
        state         => { portable_type => 'enum',     string => 'State', values => [qw(draft in_queue sending done)] },
        schedule_date => { portable_type => 'datetime', string => 'Scheduled for' },
        sent_date     => { portable_type => 'datetime', string => 'Sent on' },
        write_date    => { portable_type => 'datetime', string => 'Last written (Odoo\'s, UTC)' },
        create_date   => { portable_type => 'datetime', string => 'Made on (Odoo\'s, UTC)' },
        active        => { portable_type => 'boolean', string => 'Not archived' },
        recipients    => $int->('Odoo\'s total: every contact of the lists, opted-out included; it falls to 0 when the lists or their contacts are gone, while sent keeps the count'),
        recipients_now => $int->('Contacts of the lists today, after any deletes (opted-out included)'),
        expected      => $int->('Traces made'),
        scheduled     => $int->('Waiting to go'),
        sent          => $int->('Sent'),
        delivered     => $int->('Delivered'),
        opened        => $int->('Opened'),
        clicked       => $int->('Clicked'),
        replied       => $int->('Replied'),
        bounced       => $int->('Bounced'),
        failed        => $int->('Failed'),
        canceled      => $int->('Cancelled (opted out, blacklisted, duplicate)'),
        received_ratio => $int->('Received %'),
        opened_ratio   => $int->('Opened %'),
        queue_due      => { portable_type => 'object', string => 'When Odoo next moves a queued mailing by itself: the two crons\' interval, next call and pending triggers; null when this user may not read them (see queue_due_note)' },
        queue_due_note => { portable_type => 'text', string => 'Present when queue_due is null: which model this user may not read and which group would' },
        unreadable     => { portable_type => 'object', string => 'On a row, present when a field is null because this user may not compute it: { field => "<field> not readable by this user: its compute reads <model> (needs <group>)" }' },
        unreadable_fields => { portable_type => 'list', string => 'At the top: the row fields that are null on some row because this user may not compute them (recipients, or a counter)' },
        traces         => { portable_type => 'list', string => 'With traces=1: one entry per recipient. id is the trace; mail_id the mail.mail (absent once Odoo deleted the delivered mail); contact_id the mailing.contact; status outgoing, sent, open, reply, bounce, error or cancel; sent, opened, clicked, replied are the times Odoo recorded' },
        traces_total   => $int->('With traces=1: how many traces the mailing has (traces may show fewer)'),
        queue_note     => { portable_type => 'text', string => 'With queue=1, present when queue is null: this user may not read mail.mail and which group would' },
        queue          => { portable_type => 'list', string => 'With queue=1: mail.mail rows of the mailing as { state, count, failure_reason? }; a delivered mass mail deletes its row, so what is left is waiting, failed or cancel (an opted-out, blacklisted or duplicate recipient: not a stuck mail)' },
    };
}

1;
