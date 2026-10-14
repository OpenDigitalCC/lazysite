package Odoo::Ops::Comms::Send;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA qw(sha256_hex);
use Encode ();
use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Comms::Render;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Comms::Send - plan sending rendered messages through Odoo

=head1 DESCRIPTION

C<comms.send>: reads a C<comms.render> run's C<messages.jsonl> and
plans one send per message, carrying the message files' content as it
is now (so an owner's edit to a single file is what goes out). Apply
sends each one through Odoo's own mail composer, so Odoo addresses it
(the lead's email), drops blacklisted addresses, queues and sends it
with its configured mail server, and keeps a copy in the lead's
history.

Planning re-checks each lead: already sent with this subject since
rendering - C<already-sent>; the lead's email changed - C<email-changed>
(held). At apply, a lead whose email changed after planning makes the
plan stale.

C<< test => 1 >> plans a single send of the first message to the
configured user's own address (through the same composer, against
their own contact record) - no lead is touched and nothing enters a
lead's history. Do this before every campaign.

C<max> (default 50) refuses a plan of more sends than that; raise it
deliberately.

C<from> (default C<salesperson>): each email goes out from the lead's
salesperson, as C<"Name" <email>> - the owner's rule is that messages
come from the person the contact knows. A lead with no salesperson, or
a salesperson without an email address, is held (C<no-sender>), never
sent as someone else; a salesperson change after planning makes the
plan stale. Reply-To stays Odoo's (the team alias), so replies land on
the lead, and the chatter author stays the configured user - the record
says truthfully who sent it. C<from=none> leaves the sender to Odoo.

This is for one-to-one follow-up to people with a relationship. Bulk
marketing belongs in Odoo's mass mailing, with its unsubscribe
handling.

=head2 Series

How one message is handed to Odoo differs by series; each is written
after reading that series' composer and, where the instance is
reachable, probing it. Any other series refuses by name.

    16   mass_mail composer driven by the context (active_ids), the copy
         kept in the history with auto_delete_message off; the message
         is a message_type "email". Live (local cluster 16.0).
    17   as 18: the 17.0 composer source has the same fields (res_ids,
         force_send, auto_delete_keep_log; no auto_delete_message).
         Graded source: not probed live, and the plan says so.
    18   mass_mail composer with res_ids and force_send off, so the mail
         waits in the queue for Odoo's cron as on 16; auto_delete stays
         off, so the copy stays in the history as a message_type
         "email_outgoing". Live (local cluster 18.0).
    19   as 18. Live (local cluster 19.0).

C<res_id> is gone from the composer from 17 on (C<res_ids>, a text
holding a list, replaces it), and so is C<auto_delete_message>
(C<auto_delete> and C<auto_delete_keep_log> are the 17+ fields).

=cut

my %SENDER = ( 16 => \&_send_v16, 17 => \&_send_v17, 18 => \&_send_v17, 19 => \&_send_v17 );
my %GRADE  = ( 16 => 'live', 17 => 'source', 18 => 'live', 19 => 'live' );

sub op_name ($class) { 'comms.send' }
sub summary ($class) { 'Plan sending rendered messages via Odoo mail (test first)' }
sub pack    ($class) { 'crm' }
sub params ($class) {
    {   messages => { type => 'path', required => 1, help => 'messages.jsonl from comms.render' },
        test     => { type => 'bool', default => 0, help => 'send only the first message, to yourself' },
        max      => { type => 'int',  default => 50, help => 'refuse a plan with more sends than this' },
        from     => { type => 'str',  default => 'salesperson',
            help => 'salesperson (the lead\'s, as "Name <email>"; held if none) or none (Odoo\'s default)' },
    };
}
sub read_scope ($class) {
    {   lead           => [qw(search_read read)],
        'mail.message' => ['search_read'],
        'mail.mail'    => ['search_read'],
        'res.partner'  => ['read'],
    };
}
sub write_scope ($class) { { 'mail.compose.message' => [qw(create action_send_mail)] } }

# How a message is handed to the composer is the lead's behaviour (route
# send_email, "mail.compose.message <mode>"); a behaviour with no such
# route gets today's literal, the composer in mass_mail mode. The
# series gate stays: a route does not make an unprobed series send.
sub _composer_mode ($self, $model) {
    my $route = $self->ctx->behaviour($model)->route('send_email');
    return 'mass_mail' if !$route;
    my ($mode) = ( $route->{via} // '' ) =~ /^mail\.compose\.message (mass_mail|comment)\z/;
    Odoo::Error->throw( kind => 'config',
        message => "behaviour route send_email of $model names '" . ( $route->{via} // '' ) . "'; comms.send can use 'mail.compose.message mass_mail' or 'mail.compose.message comment'" )
        if !$mode;
    return $mode;
}

sub plan ($self) {
    my $series = $self->client->server_series;
    Odoo::Error->throw( kind => 'refused', code => 'series',
        message => "comms.send is not implemented for Odoo $series (probed: " . join( ', ', sort keys %SENDER ) . ')' )
        if !$SENDER{$series};
    my $mode = $self->_composer_mode( $self->profile->model_name('lead') );

    my @msgs = $self->_read_index( $self->param('messages') );
    my $p    = $self->profile;
    my $email_f = $p->field( lead => 'email' );

    if ( $self->param('test') ) {
        Odoo::Error->throw( kind => 'usage', message => 'no messages to test with' ) if !@msgs;
        my $me = $self->client->execute_kw( 'res.users', 'read', [ [ $self->client->uid ] ],
            { fields => [qw(partner_id email)] } )->[0];
        Odoo::Error->throw( kind => 'usage', message => 'the configured user has no email address to test with' )
            if !$me->{email};
        my $m    = $msgs[0];
        my $plan = $self->new_plan( input_count => 1 );
        $plan->note("series $series: the composer shape is read from source, not probed live")
            if $GRADE{$series} ne 'live';
        $plan->note("TEST: first message, to the configured user's own address, not to the lead");
        $plan->add(
            bucket  => 'test-send', action => 'custom', handler => $self->op_name,
            model   => 'res.partner', id => $me->{partner_id}[0],
            subject => "[TEST] $m->{subject}", body => $self->_body($m), series => $series, composer_mode => $mode,
            key     => "test:lead $m->{lead_id}",
        );
        return $plan;
    }

    Odoo::Error->throw( kind => 'refused', code => 'max',
        message => scalar(@msgs) . ' messages exceed max=' . $self->param('max') . '; raise max deliberately' )
        if @msgs > $self->param('max');

    my $from = $self->param('from');
    Odoo::Error->throw( kind => 'usage', message => "from must be salesperson or none, not '$from'" )
        if $from ne 'salesperson' && $from ne 'none';
    my $sp_f = $p->field( lead => 'salesperson' );
    my %lead = map { $_->{id} => $_ } @{ $self->model('lead')->read( [ map { $_->{lead_id} } @msgs ], [ $email_f, $sp_f ] ) };
    my %sender;
    if ( $from eq 'salesperson' ) {
        my @uids = sort { $a <=> $b } keys %{ { map { ref $_->{$sp_f} ? ( $_->{$sp_f}[0] => 1 ) : () } values %lead } };
        %sender = map { $_->{id} => $_ } @{ @uids ? $self->client->execute_kw( 'res.users', 'read', [ \@uids ],
                { fields => [qw(name email)] } ) : [] };
    }
    my $plan   = $self->new_plan( input_count => scalar @msgs );
    $plan->note("series $series: the composer shape is read from source, not probed live")
        if $GRADE{$series} ne 'live';
    my $edited = 0;
    for my $m (@msgs) {
        my $l = $lead{ $m->{lead_id} };
        if ( !$l ) {
            $plan->add( bucket => 'lead-gone', action => 'hold', key => "lead:$m->{lead_id}",
                reason => 'lead no longer readable' );
            next;
        }
        if ( lc( $l->{$email_f} || '' ) ne lc $m->{email} ) {
            $plan->add( bucket => 'email-changed', action => 'hold', key => "lead:$m->{lead_id}",
                reason => 'lead email changed since rendering - re-render' );
            next;
        }
        if ( Odoo::Ops::Comms::Render::sent_before( $self->client, $p->model_name('lead'), $m->{lead_id}, $m->{subject} ) ) {
            $plan->add( bucket => 'already-sent', action => 'skip', key => "lead:$m->{lead_id}" );
            next;
        }
        my $email_from;
        if ( $from eq 'salesperson' ) {
            my $u = ref $l->{$sp_f} ? $sender{ $l->{$sp_f}[0] } : undef;
            if ( !$u || !$u->{email} ) {
                $plan->add( bucket => 'no-sender', action => 'hold', key => "lead:$m->{lead_id}",
                    reason => $u ? "salesperson $u->{name} has no email address" : 'the lead has no salesperson' );
                next;
            }
            ( my $name = $u->{name} ) =~ s/["\\]//g;
            $email_from = qq("$name" <$u->{email}>);
        }
        my $body = $self->_body($m);
        $edited++ if sha256_hex( Encode::encode_utf8($body) ) ne $m->{body_sha256};
        $plan->add(
            bucket  => 'send', action => 'custom', handler => $self->op_name,
            model   => $p->model_name('lead'), id => $m->{lead_id},
            subject => $m->{subject}, body => $body, series => $series, composer_mode => $mode,
            ( $email_from ? ( email_from => $email_from ) : () ),
            before  => { $email_f => $l->{$email_f}, $sp_f => $l->{$sp_f} },
            key     => "lead:$m->{lead_id}",
        );
    }
    $plan->note("$edited message file(s) edited after rendering; the plan carries the edited text") if $edited;
    return $plan;
}

sub _read_index ($self, $path) {
    open my $fh, '<:raw', $path or Odoo::Error->throw( kind => 'config', message => "cannot read $path: $!" );
    my @m = map { Odoo::Ops::json()->decode($_) } grep {/\S/} <$fh>;
    close $fh;
    return @m;
}

sub _body ($self, $m) {
    open my $fh, '<:raw', $m->{file} or Odoo::Error->throw( kind => 'config', message => "cannot read $m->{file}: $!" );
    my $raw = do { local $/; <$fh> };
    close $fh;
    return Encode::decode_utf8($raw);
}

=head2 apply_custom($client, $change)

Called by the runner for each planned send.

=cut

sub apply_custom ($class, $client, $c) {
    my $impl = $SENDER{ $c->{series} }
        or Odoo::Error->throw( kind => 'refused', code => 'series', message => "no sender for series $c->{series}" );
    return $impl->( $client, $c );
}

# Odoo 16: the composer in mass_mail mode on the one record. Recipients
# come from the record (crm.lead -> email_from; res.partner -> email);
# blacklisted addresses are cancelled by the composer itself; with
# auto_delete_message off a copy stays in the record's history.
sub _send_v16 ($client, $c) {
    my $mode = $c->{composer_mode} // 'mass_mail';    # a plan from before the route existed has none
    my $ctx = {
        active_ids               => [ $c->{id} ],
        active_id                => $c->{id},
        active_model             => $c->{model},
        default_composition_mode => $mode,
        default_model            => $c->{model},
    };
    my $wid = $client->execute_kw( 'mail.compose.message', 'create', [ {
        composition_mode    => $mode,
        model               => $c->{model},
        subject             => $c->{subject},
        body                => $c->{body},
        auto_delete_message => JSON::PP::false,
        ( $c->{email_from} ? ( email_from => $c->{email_from} ) : () ),
    } ], { context => $ctx } );
    $client->execute_kw( 'mail.compose.message', 'action_send_mail', [ [$wid] ], { context => $ctx } );
    my $msg = $client->execute_kw( 'mail.message', 'search_read', [ [
        [ 'model', '=', $c->{model} ], [ 'res_id', '=', $c->{id} ],
        [ 'message_type', '=', 'email' ], [ 'subject', '=', $c->{subject} ] ] ],
        { fields => ['id'], order => 'id desc', limit => 1 } );
    Odoo::Error->throw( kind => 'fault', message => "no message recorded on $c->{model} $c->{id} after sending" )
        if !@$msg;
    return { returned => $msg->[0]{id}, after => { message_id => $msg->[0]{id} } };
}

# Odoo 17 and later (live 18 and 19; 17 from source): the composer takes
# the record in res_ids (a text holding a list), not in the context, and has
# no auto_delete_message - auto_delete is off in mass_mail mode, so the
# message stays in the record's history, as a message_type email_outgoing.
# force_send off leaves the mail in the queue for the cron, as on 16 (left
# on, the composer sends at once and a failure parks the mail in state
# exception). The queued mail.mail is read back beside the message: that
# row, in state outgoing, is what was handed to Odoo.
sub _send_v17 ($client, $c) {
    my $wid = $client->execute_kw( 'mail.compose.message', 'create', [ {
        composition_mode => 'mass_mail',
        model            => $c->{model},
        res_ids          => "[$c->{id}]",
        subject          => $c->{subject},
        body             => $c->{body},
        force_send       => JSON::PP::false,
        ( $c->{email_from} ? ( email_from => $c->{email_from} ) : () ),
    } ] );
    $client->execute_kw( 'mail.compose.message', 'action_send_mail', [ [$wid] ] );
    my $msg = $client->execute_kw( 'mail.message', 'search_read', [ [
        [ 'model', '=', $c->{model} ], [ 'res_id', '=', $c->{id} ],
        [ 'message_type', '=', 'email_outgoing' ], [ 'subject', '=', $c->{subject} ] ] ],
        { fields => ['id'], order => 'id desc', limit => 1 } );
    Odoo::Error->throw( kind => 'fault', message => "no message recorded on $c->{model} $c->{id} after sending" )
        if !@$msg;
    my $mail = $client->execute_kw( 'mail.mail', 'search_read', [ [ [ 'mail_message_id', '=', $msg->[0]{id} ] ] ],
        { fields => [qw(id state)], limit => 1 } );
    my %made = (
        message_id => $msg->[0]{id},
        ( @$mail ? ( mail_id => $mail->[0]{id}, mail_state => $mail->[0]{state} ) : () ),
    );
    return { returned => { %made }, after => { %made } };
}

1;
