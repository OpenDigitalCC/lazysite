package Odoo::Ops::Mailing::Test;

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

Odoo::Ops::Mailing::Test - send a draft mailing to a few addresses first

=head1 SYNOPSIS

    oom-ops run mailing.test --conf ops.conf --set mailing=7 --set to=me@example.com

=head1 DESCRIPTION

C<mailing.test> plans one test send of mailing C<mailing> to C<to>
(addresses, comma-separated; default the connected user's own email).
Apply drives Odoo's own test wizard (C<mailing.mailing.test>, field
C<email_to>, method C<send_mail_test>), so the mail is the mailing as a
recipient would get it: the same layout, the same sender, the same
unsubscribe rewrite - and none of the counters move, because a test
makes no trace.

On Odoo 16 the wizard renders the body against one real contact if there
is one, sends at once through the mail server (it does not wait for the
mail queue), and deletes its C<mail.mail> rows afterwards; failures are
logged on the mailing's chatter rather than raised. So apply reads that
chatter back: it reports, per address, what Odoo logged, and fails the
change when any address did not get the mail. The subject is the
mailing's own, unprefixed: look for it in the mail catcher or the
recipient's inbox.

Allowed while the mailing is draft or in_queue; any other state is
refused (C<not-testable>) naming the state. A test that went out cannot
be recalled, so a revert holds it. The run is kept in the run registry
like every run; the mailshot tool finds it there
(C<< Odoo::Ops::Runs->find >>) to enforce its rule that a mailing is
tested before it is sent. C<mailing.send> does not look.

Series: written for Odoo 16; another series is refused by name until its
profile is probed.

=cut

sub op_name ($class) { 'mailing.test' }
sub summary ($class) { 'Plan a test send of a draft mailing to a few addresses (oom-mailshot send checks it was done)' }
sub pack    ($class) { 'mailing' }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'test-send', meaning => 'a test mail of the mailing goes to the addresses in to; no counter moves' },
    ];
}
sub holds ($class) { [] }

sub params ($class) {
    {   mailing => { type => 'int',  required => 1, help => 'the mailing id' },
        to      => { type => 'list', help => 'addresses to test to, comma-separated; default your own' },
    };
}
sub read_scope ($class) { { mailing => [qw(read)], 'res.users' => ['read'] } }
sub write_scope ($class) { { test_wizard => [qw(create read &test_send)], message => ['search_read'] } }

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

sub plan ($self) {
    my $p = Odoo::Ops::Mailing::Common::ready($self);
    my $f = sub ($lf) { $p->field( mailing => $lf ) };
    my $id = $self->param('mailing');
    my $m  = $self->model('mailing')->read( [$id], [ $f->('subject'), $f->('state') ] )->[0]
        or Odoo::Error->throw( kind => 'refused', code => 'unknown-mailing', message => "mailing.test: no mailing $id",
            fix => q(oom-ops run mailing.status --conf <conf> lists the mailings) );
    my $state = $m->{ $f->('state') };
    Odoo::Error->throw( kind => 'refused', code => 'not-testable',
        message => "mailing $id is $state: a test is for a mailing that has not gone out (draft or in_queue)" )
        if $state ne 'draft' && $state ne 'in_queue';

    my @to = @{ $self->param('to') // [] };
    my $own;
    if ( !@to ) {
        my $me = $self->client->model('res.users')->read_one( $self->client->uid, ['email'] );
        my $mail = Odoo::Ops::Mailing::Common::text( $me ? $me->{email} : undef );
        Odoo::Error->throw( kind => 'usage', message => 'mailing.test: the connected user has no email address; give to=' ) if !length $mail;
        @to  = ($mail);
        $own = $mail;
    }
    for my $a (@to) {
        Odoo::Error->throw( kind => 'usage', message => "mailing.test: '$a' is not an email address" ) if !defined Odoo::Ops::Mailing::Common::email($a);
    }
    my $plan = $self->new_plan( input_count => 1 );
    $plan->note("test of mailing $id ('$m->{ $f->('subject') }') to " . join( ', ', @to ) . '; it goes at once, not through the mail queue, with the mailing\'s own subject');
    # information on the plan; the tool's own rule (--to me) lives in oom-mailshot
    $plan->note("to $own: the connected user's own mailbox, a real one on a real instance; pass to= for a test address") if defined $own;
    $plan->add(
        bucket => 'test-send', action => 'custom', handler => $self->op_name, kind => 'test-send',
        model => $p->model_name('mailing'), id => $id, key => "test:mailing $id",
        calls => [ [ $p->model_name('message'), 'search_read' ], [ $p->model_name('test_wizard'), 'create' ], [ $p->model_name('test_wizard'), $p->action('test_send') ] ],
        before => { $f->('state') => $state },
        vals => {
            wizard      => $p->model_name('test_wizard'),
            mailing     => $p->field( test_wizard => 'mailing' ),
            email_to    => $p->field( test_wizard => 'email_to' ),
            method      => $p->action('test_send'),
            message     => $p->model_name('message'),
            to          => \@to,
        },
        reason => 'a test send; nothing is recorded against the recipients',
    );
    return $plan;
}

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "mailing.test cannot apply kind '" . ( $c->{kind} // '' ) . "'" ) if ( $c->{kind} // '' ) ne 'test-send';
    my $v = $c->{vals};
    my $msgs = $client->model( $v->{message} );
    # the wizard logs its outcome on the mailing; what is there already is not this test's
    my $last = $msgs->search_read( [ [ 'model', '=', $c->{model} ], [ 'res_id', '=', $c->{id} ] ], ['id'], order => 'id desc', limit => 1 )->[0];
    my $after_id = $last ? $last->{id} : 0;
    my $wid = $client->model( $v->{wizard} )->create( { $v->{mailing} => $c->{id}, $v->{email_to} => join( "\n", @{ $v->{to} } ) } );
    $client->model( $v->{wizard} )->call( $v->{method}, [ [$wid] ] );
    my $logged = $msgs->search_read( [ [ 'model', '=', $c->{model} ], [ 'res_id', '=', $c->{id} ], [ 'id', '>', $after_id ] ], ['body'], order => 'id asc' );
    my ( @sent, @failed );
    for my $row (@$logged) {
        my $b = $row->{body} // '';
        push @sent, $1 while $b =~ /Test mailing successfully sent to ([^<]+)/g;
        while ( $b =~ /Test mailing could not be sent to ([^<:]+):(?:<br\s*\/?>)?\s*([^<]*)/g ) { push @failed, { to => $1, why => $2 } }
        while ( $b =~ /Mailing addresses incorrect: ([^<]+)/g ) { push @failed, { to => $1, why => 'not an address' } }
    }
    s/\s+\z// for @sent;
    my %got = map { lc $_ => 1 } @sent;
    my @missing = grep { !$got{ lc $_ } } @{ $v->{to} };
    Odoo::Error->throw(
        kind    => 'fault',
        message => 'the test did not reach ' . join( ', ', @missing ) . ( @failed ? ': ' . join( '; ', map { "$_->{to} - $_->{why}" } @failed ) : ' (Odoo logged no outcome for it)' ),
    ) if @missing;
    return { returned => { sent_to => \@sent }, after => { sent_to => scalar @sent, asked => scalar @{ $v->{to} } } };
}

sub undo_custom ($class, $entry) {
    return ( undef, 'a test mail that went out cannot be recalled' );
}

1;
