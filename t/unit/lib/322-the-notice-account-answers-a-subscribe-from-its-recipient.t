#!/usr/bin/perl
# SM1418: the XMPP notice account is a usable contact.
#
# A person who adds the account in a chat client got a trust dialogue with no keys
# and a presence subscription that never became mutual, because the sender only
# connected, sent and left. While connected for a send to a person it now answers a
# subscribe from the configured recipient (and nobody else), asks for its own
# subscription once, and leaves a room alone. Every message carries a plain body.
#
# Offline: a stub Net::XMPP is injected into %INC; nothing touches a network.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Notify ();

our ( @CALLS, %ROSTER, @INBOUND, %CB, %B );

{
    package Net::XMPP::Client;
    sub new     { bless {}, shift }
    sub Connect { 1 }
    sub AuthSend { ('ok') }
    sub Disconnect { push @CALLS, ['Disconnect']; 1 }
    sub RosterGet {
        die "roster exploded\n" if $B{roster_dies};
        return %ROSTER;
    }
    sub SetPresenceCallBacks { my ( $s, %cb ) = @_; %CB = %cb; 1 }
    sub PresenceSend { push @CALLS, ['PresenceSend']; 1 }
    sub Subscription {
        my ( $s, %a ) = @_;
        push @CALLS, [ 'Subscription', $a{type}, $a{to} ];
        return 1;
    }
    # Hands the queued inbound presences to the registered callback, as the
    # server's pending subscribes arrive after our own presence.
    sub Process {
        my $p = shift @INBOUND;
        return 0 unless $p;
        $CB{ $p->{type} }->( 1, bless( {%$p}, 'Stub::Presence' ) ) if $CB{ $p->{type} };
        return 1;
    }
    sub Send { push @CALLS, [ 'Send', ref $_[1] ]; 1 }
    sub MessageSend {
        my ( $s, %a ) = @_;
        push @CALLS, [ 'MessageSend', $a{to}, $a{type}, $a{body} ];
        return 1;
    }

    package Stub::Presence;
    sub GetFrom { $_[0]{from} }
    sub GetType { $_[0]{type} }

    package Net::XMPP::Presence;
    sub new          { bless {}, shift }
    sub SetTo        { 1 }
    sub InsertRawXML { 1 }

    package Net::XMPP;
}
$INC{'Net/XMPP.pm'} = 'stubbed-by-test';
$Lazysite::Notify::SRV_RESOLVER = sub { return () };

sub run {
    my ( $conf, %o ) = @_;
    @CALLS   = ();
    %CB      = ();
    @INBOUND = @{ $o{inbound} || [] };
    %ROSTER  = %{ $o{roster}  || {} };
    %B       = %{ $o{b}       || {} };
    my $ok = eval { Lazysite::Notify::_xmpp_send( $conf, 'a notice' ); 1 };
    return ( $ok, $@ );
}
sub subs { return map { $_->[1] . ' ' . $_->[2] } grep { $_->[0] eq 'Subscription' } @CALLS }

my %BASE = ( jid => 'bot@chat.example', password => 'pw', to => 'Ops@Chat.Example' );

# --- a subscribe from the recipient is approved, and ours goes back -----------
{
    my ( $ok, $err ) = run( {%BASE},
        inbound => [ { type => 'subscribe', from => 'ops@chat.example/phone' } ] );
    ok( $ok, 'the send succeeds' ) or diag $err;
    is_deeply( [ subs() ], [ 'subscribe ops@chat.example', 'subscribed ops@chat.example' ],
        'the account asks the recipient to subscribe and approves their request '
            . '(bare JID, case-insensitive)' );
    ok( ( grep { $_->[0] eq 'MessageSend' } @CALLS ), 'and the notice is still sent' );
}

# --- a stranger's subscribe is never approved ---------------------------------
{
    my ( $ok, $err ) = run( {%BASE},
        inbound => [ { type => 'subscribe', from => 'mallory@chat.example' } ] );
    ok( $ok, 'the send succeeds' ) or diag $err;
    is_deeply( [ subs() ], ['subscribe ops@chat.example'],
        'a subscribe from anyone else is ignored: nothing is approved' );
}

# --- the roster decides: no repeat request ------------------------------------
{
    run( { %BASE }, roster => { 'ops@chat.example' => { subscription => 'both' } } );
    is_deeply( [ subs() ], [], 'subscription both: no subscription stanza at all' );
    ok( !( grep { $_->[0] eq 'PresenceSend' } @CALLS ), 'and no presence is sent' );

    run( { %BASE }, roster => { 'ops@chat.example' => { subscription => 'to' } } );
    is_deeply( [ subs() ], [], 'subscription to: the account does not ask again' );

    run( { %BASE },
        roster => { 'ops@chat.example' => { subscription => 'none', ask => 'subscribe' } } );
    is_deeply( [ subs() ], [], 'a request already pending is not repeated' );

    run( { %BASE }, roster => { 'ops@chat.example' => { subscription => 'from' } } );
    is_deeply( [ subs() ], ['subscribe ops@chat.example'],
        'subscription from: the account asks for the other direction' );
}

# --- a room is not a contact ---------------------------------------------------
{
    my ( $ok, $err ) = run( { %BASE, muc => 'true', to => 'room@conf.chat.example' } );
    ok( $ok, 'a room send succeeds' ) or diag $err;
    is_deeply( [ subs() ], [], 'a room gets no subscription stanza' );
    ok( !( grep { $_->[0] eq 'PresenceSend' } @CALLS ), 'and no extra presence' );
}

# --- every message has a plain body and the right type ------------------------
{
    run( {%BASE} );
    my ($m) = grep { $_->[0] eq 'MessageSend' } @CALLS;
    is( $m->[2], 'chat',     'a person gets a chat message' );
    is( $m->[3], 'a notice', 'with a plain body' );
    run( { %BASE, muc => 'true', to => 'room@conf.chat.example' } );
    ($m) = grep { $_->[0] eq 'MessageSend' } @CALLS;
    is( $m->[2], 'groupchat', 'a room gets a groupchat message' );
    is( $m->[3], 'a notice',  'with a plain body' );
    my @sent = grep { $_->[0] eq 'Send' } @CALLS;
    is_deeply( [ map { $_->[1] } @sent ], [ 'Net::XMPP::Presence' ],
        'the room join is the only raw stanza; nothing is published under OMEMO or PEP' );
}

# --- a failing presence step still sends ---------------------------------------
{
    my ( $ok, $err ) = run( {%BASE}, b => { roster_dies => 1 } );
    ok( $ok, 'the send succeeds although the roster read died' ) or diag $err;
    my ($m) = grep { $_->[0] eq 'MessageSend' } @CALLS;
    ok( $m, 'and the notice went out' );
    ok( ( grep { $_->[0] eq 'Disconnect' } @CALLS ), 'and the socket is released' );
}

is( alarm(0), 0, 'no alarm is left pending' );
done_testing();
