package Odoo::Test::DiscussFixture;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Test::FakeOdoo;

use parent 'Odoo::Test::FakeOdoo';

# Odoo 16's Discuss on the strict fake: mail.channel, mail.channel.member and
# mail.message with what the discuss operations touch, as the 16.0 source does
# it (probed live on demo16, t/64-discuss-live.t):
#
#   * message_post on a channel makes the message as the caller's partner, drops
#     a parent that is on another channel without a word, marks the author's own
#     member row read up to the message and recounts the others' unread;
#   * /mail/channel/set_last_seen_message moves a member's seen message forward
#     only, answers the message it was asked for, and 404s a non-member;
#   * /mail/message/update_content empties a comment's body and deletes its
#     attachments for its author or an administrator and 404s anyone else; any
#     other message type is a UserError.
#
# Users: ann (11, partner 101), bob (12, partner 102), cy (13, partner 103, in
# no channel), root (14, partner 104, an administrator). Every login has the
# password "pw-<login>" and the key "key-<login>". Channels: 1 "general" (a
# public channel; ann and bob are members), 2 "ann-bob" (a chat; ann and bob).
# Messages 1 to 3 are on general: 1 by ann, 2 by bob replying to 1 (with a
# file), 3 a notification (bob joined).

my $c = sub { { type => 'char', store => 1 } };

sub _fields () {
    return (
        'res.partner'   => { name => $c->() },
        'res.users'     => { login => $c->(), partner_id => { type => 'many2one', relation => 'res.partner' }, name => $c->() },
        'ir.attachment' => { name => $c->(), datas => $c->(), res_model => $c->(), res_id => { type => 'integer' }, mimetype => $c->(),
            file_size => { type => 'integer' }, checksum => $c->() },
        'mail.channel'  => { name => $c->(), channel_type => $c->(), member_count => { type => 'integer' }, active => { type => 'boolean' } },
        'mail.channel.member' => {
            channel_id => { type => 'many2one', relation => 'mail.channel' }, partner_id => { type => 'many2one', relation => 'res.partner' },
            seen_message_id => { type => 'many2one', relation => 'mail.message' }, fetched_message_id => { type => 'many2one', relation => 'mail.message' },
            message_unread_counter => { type => 'integer' },
        },
        'mail.message' => {
            model => $c->(), res_id => { type => 'integer' }, author_id => { type => 'many2one', relation => 'res.partner' },
            date => { type => 'datetime' }, body => { type => 'html', store => 1 }, parent_id => { type => 'many2one', relation => 'mail.message' },
            attachment_ids => { type => 'many2many', relation => 'ir.attachment' }, partner_ids => { type => 'many2many', relation => 'res.partner' },
            message_type => $c->(),
        },
    );
}

sub new ($class, %args) {
    my $self;
    my %methods = (
        'mail.channel.message_post' => sub ( $fake, $margs, $kw ) { $fake->_post( $margs->[0][0], $kw ) },
    );
    $self = $class->SUPER::new(
        series  => 16,
        fields  => { _fields() },
        secrets => { map { $_ => "pw-$_" } qw(ann bob cy root) },
        methods => \%methods,
        records => {
            'res.partner' => [ map { { id => $_->[0], name => $_->[1] } } ( [ 101, 'Ann' ], [ 102, 'Bob' ], [ 103, 'Cy' ], [ 104, 'Root' ] ) ],
            'res.users'   => [ map { { id => $_->[0], login => $_->[1], name => ucfirst $_->[1], partner_id => $_->[2] } }
                ( [ 11, 'ann', 101 ], [ 12, 'bob', 102 ], [ 13, 'cy', 103 ], [ 14, 'root', 104 ] ) ],
            'mail.channel' => [
                { id => 1, name => 'general', channel_type => 'channel', member_count => 2 },
                { id => 2, name => 'ann-bob', channel_type => 'chat',    member_count => 2 },
            ],
            'mail.channel.member' => [
                map { { id => $_->[0], channel_id => $_->[1], partner_id => $_->[2], seen_message_id => $_->[3], message_unread_counter => 0 } }
                ( [ 1, 1, 101, 2 ], [ 2, 1, 102, 3 ], [ 3, 2, 101, undef ], [ 4, 2, 102, undef ] )
            ],
            'ir.attachment' => [ { id => 1, name => 'count.txt', res_model => 'mail.channel', res_id => 1, datas => 'aGVsbG8=' } ],
            'mail.message' => [
                { id => 1, model => 'mail.channel', res_id => 1, author_id => 101, date => '2026-10-17 09:00:00', body => '<p>Count starts at nine</p>', message_type => 'comment', attachment_ids => [], partner_ids => [] },
                { id => 2, model => 'mail.channel', res_id => 1, author_id => 102, date => '2026-10-17 09:05:00', body => '<p>Done &amp; dusted<br>see file</p>', parent_id => 1, message_type => 'comment', attachment_ids => [1], partner_ids => [] },
                { id => 3, model => 'mail.channel', res_id => 1, author_id => 102, date => '2026-10-17 09:06:00', body => '<p>Bob joined the channel</p>', message_type => 'notification', attachment_ids => [], partner_ids => [] },
            ],
        },
    );
    $self->{admins} = { 14 => 1 };
    $self->_recount($_) for 1, 2;
    return $self;
}

# the config-less pieces a test needs to run as one login
sub credential ($self, $login) {
    $self->add_key( $login, "key-$login" ) if !$self->{keys}{$login};
    return { login => $login, api_key => "key-$login" };
}

sub partner_of ($self, $uid) { $self->{data}{'res.users'}{$uid}{partner_id} }
sub uid_of ($self, $login) { ( grep { $_->{login} eq $login } values %{ $self->{data}{'res.users'} } )[0]{id} }

sub _fault ($class, $msg) { Odoo::Error->throw( kind => 'fault', message => $msg, fault_class => "odoo.exceptions.$class" ) }

sub member ($self, $channel, $partner) {
    return ( grep { $_->{channel_id} == $channel && $_->{partner_id} == $partner } values %{ $self->{data}{'mail.channel.member'} } )[0];
}

sub _messages ($self, $channel) {
    return sort { $a->{id} <=> $b->{id} } grep { $_->{model} eq 'mail.channel' && $_->{res_id} == $channel } values %{ $self->{data}{'mail.message'} };
}

# the unread counter Odoo computes: the channel's messages after the member's seen message
sub _recount ($self, $channel) {
    for my $m ( grep { $_->{channel_id} == $channel } values %{ $self->{data}{'mail.channel.member'} } ) {
        my $seen = $m->{seen_message_id} // 0;
        $m->{message_unread_counter} = scalar grep { $_->{id} > $seen } $self->_messages($channel);
    }
}

sub _post ( $self, $cid, $kw ) {
    my $ch = $self->{data}{'mail.channel'}{$cid} or _fault( 'MissingError', "channel $cid gone" );
    my $uid = $self->{caller_uid};
    my $pid = $self->partner_of($uid);
    # a public channel takes a post from any user; a chat or a group from its members
    _fault( 'AccessError', "You are not allowed to access 'Discussion Channel' (mail.channel) records." )
        if $ch->{channel_type} ne 'channel' && !$self->member( $cid, $pid );
    # Odoo drops a parent that is not on this channel without a word
    my $parent = $kw->{parent_id} ? $self->{data}{'mail.message'}{ $kw->{parent_id} } : undef;
    undef $parent if $parent && !( $parent->{model} eq 'mail.channel' && $parent->{res_id} == $cid );
    my $id = $self->insert( 'mail.message', {
        model => 'mail.channel', res_id => $cid, author_id => $pid, date => '2026-10-17 10:00:00',
        body => $kw->{body} // '', message_type => $kw->{message_type} // 'notification',
        ( $parent ? ( parent_id => $parent->{id} ) : () ),
        attachment_ids => [ @{ $kw->{attachment_ids} // [] } ], partner_ids => [ @{ $kw->{partner_ids} // [] } ],
    } );
    if ( my $own = $self->member( $cid, $pid ) ) { @$own{qw(seen_message_id fetched_message_id)} = ( $id, $id ) }
    $self->_recount($cid);
    return $id;
}

# the web routes of Odoo's own client, as the user whose session this is
sub route ( $self, $path, $params, $uid ) {
    my $pid = $self->partner_of($uid);
    my $not_found = sub { Odoo::Error->throw( kind => 'fault', message => '404: Not Found: 404 Not Found', code => 404, fault_class => 'werkzeug.exceptions.NotFound' ) };
    push @{ $self->{routes} }, [ $path, $uid ];
    if ( $path eq '/mail/channel/set_last_seen_message' ) {
        my $mem = $self->member( $params->{channel_id}, $pid ) or $not_found->();
        my ($target) = reverse grep { $_->{id} <= $params->{last_message_id} } $self->_messages( $params->{channel_id} );
        return undef if !$target;
        if ( ( $mem->{seen_message_id} // 0 ) < $target->{id} ) {
            @$mem{qw(seen_message_id fetched_message_id)} = ( $target->{id}, $target->{id} );
            $self->_recount( $params->{channel_id} );
        }
        return $target->{id};
    }
    if ( $path eq '/mail/message/update_content' ) {
        my $msg = $self->{data}{'mail.message'}{ $params->{message_id} } or $not_found->();
        $not_found->() if $msg->{author_id} != $pid && !$self->{admins}{$uid};
        _fault( 'UserError', "Only messages type comment can have their content updated on model 'mail.channel'" ) if $msg->{message_type} ne 'comment';
        delete $self->{data}{'ir.attachment'}{$_} for @{ $msg->{attachment_ids} };
        $msg->{body} = '';
        $msg->{attachment_ids} = [];
        return { id => $msg->{id}, body => '', attachments => [] };
    }
    $not_found->();
}

sub web_session ($self) { Odoo::Test::DiscussFixture::Session->new($self) }

package Odoo::Test::DiscussFixture::Session;

use parent -norequire, 'Odoo::Test::FakeOdoo::Session';

sub route ( $self, $path, $params = {} ) {
    Odoo::Error->throw( kind => 'fault', message => 'no session', fault_class => 'odoo.http.SessionExpiredException' ) if !defined $self->{sid};
    return $self->{fake}->route( $path, $params, $self->{identity}{uid} );
}

1;
