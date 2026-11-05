package Odoo::Ops::Discuss::ChannelCreate;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Discuss::Common;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Discuss::ChannelCreate - make a Discuss channel with its members

=head1 SYNOPSIS

    oom-ops run discuss.channel_create --conf ops.conf --set name='Project chat' \
        --set type=group --set members=ann,bob --set description='Launch work'

=head1 DESCRIPTION

C<discuss.channel_create>: a plain create of C<mail.channel> (16) or
C<discuss.channel> (18 and 19) with C<name>, C<type>, C<description> and the
members given. C<type> is C<channel> (the default: open to the people the
channel allows) or C<group> (private among its members); a chat is made by
Odoo between two people and is not made here. C<members> are logins or partner
ids, comma separated.

Odoo makes a member row for each partner named and for the login the config
runs as, whether it is named or not: the plan names them all, the creator
first, and the apply reads the rows Odoo made (the behaviour file of the
channel lists them as made with the channel). A create posts no message: the
"joined the channel" lines belong to C<add_members> (see C<discuss.members>).

    create   the channel is made with the creator and the members
    exists   this login can already read an active channel of that name and type - skipped
    unknown-member   a member is no partner or login - held

The revert unlinks the channel (the member rows go with it). Odoo lets only an
administrator unlink a channel, so a revert run by anyone else is refused by
Odoo and says so. Series: 16, 18 and 19; 17 is refused by name as not probed.

=cut

sub op_name ($class) { 'discuss.channel_create' }
sub summary ($class) { 'Make a Discuss channel or group with its members' }
sub pack    ($class) { 'discuss' }
sub buckets ($class) {
    return [
        { name => 'create', meaning => 'the channel is made with the creator and the members named' },
        { name => 'exists', meaning => 'this login can already read an active channel of that name and type' },
    ];
}
sub holds ($class) {
    return [ { name => 'unknown-member', meaning => 'a member is no partner id and no login' } ];
}

sub params ($class) {
    {   name        => { type => 'str',  required => 1, help => 'the channel name' },
        type        => { type => 'str',  default => 'channel', help => 'channel (the default) or group' },
        members     => { type => 'list', help => 'logins and partner ids, comma separated; the login the config runs as is always a member' },
        description => { type => 'str',  help => 'the channel description' },
    };
}
sub read_scope ($class) {
    { channel => ['search_read'], member => ['search_read'], user => ['search_read'], partner => ['search_read'] };
}
sub write_scope ($class) { { channel => ['create'] } }

sub plan ($self) {
    my $p = Odoo::Ops::Discuss::Common::ready($self);
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    my $plan = $self->new_plan( input_count => 1 );
    my $name = $self->param('name');
    Odoo::Error->throw( kind => 'usage', message => 'discuss.channel_create: give a name', fix => 'pass --set name=...' )
        if !defined $name || $name !~ /\S/;
    my $type = $self->param('type') // 'channel';
    Odoo::Error->throw( kind => 'usage', message => "discuss.channel_create: type '$type' is not channel or group",
        fix => 'use channel or group; Odoo makes a chat between two people itself' )
        if $type !~ /\A(?:channel|group)\z/;
    my $key = "channel:$type:$name";

    my ( $people, $why ) = Odoo::Ops::Discuss::Common::people( $self, $self->param('members') // [] );
    if ($why) { $plan->add( bucket => 'unknown-member', action => 'hold', key => $key, reason => $why ); return $plan }

    my $have = $self->model('channel')->search_read(
        [ [ $f->( channel => 'name' ), '=', $name ], [ $f->( channel => 'type' ), '=', $type ] ], [ $f->( channel => 'name' ) ], limit => 1 );
    if (@$have) {
        $plan->add( bucket => 'exists', action => 'skip', key => $key, id => $have->[0]{id},
            reason => "channel $have->[0]{id} ($name, $type) exists already" );
        return $plan;
    }

    my $me     = Odoo::Ops::Discuss::Common::my_partner( $self->client );
    my @who    = ( { partner => $me, label => "the creator (partner $me)" } );
    my %in     = ( $me => 1 );
    for my $m (@$people) { next if $in{ $m->{partner} }++; push @who, $m }
    my %vals = (
        $f->( channel => 'name' ) => $name,
        $f->( channel => 'type' ) => $type,
        ( defined $self->param('description') ? ( $f->( channel => 'description' ) => $self->param('description') ) : () ),
        # command 4 (link), one per partner: Odoo's create reads command 6 as a list inside a set and faults ("unhashable type: 'list'", live on 16)
        $f->( channel => 'partners' ) => [ map { [ 4, $_->{partner} + 0, 0 ] } @who ],
    );
    $plan->add(
        bucket => 'create', action => 'create', model => $p->model_name('channel'), ref => $key, key => $key, vals => \%vals,
        readback => [ grep { $_ ne $f->( channel => 'partners' ) } keys %vals ],
        line   => "make the $type '$name'" . ( defined $self->param('description') ? ' (' . $self->param('description') . ')' : '' )
            . '; members Odoo adds: ' . join( ', ', map { $_->{label} } @who ) . '; no message is posted',
        reason => 'a new channel; the revert unlinks it, which Odoo allows an administrator only',
    );
    return $plan;
}

1;
