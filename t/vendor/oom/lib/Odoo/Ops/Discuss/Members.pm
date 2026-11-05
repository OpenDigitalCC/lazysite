package Odoo::Ops::Discuss::Members;

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

Odoo::Ops::Discuss::Members - add people to a Discuss channel and take them out

=head1 SYNOPSIS

    oom-ops run discuss.members --conf ops.conf --set channel=7 --set add=ann,bob
    oom-ops run discuss.members --conf ops.conf --set channel=7 --set remove=bob

=head1 DESCRIPTION

C<discuss.members>: C<add> and C<remove> take logins and partner ids, comma
separated, for one C<channel>. One change per person; the plan says who is a
member already.

An add is Odoo's public C<add_members> on the channel (a member row for each new
person). On 16 and 18 Odoo posts a message on the channel for each: "joined the
channel" when the person is the login the config runs as, "invited NAME to the
channel" otherwise. On 19 it posts that message only on a group or a chat, and
none on a channel. The apply reads the member row back and names the messages
Odoo posted. The revert of an add is a remove.

A remove deletes the member row. No public method of Odoo takes someone else out
of a channel (C<action_unfollow> is the acting user leaving: see
C<discuss.leave>), so this is the row's own unlink, which Odoo's record rule
allows for the login's own row and for an administrator; for anyone else Odoo
refuses on apply and says so. It posts no message. The revert of a remove is an
add, which posts the join message again.

    add              the person becomes a member
    already-member   the person is a member already - skipped
    remove           the member row is deleted
    not-a-member     the person is no member - skipped
    unknown-channel  this login can read no channel with that id - held
    unknown-person   a name is no partner id and no login - held

Series: 16, 18 and 19; 17 is refused by name as not probed.

=cut

sub op_name ($class) { 'discuss.members' }
sub summary ($class) { 'Add people to a Discuss channel or take them out' }
sub pack    ($class) { 'discuss' }
sub buckets ($class) {
    return [
        { name => 'add', meaning => 'the person becomes a member of the channel (Odoo\'s add_members)' },
        { name => 'already-member', meaning => 'the person is a member of the channel already' },
        { name => 'remove', meaning => 'the person\'s member row is deleted' },
        { name => 'not-a-member', meaning => 'the person is no member of the channel' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-channel', meaning => 'this login can read no channel with that id' },
        { name => 'unknown-person', meaning => 'a name is no partner id and no login' },
    ];
}

sub params ($class) {
    {   channel => { type => 'int',  required => 1, help => 'the channel id (discuss.channels prints it)' },
        add     => { type => 'list', help => 'logins and partner ids to add, comma separated' },
        remove  => { type => 'list', help => 'logins and partner ids to take out, comma separated' },
    };
}
sub read_scope ($class) {
    { channel => ['search_read'], member => ['search_read'], message => ['search_read'], user => ['search_read'], partner => ['search_read'] };
}
sub write_scope ($class) { { channel => ['add_members'], member => [ 'create', 'unlink' ] } }

# every call an apply of either kind makes, by physical names (strict mode holds an apply to what its change declared)
sub _calls_of ( $channel, $member ) {
    return [ [ $channel, 'add_members' ], [ $member, 'unlink' ], [ $member, 'search_read' ], [ 'mail.message', 'search_read' ] ];
}
sub _calls ( $self, $p ) { _calls_of( $p->model_name('channel'), $p->model_name('member') ) }

sub plan ($self) {
    my $p = Odoo::Ops::Discuss::Common::ready($self);
    my $plan = $self->new_plan( input_count => 1 );
    my $cid  = $self->param('channel');
    my $hold = sub ( $bucket, $why ) { $plan->add( bucket => $bucket, action => 'hold', key => "channel:$cid", reason => $why ); return $plan };
    my @add = @{ $self->param('add') // [] };
    my @rem = @{ $self->param('remove') // [] };
    Odoo::Error->throw( kind => 'usage', message => 'discuss.members: give add or remove', fix => 'pass --set add=login,login or --set remove=login' )
        if !@add && !@rem;

    my $ch = Odoo::Ops::Discuss::Common::channel_row( $self, $cid )
        or return $hold->( 'unknown-channel', "this login can read no channel $cid" );
    my ( $add, $why ) = Odoo::Ops::Discuss::Common::people( $self, \@add );
    return $hold->( 'unknown-person', $why ) if $why;
    my $rem;
    ( $rem, $why ) = Odoo::Ops::Discuss::Common::people( $self, \@rem );
    return $hold->( 'unknown-person', $why ) if $why;
    my %both = map { $_->{partner} => 1 } @$add;
    Odoo::Error->throw( kind => 'usage', message => "discuss.members: $_->{label} is in both add and remove", fix => 'name each person once' )
        for grep { $both{ $_->{partner} } } @$rem;

    $plan->set_input_count( scalar( @$add ) + scalar( @$rem ) );
    my $have = Odoo::Ops::Discuss::Common::members_of( $self, $cid );
    my $on = "channel $cid ($ch->{name}, $ch->{type})";
    # Odoo 19 posts the join message on a group or a chat only; 16 and 18 post it for every channel
    my $posts = $p->series >= 19 && $ch->{type} eq 'channel' ? 0 : 1;
    for my $m (@$add) {
        my $key = "channel:$cid:add:$m->{partner}";
        if ( $have->{ $m->{partner} } ) {
            $plan->add( bucket => 'already-member', action => 'skip', key => $key, reason => "$m->{label} is a member of $on already" );
            next;
        }
        $plan->add(
            bucket => 'add', action => 'custom', handler => $self->op_name, kind => 'add',
            model  => $p->model_name('channel'), id => $cid + 0, key => $key, calls => _calls( $self, $p ),
            vals   => { channel => $cid + 0, partner => $m->{partner} + 0, name => $m->{name}, channel_name => $ch->{name} },
            line   => "add $m->{label} to $on" . ( $posts ? '; Odoo posts a message on the channel saying so' : '; Odoo posts no message on a channel of this type' ),
            reason => 'a new member row; the revert deletes it, and a message Odoo posted stays',
        );
    }
    for my $m (@$rem) {
        my $key = "channel:$cid:remove:$m->{partner}";
        my $mid = $have->{ $m->{partner} };
        if ( !$mid ) {
            $plan->add( bucket => 'not-a-member', action => 'skip', key => $key, reason => "$m->{label} is no member of $on" );
            next;
        }
        $plan->add(
            bucket => 'remove', action => 'custom', handler => $self->op_name, kind => 'remove',
            model  => $p->model_name('member'), id => $mid + 0, key => $key, calls => _calls( $self, $p ),
            vals   => { channel => $cid + 0, partner => $m->{partner} + 0, name => $m->{name}, member => $mid + 0, channel_name => $ch->{name} },
            line   => "remove $m->{label} from $on (member row $mid); no message is posted; Odoo lets this login do it for its own row or as an administrator",
            reason => 'the member row is deleted; the revert adds the person again',
        );
    }
    return $plan;
}

=head2 apply_custom($class, $client, $change)

Called by the runner. An add notes the channel's newest message, calls
C<add_members>, reads the member row and names the messages Odoo posted after
the noted one. A remove deletes the member row and reads it gone.

=cut

sub apply_custom ($class, $client, $c) {
    my $kind = $c->{kind} // '';
    Odoo::Error->throw( kind => 'usage', message => "discuss.members cannot apply kind '$kind'" ) if $kind !~ /\A(?:add|remove)\z/;
    my $p = Odoo::Ops::Discuss::Common::profile_for( $client, 'discuss.members' );
    my $f = sub ($lf) { $p->field( member => $lf ) };
    my $v = $c->{vals};
    my ( $cid, $pid ) = ( $v->{channel}, $v->{partner} );
    my $mem = $client->model( $p->model_name('member') );
    my $find = sub { $mem->search_read( [ [ $f->('channel'), '=', $cid ], [ $f->('partner'), '=', $pid ] ], ['id'], limit => 1 ) };
    if ( $kind eq 'remove' ) {
        my $row = $find->()->[0];
        Odoo::Error->throw( kind => 'refused', code => 'stale', message => "partner $pid is no member of channel $cid now; plan again" ) if !$row;
        $mem->unlink( $row->{id} );
        my $left = $find->();
        return {
            id => $cid, reported => 'write',
            returned => { method => 'unlink', member => $row->{id}, says => "removed partner $pid from channel $cid" },
            after => @$left ? undef : { id => $cid, partner => $pid, member => JSON::PP::false },
        };
    }
    my $before = Odoo::Ops::Discuss::Common::newest_message( $client, $p, $cid );
    $client->execute_kw( $p->model_name('channel'), $p->action('add_members'), [ [$cid] ], { partner_ids => [$pid] } );
    my $row  = $find->()->[0];
    my @msgs = @{ Odoo::Ops::Discuss::Common::channel_messages_after( $client, $p, $cid, $before ) };
    my @made = map { { model => $p->model_name('message'), id => $_, name => $v->{channel_name} } } @msgs;
    return {
        id => $cid, reported => 'write',
        returned => { method => $p->action('add_members'), member => $row ? $row->{id} : undef, messages => \@msgs,
            says => "added partner $pid to channel $cid" . ( @msgs ? '; Odoo posted message' . ( @msgs == 1 ? '' : 's' ) . ' ' . join( ', ', @msgs ) : '; Odoo posted no message' ) },
        created => \@made,
        after   => $row ? { id => $cid, partner => $pid, member => $row->{id} } : undef,
    };
}

=head2 undo_custom($class, $entry)

An add is undone by a remove of the member row it made; a remove by an add of
the same person.

=cut

sub undo_custom ($class, $e) {
    my $v = ref $e->{vals} eq 'HASH' ? $e->{vals} : {};
    my ( $cid, $pid ) = @$v{qw(channel partner)};
    return ( undef, 'the journal entry names no channel or partner: nothing to undo' ) if !$cid || !$pid;
    my $kind = ( $e->{kind} // '' ) eq 'add' ? 'remove' : 'add';
    # the channel model and its member model differ by the one word
    my $model = $e->{model};
    $model =~ s/\.member\z// if $kind eq 'add';
    $model .= '.member' if $kind eq 'remove';
    my $row = ref $e->{returned} eq 'HASH' ? $e->{returned}{member} : undef;
    return (
        {   bucket => "undo-$e->{kind}", action => 'custom', handler => 'discuss.members', kind => $kind,
            model  => $model, id => ( $kind eq 'remove' ? ( $row // $cid ) : $cid ), key => "undo:channel:$cid:$pid",
            calls  => $kind eq 'remove' ? _calls_of( ( $model =~ s/\.member\z//r ), $model ) : _calls_of( $model, "$model.member" ),
            vals   => { %$v, ( defined $row ? ( member => $row ) : () ) },
            line   => $kind eq 'remove' ? "take partner $pid out of channel $cid again (the member row the add made)" : "add partner $pid to channel $cid again",
            reason => "undo discuss.members $e->{kind}",
        },
    );
}

1;
