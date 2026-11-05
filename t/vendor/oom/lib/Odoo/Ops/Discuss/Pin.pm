package Odoo::Ops::Discuss::Pin;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Discuss::Common;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Discuss::Pin - pin or unpin a message on a Discuss channel

=head1 SYNOPSIS

    oom-ops run discuss.pin --conf ops.conf --set channel=7 --set message=120
    oom-ops run discuss.pin --conf ops.conf --set channel=7 --set message=120 --set pinned=0

=head1 DESCRIPTION

C<discuss.pin>: Odoo's public C<set_message_pin(message_id, pinned)> on the
channel (18 and 19; 17 has it, not probed). It sets C<pinned_at> on the message
and, when pinning, posts a notification on the channel naming the person who
pinned ("NAME pinned a message to this channel."); unpinning posts nothing.
Odoo's method returns without a word for a message that is not on the channel or
is already in the state asked for; the plan holds the first and skips the
second, and the apply reads C<pinned_at> back.

Odoo 16 has no pinned messages (C<mail.message> has no C<pinned_at>; its
C<channel_pin> pins the channel in one member's sidebar), so the operation is
refused there by name (C<series>).

    pin / unpin      pinned_at is set / cleared
    already-pinned / already-unpinned   the message is in that state - skipped
    unknown-channel  this login can read no channel with that id - held
    unknown-message  the message is not one this login can read - held
    message-elsewhere   the message is on another channel - held

The revert of a pin is an unpin and of an unpin a pin; the notification a pin
posted stays.

=cut

sub op_name ($class) { 'discuss.pin' }
sub summary ($class) { 'Pin or unpin a message on a Discuss channel' }
sub pack    ($class) { 'discuss' }
sub buckets ($class) {
    return [
        { name => 'pin', meaning => 'the message is pinned (Odoo posts a notification on the channel)' },
        { name => 'unpin', meaning => 'the message is unpinned' },
        { name => 'already-pinned', meaning => 'the message is pinned already' },
        { name => 'already-unpinned', meaning => 'the message is not pinned' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-channel', meaning => 'this login can read no channel with that id' },
        { name => 'unknown-message', meaning => 'the message is not one this login can read' },
        { name => 'message-elsewhere', meaning => 'the message is on another channel, or not on a channel' },
    ];
}

sub params ($class) {
    {   channel => { type => 'int',  required => 1, help => 'the channel id (discuss.channels prints it)' },
        message => { type => 'int',  required => 1, help => 'the message id on that channel (discuss.messages prints it)' },
        pinned  => { type => 'bool', default => 1, help => 'pin (the default) or, with 0, unpin' },
    };
}
sub read_scope ($class) { { channel => ['search_read'], message => [ 'search_read', 'read' ] } }
sub write_scope ($class) { { channel => ['set_message_pin'] } }

sub _gate ($p) {
    Odoo::Error->throw( kind => 'refused', code => 'series',
        message => 'discuss.pin is not available on Odoo ' . $p->series . ': that series has no pinned messages (mail.message has no pinned_at, and the channel has no set_message_pin)' )
        if !length $p->action('pin_message');
}

sub _pinned ( $op, $p, $mid ) {
    my $row = $op->model('message')->search_read( [ [ 'id', '=', 0 + $mid ] ], [ $p->field( message => 'pinned' ) ] )->[0];
    return $row && $row->{ $p->field( message => 'pinned' ) } ? 1 : 0;
}

sub plan ($self) {
    my $p = Odoo::Ops::Discuss::Common::ready($self);
    _gate($p);
    my $plan = $self->new_plan( input_count => 1 );
    my ( $cid, $mid ) = ( $self->param('channel'), $self->param('message') );
    my $want = $self->param('pinned') ? 1 : 0;
    my $key  = "channel:$cid:message:$mid";
    my $hold = sub ( $bucket, $why ) { $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => $why ); return $plan };
    my $ch = Odoo::Ops::Discuss::Common::channel_row( $self, $cid )
        or return $hold->( 'unknown-channel', "this login can read no channel $cid" );
    my $m = Odoo::Ops::Discuss::Common::message_row( $self, $mid )
        or return $hold->( 'unknown-message', "message $mid is not readable by this login" );
    return $hold->( 'message-elsewhere', "message $mid is " . ( defined $m->{channel} ? "on channel $m->{channel}" : 'not on a channel' ) . ", not on channel $cid" )
        if !defined $m->{channel} || $m->{channel} != $cid;
    my $now = _pinned( $self, $p, $mid );
    if ( $now == $want ) {
        $plan->add( bucket => $want ? 'already-pinned' : 'already-unpinned', action => 'skip', key => $key,
            reason => "message $mid of channel $cid ($ch->{name}) is " . ( $want ? 'pinned' : 'not pinned' ) . ' already' );
        return $plan;
    }
    $plan->add(
        bucket => $want ? 'pin' : 'unpin', action => 'custom', handler => $self->op_name, kind => 'pin',
        model  => $p->model_name('channel'), id => $cid + 0, key => $key,
        calls  => [ [ $p->model_name('channel'), $p->action('pin_message') ], [ $p->model_name('message'), 'search_read' ], [ $p->model_name('message'), 'read' ] ],
        vals   => { channel => $cid + 0, message => $mid + 0, pinned => $want ? JSON::PP::true : JSON::PP::false, channel_name => $ch->{name} },
        line   => ( $want ? 'pin' : 'unpin' ) . " message $mid on channel $cid ($ch->{name})"
            . ( length $m->{author_name} ? ", written by $m->{author_name}" : '' )
            . ( $want ? '; Odoo posts a notification on the channel naming the person who pinned' : '; Odoo posts nothing' ),
        reason => ( $want ? 'the revert unpins the message; the notification stays' : 'the revert pins the message again, which posts the notification again' ),
    );
    return $plan;
}

=head2 apply_custom($class, $client, $change)

Called by the runner: notes the channel's newest message, calls
C<set_message_pin>, reads C<pinned_at> back and names the messages Odoo posted.

=cut

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "discuss.pin cannot apply kind '" . ( $c->{kind} // '' ) . "'" ) if ( $c->{kind} // '' ) ne 'pin';
    my $p = Odoo::Ops::Discuss::Common::profile_for( $client, 'discuss.pin' );
    _gate($p);
    my $v    = $c->{vals};
    my $want = $v->{pinned} ? 1 : 0;
    my $before = Odoo::Ops::Discuss::Common::newest_message( $client, $p, $v->{channel} );
    $client->execute_kw( $p->model_name('channel'), $p->action('pin_message'), [ [ $v->{channel} ] ],
        { message_id => $v->{message}, pinned => $want ? JSON::PP::true : JSON::PP::false } );
    my $row = $client->model( $p->model_name('message') )->read_one( $v->{message}, [ $p->field( message => 'pinned' ) ] );
    my $now = $row && $row->{ $p->field( message => 'pinned' ) } ? 1 : 0;
    my @msgs = @{ Odoo::Ops::Discuss::Common::channel_messages_after( $client, $p, $v->{channel}, $before ) };
    return {
        id => $v->{channel}, reported => 'write',
        returned => { method => $p->action('pin_message'), messages => \@msgs,
            says => ( $want ? 'pinned' : 'unpinned' ) . " message $v->{message} on channel $v->{channel}"
                . ( @msgs ? '; Odoo posted message' . ( @msgs == 1 ? '' : 's' ) . ' ' . join( ', ', @msgs ) : '; Odoo posted no message' ) },
        created => [ map { { model => $p->model_name('message'), id => $_, name => $v->{channel_name} } } @msgs ],
        after   => $now == $want ? { id => $v->{message}, pinned => $want ? JSON::PP::true : JSON::PP::false } : undef,
    };
}

=head2 undo_custom($class, $entry)

The opposite pin of the same message.

=cut

sub undo_custom ($class, $e) {
    my $v = ref $e->{vals} eq 'HASH' ? $e->{vals} : {};
    return ( undef, 'the journal entry names no message: nothing to undo' ) if !$v->{message};
    my $back = $v->{pinned} ? 0 : 1;
    return (
        {   bucket => 'undo-pin', action => 'custom', handler => 'discuss.pin', kind => 'pin',
            model  => $e->{model}, id => $e->{id}, key => "undo:message:$v->{message}",
            calls  => [ [ $e->{model}, 'set_message_pin' ], [ 'mail.message', 'search_read' ], [ 'mail.message', 'read' ] ],
            vals   => { %$v, pinned => $back ? JSON::PP::true : JSON::PP::false },
            line   => ( $back ? 'pin' : 'unpin' ) . " message $v->{message} on channel $v->{channel} again",
            reason => 'undo discuss.pin',
        },
    );
}

1;
