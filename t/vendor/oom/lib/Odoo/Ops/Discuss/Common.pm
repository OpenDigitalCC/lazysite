package Odoo::Ops::Discuss::Common;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Digest::SHA ();
use Scalar::Util qw(blessed);

use Odoo::Error;
use Odoo::Ops::Profile;

=head1 NAME

Odoo::Ops::Discuss::Common - what the discuss operations share

=head1 DESCRIPTION

Not an operation: plain functions the C<discuss.*> operations call, so that
the series gate, the web routes and the text conversions are written once.

Discuss is Odoo's messaging: a channel (C<mail.channel> on 16) holds
messages (C<mail.message> with C<model> C<mail.channel> and C<res_id> the
channel) and a member row per partner (C<mail.channel.member>) that holds what
the member has read. The operations act as the login OOM runs as. Posting is
Odoo's public C<message_post> on the channel. Marking read and emptying a
message have no public method on 16 (C<_channel_seen> and
C<_message_update_content> are private, which Odoo refuses over RPC), so they
use the two web routes Odoo's own client uses, over a web session as the
login: the session the Context already holds, or one opened from the
config's login and password.

=head2 ready($op)

The discuss profile for this server, or a refusal. A series with no profile
of its own is refused by name (C<series>): 17 and later rename the channel
models and none was probed. The profile is then checked against the live
C<fields_get> (C<profile> when a mapped model or field is missing).

=cut

sub ready ($op) {
    my $series = $op->client->server_series;
    my $p      = $op->profile;
    _series_gate( $op->op_name, $series, $p );
    my $v = $p->validate( $op->client );
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'profile',
        message => 'the discuss profile does not match this server: ' . join( '; ', @{ $v->{missing} } ),
    ) if !$v->{ok};
    return $p;
}

sub _series_gate ( $name, $series, $p ) {
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'series',
        message => "$name is not probed on Odoo $series: the discuss pack has a profile for series "
            . $p->series . ' only (17 and later call the channel models discuss.channel and discuss.channel.member)',
    ) if $p->series != $series;
    return;
}

=head2 profile_for($client, $op_name)

The profile at apply time, where an operation has the client and no context.
Refused by name on a series the pack was not probed on.

=cut

sub profile_for ( $client, $op_name ) {
    my $series = $client->server_series;
    my $p      = Odoo::Ops::Profile->load( pack => 'discuss', series => $series );
    _series_gate( $op_name, $series, $p );
    return $p;
}

=head2 id_of($value)

The id in a many2one read (C<[id, name]>), or the number itself; undef for an
empty value.

=cut

sub id_of ($v) { ref $v eq 'ARRAY' ? $v->[0] : ( $v ? 0 + $v : undef ) }

=head2 name_of($value)

The name in a many2one read, or an empty string.

=cut

sub name_of ($v) { ref $v eq 'ARRAY' ? ( $v->[1] // '' ) : '' }

=head2 my_partner($client)

The partner of the login the client runs as.

=cut

sub my_partner ($client) {
    my $row = $client->execute_kw( 'res.users', 'read', [ [ $client->uid ] ], { fields => ['partner_id'] } )->[0];
    return id_of( $row->{partner_id} );
}

=head2 html_text($html)

A message body as plain text: breaks and paragraph ends become new lines,
tags go, the common entities are decoded.

=cut

sub html_text ($h) {
    return '' if !defined $h || ref $h;
    my $t = $h;
    $t =~ s{<\s*br\s*/?\s*>}{\n}gi;
    $t =~ s{<\s*/\s*(?:p|div|li|h[1-6]|tr)\s*>}{\n}gi;
    $t =~ s/<[^>]*>//g;
    my %ent = ( amp => '&', lt => '<', gt => '>', quot => '"', apos => "'", nbsp => ' ' );
    $t =~ s/&#(\d+);/chr $1/ge;
    $t =~ s/&#x([0-9a-fA-F]+);/chr hex $1/ge;
    $t =~ s/&(amp|lt|gt|quot|apos|nbsp);/$ent{$1}/g;
    $t =~ s/[ \t]+\n/\n/g;
    $t =~ s/\n{3,}/\n\n/g;
    $t =~ s/\A\s+|\s+\z//g;
    return $t;
}

=head2 text_html($text)

Plain text as the HTML Odoo's client sends: escaped, new lines as breaks, one
paragraph.

=cut

sub text_html ($t) {
    my $e = $t =~ s/&/&amp;/gr =~ s/</&lt;/gr =~ s/>/&gt;/gr;
    $e =~ s/\r?\n/<br>/g;
    return "<p>$e</p>";
}

=head2 sha1_file($path)

The SHA-1 of a file, as Odoo keeps an attachment's checksum.

=cut

sub sha1_file ($path) {
    open my $fh, '<:raw', $path or Odoo::Error->throw( kind => 'usage', message => "cannot read $path: $!", fix => 'check the path exists and this user can read it' );
    my $d = Digest::SHA->new(1);
    $d->addfile($fh);
    close $fh;
    return $d->hexdigest;
}

=head2 web_call($client, $path, \%params)

One call of a JSON web route of Odoo as the login the client runs as. A client
on a web session (a C<credential = password> config, or a session id carried
by the caller) uses that session. Any other client opens one from its own login
and secret, which works where the secret is the login's password (the local
cluster's configs); a real API key is refused by Odoo's web login, and the call
dies as C<config> naming that and the fix. Odoo's own fault comes back in its
words, with the routes' known 404 explained after them.

=cut

sub web_call ( $client, $path, $params ) {
    my ( $web, $own ) = _web($client);
    my $res = eval { $web->route( $path, $params ) };
    my $err = $@;
    eval { $web->destroy } if $own;
    if ($err) {
        if ( blessed($err) && $err->isa('Odoo::Error') && $err->kind eq 'fault' && ( $err->message // '' ) =~ /\b404\b/ ) {
            Odoo::Error->throw(
                kind        => 'fault',
                message     => $err->message . "\nOdoo's route answers 404 Not Found when the login is no member of the channel, "
                    . 'or when it did not write the message and is no administrator',
                fault_class => $err->fault_class,
                code        => $err->code,
            );
        }
        die $err;
    }
    return $res;
}

sub _web ($client) {
    my $t = $client->transport;
    while ( blessed($t) ) {
        return ( $t, 0 ) if $t->can('route') && $t->can('session_id') && defined $t->session_id;
        last if !$t->can('inner_transport');
        $t = $t->inner_transport;
    }
    my $web = eval { $client->own_web_session };
    if ( !$web ) {
        my $e = $@;
        my $why = blessed($e) && $e->can('message') ? ( $e->message =~ s/\s+/ /gr ) : "$e";
        Odoo::Error->throw(
            kind    => 'config',
            message => "Odoo's own client marks a channel read and empties a message over a web route, which needs a web session as the login, and none could be opened: $why",
            fix     => 'use a config with credential = password (a session as the login), or a login whose key is its password',
        );
    }
    return ( $web, 1 );
}

=head2 member_row($op, $channel_id, $partner_id)

The login's membership row in a channel (id, seen message id, unread), or
undef when it has none. A public channel can be read and posted to by a login
that is not a member.

=cut

sub member_row ( $op, $channel_id, $partner_id ) {
    my $p = $op->profile;
    my $f = sub ($lf) { $p->field( member => $lf ) };
    my $rows = $op->model('member')->search_read(
        [ [ $f->('channel'), '=', 0 + $channel_id ], [ $f->('partner'), '=', 0 + $partner_id ] ],
        [ $f->('seen'), $f->('unread') ], limit => 1 );
    return undef if !@$rows;
    return { id => $rows->[0]{id}, seen => id_of( $rows->[0]{ $f->('seen') } ), seen_raw => $rows->[0]{ $f->('seen') }, unread => $rows->[0]{ $f->('unread') } // 0 };
}

=head2 channel_row($op, $channel_id)

The channel as C<< { id, name, type } >>, or undef when this login cannot
read one by that id.

=cut

sub channel_row ( $op, $channel_id ) {
    my $p = $op->profile;
    my $f = sub ($lf) { $p->field( channel => $lf ) };
    my $rows = $op->model('channel')->search_read( [ [ 'id', '=', 0 + $channel_id ] ], [ $f->('name'), $f->('type') ] );
    return undef if !@$rows;
    return { id => $rows->[0]{id}, name => $rows->[0]{ $f->('name') }, type => $rows->[0]{ $f->('type') } };
}

=head2 last_message_id($op, $channel_id)

The newest message of the channel, or undef when it has none.

=cut

sub last_message_id ( $op, $channel_id ) {
    my $p = $op->profile;
    my $f = sub ($lf) { $p->field( message => $lf ) };
    my $rows = $op->model('message')->search_read(
        [ [ $f->('model'), '=', $p->model_name('channel') ], [ $f->('res_id'), '=', 0 + $channel_id ] ],
        ['id'], order => 'id desc', limit => 1 );
    return @$rows ? $rows->[0]{id} : undef;
}

=head2 message_row($op, $message_id)

A message with the fields the operations plan from, or undef when this login
cannot read one by that id. C<channel> is the channel id when the message is on
a channel and undef when it is on another record.

=cut

sub message_row ( $op, $message_id ) {
    my $p = $op->profile;
    my $f = sub ($lf) { $p->field( message => $lf ) };
    my $rows = $op->model('message')->search_read( [ [ 'id', '=', 0 + $message_id ] ],
        [ map { $f->($_) } qw(model res_id author body parent attachments type) ] );
    return undef if !@$rows;
    my $r = $rows->[0];
    return {
        id          => $r->{id},
        channel     => ( ( $r->{ $f->('model') } // '' ) eq $p->model_name('channel') ? $r->{ $f->('res_id') } : undef ),
        author      => id_of( $r->{ $f->('author') } ),
        author_name => name_of( $r->{ $f->('author') } ),
        body        => $r->{ $f->('body') },
        parent      => id_of( $r->{ $f->('parent') } ),
        attachments => [ @{ $r->{ $f->('attachments') } // [] } ],
        type        => $r->{ $f->('type') },
    };
}

1;
