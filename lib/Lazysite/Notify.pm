package Lazysite::Notify;

# SM113/SM136: operator notifications - one write path. notify() appends a notice
# to the manager bell store (lazysite/logs/notices.jsonl) and, when an endpoint is
# routed and configured, also delivers it - today over XMPP - so an operator hears
# about it without being logged in.
#
# SM231 turned that single path into a CHANNEL. Four things changed and each
# closes something the filing named:
#
#   TYPES      a registry, so a notification declares what it is and what it
#              carries. Three types were already live (submission, feedback,
#              reset-request) against a filing that said there was one, which is
#              itself the argument for a registry: nobody could see the set.
#   TEMPLATES  a per-type, per-endpoint body, overridable per site. This is what
#              finally DELIVERS `url` - it was recorded and discarded, and that
#              one omission is most of what made a notice hard to act on.
#   ROUTING    which types reach which endpoints, so a service alert can reach an
#              operator while submission notices go to a room.
#   EMISSION   a type can be silenced without touching its caller. A partner's
#              three-day programme produced 690 events where five were wanted;
#              the answer is not to batch them (which needs pending state and a
#              timer lazysite does not have) but to not send them.
#
# The bell store is ALWAYS written and is always the record. Endpoint delivery is
# strictly best-effort: the XMPP client is lazy-required and time-boxed so a CGI
# request can never hang on a chat server.
#
# Not here, deliberately: digest/batching, timers, inbound actions, workflow, and
# the agent-messaging store - the last is a door SM231 asks to be left open, not
# a feature to build. See SM281 for what remains.

use strict;
use warnings;
use JSON::PP       ();
use Lazysite::Util qw(log_event);
use Exporter 'import';
our @EXPORT_OK = qw(notify notify_types);

# Test hook: overridable sender (t/ swaps this out to capture sends).
our $XMPP_SENDER = \&_xmpp_send;

# --- the type registry -------------------------------------------------------
#
# Each type declares a title (what a sysop sees in a routing UI) and the
# variables its templates may use beyond the universal ones. `default_route` is
# where it goes when the site says nothing.
#
# An UNREGISTERED type is still delivered, on the generic template and the
# default route, with a WARN. Refusing it would lose an event because someone
# added a caller before an entry here, and losing sysop notifications to
# enforce a registry is the wrong trade.
my %TYPES = (
    submission => {
        title         => 'A form was submitted',
        default_route => 'bell,xmpp',
    },
    feedback => {
        title         => 'An agent sent feedback',
        default_route => 'bell,xmpp',
    },
    'reset-request' => {
        title         => 'A password reset needs an operator',
        default_route => 'bell,xmpp',
    },
    # Seeded from the events SM231 named as things the platform already learns
    # and tells nobody. They have no caller yet; a type with no emitter is a
    # declared vocabulary, not a promise that something sends it.
    'credential-expiring' => {
        title         => 'A credential is about to lapse',
        default_route => 'bell,xmpp',
    },
    'backup-outcome' => {
        title         => 'A backup completed or failed',
        default_route => 'bell',
    },
    'audit-finding' => {
        title         => 'An audit finding appeared',
        default_route => 'bell',
    },
    'service-degraded' => {
        title         => 'A service is degraded or misconfigured',
        default_route => 'bell,xmpp',
    },
);

sub notify_types { return { map { $_ => { %{ $TYPES{$_} } } } keys %TYPES } }

# --- the built-in templates --------------------------------------------------
#
# One line for xmpp (a chat client shows one line), the message alone for the
# bell (the manager renders url as a link from the record's own field, so
# repeating it in the text would double it).
#
# `[% url %]` is the point of the exercise. A site overrides any of these with
# lazysite/notify-templates/<type>.<endpoint>.tt.
my %DEFAULT_TEMPLATE = (
    'default.xmpp' => '[% site %]: [% message %][% IF url %] -> [% base %][% url %][% END %]',
    'default.bell' => '[% message %]',
);

sub _template {
    my ( $docroot, $type, $endpoint ) = @_;

    # Per-site override first: a specific type beats the generic one.
    for my $key ( "$type.$endpoint", "default.$endpoint" ) {
        my $path = "$docroot/lazysite/notify-templates/$key.tt";
        next unless -f $path;
        open my $fh, '<:utf8', $path or next;
        local $/;
        my $body = <$fh>;
        close $fh;
        next unless defined $body && length $body;
        chomp $body;
        return ( $body, 1 );    # 1 = came from a file, so render it with TT
    }
    return ( $DEFAULT_TEMPLATE{"default.$endpoint"} // '[% message %]', 0 );
}

# Render a body. The built-ins use only [% var %] and [% IF var %]...[% END %],
# which a few lines of substitution handle - so the common path never loads
# Template. A SITE-SUPPLIED template gets the real thing, lazily required, and a
# broken one falls back to the message rather than losing the notice.
sub _render {
    my ( $body, $from_file, $vars ) = @_;

    if ($from_file) {
        my $out = eval {
            require Template;
            my $t = Template->new( { ABSOLUTE => 0, RELATIVE => 0 } );
            my $o = '';
            $t->process( \$body, $vars, \$o ) or die $t->error() . "\n";
            $o;
        };
        if ( defined $out && length $out ) { $out =~ s/\s+\z//; return $out }
        log_event( 'WARN', 'notify', 'template failed; using the message',
            error => "$@" );
        return $vars->{message};
    }

    # [% IF x %]...[% END %] - non-nested, which is all the built-ins use.
    $body =~ s{\[\%\s*IF\s+(\w+)\s*\%\](.*?)\[\%\s*END\s*\%\]}
              {length( $vars->{$1} // '' ) ? $2 : ''}ges;
    $body =~ s{\[\%\s*(\w+)\s*\%\]}{$vars->{$1} // ''}ge;
    $body =~ s/\s+\z//;
    $body =~ s/\A\s+//;
    return $body;
}

# --- config: routing and emission -------------------------------------------
#
# lazysite/notify.conf, one key per line:
#   route.<type>:  bell,xmpp      which endpoints this type reaches
#   emit.<type>:   off            silence a type without touching its caller
#   base_url:      https://...    prefix for the [% url %] a template delivers
#
# Absent file, absent key: the type's own default_route, and emission on. So a
# site that never writes this file behaves exactly as it did before SM231.
sub _notify_conf {
    my ($docroot) = @_;
    my %c;
    open my $fh, '<:utf8', "$docroot/lazysite/notify.conf" or return \%c;
    while ( my $l = <$fh> ) {
        next if $l =~ /^\s*(?:#|$)/;
        $c{$1} = $2 if $l =~ /^([\w.-]+)\s*:\s*(.*?)\s*$/;
    }
    close $fh;
    return \%c;
}

sub _emits {
    my ( $conf, $type ) = @_;
    my $v = $conf->{"emit.$type"};
    return 1 unless defined $v && length $v;
    return $v =~ /^(?:0|off|false|no)$/i ? 0 : 1;
}

sub _route {
    my ( $conf, $type ) = @_;
    my $spec = $conf->{"route.$type"};
    $spec = ( $TYPES{$type} ? $TYPES{$type}{default_route} : 'bell,xmpp' )
        unless defined $spec && length $spec;
    my %on = map { lc($_) => 1 } grep { length } split /[,\s]+/, $spec;

    # The bell is the record and is never routed away. A site that writes
    # `route.submission: xmpp` means "also xmpp", not "instead of the record" -
    # and a notice nothing wrote down is not a notice.
    $on{bell} = 1;
    return \%on;
}

sub notify {
    my ( $docroot, $n ) = @_;
    return 0 unless defined $docroot && ref $n eq 'HASH' && length( $n->{message} // '' );

    my $logdir = "$docroot/lazysite/logs";
    return 0 unless -d $logdir;

    my $type = $n->{type} // 'event';
    my $conf = _notify_conf($docroot);

    # SM231 emission control. Checked BEFORE the bell write: a silenced type is
    # silent, not quietly accumulating in a store nobody reads. Reported as a
    # success to the caller - the caller asked to notify and the site's policy
    # is that this type does not, which is not a failure of the call.
    unless ( _emits( $conf, $type ) ) {
        log_event( 'INFO', 'notify', 'type silenced by config', type => $type );
        return 1;
    }

    log_event( 'WARN', 'notify', 'unregistered notification type', type => $type )
        unless $TYPES{$type} || $type eq 'event';

    my %rec = (
        ts      => time(),
        type    => $type,
        message => $n->{message},
        ( defined $n->{target} ? ( target => $n->{target} ) : () ),
        ( defined $n->{url}    ? ( url    => $n->{url} )    : () ),
    );
    $rec{message} =~ s/[\r\n]+/ /g;

    my $route = _route( $conf, $type );

    open my $fh, '>>', "$logdir/notices.jsonl" or return 0;
    print {$fh} JSON::PP::encode_json( \%rec ) . "\n";
    close $fh;

    # SM231: the variables a template may use. `url` is here because delivering
    # it is the whole point - it was stored and dropped before this.
    my %vars = (
        message => $rec{message},
        type    => $type,
        target  => ( $rec{target} // '' ),
        url     => ( $rec{url}    // '' ),
        site    => _site_name($docroot),
        base    => ( $conf->{base_url} // _site_url($docroot) ),
    );
    $vars{base} =~ s{/+$}{} if defined $vars{base};

    if ( $route->{xmpp} ) {
        my $xconf = _xmpp_conf($docroot);
        if ($xconf) {
            my ( $body, $from_file ) = _template( $docroot, $type, 'xmpp' );
            my $text = _render( $body, $from_file, \%vars );
            local $@;
            eval { $XMPP_SENDER->( $xconf, $text ); 1 } or do {
                log_event( 'WARN', 'notify', 'xmpp delivery failed', error => "$@" );
            };
        }
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

sub _conf_value {
    my ( $docroot, $key ) = @_;
    open my $fh, '<:utf8', "$docroot/lazysite/lazysite.conf" or return '';
    while ( my $l = <$fh> ) {
        if ( $l =~ /^\Q$key\E\s*:\s*(.+?)\s*$/ ) { close $fh; return $1 }
    }
    close $fh;
    return '';
}

sub _site_name { return _conf_value( $_[0], 'site_name' ) }
sub _site_url  { return _conf_value( $_[0], 'site_url' ) }

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
