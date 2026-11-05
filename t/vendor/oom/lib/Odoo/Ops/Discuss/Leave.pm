package Odoo::Ops::Discuss::Leave;

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

Odoo::Ops::Discuss::Leave - the acting user leaves a Discuss channel

=head1 SYNOPSIS

    oom-ops run discuss.leave --conf ops.conf --set channel=7

=head1 DESCRIPTION

C<discuss.leave>: Odoo's public C<action_unfollow> on the channel, for the login
the config runs as (the partner of the acting user; nobody else can be taken
out this way: see C<discuss.members> remove). Odoo deletes the member row and
unsubscribes the partner as a follower. It then posts "left the channel" on the
channel as the leaver on 16, 18 and, for a group or a chat, on 19; on a 19
channel (type C<channel>) it posts nothing. The plan names the message it expects
and the apply names the messages Odoo posted.

A login that is no member is skipped (C<not-a-member>); Odoo would only drop a
follower subscription and leave the channel as it was.

There is no revert. Odoo has no way to put a member back that the member could
call, and whether a person may rejoin is the channel's rule: a revert is held
C<irreversible>, and the plan says so. To bring someone back, plan
C<discuss.members> with C<add>.

    leave            the member row is deleted
    not-a-member     this login is no member of the channel - skipped
    unknown-channel  this login can read no channel with that id - held

Series: 16, 18 and 19; 17 is refused by name as not probed.

=cut

sub op_name ($class) { 'discuss.leave' }
sub summary ($class) { 'The acting user leaves a Discuss channel' }
sub pack    ($class) { 'discuss' }
sub buckets ($class) {
    return [
        { name => 'leave', meaning => 'the login\'s member row is deleted (Odoo\'s action_unfollow)' },
        { name => 'not-a-member', meaning => 'the login is no member of the channel' },
    ];
}
sub holds ($class) { return [ { name => 'unknown-channel', meaning => 'this login can read no channel with that id' } ] }

sub params ($class) { { channel => { type => 'int', required => 1, help => 'the channel id (discuss.channels prints it)' } } }
sub read_scope ($class) { { channel => ['search_read'], member => ['search_read'], message => ['search_read'] } }
sub write_scope ($class) { { channel => ['action_unfollow'] } }

sub plan ($self) {
    my $p = Odoo::Ops::Discuss::Common::ready($self);
    my $plan = $self->new_plan( input_count => 1 );
    my $cid  = $self->param('channel');
    my $key  = "channel:$cid";
    my $ch = Odoo::Ops::Discuss::Common::channel_row( $self, $cid );
    if ( !$ch ) { $plan->add( bucket => 'unknown-channel', action => 'hold', key => $key, reason => "this login can read no channel $cid" ); return $plan }
    my $me  = Odoo::Ops::Discuss::Common::my_partner( $self->client );
    my $mem = Odoo::Ops::Discuss::Common::member_row( $self, $cid, $me );
    if ( !$mem ) {
        $plan->add( bucket => 'not-a-member', action => 'skip', key => $key, reason => "this login is no member of channel $cid ($ch->{name})" );
        return $plan;
    }
    my $posts = $p->series >= 19 && $ch->{type} eq 'channel' ? 0 : 1;
    $plan->add(
        bucket => 'leave', action => 'custom', handler => $self->op_name, kind => 'leave',
        model  => $p->model_name('channel'), id => $cid + 0, key => $key,
        calls  => [ [ $p->model_name('channel'), $p->action('leave') ], [ $p->model_name('member'), 'search_read' ], [ $p->model_name('message'), 'search_read' ] ],
        vals   => { channel => $cid + 0, partner => $me + 0, member => $mem->{id} + 0, channel_name => $ch->{name} },
        line   => "leave channel $cid ($ch->{name}, $ch->{type}) as partner $me (member row $mem->{id})"
            . ( $posts ? '; Odoo posts \'left the channel\' on the channel' : '; Odoo posts no message when a member leaves a channel of this type' ),
        reason => 'there is no revert: nothing in Odoo puts a member back for the member; plan discuss.members add to bring the person back',
    );
    return $plan;
}

=head2 apply_custom($class, $client, $change)

Called by the runner: notes the channel's newest message, calls
C<action_unfollow>, reads the member row gone and names the messages Odoo
posted. A login that can no longer read the channel (a group, a chat) cannot
list those messages; the result says so and the read-back stands on the member
row.

=cut

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "discuss.leave cannot apply kind '" . ( $c->{kind} // '' ) . "'" ) if ( $c->{kind} // '' ) ne 'leave';
    my $p = Odoo::Ops::Discuss::Common::profile_for( $client, 'discuss.leave' );
    my $f = sub ($lf) { $p->field( member => $lf ) };
    my $v = $c->{vals};
    my $before = Odoo::Ops::Discuss::Common::newest_message( $client, $p, $v->{channel} );
    $client->execute_kw( $p->model_name('channel'), $p->action('leave'), [ [ $v->{channel} ] ], {} );
    my $left = $client->model( $p->model_name('member') )->search_read(
        [ [ $f->('channel'), '=', $v->{channel} ], [ $f->('partner'), '=', $v->{partner} ] ], ['id'], limit => 1 );
    my $msgs = eval { Odoo::Ops::Discuss::Common::channel_messages_after( $client, $p, $v->{channel}, $before ) };
    my $unread = $msgs ? '' : '; the channel is not readable now, so the message Odoo posted is not listed';
    my @m = @{ $msgs // [] };
    return {
        id => $v->{channel}, reported => 'write',
        returned => { method => $p->action('leave'), messages => \@m,
            says => "left channel $v->{channel}" . ( @m ? '; Odoo posted message' . ( @m == 1 ? '' : 's' ) . ' ' . join( ', ', @m ) : '; Odoo posted no message' ) . $unread },
        created => [ map { { model => $p->model_name('message'), id => $_, name => $v->{channel_name} } } @m ],
        after   => @$left ? undef : { id => $v->{channel}, partner => $v->{partner}, member => JSON::PP::false },
    };
}

=head2 undo_custom($class, $entry)

None: the revert holds the row.

=cut

sub undo_custom ($class, $e) {
    my $cid = ref $e->{vals} eq 'HASH' ? $e->{vals}{channel} : undef;
    return ( undef, 'channel' . ( defined $cid ? " $cid" : '' ) . ': leaving has no inverse for the member; plan discuss.members with add to bring the person back' );
}

1;
