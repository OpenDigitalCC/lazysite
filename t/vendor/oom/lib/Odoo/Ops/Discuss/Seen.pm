package Odoo::Ops::Discuss::Seen;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Discuss::Common;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Discuss::Seen - mark a channel read

=head1 SYNOPSIS

    oom-ops run discuss.seen --conf ops.conf --set channel=7
    oom-ops run discuss.seen --conf ops.conf --set channel=7 --set message=120

=head1 DESCRIPTION

C<discuss.seen>: marks the channel read for the login the config runs as, up to
C<message> (a message id in that channel) or, without it, the newest message.
Odoo holds this on the member's row: C<seen_message_id> (the last message read),
C<fetched_message_id> and the unread counter it computes. Its own client does it
at the web route C</mail/channel/set_last_seen_message> on 16 and
C</discuss/channel/mark_as_read> on 18 and 19, because the method behind it
(C<_channel_seen> on 16, C<_mark_as_read> on 18 and 19) is private and Odoo refuses private methods over
RPC. The plan holds one C<route> change (L<Odoo::Ops::Plan>) that calls the route over a
web session as the login (see L<Odoo::Ops::Route>); the member's seen message is its
C<precondition> (read again at apply, so a plan made before another client marked the
channel read is refused C<stale>) and its C<verify> (read back after).

The route moves the seen message forward only: a message at or before the
member's seen message changes nothing, so the plan skips it (C<already-seen>)
and a revert is held C<irreversible>, saying so.

    seen             the channel is marked read up to the message
    already-seen     the login's seen message is that message or a later one - skipped
    unknown-channel  this login can read no channel with that id - held
    unknown-message  the message is not one this login can read - held
    message-elsewhere  the message is on another channel - held
    no-messages      the channel has no message - held

A login with no membership row in the channel is planned like any other and
Odoo answers on apply: 16 answers 404 Not Found to a non-member; 18 and 19
return without a word and change nothing, which apply reads back and says
(no membership row, nothing moved). Series: 16, 18 and 19; 17 is refused by
name as not probed.

=cut

sub op_name ($class) { 'discuss.seen' }
sub summary ($class) { 'Mark a Discuss channel read up to a message' }
sub pack    ($class) { 'discuss' }
sub buckets ($class) {
    return [
        { name => 'seen', meaning => 'the channel is marked read up to the message, over Odoo\'s own web route' },
        { name => 'already-seen', meaning => 'the login\'s seen message is that message or a later one' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-channel', meaning => 'this login can read no channel with that id' },
        { name => 'unknown-message', meaning => 'the message is not one this login can read' },
        { name => 'message-elsewhere', meaning => 'the message is on another channel, or not on a channel' },
        { name => 'no-messages', meaning => 'the channel has no message to mark' },
    ];
}

sub params ($class) {
    {   channel => { type => 'int', required => 1, help => 'the channel id (discuss.channels prints it)' },
        message => { type => 'int', help => 'read up to this message id (default: the newest)' },
    };
}
sub read_scope ($class) {
    { channel => ['search_read'], member => [ 'search_read', 'read' ], message => ['search_read'] };
}
# The write is a web route, not an RPC call: Odoo's own client uses one per series, and the apply is
# held to them. The member's row is read before (the precondition) and after (the verify).
sub routes ($class) { [ '/mail/channel/set_last_seen_message', '/discuss/channel/mark_as_read' ] }
sub write_scope ($class) { {} }

sub plan ($self) {
    my $p = Odoo::Ops::Discuss::Common::ready($self);
    my $plan = $self->new_plan( input_count => 1 );
    my $cid  = $self->param('channel');
    my $key  = "channel:$cid";
    my $hold = sub ( $bucket, $why ) { $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => $why ); return $plan };

    my $ch = Odoo::Ops::Discuss::Common::channel_row( $self, $cid )
        or return $hold->( 'unknown-channel', "this login can read no channel $cid" );
    my $target = $self->param('message');
    if ( defined $target ) {
        my $m = Odoo::Ops::Discuss::Common::message_row( $self, $target )
            or return $hold->( 'unknown-message', "message $target is not readable by this login" );
        return $hold->( 'message-elsewhere', "message $target is " . ( defined $m->{channel} ? "on channel $m->{channel}" : 'not on a channel' ) . ", not on channel $cid" )
            if !defined $m->{channel} || $m->{channel} != $cid;
    }
    else {
        $target = Odoo::Ops::Discuss::Common::last_message_id( $self, $cid )
            or return $hold->( 'no-messages', "channel $cid ($ch->{name}) has no message" );
    }
    my $me  = Odoo::Ops::Discuss::Common::my_partner( $self->client );
    my $mem = Odoo::Ops::Discuss::Common::member_row( $self, $cid, $me );
    my $was = $mem ? $mem->{seen} : undef;
    if ( defined $was && $was >= $target ) {
        $plan->add( bucket => 'already-seen', action => 'skip', key => $key,
            reason => "the login has read up to message $was of channel $cid ($ch->{name}) already" );
        return $plan;
    }
    $plan->note("this login has no membership row in channel $cid; Odoo answers on apply") if !$mem;
    my $mf = $p->field( member => 'seen' );
    $plan->add(
        bucket => 'seen', action => 'route', key => $key, model => $p->model_name('member'),
        path   => $p->action('seen_route'), params => { channel_id => $cid + 0, last_message_id => $target + 0 },
        ( $mem ? ( precondition => { model => $p->model_name('member'), ids => [ $mem->{id} ], fields => { $mf => $was } } ) : () ),
        ( $mem ? ( verify => { model => $p->model_name('member'), ids => [ $mem->{id} ], fields => { $mf => $target + 0 } } ) : () ),
        line   => "mark channel $cid ($ch->{name}) read up to message $target" . ( defined $was ? " (read up to $was now)" : '' )
            . ( $mem && $mem->{unread} ? "; $mem->{unread} unread" : '' ),
        fault_note => "Odoo's route answers 404 Not Found when the login is no member of the channel",
        reason => 'Odoo moves the seen message forward only, so this cannot be taken back',
    );
    return $plan;
}

1;
