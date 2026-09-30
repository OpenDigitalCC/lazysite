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
use Lazysite::Util  qw(log_event cannot_read interpolate_env);
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
        # SM928 defect 2: the submitted fields, when the form opts in with
        # `notify: full`. An ARRAY of { name, label, value, truncated } - values,
        # not a formatted block, because the formatting belongs in a template and
        # that is the whole reason they have to arrive here at all. `fields_text`
        # below is DERIVED from this for the built-in renderer, which has no loop.
        vars => ['fields'],
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
# SM928 defect 3: A MULTI-LINE BODY, once defect 1 made one possible and defect 2
# gave it something to say. The one-line form is kept and is still what a notice
# without fields gets - the comment above was right that a chat client shows one
# line, for a notice that IS one line.
#
# `submission.xmpp` is selected over `default.xmpp` by the existing per-type
# lookup in _template, so this needs no new mechanism: a form that has not opted in
# sends no fields, `fields_text` is empty, and the IF collapses to exactly the old
# single line. The multi-line shape appears only on `notify: full`.
#
# LABELS ARE NOT PADDED INTO COLUMNS. Most chat clients set text proportionally, so
# padded alignment arrives ragged and worse than none.
my %DEFAULT_TEMPLATE = (
    'default.xmpp' => '[% site %]: [% message %][% IF url %] -> [% base %][% url %][% END %]',
    'default.bell' => '[% message %]',
    # The `.full` suffix is the whole safety of this. A form that has NOT opted in
    # sends no fields, so _template never reaches this key and the notice is
    # byte-for-byte the one-line `default.xmpp` it has always been. Writing the
    # multi-line shape as `submission.xmpp` instead was tried and was wrong: the
    # collapsed IF still left a blank line, which is a behaviour change on a form
    # that never asked for one - and "nothing changes unless you ask" is the
    # ruling, not a nicety.
    'submission.xmpp.full' =>
        "[% site %]: [% message %]\n\n[% fields_text %]"
        . '[% IF url %]' . "\n\nRead it: " . '[% base %][% url %][% END %]',
);

sub _template {
    my ( $docroot, $type, $endpoint, $has_fields ) = @_;

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
    # SM928: THE BUILT-IN FALLBACK NOW TRIES THE PER-TYPE KEY TOO. The per-site
    # override loop above has always looked for `<type>.<endpoint>` before
    # `default.<endpoint>`, but this line only ever read `default.<endpoint>` from
    # %DEFAULT_TEMPLATE - so a built-in per-type template could be added to that
    # hash and silently never used. Nobody had noticed because until now every key
    # in it was a `default.*` one. Found by the multi-line submission body being
    # ignored in favour of the one-liner.
    # A `.full` built-in is reached ONLY when the caller says fields are present,
    # so a form that has not opted in cannot be given the longer body. The
    # per-SITE override loop above is deliberately not suffixed: a site that writes
    # submission.xmpp.tt means it for both, and giving it two filenames to learn
    # would be a second mechanism for one decision.
    my @keys = ( $has_fields ? "$type.$endpoint.full" : () );
    push @keys, "$type.$endpoint", "default.$endpoint";
    for my $key (@keys) {
        return ( $DEFAULT_TEMPLATE{$key}, 0 ) if defined $DEFAULT_TEMPLATE{$key};
    }
    return ( '[% message %]', 0 );
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
    # SM928 defect 1: THE STORE'S COPY IS FLATTENED, THE TEMPLATE'S IS NOT.
    #
    # This strip carried no comment and sat immediately before the notices.jsonl
    # append, so its evident purpose was to keep the store one record per line.
    # JSON::PP::encode_json already escapes a newline as \n INSIDE the JSON
    # string, so a multi-line message could never have broken the JSONL format -
    # but %vars below was built from this stripped copy, which silently flattened
    # multi-line bodies for EVERY endpoint and every template, XMPP and email
    # alike. A site that wrote a careful multi-line submission.xmpp.tt got its own
    # literal newlines back and lost only the interpolated [% message %], which is
    # the worst version: it works until the content matters.
    #
    # KEPT, AND NOT BECAUSE THE FORMAT NEEDS IT - a sabotage pass proved that.
    # Commenting this line out changes nothing measurable: encode_json escapes a
    # newline as \n inside the JSON string, so the store stays one record per line
    # either way, which is exactly what SM928 said and what an earlier version of
    # this comment got wrong by implying the strip was load-bearing.
    #
    # What it actually does is normalise what the BELL shows. It stays because
    # removing it would change what is written into notices.jsonl on every site,
    # and that is a separate decision from fixing the templates - which is the
    # whole of what this filing was asked for. Recorded so the next reader does
    # not delete it believing it is protecting the format, or keep it believing it
    # is.
    $rec{message} =~ s/[\r\n]+/ /g;

    my $route = _route( $conf, $type );

    open my $fh, '>>', "$logdir/notices.jsonl" or return 0;
    print {$fh} JSON::PP::encode_json( \%rec ) . "\n";
    close $fh;

    # SM231: the variables a template may use. `url` is here because delivering
    # it is the whole point - it was stored and dropped before this.
    my %vars = (
        # SM928 defect 1: from the ORIGINAL, not the store's flattened copy. See
        # the strip above for why the two differ and why only one of them should.
        message => $n->{message},
        type    => $type,
        target  => ( $rec{target} // '' ),
        url     => ( $rec{url}    // '' ),
        to      => ( $rec{to}     // '' ),
        site    => _site_name($docroot),
        base    => ( $conf->{base_url} // _site_url($docroot) ),
    );
    $vars{base} =~ s{/+$}{} if defined $vars{base};

    # SM928 defect 2: the submitted fields reach the templates.
    #
    # TWO SHAPES, and the second exists only because the built-in renderer has no
    # loop. `fields` is the STRUCTURE - an array of { name, label, value,
    # truncated } - which a site-supplied template gets real Template Toolkit for
    # and can [% FOREACH f IN fields %] over. `fields_text` is derived from it
    # here, so the shipped default (rendered by the few lines of substitution in
    # _render) has something to interpolate.
    #
    # Deriving it HERE rather than in the caller is the point of defect 2: the
    # caller hands over values and the notifier decides how a notice reads, so a
    # site that wants a different shape overrides a template instead of patching a
    # form handler.
    if ( ref $n->{fields} eq 'ARRAY' && @{ $n->{fields} } ) {
        $vars{fields}      = $n->{fields};
        $vars{fields_text} = join "\n", map {
            my $l = $_->{label} // $_->{name} // '';
            my $v = $_->{value} // '';
            "$l: $v" . ( $_->{truncated} ? ' [...]' : '' );
        } @{ $n->{fields} };
    }
    else {
        # Named even when empty, so a template's [% IF fields_text %] is a test
        # against a defined value rather than against a missing key.
        $vars{fields}      = [];
        $vars{fields_text} = '';
    }

    if ( $route->{xmpp} ) {
        my $xconf = _xmpp_conf($docroot);
        if ($xconf) {
            my ( $body, $from_file )
                = _template( $docroot, $type, 'xmpp', length $vars{fields_text} );
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

    # SM925 X3: FOUR DISTINCT CAUSES returned undef here, none of them saying
    # anything - the extension off, no conf file, a conf that will not open, and a
    # conf missing a required key. An operator spent an afternoon over four
    # submissions on a site where the answer was one of them, and the code knew
    # which. Only the first is a deliberate state; the other three are faults and
    # now say so. The four-state rule SM906, SM907 and SM917 applied to the stores,
    # arriving on the notification path.
    return undef unless _plugin_enabled( $docroot, 'notify-xmpp.pl' );

    my $path = Lazysite::Paths::lazysite_dir($docroot) . "/notify-xmpp.conf";
    my $fh;
    if ( !open( $fh, '<', $path ) ) {    # not a store - the xmpp client config
        if ( $!{ENOENT} ) {
            log_event( 'WARN', 'notify',
                'xmpp delivery is enabled and not configured, so nothing is sent',
                file => $path );
        }
        else {
            cannot_read( 'the xmpp client config', $path );
        }
        return undef;
    }
    my %c;
    while ( my $l = <$fh> ) {
        $c{$1} = $2 if $l =~ /^(\w+)\s*:\s*(.*?)\s*$/;
    }
    close $fh;
    my @missing = grep { !length( $c{$_} // '' ) } qw(jid password to);
    if (@missing) {
        log_event( 'WARN', 'notify',
            'xmpp delivery is configured without a value it cannot work without, '
                . 'so nothing is sent',
            file    => $path,
            missing => join( ', ', @missing ) );
        return undef;
    }

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
    my $path = Lazysite::Paths::lazysite_dir($docroot) . "/lazysite.conf";
    # SM926: an absent conf and one that will not open were both ''. The first is
    # ordinary on a tree being built; the second means every value this
    # notification needed is missing for a reason somebody can fix.
    my $fh;
    if ( !open( $fh, '<:utf8', $path ) ) {    # not a store - site config
        cannot_read( 'the site config', $path ) unless $!{ENOENT};
        return '';
    }
    while ( my $l = <$fh> ) {
        if ( $l =~ /^\Q$key\E\s*:\s*(.+?)\s*$/ ) { close $fh; return $1 }
    }
    close $fh;
    return '';
}

sub _site_name { return _conf_value( $_[0], 'site_name' ) }

# SM926: `site_url` HOLDS A TEMPLATE, NOT A URL - `${REQUEST_SCHEME}://${SERVER_NAME}`
# is what install.pl and TestHelper write, so one config works on any domain. This
# returned the raw line, so the first XMPP notification to arrive on a live site
# carried `${REQUEST_SCHEME}://${SERVER_NAME}/manager/plugins` as its link. The
# processor and tools/lazysite-users.pl both expand it; this was the third reader
# and the only one that did not.
#
# AND A NOTIFICATION HAS A CASE NEITHER OF THOSE HAS: no request context at all. A
# cron- or CLI-driven notice has no SERVER_NAME to borrow, so interpolation
# correctly yields `://` - and emitting THAT is worse than emitting nothing,
# because it looks like a link. When the expansion cannot complete, the base is
# empty and the template's `[% base %]/manager/...` degrades to an absolute PATH,
# which a reader can still use against whatever host they reached the site on.
# `base_url` in notify.conf overrides all of it and is the deliberate escape for a
# site whose notifications must point elsewhere - NOT the fix for this, which was
# ruled 2026-09-30: site_url is the single source of truth and a second place to
# write the site's own address goes stale in silence.
sub _site_url {
    my ($docroot) = @_;
    my $raw = _conf_value( $docroot, 'site_url' );
    return '' unless length( $raw // '' );
    return '' unless Lazysite::Util::env_interpolation_complete($raw);
    return interpolate_env($raw);
}

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
