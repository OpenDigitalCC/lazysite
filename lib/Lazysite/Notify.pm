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
use JSON::PP        ();
use Fcntl           qw(:flock);
use Lazysite::Util  qw(log_event cannot_read interpolate_env);
use Lazysite::Paths ();
use Exporter 'import';
our @EXPORT_OK = qw(notify notify_types form_notify_mode route_report);

# Test hook: overridable sender (t/ swaps this out to capture sends).
our $XMPP_SENDER = \&_xmpp_send;
our $XMPP_BOUNCE_WAIT = 3;              # SM955: seconds the TEST waits for a refusal

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
        my ($xconf) = _xmpp_conf_or_why($docroot);    # the reason is logged there
        if ($xconf) {
            my ( $body, $from_file )
                = _template( $docroot, $type, 'xmpp', length $vars{fields_text} );
            my $text = _render( $body, $from_file, \%vars );
            local $@;
            eval { $XMPP_SENDER->( $xconf, $text ); 1 } or do {
                my $err = "$@";
                log_event( 'WARN', 'notify', 'xmpp delivery failed', error => $err );
                _audit_delivery_failure( $docroot, $xconf->{to}, $err, 'notify' ); # SM955
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

    my ( $body, $from_file ) = _template( $docroot, $rec->{type}, 'email' );
    my $text    = _render( $body, $from_file, $vars );
    my $subject = sprintf '%s%s',
        ( length( $vars->{site} // '' ) ? "[$vars->{site}] "            : '' ),
        ( $TYPES{ $rec->{type} }        ? $TYPES{ $rec->{type} }{title} : 'Notice' );
    return send_mail( $docroot, to => $addr, subject => $subject, text => $text, what => 'notice',
        conf => $conf );
}

# SM1053 (n570): THE SITE'S MAIL TO ONE ACCOUNT, BOUNDED - steps 3 and 4 of a
# notice and the send, for every caller that mails an account at the address its
# own record holds. A notice is one; an account import's claim link, mailed when
# the operator chooses it, is the other. One transport and one per-hour bound,
# counted from one record, so a second caller cannot be a second way round it.
# Returns '' when the mail was sent, or the reason it was not.
sub send_mail {
    my ( $docroot, %m ) = @_;
    my $what = $m{what} // 'mail';
    my $conf = ref $m{conf} eq 'HASH' ? $m{conf} : _notify_conf($docroot);

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
        what => $what,
        axes => [ {
                name    => 'this site',
                limit   => ( $cap ? $cap : undef ),
                used    => _mail_sent_last_hour($docroot),
                window  => 'hour',
                setting => 'mail.per_hour in notify.conf',
        } ],
    );
    return $capwhy unless $ok;

    local $@;
    my $sent = eval { $MAIL_SENDER->( $docroot, $script, $m{to}, $m{subject}, $m{text} ) };
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
    local $SIG{PIPE} = 'IGNORE';    # SM959: a child that exits early must not kill us
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
#
# SM927: AND THE REASON, AS THE SECOND RETURN VALUE. X3 made these four states say
# which one they were - into the server error log, where the operator configuring
# the site cannot see it. The test action has to put the same sentence in front of
# them, so one reader answers both: the config, or why there is none.
#
# SM938 D2: A FORM'S `notify:` STATE, PARSED ONCE.
#
# This parse lived in plugins/form-handler.pl, which is a CGI - the manager cannot
# call it, so showing an operator what a form does with its notices would have
# meant a second reader of the same line. It lives here now and the handler calls
# it, so the page and the delivery path cannot disagree about what `notify: fll`
# means.
#
# Returns ( $mode, $unrecognised ): mode is off / on / full, defaulting to on,
# and the second value is the text that was not understood, if any - the caller
# decides whether to log it (the handler does; a report does not).
sub form_notify_mode {
    my ($text) = @_;
    for my $l ( split /\n/, ( $text // '' ) ) {
        next unless $l =~ /^notify\s*:\s*(.+?)\s*$/;
        my $raw = $1;
        my $v   = lc $raw;
        return ('off')  if $v =~ /^(?:0|off|false|no)$/;
        return ('full') if $v =~ /^full$/;
        return ('on')   if $v =~ /^(?:1|on|true|yes)$/;
        return ( 'on', $raw );
    }
    return ('on');
}

# SM938 D2: WHERE WILL THIS BE ANNOUNCED, AND IF NOT, WHAT SAYS NO?
#
# Whether a submission reaches XMPP is decided in three places - the form's
# `notify:`, the site's notify.conf (`emit.<type>`, `route.<type>`), and the
# extension plus its account - and only the last had any interface. So an
# operator could neither confirm from the manager that a form announces itself
# nor diagnose it when it did not.
#
# This answers it from the SAME checks delivery uses (_emits, _route,
# _xmpp_conf_state) rather than a description of them, so the report cannot say
# "reaches XMPP" about a notice delivery would drop. Read-only: the text stays the
# source of truth (the report's own condition), and this is what lets someone see
# what the text currently does.
#
#   reaches   endpoints a notice of this type will reach, in order
#   withheld  [ { endpoint, why } ] for each endpoint that will not, and the one
#             thing that decides it - the FIRST no, in the order delivery meets
#             them, because naming a later reason sends somebody to fix
#             something that is not the cause
#   mode      the form's own notify: state, when one was given
sub route_report {
    my ( $docroot, $type, $form_mode ) = @_;
    $type //= 'submission';
    my %r = ( type => $type, reaches => [], withheld => [] );
    $r{mode} = $form_mode if defined $form_mode;

    if ( defined $form_mode && $form_mode eq 'off' ) {
        push @{ $r{withheld} },
            { endpoint => 'all', why => "this form's own config says notify: off" };
        return \%r;
    }
    my $conf = _notify_conf($docroot);
    unless ( _emits( $conf, $type ) ) {
        push @{ $r{withheld} },
            { endpoint => 'all', why => "lazysite/notify.conf says emit.$type: off" };
        return \%r;
    }
    my $route = _route( $conf, $type );
    push @{ $r{reaches} }, 'bell';

    if ( !$route->{xmpp} ) {
        push @{ $r{withheld} }, { endpoint => 'xmpp',
            why => "lazysite/notify.conf routes $type to "
                . join( ',', sort keys %$route ) . ' - xmpp is not in it' };
    }
    else {
        my ( $xc, $why ) = _xmpp_conf_state($docroot);
        if   ($xc) { push @{ $r{reaches} },  'xmpp' }
        else       { push @{ $r{withheld} }, { endpoint => 'xmpp', why => $why } }
    }
    if ( $route->{email} ) {
        # Mail goes only to people who asked for it (SM485), so it is a reach
        # with a condition rather than a promise.
        push @{ $r{reaches} }, 'email';
        $r{email_note} = 'only to accounts that have opted in to mail notices';
    }
    $r{reaches_xmpp} = ( grep { $_ eq 'xmpp' } @{ $r{reaches} } ) ? 1 : 0;
    return \%r;
}

# RENAMED FROM `_xmpp_conf` ON PURPOSE. `return ( undef, $why )` in SCALAR context
# yields $why, which is a non-empty string and therefore true - so a call site left
# un-updated would have treated the reason as a config and gone on to send with it.
# A rename makes every such call site a compile-time failure instead. There were
# two (notify() and t/unit/lib/57).
sub _xmpp_conf_or_why {
    my ($docroot) = @_;
    my ( $c, $why, $log ) = _xmpp_conf_state($docroot);
    $log->() if $log;
    return ( $c, $why );
}

# SM938 D2: THE SAME CHECKS, WITHOUT THE LOGGING.
#
# route_report asks this question every time an operator opens the Handlers page,
# and _xmpp_conf_or_why logs a WARN for an unconfigured or incomplete account -
# right when a submission is being dropped, noise when somebody is merely looking.
# So the checks live here once and return the log line as a closure; the delivery
# path runs it and the report does not. Two copies of "is XMPP usable" would be
# the drift SM925 X3 spent a filing removing.
sub _xmpp_conf_state {
    my ($docroot) = @_;

    # SM925 X3: FOUR DISTINCT CAUSES returned undef here, none of them saying
    # anything - the extension off, no conf file, a conf that will not open, and a
    # conf missing a required key. An operator spent an afternoon over four
    # submissions on a site where the answer was one of them, and the code knew
    # which. Only the first is a deliberate state; the other three are faults and
    # now say so. The four-state rule SM906, SM907 and SM917 applied to the stores,
    # arriving on the notification path.
    return ( undef, 'XMPP notifications are switched off for this site.' )
        unless _plugin_enabled( $docroot, 'notify-xmpp.pl' );

    my $path = Lazysite::Paths::lazysite_dir($docroot) . "/notify-xmpp.conf";
    my $fh;
    if ( !open( $fh, '<', $path ) ) {    # not a store - the xmpp client config
        if ( $!{ENOENT} ) {
            return ( undef, 'There is no XMPP configuration yet - fill the '
                    . 'settings in and Save, then test.',
                sub {
                    log_event( 'WARN', 'notify',
                        'xmpp delivery is enabled and not configured, so nothing is sent',
                        file => $path );
                } );
        }
        my $err = "$!";
        return ( undef, "The XMPP configuration cannot be read ($path) - check "
                . 'its ownership and permissions.',
            sub { local $! = $err; cannot_read( 'the xmpp client config', $path ) } );
    }
    my %c;
    while ( my $l = <$fh> ) {
        $c{$1} = $2 if $l =~ /^(\w+)\s*:\s*(.*?)\s*$/;
    }
    close $fh;
    my @missing = grep { !length( $c{$_} // '' ) } qw(jid password to);
    if (@missing) {
        return ( undef, 'The XMPP configuration is incomplete: no '
                . join( ', ', @missing ) . '.',
            sub {
                log_event( 'WARN', 'notify',
                    'xmpp delivery is configured without a value it cannot work without, '
                        . 'so nothing is sent',
                    file    => $path,
                    missing => join( ', ', @missing ) );
            } );
    }

    # Default the sender nickname to the site name, sanitised to nick-safe
    # characters - so the ping reads as "My-Site: New form submission ...".
    unless ( length( $c{nick} // '' ) ) {
        my $name = _site_name($docroot);
        $name =~ s/[^A-Za-z0-9_-]+/-/g;
        $name =~ s/^-+|-+$//g;
        $c{nick} = length $name ? $name : 'lazysite';
    }
    return ( \%c, '' );
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

# SM1020 (SM1010 F3): A BELL NOTICE FOR ONE ACCOUNT, from a notification rule.
#
# Written straight to the bell store with `to` set, and NOT through notify():
# notify() routes by type, and a site that routed a type to its XMPP room would
# have put one member's notice in the operators' chat. A rule's bell notice is
# for its addressee and goes nowhere else. The reader (Lazysite::Manager::Notices)
# shows an addressed notice to that account only.
#
# Returns 1 when the line was written, 0 when it was not.
sub bell_for {
    my ( $docroot, $account, $n ) = @_;
    return 0 unless defined $docroot && defined $account && ref $n eq 'HASH';
    ( my $to = $account ) =~ s/[^a-zA-Z0-9_.\@-]//g;
    return 0 unless length $to && $to eq $account;
    my $msg = $n->{message} // '';
    $msg =~ s/[\r\n]+/ /g;
    return 0 unless length $msg;
    my $logdir = Lazysite::Paths::lazysite_dir($docroot) . "/logs";
    eval { require File::Path; File::Path::make_path($logdir) unless -d $logdir; 1 } or return 0;
    my %rec = ( ts => time(), type => ( $n->{type} // 'rule' ), message => $msg, to => $to,
        ( defined $n->{target} ? ( target => $n->{target} ) : () ),
        ( defined $n->{url}    ? ( url    => $n->{url} )    : () ) );
    open my $fh, '>>', "$logdir/notices.jsonl" or return 0;
    flock $fh, LOCK_EX;
    my $ok = print {$fh} JSON::PP::encode_json( \%rec ) . "\n";
    close $fh or return 0;
    return $ok ? 1 : 0;
}

# SM1020: the site's absolute address for a link a message carries - notify.conf's
# base_url, else site_url expanded - with no trailing slash, or '' when neither
# resolves (a daemon has no request to borrow a host from; see _site_url).
sub site_base {
    my ($docroot) = @_;
    my $conf      = _notify_conf($docroot);
    my $b         = $conf->{base_url};
    $b = _site_url($docroot) unless defined $b && length $b;
    $b = ''                  unless defined $b;
    $b =~ s{/+\z}{};
    return $b;
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

# SM925 X2: FIND THE ENDPOINT THE DOMAIN PUBLISHES.
#
# An operator configured a valid account on a live site and could not connect: the
# port had defaulted to 5222 while `dig +short SRV _xmpp-client._tcp.project.im`
# answered `10 0 47594 xmpp.project.im.` - a different host AND a different port,
# neither unusual, since SRV exists so the client-facing endpoint need not be the
# JID's domain. They had to run that lookup by hand and transcribe two values the
# code could have resolved itself.
#
# THIS IS A REGRESSION RATHER THAN A MISSING FEATURE, which is why it is twenty
# lines and not a design. notify-xmpp's own header says delivery is "based on the
# xmpp-lite connector"; XMPP::Lite resolves SRV and tracks whether the port was
# explicit, and this flow was derived from it WITHOUT those two clauses. Measured
# 2026-10-01: XMPP::Lite::_resolve_srv returns xmpp.project.im 47594 for that
# domain, and the notification hook on this host has been delivering through it.
#
# Two things it does that XMPP::Lite does not, both cheap:
#   - a TIGHT resolver timeout, because this runs in a CGI request and the 15s
#     alarm around the caller is the whole budget for DNS and the connection;
#   - a target of "." is refused. RFC 2782 says that means the service is
#     decidedly NOT available at this domain, and treating it as a hostname would
#     turn an explicit "no" into a connection attempt against nonsense.
#
# Returns () when there is no usable record, so the caller keeps <domain>:5222 -
# which is what a fallback is for. A failure to resolve is reported rather than
# swallowed: silence on this path is what cost the operator an afternoon (X3).
our $SRV_RESOLVER = \&_resolve_xmpp_srv;

# WHICH HOST AND PORT THIS SEND WILL USE - a decision with a name, so it can be
# tested without a network. It had no name, which is why the first version of
# t/unit/lib/61 reached the real server: the only way to observe the choice was to
# attempt the connection and read the host out of the failure message.
#
# THE RULE IS THE OPERATOR'S, and it is stricter than XMPP::Lite's: "either let SRV
# do its job or specify". SRV is consulted only when NEITHER host nor port is
# given; a conf naming either is obeyed exactly and nothing is looked up.
# XMPP::Lite tracks only whether the PORT was explicit, so it will replace a host
# the operator did set - and a host somebody typed is a specification.
#
# SM927: the third return value is WHERE the endpoint came from - conf, srv or
# default. The test action shows it, because "5222" and "5222 because nothing
# published anything else" send an operator to different places, and the whole of
# X2 was an operator who could not tell which of those they were looking at.
sub _xmpp_endpoint {
    my ( $conf, $domain ) = @_;
    my $host_named = length( $conf->{host} // '' )      ? 1             : 0;
    my $port_named = ( $conf->{port} // '' ) =~ /^\d+$/ ? 1             : 0;
    my $host       = $host_named                        ? $conf->{host} : $domain;
    my $port       = $port_named                        ? $conf->{port} : 5222;

    return ( $host, $port, 'conf' ) if $host_named || $port_named;

    my ( $srv_host, $srv_port ) = $SRV_RESOLVER->($domain);
    return ( $host, $port, 'default' ) unless length( $srv_host // '' );

    log_event( 'INFO', 'notify', 'xmpp endpoint resolved from the SRV record',
        domain => $domain, host => $srv_host, port => $srv_port );
    return ( $srv_host, $srv_port, 'srv' );
}

# How the endpoint was chosen, in words an operator reads on the test result.
my %ENDPOINT_SOURCE = (
    conf    => 'as configured',
    srv     => "from the domain's SRV record",
    default => 'the JID domain and the standard port - nothing else was published',
);

sub _resolve_xmpp_srv {
    my ($domain) = @_;
    my $name     = "_xmpp-client._tcp.$domain";
    my @found    = eval {
        require Net::DNS;
        my $res = Net::DNS::Resolver->new(
            udp_timeout => 3,
            tcp_timeout => 3,
            retry       => 1,
        );
        my $reply = $res->query( $name, 'SRV' );
        return () unless $reply;
        my @rr = sort { $a->priority <=> $b->priority || $b->weight <=> $a->weight }
            grep { $_->type eq 'SRV' } $reply->answer;
        return () unless @rr;
        my $target = $rr[0]->target // '';
        $target =~ s/\.\z//;    # the FQDN trailing dot
        return () if $target eq '' || $rr[0]->target eq '.';
        return ( $target, $rr[0]->port );
    };
    if ( !@found && length( $@ // '' ) ) {
        log_event( 'WARN', 'notify',
            'the xmpp SRV lookup failed, so the JID domain and port 5222 are used',
            record => $name, error => "$@" );
    }
    return @found;
}

# One-shot XMPP send, based on the xmpp-lite connector's connect/send flow
# (Net::XMPP::Client: Connect -> AuthSend -> chat MessageSend, or a MUC
# presence-join then a groupchat send). Time-boxed with alarm so a CGI request
# cannot hang on an unreachable chat server.
#
# SM927: AND IT RECORDS WHICH STAGE IT REACHED, when the caller hands it somewhere
# to record into. The test action is the caller that does; a notification does not,
# and the `if ref $steps` in $note is the whole of the difference. One flow, so what
# the test exercises is the delivery path itself rather than a parallel imitation of
# it - the thing that would otherwise agree with delivery right up to the release
# where it stopped agreeing.
sub _xmpp_send {
    my ( $conf, $text, $steps ) = @_;

    # Each stage says what happened as it happens, because the staging is only
    # useful if the record survives the die - "authenticated, then the send failed"
    # and "could not connect" send an operator to different settings.
    my $note = sub {
        push @{$steps}, { step => $_[0], ok => ( $_[1] ? 1 : 0 ), detail => $_[2] // '' }
            if ref $steps eq 'ARRAY';
        return;
    };

    # X1's fault, reported as a stage rather than as Perl's @INC paragraph: the
    # module is declared in the descriptor, so the enable path refuses without it -
    # but a site that lost the package after enabling still arrives here.
    unless ( eval { require Net::XMPP; 1 } ) {
        $note->( 'library', 0, 'Net::XMPP is not installed' );
        die "notify-xmpp: the XMPP client library is not installed "
            . "(Net::XMPP - on Debian, libnet-xmpp-perl)\n";
    }
    $note->( 'library', 1, 'Net::XMPP is installed' );

    my ( $user, $domain ) = ( $conf->{jid} // '' ) =~ /^([^@]+)\@(.+)$/;
    if ( !defined $domain ) {
        $note->( 'jid', 0, 'the client JID is not user@domain' );
        die "notify-xmpp: jid must be user\@domain\n";
    }
    my $tls  = ( $conf->{tls}        // '1' ) =~ /^(?:1|true|yes)$/i ? 1 : 0;
    my $nick = length( $conf->{nick} // '' ) ? $conf->{nick}             : 'lazysite';
    my $muc  = ( $conf->{muc}        // '' ) =~ /^(?:1|true|yes)$/i ? 1  : 0;

    # Declared here and ASSIGNED inside the alarm, because choosing them may cost
    # a DNS round trip (SM925 X2) and that belongs inside the time budget. The
    # connect-failure message below names both, which is the one thing this path
    # did well before X2 and must keep doing: it is what let the operator spot the
    # 5222-against-47594 mismatch.
    my ( $host, $port );
    local $SIG{ALRM} = sub { die "notify-xmpp: timed out\n" };
    alarm 15;    # network-bound: the XMPP peer, not this process (t/lint/120)
    my $client = Net::XMPP::Client->new();
    my $ok     = eval {
        # SM925 X2: the endpoint decision, and the SRV lookup in it, sit INSIDE
        # the alarm window on purpose. The 15 seconds is the budget for reaching
        # the chat server, and a resolver that cannot answer is part of not
        # reaching it - a DNS wait outside the alarm would be an unbounded hang in
        # a CGI by another name, which is what t/lint/120 and the comment above
        # exist to prevent.
        my $source;
        ( $host, $port, $source ) = _xmpp_endpoint( $conf, $domain );
        $note->( 'endpoint', 1,
            "$host:$port - " . ( $ENDPOINT_SOURCE{ $source // '' } // 'chosen' ) );

        unless (
            defined $client->Connect(
                hostname      => $host,
                port          => $port,
                tls           => $tls,
                componentname => $domain,
            )
            )
        {
            $note->( 'connect', 0, "nothing answered at $host:$port" );
            die "notify-xmpp: connect to $host:$port failed\n";
        }
        $note->( 'connect', 1, "connected to $host:$port" . ( $tls ? ' with TLS' : '' ) );

        my @auth = $client->AuthSend(
            username => $user,
            password => $conf->{password},
            resource => $nick,
        );
        if ( ( $auth[0] // '' ) ne 'ok' ) {
            $note->( 'auth', 0, "the server refused the account: $auth[0]" );
            die "notify-xmpp: auth failed: $auth[0]\n";
        }
        $note->( 'auth', 1, "signed in as $user as resource $nick" );

        if ($muc) {
            # Join the room (bare names get no default domain here - configure the
            # full room JID), then send as groupchat.
            my $p = Net::XMPP::Presence->new();
            $p->SetTo("$conf->{to}/$nick");
            $p->InsertRawXML('<x xmlns="http://jabber.org/protocol/muc"/>');
            $client->Send($p);

            # UNCONFIRMED, AND SAID SO. This path sends the join presence and reads
            # nothing back, so a room that refuses the join - members-only, wrong
            # password, no such room - is indistinguishable here from one that
            # accepted it. The filing hoped this stage would separate "authenticated
            # but the room said no" from "could not connect"; it separates them as
            # far as the protocol flow allows and no further, and claiming a join
            # succeeded because a packet left is the four-state fault in miniature.
            $note->( 'join', 1,
                "join sent to $conf->{to} as $nick - a room that refuses a join "
                    . 'does not answer this path, so a refusal shows up as the '
                    . 'message never arriving' );
            $steps->[-1]{unconfirmed} = 1 if ref $steps eq 'ARRAY';

            my $refused = _xmpp_send_and_await( $client, $conf->{to},
                sub { $client->MessageSend( to => $conf->{to}, body => $text, type => 'groupchat' ) },
                ( $conf->{_await_bounce} ? $XMPP_BOUNCE_WAIT : 0 ) );
            $note->( 'send', 1, "sent to the room $conf->{to} as groupchat" );
            _xmpp_delivery_step( $note, $steps, $conf, $refused );
        }
        else {
            my $refused = _xmpp_send_and_await( $client, $conf->{to},
                sub { $client->MessageSend( to => $conf->{to}, body => $text, type => 'chat' ) },
                ( $conf->{_await_bounce} ? $XMPP_BOUNCE_WAIT : 0 ) );
            $note->( 'send', 1, "sent to $conf->{to} as a chat message" );
            _xmpp_delivery_step( $note, $steps, $conf, $refused );
        }
        1;
    };
    my $err = $@;
    eval { $client->Disconnect() };
    alarm 0;
    die $err unless $ok;
    return 1;
}

# SM955 (ruled R9): A REFUSED RECIPIENT IS A FAILED TEST.
#
# The server accepts a message to a JID it cannot deliver to and answers with an
# error stanza AFTER the send - `item-not-found`, `remote-server-not-found`,
# `service-unavailable`. This path used to disconnect straight after sending, so
# the test reported "sent" for a recipient that does not exist (the 0.15.2 edge
# walk, R4). The callback is set BEFORE the send so a fast bounce is not missed;
# then the stream is read for up to $secs. Only the TEST waits: a real notice is
# sent while a visitor's form submission is waiting for its reply, so it does
# not pay three seconds for this.
#
# Returns '' when nothing was refused, else the server's condition (and text).
sub _xmpp_send_and_await {
    my ( $client, $to, $send, $secs ) = @_;
    my $refused = '';
    ( my $bare_to = lc( $to // '' ) ) =~ s{/.*}{}s;
    my ($to_domain) = $bare_to =~ /\@(.+)\z/;
    $to_domain //= $bare_to;    # a room or a bare domain: the bounce comes from it
    if ($secs) {
        $client->SetMessageCallBacks( error => sub {
                my ( undef, $msg ) = @_;
                # From the XML: GetXML is a real method; the Get* accessors are made
                # on demand by AUTOLOAD and `can` does not see them.
                my $xml = eval { $msg->GetXML() } // '';
                my ($from) = $xml =~ m{\A\s*<message\b[^>]*\bfrom=["']([^"']+)};
                $from = lc( $from // '' );
                $from =~ s{/.*}{}s;
                return if length $from && $from ne $bare_to && $from ne $to_domain;
                my ($cond) = $xml =~ m{<error\b[^>]*>.*?<([a-z-]+)\b[^>]*xmlns=["']urn:ietf:params:xml:ns:xmpp-stanzas}sx;
                my ($why) = $xml =~ m{<text\b[^>]*>([^<]*)</text>}s;
                $refused = ( $cond // 'error' ) . ( defined $why && length $why ? ": $why" : '' );
        } );
    }
    $send->();
    my $until = time + ( $secs || 0 );
    while ( $secs && !length $refused && time < $until ) {
        last unless defined $client->Process(0.5);    # undef: the stream closed
    }
    return $refused;
}

# The delivery stage, said only when the bounce was awaited.
sub _xmpp_delivery_step {
    my ( $note, $steps, $conf, $refused ) = @_;
    return unless $conf->{_await_bounce};
    if ( length $refused ) {
        $note->( 'delivery', 0, "the server refused delivery to $conf->{to}: $refused" );
        die "notify-xmpp: the server refused delivery to $conf->{to} ($refused)\n";
    }
    $note->( 'delivery', 1, "no refusal from the server within $XMPP_BOUNCE_WAIT seconds" );
    return;
}

# SM955 (ruled R9): every delivery failure, from the test or a real notice, is in
# the audit log, so it can be exported. The bell and STDERR said it before; the
# audit trail is the record an operator keeps.
sub _audit_delivery_failure {
    my ( $docroot, $to, $err, $origin ) = @_;
    $err = defined $err ? "$err" : '';
    $err =~ s/\A\s*notify-xmpp:\s*//;
    $err =~ s/\s+\z//;
    eval {
        require Lazysite::Audit;
        no warnings 'once';
        local $Lazysite::Audit::LAZYSITE_DIR = $Lazysite::Audit::LAZYSITE_DIR
            // Lazysite::Paths::lazysite_dir($docroot);
        Lazysite::Audit::audit_log( '', 'notify', 'xmpp -> ' . ( $to // '' ), '', 'failed', $origin, $err );
        1;
    } or log_event( 'WARN', 'notify', 'delivery failure not audited', error => "$@" );
    return;
}

# --- SM927: the test an operator can run before anything real happens ---------
#
# form-smtp declares a `validate` action and the config page shows a button for
# it. notify-xmpp declared no actions at all, so an operator who had just typed
# eight fields including a password had no way to learn whether any of it worked
# until an event fired - and the whole shape of this plugin's failure is that when
# one does fire, nothing tells them: an XMPP notice that never arrives looks
# exactly like a site where nothing has happened.
#
# THE DAY'S OWN RECORD IS THE ARGUMENT. Three defects were filed on 2026-09-30 from
# one afternoon, and this button answers each in one press: X1 (Net::XMPP not
# installed) as a `library` stage, X2 (port 5222 asserted over an SRV record giving
# 47594) as an `endpoint` stage naming where the endpoint came from, and SM926 (a
# body carrying `${REQUEST_SCHEME}://${SERVER_NAME}`) because the rendered message
# is SHOWN rather than summarised. That last one was invisible for the whole
# afternoon and became obvious the moment a human read what had been sent.
#
# WHAT IT IS NOT: a notify() call. No bell row is written, because the reporter's
# only available test WAS a real submission - which left a stored row only a person
# can delete (SM924), and only exercised this path at all if it escaped the spam
# quarantine (SM216). A test that leaves evidence behind, and can fail for a reason
# that has nothing to do with what is being tested, is not a test.

# The body the test sends, through the SAME template machinery a notice uses - so a
# site that overrode default.xmpp has its own template tested, and an operator sees
# the link a real notice would carry on this site rather than a promise about it.
#
# IT HAS TO READ AS A TEST. The recipient is often a room a team shares, and a test
# that reads like a real alert teaches people to ignore real alerts.
sub _test_body {
    my ($docroot) = @_;
    my $conf      = _notify_conf($docroot);
    my %vars      = (
        message => 'TEST - this is the XMPP delivery test from the Lazysite '
            . 'manager, sent by hand at '
            . scalar( localtime time ) . '. Nothing needs doing.',
        type   => 'test',
        target => '',
        to     => '',
        url    => '/manager/plugins',
        site   => _site_name($docroot),
        base   => ( $conf->{base_url} // _site_url($docroot) ),
    );
    $vars{base} =~ s{/+$}{} if defined $vars{base};
    my ( $body, $from_file ) = _template( $docroot, 'test', 'xmpp' );
    return _render( $body, $from_file, \%vars );
}

# Run the test and report every stage it reached. Returns the plugin action's
# result: ok, the stage it stopped at, the steps, the body as sent, and either a
# one-line verdict or the reason it failed.
#
# THE STEP-BY-STEP IS THE POINT, not the pass/fail. A bare failure sends an
# operator back through all eight fields; a named stage sends them to one of them.
sub test_xmpp {
    my ($docroot) = @_;
    my @steps;

    my ( $conf, $why ) = _xmpp_conf_or_why($docroot);
    return { ok => 0, stage => 'config', steps => \@steps, error => $why }
        unless $conf;
    push @steps, {
        step   => 'config',
        ok     => 1,
        detail => "sending as $conf->{jid} to $conf->{to}"
            . ( ( $conf->{muc} // '' ) =~ /^(?:1|true|yes)$/i ? ' (a group chat room)' : '' ),
    };

    my $text = _test_body($docroot);

    # Through $XMPP_SENDER, which is the hook notify() delivers through, so this
    # tests the path in use and not a second one that resembles it.
    my $ok = eval { $XMPP_SENDER->( { %$conf, _await_bounce => 1 }, $text, \@steps ); 1 }; # SM955
    my $err = $@ // '';
    $err =~ s/\A\s*notify-xmpp:\s*//;
    $err =~ s/\s+\z//;

    if ($ok) {
        my ($endpoint) = grep { $_->{step} eq 'endpoint' } @steps;
        my ($awaited)  = grep { $_->{step} eq 'delivery' } @steps;
        return {
            ok      => 1,
            stage   => 'ok',
            steps   => \@steps,
            sent    => $text,
            message => "Test message sent to $conf->{to}"
                . ( $endpoint ? ' via ' . $endpoint->{detail} : '' )
                . ( $awaited
                ? ". The server raised no refusal within $XMPP_BOUNCE_WAIT seconds. Check that it "
                    . 'arrived - a server can still drop a message silently.'
                : '. Check that it arrived - a server can accept a message it '
                    . 'then declines to deliver.' ),
        };
    }

    # A stage that died rather than returning a failure recorded nothing, so the
    # step it died in is named here. Without this the result would report the last
    # stage that SUCCEEDED as the place it stopped, which is the opposite of true.
    push @steps, { step => 'send', ok => 0, detail => $err }
        unless grep { !$_->{ok} } @steps;
    my ($failed) = grep { !$_->{ok} } @steps;
    _audit_delivery_failure( $docroot, $conf->{to}, ( length $err ? $err : $failed->{detail} ), 'test' );

    return {
        ok    => 0,
        stage => $failed->{step},
        steps => \@steps,
        sent  => $text,
        error => "The test stopped at '$failed->{step}': "
            . ( length $err ? $err : $failed->{detail} ),
    };
}

1;
