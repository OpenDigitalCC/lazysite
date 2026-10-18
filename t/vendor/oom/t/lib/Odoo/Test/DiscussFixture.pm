package Odoo::Test::DiscussFixture;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Test::FakeOdoo;

use parent 'Odoo::Test::FakeOdoo';

# Odoo's Discuss on the strict fake: mail.channel, mail.channel.member and
# mail.message with what the discuss operations touch, as the 16.0 source does
# it (probed live on demo16, t/64-discuss-live.t). new( series => 18 or 19 ) does
# it as those sources do: the models are discuss.channel and
# discuss.channel.member; message_post escapes a str body unless body_is_html is
# set (19 answers the new message as a list of ids); /discuss/channel/mark_as_read
# moves the seen message forward only and ignores a login with no member row;
# /mail/message/update_content leaves the edited marker as the body (19 takes the
# content as update_data, refuses the flat form, and clears the parent link).
# Series 16:
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

sub _fields ($CH, $MEM) {
    return (
        'res.partner'   => { name => $c->() },
        'res.users'     => { login => $c->(), partner_id => { type => 'many2one', relation => 'res.partner' }, name => $c->() },
        'ir.attachment' => { name => $c->(), datas => $c->(), res_model => $c->(), res_id => { type => 'integer' }, mimetype => $c->(),
            file_size => { type => 'integer' }, checksum => $c->() },
        $CH  => { name => $c->(), channel_type => $c->(), member_count => { type => 'integer' }, active => { type => 'boolean' } },
        $MEM => {
            channel_id => { type => 'many2one', relation => $CH }, partner_id => { type => 'many2one', relation => 'res.partner' },
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
    my $series = $args{series} // 16;
    my $CH  = $series >= 18 ? 'discuss.channel'        : 'mail.channel';
    my $MEM = $series >= 18 ? 'discuss.channel.member' : 'mail.channel.member';
    my %methods = (
        "$CH.message_post" => sub ( $fake, $margs, $kw ) { $fake->_post( $margs->[0][0], $kw ) },
    );
    $self = $class->SUPER::new(
        series  => $series,
        fields  => { _fields( $CH, $MEM ) },
        secrets => { map { $_ => "pw-$_" } qw(ann bob cy root) },
        methods => \%methods,
        records => {
            'res.partner' => [ map { { id => $_->[0], name => $_->[1] } } ( [ 101, 'Ann' ], [ 102, 'Bob' ], [ 103, 'Cy' ], [ 104, 'Root' ] ) ],
            'res.users'   => [ map { { id => $_->[0], login => $_->[1], name => ucfirst $_->[1], partner_id => $_->[2] } }
                ( [ 11, 'ann', 101 ], [ 12, 'bob', 102 ], [ 13, 'cy', 103 ], [ 14, 'root', 104 ] ) ],
            $CH => [
                { id => 1, name => 'general', channel_type => 'channel', member_count => 2 },
                { id => 2, name => 'ann-bob', channel_type => 'chat',    member_count => 2 },
            ],
            $MEM => [
                map { { id => $_->[0], channel_id => $_->[1], partner_id => $_->[2], seen_message_id => $_->[3], message_unread_counter => 0 } }
                ( [ 1, 1, 101, 2 ], [ 2, 1, 102, 3 ], [ 3, 2, 101, undef ], [ 4, 2, 102, undef ] )
            ],
            'ir.attachment' => [ { id => 1, name => 'count.txt', res_model => $CH, res_id => 1, datas => 'aGVsbG8=' } ],
            'mail.message' => [
                { id => 1, model => $CH, res_id => 1, author_id => 101, date => '2026-10-17 09:00:00', body => '<p>Count starts at nine</p>', message_type => 'comment', attachment_ids => [], partner_ids => [] },
                { id => 2, model => $CH, res_id => 1, author_id => 102, date => '2026-10-17 09:05:00', body => '<p>Done &amp; dusted<br>see file</p>', parent_id => 1, message_type => 'comment', attachment_ids => [1], partner_ids => [] },
                { id => 3, model => $CH, res_id => 1, author_id => 102, date => '2026-10-17 09:06:00', body => '<p>Bob joined the channel</p>', message_type => 'notification', attachment_ids => [], partner_ids => [] },
            ],
        },
    );
    @$self{qw(CH MEM)} = ( $CH, $MEM );
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
    return ( grep { $_->{channel_id} == $channel && $_->{partner_id} == $partner } values %{ $self->{data}{ $self->{MEM} } } )[0];
}

sub _messages ($self, $channel) {
    return sort { $a->{id} <=> $b->{id} } grep { $_->{model} eq $self->{CH} && $_->{res_id} == $channel } values %{ $self->{data}{'mail.message'} };
}

# the unread counter Odoo computes: the channel's messages after the member's seen message
sub _recount ($self, $channel) {
    for my $m ( grep { $_->{channel_id} == $channel } values %{ $self->{data}{ $self->{MEM} } } ) {
        my $seen = $m->{seen_message_id} // 0;
        $m->{message_unread_counter} = scalar grep { $_->{id} > $seen } $self->_messages($channel);
    }
}

sub _post ( $self, $cid, $kw ) {
    my $ch = $self->{data}{ $self->{CH} }{$cid} or _fault( 'MissingError', "channel $cid gone" );
    my $uid = $self->{caller_uid};
    my $pid = $self->partner_of($uid);
    # a public channel takes a post from any user; a chat or a group from its members
    _fault( 'AccessError', "You are not allowed to access 'Discussion Channel' ($self->{CH}) records." )
        if $ch->{channel_type} ne 'channel' && !$self->member( $cid, $pid );
    # Odoo drops a parent that is not on this channel without a word
    # 16 reads a str body as HTML; 18 and 19 escape it unless body_is_html is set, and 16 has no such argument
    my $body = $kw->{body} // '';
    if ( $self->{series} >= 18 ) {
        if ( !$kw->{body_is_html} ) {
            $body =~ s/&/&amp;/g;
            $body =~ s/</&lt;/g;
            $body =~ s/>/&gt;/g;
            $body = "<p>$body</p>";
        }
    }
    else { _fault( 'TypeError', "message_post() got an unexpected keyword argument 'body_is_html'" ) if exists $kw->{body_is_html} }
    my $parent = $kw->{parent_id} ? $self->{data}{'mail.message'}{ $kw->{parent_id} } : undef;
    undef $parent if $parent && !( $parent->{model} eq $self->{CH} && $parent->{res_id} == $cid );
    my $id = $self->insert( 'mail.message', {
        model => $self->{CH}, res_id => $cid, author_id => $pid, date => '2026-10-17 10:00:00',
        body => $body, message_type => $kw->{message_type} // 'notification',
        ( $parent ? ( parent_id => $parent->{id} ) : () ),
        attachment_ids => [ @{ $kw->{attachment_ids} // [] } ], partner_ids => [ @{ $kw->{partner_ids} // [] } ],
    } );
    if ( my $own = $self->member( $cid, $pid ) ) { @$own{qw(seen_message_id fetched_message_id)} = ( $id, $id ) }
    $self->_recount($cid);
    return $self->{series} >= 19 ? [$id] : $id;    # 19 answers the recordset as a list of ids
}

# the web routes of Odoo's own client, as the user whose session this is
sub route ( $self, $path, $params, $uid ) {
    my $pid = $self->partner_of($uid);
    my $not_found = sub { Odoo::Error->throw( kind => 'fault', message => '404: Not Found: 404 Not Found', code => 404, fault_class => 'werkzeug.exceptions.NotFound' ) };
    push @{ $self->{routes} }, [ $path, $uid ];
    my $s = $self->{series};
    my $seen_path = $s == 16 ? '/mail/channel/set_last_seen_message' : '/discuss/channel/mark_as_read';
    if ( $path eq $seen_path ) {
        my $mem = $self->member( $params->{channel_id}, $pid );
        # 16 answers 404 to a login with no member row; 18 and 19 return without a word
        if ( !$mem ) { $not_found->() if $s == 16; return undef }
        my ($target) = reverse grep { $_->{id} <= $params->{last_message_id} } $self->_messages( $params->{channel_id} );
        return undef if !$target;
        if ( ( $mem->{seen_message_id} // 0 ) < $target->{id} ) {
            @$mem{qw(seen_message_id fetched_message_id)} = ( $target->{id}, $target->{id} );
            $self->_recount( $params->{channel_id} );
        }
        return $s == 16 ? $target->{id} : undef;
    }
    if ( $path eq '/mail/message/update_content' ) {
        # 19 takes the new content as update_data; 16 and 18 as flat arguments
        my $data = $s >= 19 ? $params->{update_data} : $params;
        _fault( 'TypeError', 'mail_message_update_content() missing 1 required positional argument: \'update_data\'' ) if $s >= 19 && ref $data ne 'HASH';
        _fault( 'TypeError', 'mail_message_update_content() got an unexpected keyword argument \'body\'' ) if $s >= 19 && exists $params->{body};
        my $msg = $self->{data}{'mail.message'}{ $params->{message_id} } or $not_found->();
        $not_found->() if $msg->{author_id} != $pid && !$self->{admins}{$uid};
        _fault( 'UserError', "Only messages type comment can have their content updated on model '$self->{CH}'" ) if $msg->{message_type} ne 'comment';
        delete $self->{data}{'ir.attachment'}{$_} for @{ $msg->{attachment_ids} };
        # 18 and 19 leave Odoo's edited marker where the body was; 19 also clears the parent
        $msg->{body} = $s >= 18 ? '<span class="o-mail-Message-edited"></span>' : '';
        delete $msg->{parent_id} if $s >= 19;
        $msg->{attachment_ids} = [];
        return { id => $msg->{id}, body => $msg->{body}, attachments => [] };
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
