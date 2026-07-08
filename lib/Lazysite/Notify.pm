package Lazysite::Notify;

# SM113/SM136: operator notifications - one write path. notify() appends a notice
# to the manager bell store (lazysite/logs/notices.jsonl) and, when the
# notify-xmpp plugin is enabled and configured, also delivers it over XMPP so an
# operator hears about it without being logged in.
#
# The XMPP client is one per site (like SMTP delivery: one client config in
# lazysite/notify-xmpp.conf), sending to a single recipient - an individual JID or
# a group chat (MUC) room. Per-user addressing is a future feature. The send logic
# is based on the xmpp-lite connector (Net::XMPP underneath; Debian
# libnet-xmpp-perl), lazy-required and time-boxed so a CGI request can never hang
# on a chat server: delivery is strictly best-effort, the bell store is the record.

use strict;
use warnings;
use JSON::PP       ();
use Lazysite::Util qw(log_event);
use Exporter 'import';
our @EXPORT_OK = qw(notify);

# Test hook: overridable sender (t/ swaps this out to capture sends).
our $XMPP_SENDER = \&_xmpp_send;

sub notify {
    my ( $docroot, $n ) = @_;
    return 0 unless defined $docroot && ref $n eq 'HASH' && length( $n->{message} // '' );

    my $logdir = "$docroot/lazysite/logs";
    return 0 unless -d $logdir;
    my %rec = (
        ts      => time(),
        type    => ( $n->{type} // 'event' ),
        message => $n->{message},
        ( defined $n->{target} ? ( target => $n->{target} ) : () ),
        ( defined $n->{url}    ? ( url    => $n->{url} )    : () ),
    );
    $rec{message} =~ s/[\r\n]+/ /g;
    open my $fh, '>>', "$logdir/notices.jsonl" or return 0;
    print {$fh} JSON::PP::encode_json( \%rec ) . "\n";
    close $fh;

    # Best-effort XMPP delivery; failure never affects the caller.
    my $conf = _xmpp_conf($docroot);
    if ($conf) {
        local $@;
        eval { $XMPP_SENDER->( $conf, $rec{message} ); 1 } or do {
            log_event( 'WARN', 'notify', 'xmpp delivery failed', error => "$@" );
        };
    }
    return 1;
}

# The notify-xmpp client config, or undef when the plugin is disabled or not
# configured. Enabled = listed in the lazysite.conf `plugins:` block (the same
# registry the manager's Plugins page toggles).
sub _xmpp_conf {
    my ($docroot) = @_;
    return undef unless _plugin_enabled( $docroot, 'notify-xmpp.pl' );
    my $path = "$docroot/lazysite/notify-xmpp.conf";
    open my $fh, '<', $path or return undef;
    my %c;
    while ( my $l = <$fh> ) {
        $c{$1} = $2 if $l =~ /^(\w+)\s*:\s*(.*?)\s*$/;
    }
    close $fh;
    return undef unless length( $c{jid} // '' ) && length( $c{password} // '' )
        && length( $c{to} // '' );

    # Default the sender nickname to the site name, sanitised to nick-safe
    # characters - so the ping reads as "My-Site: New form submission ...".
    unless ( length( $c{nick} // '' ) ) {
        my $name = _site_name($docroot);
        $name =~ s/[^A-Za-z0-9_-]+/-/g;
        $name =~ s/^-+|-+$//g;
        $c{nick} = length $name ? $name : 'lazysite';
    }
    return \%c;
}

sub _site_name {
    my ($docroot) = @_;
    open my $fh, '<:utf8', "$docroot/lazysite/lazysite.conf" or return '';
    while ( my $l = <$fh> ) {
        if ( $l =~ /^site_name\s*:\s*(.+?)\s*$/ ) { close $fh; return $1 }
    }
    close $fh;
    return '';
}

sub _plugin_enabled {
    my ( $docroot, $name ) = @_;
    open my $fh, '<:utf8', "$docroot/lazysite/lazysite.conf" or return 0;
    my ( $in, $found ) = ( 0, 0 );
    while ( my $l = <$fh> ) {
        chomp $l;
        if    ( $l =~ /^plugins\s*:\s*$/ ) { $in = 1; next }
        elsif ( $in && $l =~ /^\s+-\s+(.+?)\s*$/ ) {
            ( my $base = $1 ) =~ s{.*/}{};
            $found = 1 if $base eq $name;
        }
        elsif ( $in && $l !~ /^\s/ ) { last }
    }
    close $fh;
    return $found;
}

# One-shot XMPP send, based on the xmpp-lite connector's connect/send flow
# (Net::XMPP::Client: Connect -> AuthSend -> chat MessageSend, or a MUC
# presence-join then a groupchat send). Time-boxed with alarm so a CGI request
# cannot hang on an unreachable chat server.
sub _xmpp_send {
    my ( $conf, $text ) = @_;
    require Net::XMPP;

    my ( $user, $domain ) = ( $conf->{jid} // '' ) =~ /^([^@]+)\@(.+)$/;
    die "notify-xmpp: jid must be user\@domain\n" unless defined $domain;
    my $host = length( $conf->{host} // '' ) ? $conf->{host} : $domain;
    my $port = ( $conf->{port} // '' )  =~ /^\d+$/             ? $conf->{port} : 5222;
    my $tls  = ( $conf->{tls}  // '1' ) =~ /^(?:1|true|yes)$/i ? 1             : 0;
    my $nick = length( $conf->{nick} // '' ) ? $conf->{nick}            : 'lazysite';
    my $muc  = ( $conf->{muc}        // '' ) =~ /^(?:1|true|yes)$/i ? 1 : 0;

    local $SIG{ALRM} = sub { die "notify-xmpp: timed out\n" };
    alarm 15;
    my $client = Net::XMPP::Client->new();
    my $ok     = eval {
        defined $client->Connect(
            hostname      => $host,
            port          => $port,
            tls           => $tls,
            componentname => $domain,
        ) or die "notify-xmpp: connect to $host:$port failed\n";
        my @auth = $client->AuthSend(
            username => $user,
            password => $conf->{password},
            resource => $nick,
        );
        die "notify-xmpp: auth failed: $auth[0]\n"
            unless ( $auth[0] // '' ) eq 'ok';

        if ($muc) {
            # Join the room (bare names get no default domain here - configure the
            # full room JID), then send as groupchat.
            my $p = Net::XMPP::Presence->new();
            $p->SetTo("$conf->{to}/$nick");
            $p->InsertRawXML('<x xmlns="http://jabber.org/protocol/muc"/>');
            $client->Send($p);
            $client->MessageSend( to => $conf->{to}, body => $text, type => 'groupchat' );
        }
        else {
            $client->MessageSend( to => $conf->{to}, body => $text, type => 'chat' );
        }
        1;
    };
    my $err = $@;
    eval { $client->Disconnect() };
    alarm 0;
    die $err unless $ok;
    return 1;
}

1;
