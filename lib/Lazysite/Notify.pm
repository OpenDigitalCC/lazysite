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
use Fcntl           qw(:flock);
use Lazysite::Util  qw(log_event cannot_read);
use Lazysite::Paths ();
use Exporter 'import';
our @EXPORT_OK = qw(notify notify_types);

# Test hook: overridable sender (t/ swaps this out to capture sends).
our $XMPP_SENDER = \&_xmpp_send;

# SM485: the same hook for mail. The transport is the Form SMTP extension,
# reached over its `--pipe` interface, so a test that swapped only the conf would
# still be talking to a real script; this is the seam t/ replaces instead.
our $MAIL_SENDER = \&_mail_send;

# SM485: how many notice emails this site may send in an hour.
#
# One axis, not two. SM877 built a PER-RECIPIENT cap as well, because a form
# acknowledgement goes to an address the visitor typed and a site writing to
# addresses it did not choose is an open relay in miniature. That reasoning does
# not carry here and the ruling says so: a notice can only ever reach an account
# that exists, at the address its own record holds, having opted in. The
# per-site bound stays because "unbounded" should be a decision rather than the
# default - it is what stops a loop in a caller mailing all night.
our $DEFAULT_MAIL_PER_HOUR = 60;

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
        my $path = Lazysite::Paths::lazysite_dir($docroot) . "/notify-templates/$key.tt";

        # The `-f` that used to stand here is gone: the open below already skips
        # an absent candidate, so the stat only duplicated the answer - and
        # t/lint/121 is right that a stat this process may not make fails exactly
        # like an open it may not make. Behaviour is unchanged; one fewer way to
        # be told "no" for the wrong reason.
        open my $fh, '<:utf8', $path or next;    # not a store - a template file
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
    open my $fh, '<:utf8', Lazysite::Paths::lazysite_dir($docroot) . "/notify.conf" or return \%c; # not a store - site config
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

    my $logdir = Lazysite::Paths::lazysite_dir($docroot) . "/logs";
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

    # SM485 / SM281 item 2: WHO THE NOTICE IS FOR, optional.
    #
    # `to` names an ACCOUNT, never an address - the address is the account's own,
    # read from its record at delivery. A notice that carried an address would be
    # a way to make the site write to anywhere, which is the shape SM877 built
    # caps against; naming an account cannot reach anybody who does not already
    # have a record here.
    #
    # Absent means broadcast, exactly as before, so nothing that emits a notice
    # today has to change - and a broadcast reaches nobody by mail, because there
    # is no addressee to look up. That is the ruling, and it is also what falls
    # out of the code: there is nothing here to send to.
    my $to = $n->{to};
    if ( defined $to ) {
        $to =~ s/[^a-zA-Z0-9_.-]//g;
        # A `to` that sanitises away is a caller error, and silently promoting it
        # to a broadcast would show one account's notice to everyone holding the
        # bell. Refuse the addressing, keep the notice.
        if ( !length $to ) {
            log_event( 'WARN', 'notify',
                'notice addressed to a name with no usable characters - kept as a broadcast',
                type => $type );
            $to = undef;
        }
    }

    my %rec = (
        ts      => time(),
        type    => $type,
        message => $n->{message},
        ( defined $to          ? ( to     => $to )          : () ),
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
        to      => ( $rec{to}     // '' ),
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

    # SM485: AND BY MAIL, if the site routes this type there and the person asked
    # for it. Every refusal below is logged with its own reason - a notice that
    # did not become an email is an ordinary outcome, not a failure of notify(),
    # so the return value does not change. The bell already has the record, and
    # losing a notice because a mail server was unreachable would be the wrong
    # trade entirely.
    if ( $route->{email} ) {
        my $why = _mail_notice( $docroot, $conf, \%rec, \%vars );
        log_event( 'INFO', 'notify', 'notice not mailed', type => $type, why => $why )
            if length $why;
    }
    return 1;
}

# Deliver one notice by mail. Returns '' when it was sent, or the reason it was
# not - so every path out of here says something, and the caller logs it.
#
# THE ORDER OF THE REFUSALS IS THE DESIGN. Cheapest and most specific first, so
# the reason a sysop reads is the one that will help: "nobody is addressed"
# before "that account has not opted in" before "the extension is off".
sub _mail_notice {
    my ( $docroot, $conf, $rec, $vars ) = @_;

    # 1. A BROADCAST REACHES NOBODY BY MAIL. Ruled, and there is nothing to send
    #    to in any case - a list of every account's address is a different
    #    feature from a notification one.
    return 'the notice is a broadcast, which is a bell item'
        unless length( $rec->{to} // '' );

    # 2. THE PERSON DECIDES. Opt-in, so a site that turns the route on does not
    #    start mailing people who never asked.
    my ( $addr, $why ) = _mail_recipient( $docroot, $rec->{to} );
    return $why unless length $addr;

    # 3. THE TRANSPORT, NAMED WHEN IT IS OFF. There is one mail configuration on
    #    a lazysite site and it belongs to the Form SMTP extension - SM842 spent
    #    a release removing the second one, and a notice endpoint that carried
    #    its own would put it straight back.
    my $script = _smtp_script();
    return 'the Form SMTP extension is not installed, so this site cannot send mail'
        unless defined $script;
    return 'the Form SMTP extension is switched off (enable it on the Extensions page)'
        unless _plugin_enabled( $docroot, 'form-smtp.pl' );
    my $smtp = Lazysite::Paths::lazysite_dir($docroot) . '/forms/smtp.conf';
    return 'the Form SMTP extension has no settings yet (save the SMTP settings first)'
        unless -f $smtp;

    # 4. THE BOUND. Counted from this site's own record, and an unreadable record
    #    REFUSES rather than counting as zero - within_caps treats an undefined
    #    count as "could not tell", which is the only safe reading for a cap.
    my $cap = $conf->{'mail.per_hour'};
    $cap = $DEFAULT_MAIL_PER_HOUR unless defined $cap && $cap =~ /\A\d+\z/;
    require Lazysite::Egress;
    my ( $ok, $capwhy ) = Lazysite::Egress::within_caps(
        what => 'notice',
        axes => [ {
                name    => 'this site',
                limit   => ( $cap ? $cap : undef ),
                used    => _mail_sent_last_hour($docroot),
                window  => 'hour',
                setting => 'mail.per_hour in notify.conf',
        } ],
    );
    return $capwhy unless $ok;

    my ( $body, $from_file ) = _template( $docroot, $rec->{type}, 'email' );
    my $text    = _render( $body, $from_file, $vars );
    my $subject = sprintf '%s%s',
        ( length( $vars->{site} // '' ) ? "[$vars->{site}] "            : '' ),
        ( $TYPES{ $rec->{type} }        ? $TYPES{ $rec->{type} }{title} : 'Notice' );

    local $@;
    my $sent = eval { $MAIL_SENDER->( $docroot, $script, $addr, $subject, $text ) };
    if ( !$sent ) {
        my $err = $@ || 'the transport reported no reason';
        $err =~ s/\s+\z//;
        return "the mail was not accepted: $err";
    }
    _record_mail_sent($docroot);
    return '';
}

# SM485: where a notice for this account should go, or '' and the reason.
#
# BOTH FACTS COME FROM THE ACCOUNT'S OWN RECORD - the opt-in and the address.
# Nothing a caller passes can redirect a notice, so the worst a wrong `to` can do
# is mail the wrong PERSON WHO ALREADY HAS AN ACCOUNT HERE, never an arbitrary
# stranger. That is what makes the single per-site cap sufficient.
sub _mail_recipient {
    my ( $docroot, $login ) = @_;
    my $settings = eval {
        require Lazysite::Auth::Settings;
        no warnings 'once';
        local $Lazysite::Auth::Settings::AUTH_DIR
            = Lazysite::Paths::lazysite_dir($docroot) . '/auth';
        # FOUR STATES, not two. An unreadable store is not a store where nobody
        # opted in: read_settings() returns {} for both, and settings_readable()
        # is the companion that tells them apart (SM778/SM784). Refusing on
        # "could not tell" is right for a send - the alternative is mailing
        # somebody on the strength of a file we failed to open.
        return undef unless Lazysite::Auth::Settings::settings_readable();
        Lazysite::Auth::Settings::read_settings();
    };
    return ( '', 'the account store could not be read, so no opt-in could be confirmed' )
        unless ref $settings eq 'HASH';

    my $acct = $settings->{$login};
    return ( '', "there is no account '$login'" ) unless ref $acct eq 'HASH';

    my $opted = $acct->{notify_email} // '';
    return ( '', "'$login' has not asked for notices by mail" )
        unless $opted =~ /\A(?:1|on|true|yes)\z/i;

    my $addr = $acct->{email} // '';
    $addr =~ s/\A\s+|\s+\z//g;
    return ( '', "'$login' asked for notices by mail but the account has no address" )
        unless length $addr;
    return ( '', "'$login' has an address that is not one ($addr)" )
        unless $addr =~ /\A[^\s\@,;<>]+\@[^\s\@,;<>]+\.[A-Za-z]{2,}\z/;
    return ( $addr, '' );
}

# The site's own notice-mail record. Its OWN file, deliberately not the form
# handler's submitter-mail.jsonl: sharing that bucket would mean a busy contact
# form silencing the sysop's notices, which are the thing you least want capped
# by something unrelated.
sub _mail_record_file {
    return Lazysite::Paths::lazysite_dir( $_[0] ) . '/logs/notice-mail.jsonl';
}

# How many went out in the last hour, or undef when the record exists and will
# not open - the third state within_caps refuses on. A missing file is a genuine
# zero: nothing has been sent yet.
#
# ABSENCE IS THE OPEN'S ENOENT, NEVER A STAT. This had `return 0 unless -e $f`
# in front of it and t/lint/121 refused it, rightly: a stat the process may not
# make fails exactly like an open it may not make, so the guard would have turned
# "I am not allowed to look" into "nothing has been sent" - and a cap that cannot
# count must never read as room to send.
sub _mail_sent_last_hour {
    my ($docroot) = @_;
    my $f = _mail_record_file($docroot);
    open my $fh, '<', $f
        or return $!{ENOENT} ? 0 : cannot_read( 'the notice-mail record', $f );
    my $cut = time() - 3600;
    my $n   = 0;
    while ( my $l = <$fh> ) {
        my $r = eval { JSON::PP::decode_json($l) } or next;
        $n++ if ( $r->{t} // 0 ) >= $cut;
    }
    close $fh;
    return $n;
}

# One line per send. The ADDRESS IS NOT WRITTEN - only that a send happened -
# for SM877's reason: a file of addresses is a mailing list, and this one would
# be a list of the site's own operators.
sub _record_mail_sent {
    my ($docroot) = @_;
    my $f = _mail_record_file($docroot);
    open my $fh, '>>', $f or return 0;
    eval {
        flock $fh, LOCK_EX;
        print {$fh} JSON::PP::encode_json( { t => time() } ) . "\n";
        1;
    };
    close $fh;
    return 1;
}

# Where the Form SMTP extension's script lives. The same four places
# Lazysite::Handlers::_find_script looks, because there is one answer to "where
# are the extension scripts" and two copies of it would diverge the first time
# somebody moved the tree (SM850 is that lesson).
sub _smtp_script {
    my @tried = (
        __FILE__ =~ s{/lib/Lazysite/Notify\.pm\z}{}r . '/plugins/form-smtp.pl',
        '/usr/share/lazysite/plugins/form-smtp.pl',
    );
    for my $p (@tried) { return $p if -f $p }
    return undef;
}

# Hand the composed notice to the Form SMTP extension over its --pipe interface.
# The extension merges its own smtp.conf connection settings into whatever config
# it is given, so this passes only from/to/subject and never a credential.
sub _mail_send {
    my ( $docroot, $script, $addr, $subject, $text ) = @_;
    require IPC::Open2;
    local $ENV{DOCUMENT_ROOT} = $docroot;
    my $payload = JSON::PP::encode_json( {
            config => { to      => $addr, subject_prefix => "$subject - " },
            form   => { message => $text },
    } );
    my ( $out, $in );
    my $pid = eval { IPC::Open2::open2( $out, $in, $^X, $script, '--pipe' ) }
        or die "the extension's script could not be started\n";
    print {$in} $payload;
    close $in;
    my $res = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my $r = eval { JSON::PP::decode_json( $res // '' ) } || {};
    die( ( $r->{error} // 'no answer from the extension' ) . "\n" ) unless $r->{ok};
    return 1;
}

# The notify-xmpp client config, or undef when the plugin is disabled or not
# configured. Enabled = listed in the lazysite.conf `plugins:` block (the same
# registry the manager's Plugins page toggles).
sub _xmpp_conf {
    my ($docroot) = @_;
    return undef unless _plugin_enabled( $docroot, 'notify-xmpp.pl' );
    my $path = Lazysite::Paths::lazysite_dir($docroot) . "/notify-xmpp.conf";
    open my $fh, '<', $path or return undef;    # not a store - the xmpp client config
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
    open my $fh, '<:utf8', Lazysite::Paths::lazysite_dir($docroot) . "/lazysite.conf" or return ''; # not a store - site config
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
    open my $fh, '<:utf8', Lazysite::Paths::lazysite_dir($docroot) . "/lazysite.conf" or return 0; # not a store - site config
    my ( $in, $found ) = ( 0, 0 );
    while ( my $l = <$fh> ) {
        chomp $l;
        # SM915: BOTH SPELLINGS, because SM817 renamed this list to
        # `extensions:` and said the two open the same one - "a site cannot end
        # up with two lists that disagree about what is enabled". This reader
        # accepted only the old name, so on a site that adopted the new one it
        # reported every extension disabled, and a notice reached no endpoint but
        # the bell. That is not a new hole: XMPP delivery has been silently off
        # on those sites since the rename, which SM485's build walked into while
        # looking for the SMTP transport. Three more readers are still wrong and
        # one of them WRITES a second list - measured and filed as SM915, not
        # fixed here, because the writer needs a ruling about a conf that already
        # carries both headers.
        if    ( $l =~ /^(?:extensions|plugins)\s*:\s*$/ ) { $in = 1; next }
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
    alarm 15;    # network-bound: the XMPP peer, not this process (t/lint/120)
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
