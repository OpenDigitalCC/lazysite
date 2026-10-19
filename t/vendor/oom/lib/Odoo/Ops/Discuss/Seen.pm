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
RPC; so apply runs over a web session as the login (see
L<Odoo::Ops::Discuss::Common>). Apply reads the member's seen message back.

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
    { channel => ['search_read'], member => ['search_read'], message => ['search_read'] };
}
# The write is a web route, not an RPC call, so there is no method to name for it:
# the scope holds the read-back of the member's row, which makes this a write operation.
sub write_scope ($class) { { member => ['read'] } }

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
    $plan->add(
        bucket => 'seen', action => 'custom', handler => $self->op_name, kind => 'seen',
        model  => $p->model_name('member'), ( $mem ? ( id => $mem->{id}, before => { $p->field( member => 'seen' ) => $mem->{seen_raw} } ) : () ),
        key    => $key,
        calls  => [ [ $p->model_name('member'), 'search_read' ] ],
        vals   => { channel => $cid + 0, channel_name => $ch->{name}, message => $target + 0, previous => $was },
        line   => "mark channel $cid ($ch->{name}) read up to message $target" . ( defined $was ? " (read up to $was now)" : '' )
            . ( $mem && $mem->{unread} ? "; $mem->{unread} unread" : '' ),
        reason => 'Odoo moves the seen message forward only, so this cannot be taken back',
    );
    return $plan;
}

=head2 apply_custom($class, $client, $change)

Called by the runner: the web route as the login, then the member's row read
back. The read-back holds when the seen message is the planned one or later.

=cut

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "discuss.seen cannot apply kind '" . ( $c->{kind} // '' ) . "'" ) if ( $c->{kind} // '' ) ne 'seen';
    my $p = Odoo::Ops::Discuss::Common::profile_for( $client, 'discuss.seen' );
    my $f = sub ($lf) { $p->field( member => $lf ) };
    my $v = $c->{vals};
    Odoo::Ops::Discuss::Common::web_call( $client, $p->action('seen_route'), { channel_id => $v->{channel}, last_message_id => $v->{message} } );
    my $me   = Odoo::Ops::Discuss::Common::my_partner($client);
    my $rows = $client->model( $p->model_name('member') )->search_read(
        [ [ $f->('channel'), '=', $v->{channel} ], [ $f->('partner'), '=', $me ] ], [ $f->('seen'), $f->('unread') ], limit => 1 );
    my $now = @$rows ? Odoo::Ops::Discuss::Common::id_of( $rows->[0]{ $f->('seen') } ) : undef;
    my %after = @$rows ? ( id => $rows->[0]{id}, $f->('seen') => $now, $f->('unread') => $rows->[0]{ $f->('unread') } ) : ();
    return {
        ( @$rows ? ( id => $rows->[0]{id} ) : () ),
        reported => 'write',
        returned => {
            method => 'set_last_seen_message', previous => $v->{previous}, seen => $now,
            says   => ( @$rows
                ? "channel $v->{channel} read up to message " . ( $now // 'none' )
                : "channel $v->{channel}: this login has no membership row there; Odoo answered and moved nothing" ),
        },
        after => ( defined $now && $now >= $v->{message} ? \%after : undef ),
    };
}

=head2 undo_custom($class, $entry)

None: the revert holds the row. Odoo's route moves the seen message forward only
(a message at or before the current one changes nothing, proved live on 16), so
there is no way back to the earlier one.

=cut

sub undo_custom ($class, $e) {
    my $v = ref $e->{vals} eq 'HASH' ? $e->{vals} : {};
    my $was = defined $v->{previous} ? "message $v->{previous}" : 'no message';
    return ( undef, "Odoo moves a member's seen message forward only (its route ignores an earlier message), so the channel cannot be marked unread again; it was read up to $was before" );
}

1;
