#!/usr/bin/perl
# Lazysite::Notify::_xmpp_send - the one-shot XMPP flow.
#
# Both existing notify tests swap $XMPP_SENDER for a capture sub, which is right
# for testing the CHANNEL and leaves the transport itself unexecuted: it was the
# whole of the module's uncovered remainder, and the least-verified code in the
# tree sat behind it.
#
# This drives the real sub against a stub Net::XMPP injected into %INC. That is
# testing OUR sequencing at a library boundary, not testing the stub: connect
# before auth, auth failure refused rather than sent into, the MUC join that must
# precede a groupchat send, and - the one with real operational weight - the
# Disconnect that has to happen even when the send died, because a CGI that
# leaks a socket per failed notification degrades the whole site rather than the
# notification.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Notify ();

# --- a stub Net::XMPP, recording the call sequence --------------------------
our @CALLS;
our %BEHAVIOUR;

{
    package Net::XMPP::Client;
    sub new { bless {}, shift }
    sub Connect {
        my ( $self, %a ) = @_;
        push @CALLS, [ 'Connect', $a{hostname}, $a{port}, $a{tls}, $a{componentname} ];
        return $BEHAVIOUR{connect_fails} ? undef : 1;
    }
    sub AuthSend {
        my ( $self, %a ) = @_;
        push @CALLS, [ 'AuthSend', $a{username}, $a{resource} ];
        return $BEHAVIOUR{auth_fails} ? ('failed') : ('ok');
    }
    sub Send { push @CALLS, [ 'Send', ref $_[1] ]; 1 }
    sub MessageSend {
        my ( $self, %a ) = @_;
        push @CALLS, [ 'MessageSend', $a{to}, $a{type}, $a{body} ];
        die "send exploded\n" if $BEHAVIOUR{send_dies};
        return 1;
    }
    sub Disconnect { push @CALLS, ['Disconnect']; 1 }

    package Net::XMPP::Presence;
    sub new          { bless {}, shift }
    sub SetTo        { push @CALLS, [ 'SetTo',        $_[1] ]; 1 }
    sub InsertRawXML { push @CALLS, [ 'InsertRawXML', $_[1] ]; 1 }

    package Net::XMPP;
}
$INC{'Net/XMPP.pm'} = 'stubbed-by-test';

sub run {
    my ( $conf, $text, %b ) = @_;
    @CALLS     = ();
    %BEHAVIOUR = %b;
    my $ok  = eval { Lazysite::Notify::_xmpp_send( $conf, $text ); 1 };
    my $err = $@;
    return ( $ok, $err );
}

sub called { my $n = shift; return grep { $_->[0] eq $n } @CALLS }

my %BASE = ( jid => 'bot@chat.example', password => 'pw', to => 'ops@chat.example' );

# --- the ordinary chat send -------------------------------------------------
{
    my ( $ok, $err ) = run( {%BASE}, 'hello' );
    ok( $ok, 'a chat send succeeds' ) or diag $err;

    my @names = map { $_->[0] } @CALLS;
    is_deeply( \@names, [qw(Connect AuthSend MessageSend Disconnect)],
        'connect, authenticate, send, disconnect - in that order' )
        or diag explain \@names;

    my ($msg) = grep { $_->[0] eq 'MessageSend' } @CALLS;
    is( $msg->[1], 'ops@chat.example', 'addressed to the configured recipient' );
    is( $msg->[2], 'chat',             'as a chat message' );
    is( $msg->[3], 'hello',            'carrying the rendered body' );
}

# --- defaults derived from the JID ------------------------------------------
{
    run( {%BASE}, 'x' );
    my ($c) = grep { $_->[0] eq 'Connect' } @CALLS;
    is( $c->[1], 'chat.example', 'the host defaults to the JID domain' );
    is( $c->[2], 5222,           'and the port to 5222' );
    is( $c->[3], 1,              'with TLS on by default' );

    my ($a) = grep { $_->[0] eq 'AuthSend' } @CALLS;
    is( $a->[1], 'bot',      'the username is the JID local part' );
    is( $a->[2], 'lazysite', 'and the resource defaults to lazysite' );
}

{
    run( { %BASE, host => 'relay.internal', port => '5269', tls => 'no',
            nick => 'my-site' }, 'x' );
    my ($c) = grep { $_->[0] eq 'Connect' } @CALLS;
    is_deeply( [ @{$c}[ 1, 2, 3 ] ], [ 'relay.internal', '5269', 0 ],
        'an explicit host, port and tls:no override the defaults' );
    my ($a) = grep { $_->[0] eq 'AuthSend' } @CALLS;
    is( $a->[2], 'my-site', 'and nick becomes the resource' );
}

# A non-numeric port must not be passed through to the socket layer.
{
    run( { %BASE, port => 'not-a-port' }, 'x' );
    my ($c) = grep { $_->[0] eq 'Connect' } @CALLS;
    is( $c->[2], 5222, 'a non-numeric port falls back to 5222' );
}

# --- the MUC branch ---------------------------------------------------------
{
    my ( $ok, $err ) = run( { %BASE, muc => 'yes', to => 'room@conf.example',
            nick => 'sitebot' }, 'to the room' );
    ok( $ok, 'a MUC send succeeds' ) or diag $err;

    my @names = map { $_->[0] } @CALLS;
    is_deeply( \@names,
        [qw(Connect AuthSend SetTo InsertRawXML Send MessageSend Disconnect)],
        'the room is JOINED before anything is said to it' )
        or diag explain \@names;

    my ($to) = grep { $_->[0] eq 'SetTo' } @CALLS;
    is( $to->[1], 'room@conf.example/sitebot',
        'joining as room/nick, which is how a MUC identifies a participant' );

    my ($raw) = grep { $_->[0] eq 'InsertRawXML' } @CALLS;
    like( $raw->[1], qr{xmlns="http://jabber\.org/protocol/muc"},
        'with the muc namespace, or the server treats it as a plain presence' );

    my ($msg) = grep { $_->[0] eq 'MessageSend' } @CALLS;
    is( $msg->[2], 'groupchat', 'and the message is groupchat, not chat' );
}

# --- failures ---------------------------------------------------------------
{
    my ( $ok, $err ) = run( { %BASE, jid => 'no-at-sign' }, 'x' );
    ok( !$ok, 'a JID without a domain is refused' );
    like( $err, qr/must be user\@domain/, 'and says why' );
    is( scalar @CALLS, 0, 'before any connection is attempted' );
}

{
    my ( $ok, $err ) = run( {%BASE}, 'x', connect_fails => 1 );
    ok( !$ok, 'a failed connect propagates' );
    like( $err, qr/connect to chat\.example:5222 failed/,
        'naming the host and port actually tried' );
    ok( !called('AuthSend'), 'and no credentials are sent into a dead socket' );
}

{
    my ( $ok, $err ) = run( {%BASE}, 'x', auth_fails => 1 );
    ok( !$ok, 'a failed auth propagates' );
    like( $err, qr/auth failed/, 'and says so' );
    ok( !called('MessageSend'), 'and nothing is sent unauthenticated' );
}

# The one that matters operationally: the socket is released even on the error
# path. A CGI leaking one connection per failed notification degrades the site,
# not just the notification.
{
    my ( $ok, $err ) = run( {%BASE}, 'x', send_dies => 1 );
    ok( !$ok, 'a send that dies propagates' );
    like( $err, qr/send exploded/, 'with the underlying error, not a rewrite' );
    ok( called('Disconnect'), 'and Disconnect STILL happens - no leaked socket' );
}

# --- the alarm is cleared, whatever happened --------------------------------
# A leftover alarm would fire later, in the middle of an unrelated request in
# the same process, and look like anything but a notification bug.
{
    run( {%BASE}, 'x' );
    is( alarm(0), 0, 'no alarm is left pending after a success' );

    run( {%BASE}, 'x', send_dies => 1 );
    is( alarm(0), 0, 'nor after a failure' );
}

done_testing();
