package Odoo::Ops::Mailing::Process;

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

Odoo::Ops::Mailing::Process - push Odoo's two mail queues now

=head1 SYNOPSIS

    oom-ops run mailing.process --conf ops.conf --set mailing=7

=head1 DESCRIPTION

A mailing put in the queue is moved by Odoo's mass-mailing queue cron,
and mails left outgoing by the mail queue cron. On a fresh instance
those run once a day and once an hour; queueing a mailing also makes a
one-off trigger that a running cron worker answers within seconds, but
an instance with no cron worker, a mailing whose schedule was moved to
the past, and mails a down mail server left behind all wait for the
intervals, which a try-out cannot do. C<mailing.process> pushes both, as
two C<custom> changes in order:

    mass-queue   the cron record mass_mailing.ir_cron_mass_mailing_queue, run through
                 ir.cron.method_direct_trigger (the job itself, _process_mass_mailing_queue,
                 is private and cannot be called over RPC)
    mail-queue   mail.mail.process_email_queue, which sends the outgoing mails

C<mailing> is optional and only narrows what is read back and which
mails the second change sends (that mailing's outgoing mails; without it,
every outgoing mail). It cannot narrow the first: Odoo's job takes
every queued mailing whose schedule is due, so the plan note names them,
and the plan is the place to see that before approving. Each change reads
back the mailing's counters (state, sent, failed, scheduled), or without
C<mailing> the number of queued mailings and outgoing mails left.

Not reversible, and says so: a revert holds both. Series: written for
Odoo 16; another series is refused by name until its profile is probed.

=cut

sub op_name ($class) { 'mailing.process' }
sub summary ($class) { 'Plan pushing Odoo\'s mass-mailing and mail queues now, instead of waiting for their crons' }
sub pack    ($class) { 'mailing' }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'mass-queue', meaning => 'Odoo\'s mass-mailing queue cron is run now' },
        { name => 'mail-queue', meaning => 'the outgoing mails are sent now' },
    ];
}
sub holds ($class) { [] }

sub params ($class) {
    {   mailing => { type => 'int', help => 'a mailing to narrow the mail push and the read-back to (optional)' } };
}
sub read_scope ($class) {
    {   mailing => [qw(search_read read)],
        mail    => ['search_read'],
        cron    => ['read'],
        'ir.model.data' => ['search_read'],
    };
}
sub write_scope ($class) { { cron => [qw(read &cron_trigger)], mail => [qw(search_read &process_mail_queue)], mailing => ['read'] } }

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

my @AFTER = qw(state sent failed scheduled canceled expected);

sub plan ($self) {
    my $p = Odoo::Ops::Mailing::Common::ready($self);
    my $f = sub ($lm, $lf) { $p->field( $lm => $lf ) };
    my $id = $self->param('mailing');
    if ( defined $id ) {
        $self->model('mailing')->read( [$id], [ $f->( mailing => 'state' ) ] )->[0]
            or Odoo::Error->throw( kind => 'refused', code => 'unknown-mailing', message => "mailing.process: no mailing $id",
            fix => q(oom-ops run mailing.status --conf <conf> lists the mailings) );
    }
    my $xml = $p->action('mass_queue_cron');
    my $cron = Odoo::Ops::Mailing::Common::xmlid_id( $self, $xml )
        or Odoo::Error->throw( kind => 'config', message => "mailing.process: the cron $xml does not exist on this instance (is mass_mailing installed?)" );

    my $queued = $self->model('mailing')->search_read( [ [ $f->( mailing => 'state' ), 'in', [qw(in_queue sending)] ] ],
        [ $f->( mailing => 'subject' ), $f->( mailing => 'state' ), $f->( mailing => 'schedule_date' ) ], order => 'id asc' );
    my $outgoing = $self->model('mail')->search_read( [ [ $f->( mail => 'state' ), '=', 'outgoing' ] ], [ $f->( mail => 'mailing' ) ] );
    my @mine = defined $id ? grep { Odoo::Ops::Mailing::Common::id_of( $_->{ $f->( mail => 'mailing' ) } ) == $id } @$outgoing : @$outgoing;

    my $plan = $self->new_plan( input_count => 2 );
    $plan->note( 'the mass-mailing job takes every queued mailing that is due, not only the one named: '
        . ( @$queued ? join( '; ', map { "mailing $_->{id} ('$_->{ $f->( mailing => 'subject' ) }', $_->{ $f->( mailing => 'state' ) })" } @$queued ) : 'none is queued now' ) );
    $plan->note( scalar(@mine) . ' outgoing mail(s) ' . ( defined $id ? "of mailing $id" : 'in all' ) . ' will be sent' . ( defined $id ? '; other mailings\' mails are left for their own run' : '' ) );
    $plan->note('neither push can be taken back');
    my %common = ( action => 'custom', handler => $self->op_name );
    my %v = (
        mailing      => $id,
        after_fields => { map { $_ => $f->( mailing => $_ ) } @AFTER },
        mailing_model => $p->model_name('mailing'),
        state_field  => $f->( mailing => 'state' ),
        mail_model   => $p->model_name('mail'),
        mail_mailing => $f->( mail => 'mailing' ),
        mail_state   => $f->( mail => 'state' ),
    );
    $plan->add( %common, bucket => 'mass-queue', kind => 'mass-queue', model => $p->model_name('cron'), id => $cron, key => 'process:mass-queue',
        vals => { %v, method => $p->action('cron_trigger') }, reason => "runs $xml now" );
    $plan->add( %common, bucket => 'mail-queue', kind => 'mail-queue', model => $p->model_name('mail'), key => 'process:mail-queue',
        vals => { %v, method => $p->action('process_mail_queue') }, reason => 'sends ' . ( defined $id ? "mailing ${id}'s" : 'every' ) . ' outgoing mail now' );
    return $plan;
}

sub apply_custom ($class, $client, $c) {
    my $kind = $c->{kind} // '';
    Odoo::Error->throw( kind => 'usage', message => "mailing.process cannot apply kind '$kind'" ) if $kind !~ /^(mass|mail)-queue\z/;
    my $v = $c->{vals};
    if ( $kind eq 'mass-queue' ) {
        $client->model( $c->{model} )->call( $v->{method}, [ [ $c->{id} ] ] );
    }
    else {
        my $mail = $client->model( $c->{model} );
        my @dom  = ( [ $v->{mail_state}, '=', 'outgoing' ], ( defined $v->{mailing} ? [ $v->{mail_mailing}, '=', $v->{mailing} ] : () ) );
        my $ids  = [ map { $_->{id} } @{ $mail->search_read( \@dom, ['id'] ) } ];
        $mail->call( $v->{method}, [$ids] ) if @$ids;
    }
    my %after;
    if ( defined $v->{mailing} ) {
        my $row = $client->model( $v->{mailing_model} )->read_one( $v->{mailing}, [ values %{ $v->{after_fields} } ] );
        %after = map { $_ => $row->{ $v->{after_fields}{$_} } } keys %{ $v->{after_fields} };
    }
    else {
        my $q = $client->model( $v->{mailing_model} )->search_read( [ [ $v->{state_field}, 'in', [qw(in_queue sending)] ] ], ['id'] );
        my $o = $client->model( $v->{mail_model} )->search_read( [ [ $v->{mail_state}, '=', 'outgoing' ] ], ['id'] );
        %after = ( queued_mailings => scalar @$q, outgoing_mails => scalar @$o );
    }
    return { returned => { %after }, after => { %after } };
}

sub undo_custom ($class, $entry) {
    return ( undef, 'a queue push cannot be taken back: the mails it sent are gone' );
}

1;
