#!/usr/bin/perl
# lazysite-form-handler.pl - form POST receiver, validation, dispatch
use strict;
use warnings;
use POSIX       qw(strftime);
use Digest::SHA qw(hmac_sha256_hex);
use Fcntl       qw(:flock O_RDWR O_CREAT);
use DB_File;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use JSON::PP       qw(encode_json decode_json);

my $LOG_COMPONENT = 'form-handler';

if ( grep { $_ eq '--describe' } @ARGV ) {
    print encode_json( {
            id   => 'form-handler',
            name => 'Form Handler',
            # SM842: the handler types, and which form calls which handler, are
            # the handler contract's (Lazysite::Handlers) - listed by
            # handler-list and configured on the Handlers page - rather than
            # this plugin's to declare. It receives a POST and hands it on.
            description => 'Receives form submissions and hands each to the handlers its form '
                . 'names. Delivery is configured on the Handlers page.',
            version       => '2.0',
            config_file   => '',
            config_schema => [],
            actions       => [],
    } );
    exit 0;
}

my $DOCROOT = $ENV{DOCUMENT_ROOT} || $ENV{REDIRECT_DOCUMENT_ROOT}
    or die "DOCUMENT_ROOT not set\n";

# SM842: DELIVERY IS THE HANDLER CONTRACT'S, SO THE MODULE TREE IS REQUIRED.
#
# This plugin used to be module-free, so that a missing lib cost a member a
# rate-limit waiver and never anybody a submission. That held only for the
# file, email and webhook targets it carried copies of; the table and connector
# targets needed the lib all along. There is one implementation of delivery
# now, in Lazysite::Handlers, which the timer calls too - two copies would be
# two answers to "where did this submission go". A host where the tree cannot
# be found refuses the submission with the message below, which is the honest
# outcome: the visitor is not thanked for something that was not delivered.
_locate_lib();
my $HANDLERS_OK  = eval { require Lazysite::Handlers; require Lazysite::Paths; 1 };
my $HANDLERS_ERR = $HANDLERS_OK ? '' : ( $@ || 'unknown' );
# SM850: the engine tree is wherever the resolver finds it - a site that moved it
# out of the docroot keeps its form configs there. Without the modules nothing
# below runs: the submission is refused before any of it is read.
my $LAZYSITE_DIR = $HANDLERS_OK ? Lazysite::Paths::lazysite_dir($DOCROOT) : undef;
my $FORMS_DIR    = defined $LAZYSITE_DIR ? "$LAZYSITE_DIR/forms"          : undef;
{
    no warnings 'once';    # SM557: set at runtime, read by the module
    $Lazysite::Handlers::DOCROOT = $DOCROOT if $HANDLERS_OK;
}
# SM415: where a native (no-JS) post redirects back to, captured after
# parse_post and consumed by respond_ok/respond_error at the bottom -
# declared here because the capture site precedes them in file order.
our ( $REDIRECT_PAGE, $REDIRECT_FORM ) = ( '', '' );
# SM888 A7: which anti-spam control refused this POST, set by reject() /
# reject_user() and read once by the catch at the bottom of the main eval.
# Declared HERE for the same reason as the pair above - the catch precedes the
# subs in file order, and `our` scopes from its point of declaration, so
# declaring it beside the subs is a compile error under strict rather than a
# silent empty value. The reasoning for the mechanism is with those subs.
our $BLOCK_REASON = '';

# SM579: THE SENTENCES A SUCCESSFUL SUBMISSION MAY BE TOLD, keyed by the outcome
# token that selects one. Declared HERE for the third time for the same
# file-order reason as the two above - the main flow chooses a sentence long
# before respond_ok defines how it is delivered, and `our` beside respond_ok is a
# compile error under strict rather than a silent empty value. (SM912 spent ten
# failing assertions on exactly that shape, with `our $PROBE_NOBODY` sitting below
# a main flow that ran at the top.)
#
# THE PROCESSOR'S BANNER HOLDS THE SAME TWO SENTENCES. It has to: the JS path
# takes them from here in JSON, the no-JS path gets a redirect carrying only the
# TOKEN, and the render path is module-free (ADR 0001) so it cannot read this
# file. That is the situation _acl_allows_read is in, and it gets the same
# treatment - carry the copy, and make t/lint/156 responsible for the agreement.
our %OUTCOME_SAID = (
    ok => 'Thank you - your message has been sent.',
    # A connector delivered: the submission left for a service rather than
    # reaching a person. True whether or not the connector keeps an answer, and it
    # promises neither a reply nor a page.
    'ok-processing' =>
        'Thank you - your submission has been received and sent for processing.',
);

# Hard ceiling on a POST body, so a hostile upload can't exhaust memory before the
# per-form size limits are even checked. Generous; real limits are per-form.
my $MAX_POST_BYTES = 64 * 1024 * 1024;

# N141B: the largest a single submitted FIELD may be.
#
# There was no such constant. Every field was passed through
# sanitise_header($v, 10000), which TRUNCATES - so a value longer than ten
# thousand characters was silently cut and the row stored with ok. A signature
# captured as a data URL arrived with a valid PNG header and no IEND: not a
# rejected submission, a corrupt one recorded as good. A corrupt value stored
# with an ok is worse than a refused one, because nothing downstream can tell
# it happened.
#
# Ten thousand bytes was 0.015% of the request this handler already accepts,
# so it protected nothing that $MAX_POST_BYTES was not already protecting - it
# only decided, silently, which submissions would be damaged rather than
# refused.
#
# One mebibyte, and it REFUSES, naming the field. Generous enough that no
# ordinary text field, long essay or captured signature reaches it, small
# enough to stay a sane per-field bound well inside the request cap.
my $MAX_FIELD_BYTES = 1024 * 1024;
# SM523: the underscore keys a CLIENT may send (see parse_post).
my %PROTOCOL_KEY = map { $_ => 1 } qw(_form _page _hp _ts _tk);

# --- Main ---

my $name = '';    # hoisted so the catch below can attribute a block to its form
eval {
    reject('Method not allowed')
        unless ( $ENV{REQUEST_METHOD} // '' ) eq 'POST';

    my %form = parse_post();
    $name = $form{_form} // '';
    $name =~ s/[^a-zA-Z0-9_-]//g;
    reject('Missing form name') unless $name;

    # SM415: capture where a native post goes back to, BEFORE any check can
    # die - the redirect answers refusals too. Validation is the whole guard
    # against an open redirect: same-site absolute path or nothing.
    {
        my $pg = $form{_page} // '';
        if ( $pg =~ m{\A/} && $pg !~ m{\A//} && $pg !~ /[\r\n]/ && length($pg) <= 500 ) {
            $REDIRECT_PAGE = $pg;
            $REDIRECT_FORM = $name;
        }
    }

    # SM402: this handler reads NO identity from the request, because it has no
    # way to verify one.
    #
    # It is not behind the auth wrapper - the shipped templates front only
    # lazysite-processor.pl and lazysite-manager-api.pl, and /cgi-bin/ is
    # otherwise a plain ScriptAlias - so the processor's trust-header stripping
    # never runs for it and HTTP_X_REMOTE_USER arrives exactly as the client
    # sent it. There is no configuration under which it could be trusted here:
    # `auth_proxy_trusted` is consulted by the processor, on the request the
    # processor handles, and this handler cannot tell a proxied identity from an
    # invented one.
    #
    # It used to be recorded twice. `_auth_user` on the submission was DEAD -
    # every delivery target skips _-prefixed keys, so it never reached a stored
    # record, an email or a webhook. The audit entry was not: an unverifiable
    # name went into the actor column of lazysite/logs/audit.log, the shared
    # trail every other surface writes to with an identity it HAS verified.
    # A forged name there is a false record in the one artefact whose whole
    # purpose is to say who did something.
    #
    # A public form submission has no verified actor, so it is recorded as
    # having none. The address is still logged, which is the fact that is
    # actually known.

    unless ($HANDLERS_OK) {
        log_event( 'ERROR', $name,
            'the engine modules could not be loaded, so this form cannot deliver',
            error => $HANDLERS_ERR );
        reject_user( 'This form is not accepting submissions right now. '
                . 'Please contact the site owner.' );
    }
    my $conf = load_form_conf($name);

    check_honeypot( $form{_hp} // '' );
    check_timestamp( $form{_ts} // '', $form{_tk} // '', load_form_secret(),
        $conf->{timestamp_window} );

    # SM425: a signed-in member is not the traffic the anonymous rate limit
    # exists to stop, and meeting it mid-form reads as the site being broken.
    # The session cookie is verified CRYPTOGRAPHICALLY (SM411's shared
    # verifier - HMAC over the payload, registry and account checks inside),
    # which is different in kind from the header identity SM402 rightly
    # stripped: nothing here reads X-Remote-User, and the verified name is
    # used as a BOOLEAN for this one decision - it is not recorded on the
    # submission, not written to the audit actor column, and not passed to
    # any handler. The submission stays actor-less; only the limiter learns
    # that SOME verified member is asking.
    # The module tree was located at start-up (SM473: `prove -l` puts lib/ on
    # @INC and a real install does not). The attempt still degrades to
    # ANONYMOUS on any failure, because a broken exemption must cost a member
    # a rate limit, never anybody a form.
    my $signed_in = eval {
        # SM557: the package is require'd at runtime, so this file mentions the
        # variable once by design - t/lint/04 refuses the 'used only once' warning.
        no warnings 'once';
        require Lazysite::Auth::Session;
        local $Lazysite::Auth::Session::LAZYSITE_DIR = $LAZYSITE_DIR;
        my ($session) = Lazysite::Auth::Session::verify_session_cookie();
        ( ref $session eq 'HASH' ) ? 1 : 0;
    } // 0;
    if ($signed_in) {
        log_event( 'INFO', 'form', 'rate limit waived: verified session' );
    }
    else {
        check_rate_limit( $ENV{REMOTE_ADDR} // '0.0.0.0', $conf->{rate_limit} );
    }

    # Binary uploads: reject up front (before any handler runs) if the form does
    # not accept files, or a file breaks the form's size / type / count limits.
    if ( my $files = $form{_files} ) {
        reject_user('This form does not accept file uploads.') unless $conf->{upload};
        validate_uploads( $files, $conf->{upload} );
    }

    # Reject a contentless submission - every visible field blank and no file
    # uploaded. HTML5 `required` stops this in a browser, so it is almost always an
    # automated/blank POST; saving a "thank you" + an empty record is worse than an
    # honest error.
    my $has_content = ( $form{_files} && @{ $form{_files} } ) ? 1 : 0;
    unless ($has_content) {
        for my $k ( keys %form ) {
            next if $k =~ /^_/;
            if ( defined $form{$k} && $form{$k} =~ /\S/ ) { $has_content = 1; last }
        }
    }
    reject_user('Please fill in the form before submitting.') unless $has_content;

    # SM216: score the (valid) submission; a suspect one is STORED but flagged so
    # it stays out of the notification bell and lands under the Quarantine filter.
    my ( $quarantined, $spam_reason ) = _spam_assessment( \%form, $conf );
    if ($quarantined) {
        $form{_quarantined} = 1;
        $form{_spam_reason} = $spam_reason;
    }

    # SM842: each target NAMES a handler, and the handler contract delivers -
    # the same code the schedule calls, one audit line per handler.
    my $handlers  = Lazysite::Handlers::read_handlers();
    my $delivered = 0;
    my $processed = 0;    # SM579: a connector took it onward, see below
    for my $id ( @{ $conf->{targets} } ) {
        my $r = Lazysite::Handlers::deliver(
            $id, { _visible_fields( \%form ) },
            origin      => 'form',
            source      => "form:$name",
            store       => $name,
            ip          => $ENV{REMOTE_ADDR} // '',
            actor       => '',                        # SM402: no verified actor
            files       => $form{_files},
            quarantined => $form{_quarantined},
            spam_reason => $form{_spam_reason},
            ( defined $handlers ? ( handlers => $handlers ) : () ),
        );
        $delivered++ if $r->{ok};
        # SM579: DID ANYTHING LEAVE THE SITE FOR A SERVICE? A connector handler
        # sends the submission onward to be processed rather than to a person, so
        # "your message has been sent" is the one thing that did not happen. The
        # type comes from deliver's own answer, not from reading the conf again.
        $processed++ if $r->{ok} && ( $r->{type} // '' ) eq 'connector';
    }

    # If NOTHING actually accepted the submission - every target disabled, unknown,
    # or failed (e.g. the form handler / its delivery plugin is turned off) - the
    # submission was NOT saved. Fail loudly instead of showing a false "thank you".
    unless ($delivered) {
        log_event( 'ERROR', $name, 'form not delivered - no active target',
            ip => $ENV{REMOTE_ADDR} // 'unknown' );
        # SM781: "no active delivery target" sent the OWNER to the binding
        # when a connector had refused the mode; the record already holds the
        # reason. Say what happened - nothing accepted it - and where to look.
        reject_user( 'This form is not accepting submissions right now '
                . '(nothing accepted the submission: its delivery is switched off '
                . 'or refused it - the site owner can see why in the event log). '
                . 'Please contact the site owner.' );
    }

    log_event( 'INFO', $name, 'form received', ip => $ENV{REMOTE_ADDR} // 'unknown' );
    _audit_submission( $name, '', $ENV{REMOTE_ADDR} // '' );    # SM402: no verified actor
        # SM216: a quarantined (suspect) submission is stored but does NOT ring the
        # bell - the sysop finds it under the Submissions Quarantine filter.
    _notify_submission( $name, $conf->{notify_off} )
        unless $form{_quarantined};    # SM113 badge
    _record_form_event( $name, $form{_quarantined} ? 'quarantined' : 'stored' ); # SM216-2
        # SM579: WHICH TRUE SENTENCE. A connector delivered means the submission left
        # for a service, so it was received and sent for processing - which is what
        # happened, and it promises neither a reply nor a page, because only the author
        # knows whether the site shows the answer anywhere. Everything else keeps the
        # sentence it had.
    my $outcome = $processed ? 'ok-processing' : 'ok';
    respond_ok( $OUTCOME_SAID{$outcome}, $outcome );
};
if ($@) {
    my $err = $@;
    $err =~ s/\s+$//;
    log_event( 'ERROR', $name, 'processing failed', error => $err, ip => $ENV{REMOTE_ADDR} // 'unknown' );
    # SM216-2: an anti-spam control blocked this POST - count it (per form, by
    # reason) so the report shows "controls stopped N", not silence. The code
    # comes from the control that fired, not from the message it printed.
    if ( length $BLOCK_REASON ) { _record_form_event( $name, 'blocked', $BLOCK_REASON ); }
    # USER: messages (e.g. upload too large / wrong type) are safe to show the
    # submitter; everything else gets a generic message.
    if ( $err =~ /^USER:(.*)/s ) { respond_error($1); }
    else { respond_error('An error occurred - please try again.'); }
}

# --- Config ---

# SM231: is a top-level boolean key explicitly OFF in a form's own config
# text? Absent, unparseable or anything else => 0 (not off), so the caller's
# default stands.
sub _conf_flag_off {
    my ( $text, $key ) = @_;
    my $off = 0;
    for my $l ( split /\n/, ( $text // '' ) ) {
        next unless $l =~ /^\Q$key\E\s*:\s*(.+?)\s*$/;
        $off = ( $1 =~ /^(?:0|off|false|no)$/i ) ? 1 : 0;
        last;
    }
    return $off;
}

# Optional binary-upload constraints. Present any of these keys to enable file
# uploads on the form; absent (undef) = the form accepts no files.
#   upload_max_kb:    <int>           max size of EACH file, KiB
#   upload_max_files: <int>           max number of files per submission
#   upload_accept:    jpg, png, pdf   allowed extensions (also matched loosely
#                                     against the part's Content-Type)
sub _upload_rules {
    my ($text) = @_;
    return undef unless $text =~ /^\s*upload_(?:max_kb|max_files|accept)\s*:/m;
    my ($kb)   = $text =~ /^\s*upload_max_kb\s*:\s*(\d+)/m;
    my ($maxn) = $text =~ /^\s*upload_max_files\s*:\s*(\d+)/m;
    my ($acc)  = $text =~ /^\s*upload_accept\s*:\s*(.+?)\s*$/m;
    my @accept = grep { length }
        map { my $x = lc $_; $x =~ s/^\s+|\s+$//g; $x =~ s/^\.//; $x }
        split /[,\s|]+/, ( $acc // '' );
    return {
        max_kb    => ( $kb   ? $kb + 0   : 5120 ),    # 5 MiB default
        max_files => ( $maxn ? $maxn + 0 : 5 ),
        accept    => \@accept,                        # empty = any type
    };
}

sub load_form_conf {
    my ($name) = @_;
    my $path = "$FORMS_DIR/$name.conf";
    reject("Form '$name' not configured") unless -f $path;

    open( my $fh, '<:utf8', $path ) or reject("Cannot read form config");
    my $text = do { local $/; <$fh> };
    close $fh;

    # SM842: a form's targets name handlers and nothing else. An inline target
    # left in a config the upgrade did not reach is said in the log - it is
    # never delivered, because delivering it would be a second way to name a
    # destination, one no listing shows and nobody with the destination's
    # permission vetted.
    my ( $ids, $inline ) = Lazysite::Handlers::parse_form_conf($text);
    log_event( 'ERROR', $name, 'this form has inline targets, which no longer deliver - '
            . 'run lazysite-handlers.pl convert (SM842)', count => scalar @$inline )
        if @$inline;
    my @targets = @$ids;
    reject("No targets configured for form '$name'") unless @targets;

    my $upload = _upload_rules($text);

    # SM401: per-form submission ceiling, submissions per address per hour.
    # Absent leaves the shipped default of 5; `off` (or 0) removes the limit for
    # a form whose access is already controlled another way.
    my $rate_limit;
    if ( my ($rl) = $text =~ /^\s*rate_limit\s*:\s*(\S+)/m ) {
        $rate_limit = ( lc $rl eq 'off' || lc $rl eq 'none' ) ? 0
            : ( $rl =~ /^\d+$/ ) ? $rl + 0
            :                      undef;
    }

    # SM501: per-form validity window for the render timestamp, in seconds.
    # Absent leaves the shipped 7200 (two hours). A long careful form crosses
    # two hours as the ORDINARY case, and the refusal lands after the typing -
    # which is the worst possible moment for it. `off` removes the age ceiling
    # for a form whose access is controlled another way; the HMAC and the
    # too-fast floor are unaffected either way, so this relaxes staleness and
    # nothing else.
    my $ts_window;
    if ( my ($tw) = $text =~ /^\s*timestamp_window\s*:\s*(\S+)/m ) {
        $ts_window = ( lc $tw eq 'off' || lc $tw eq 'none' ) ? 0
            : ( $tw =~ /^\d+$/ ) ? $tw + 0
            :                      undef;
    }

    # SM216: per-form quarantine scoring config. quarantine defaults ON - a false
    # positive still arrives (just unannounced, under the Quarantine filter), so
    # cheap heuristics are safe on by default. spam_keywords is a comma-separated
    # operator list; spam_url_threshold is the min URL count that flags (default 2).
    my ($q)  = $text =~ /^\s*quarantine\s*:\s*(\S+)/m;
    my ($kw) = $text =~ /^\s*spam_keywords\s*:\s*(.+?)\s*$/m;
    my ($ut) = $text =~ /^\s*spam_url_threshold\s*:\s*(\d+)/m;

    return {
        targets            => \@targets,
        upload             => $upload,
        notify_off         => _conf_flag_off( $text, 'notify' ),    # SM231
        quarantine         => ( defined $q  ? $q      : 'on' ),
        spam_keywords      => ( defined $kw ? $kw     : '' ),
        spam_url_threshold => ( defined $ut ? $ut + 0 : 2 ),
        rate_limit         => $rate_limit,    # SM401; undef = default
        timestamp_window   => $ts_window,     # SM501; undef = default, 0 = off
    };
}

# SM216: quarantine scoring - store-but-flag a suspect submission (kept out of the
# notification bell, shown under the Submissions Quarantine filter) rather than
# reject it. A false positive costs nothing (the message still arrives, just
# unannounced), which is what makes cheap content heuristics safe on by default.
# Signals: >= spam_url_threshold LINKS in the visible text (see _count_links -
# SM913 S1 widened this from "written with a scheme" to "written by somebody"),
# any operator keyword, and a submission whose fields are one value said three
# times (_one_value_everywhere, SM913 S3).
# Returns (0|1, reason). Content-based and server-side - no tracker, no CAPTCHA.
sub _spam_assessment {
    my ( $form, $conf ) = @_;
    return ( 0, '' )
        if lc( $conf->{quarantine} // 'on' ) =~ /^(?:0|off|no|false|disabled)$/;

    my $text = '';
    for my $k ( keys %$form ) {
        next if $k =~ /^_/;
        $text .= ' ' . $form->{$k}
            if defined $form->{$k} && !ref $form->{$k};
    }

    my @reasons;
    my $threshold = ( $conf->{spam_url_threshold} // 2 ) + 0;
    my $urls      = _count_links($text);
    # The WORD stays "urls" though the counting widened: it is stored in every
    # quarantined record and read back by the Submissions page, and a rename
    # would leave the store holding two spellings of one fact for no gain.
    push @reasons, "$urls urls" if $threshold > 0 && $urls >= $threshold;

    if ( defined $conf->{spam_keywords} && length $conf->{spam_keywords} ) {
        for my $kw ( split /\s*,\s*/, $conf->{spam_keywords} ) {
            next unless length $kw;
            if ( $text =~ /\Q$kw\E/i ) { push @reasons, "keyword '$kw'"; last }
        }
    }

    if ( my $host = _disguised_link($text) ) { push @reasons, "a link written as '$host'" }
    if ( my $why = _one_value_everywhere($form) ) { push @reasons, $why }

    return @reasons ? ( 1, join( ' + ', @reasons ) ) : ( 0, '' );
}

# SM913 S1: COUNT THE LINKS SOMEBODY WROTE, not the ones written with a scheme.
#
# The count used to be `() = $text =~ m{https?://}gi`, and the spam that arrived
# on a live form for two months wrote its opt-out host as `brnd .li/delist` - a
# link-shortener with a SPACE inserted, which is the shape used to defeat link
# filters and which that pattern cannot see at all. It was the one marker present
# in all three sales pitches.
#
# THREE SHAPES, AND DELIBERATELY NOT A FOURTH. A scheme; a `www.` host; a host
# with a path. A BARE `example.com` in prose is NOT counted, and that omission is
# the whole reason this is safe to turn on for everybody:
#
#   * `photo.png`, `report.pdf`, `Node.js` - a filename is a host-shaped thing
#     with no path and no www, and counting it would flag somebody describing
#     their own attachment.
#   * `ada@example.net` - an address is a host-shaped thing too. Addresses are
#     removed before anything is counted. Measured, that strip is narrower than
#     it first looks: a BARE host is not counted anyway, so an ordinary address
#     was never going to score. What it actually protects against is an address
#     followed by a path - `sales@host.tld/x`, and the free-mail senders in the
#     reported spam - so it is defence in depth rather than the load-bearing
#     guard. Saying so because the first version of this comment claimed more.
#
# Each match counts once however it is written, so a pitch quoting one host three
# ways is one link, not three.
sub _count_links {
    my ($text) = @_;
    return 0 unless defined $text && length $text;

    # Addresses first: the local part would otherwise leave a bare host behind.
    ( my $t = $text ) =~ s/\S+@\S+//g;

    # `www.` is stripped from the KEY, or one site named twice - once with the
    # prefix and once without, which is how people actually write - counts as two
    # links and reaches a threshold of two on its own.
    my %seen;
    my $note = sub { ( my $h = lc $_[0] ) =~ s/\Awww\.//; $seen{$h}++ if length $h };

    while ( $t =~ m{https?://([^\s/]+)}gi )                       { $note->($1) }
    while ( $t =~ m{\b((?:www\.)[a-z0-9-]+(?:\.[a-z0-9-]+)+)}gi ) { $note->($1) }
    while ( $t =~ m{\b([a-z0-9-]+(?:\.[a-z0-9-]+)+)/\S}gi )       { $note->($1) }

    # And the shape the field actually found - see _disguised_link.
    if ( my $host = _disguised_link($t) ) { $note->($host) }

    return scalar keys %seen;
}

# SM913 S1, the part that is a signal on its own rather than a countable link.
#
# `brnd .li/delist` - a host with a SPACE before its top-level domain and a path
# after it. The reported spam wrote its shortener that way twice in one message,
# which is the marker present in all three sales pitches, and the reason is that
# it defeats a link filter while still being readable to a person who retypes it.
#
# COUNTING IT WAS NOT ENOUGH, and the real message is why: both of its links were
# the SAME host, and this counter deduplicates by host on purpose - so a pitch
# quoting one shortener twice scored one link against a threshold of two and
# sailed through. Deduplicating is right (a person naming one site three ways is
# not three links) and so the disguise has to be its own reason.
#
# THE PATH IS WHAT MAKES IT SAFE. Without it, `... at the shop .Then I left` -
# a space before a full stop, which sloppy typing does produce - would match.
# With it, the string has to look like somebody typing a link they did not want
# read as one, and nothing honest has that shape.
sub _disguised_link {
    my ($text) = @_;
    return '' unless defined $text && length $text;
    return lc "$1.$2" if $text =~ m{\b([a-z0-9-]{2,})\s+\.([a-z]{2,6})/\S}i;
    return '';
}

# SM913 S3: A SUBMISSION WHOSE FIELDS ARE ONE THING SAID THREE TIMES is not a
# message anybody wrote.
#
# The gibberish submission on that form carried name, subject and message as
# upper-case letter runs, each containing THE SAME 7-DIGIT NUMBER. No URL rule
# will ever see that, and no dictionary or list has to be maintained to catch it.
#
# Two shapes, both needing at least three filled fields so that a two-field form
# (a name and a message that repeats it) cannot trip:
#
#   * every field reduces to the same text;
#   * one run of five or more digits appears in every field. A reference number
#     legitimately appears in two fields now and then; in all of them, with
#     nothing else shared, it is a bot checking whether the form delivers.
sub _one_value_everywhere {
    my ($form) = @_;
    my @vals = map { $form->{$_} }
        grep { !/^_/ && defined $form->{$_} && !ref $form->{$_} && length $form->{$_} }
        sort keys %$form;
    return '' unless @vals >= 3;

    my %norm;
    for my $v (@vals) {
        ( my $n = lc $v ) =~ s/[^a-z0-9]+//g;
        $norm{$n}++ if length $n;
    }
    return 'every field holds the same value' if 1 == keys %norm;

    my @runs = ( $vals[0] =~ /(\d{5,})/g );
    for my $run (@runs) {
        return "the number $run is in every field"
            if @vals == grep { index( $_, $run ) >= 0 } @vals;
    }
    return '';
}

# SM115: one line per submission in the audit trail - the submitter is the
# public, so the actor is blank (SM402), and origin is "form". SM842: through
# Lazysite::Audit, now that this plugin loads the module tree, so the trail
# has one writer and one reading of its own switch (N13-04's marked copy and
# the lint that pinned the two together are gone with the copy). Each
# handler's outcome is its own line, written by Lazysite::Handlers::deliver.
sub _audit_submission {
    my ( $form, $user, $ip ) = @_;
    eval {
        require Lazysite::Audit;
        no warnings 'once';
        local $Lazysite::Audit::LAZYSITE_DIR = $LAZYSITE_DIR;
        Lazysite::Audit::audit_log( $user, 'submit', $form, $ip, 'ok', 'form' );
        1;
    };
    return;
}

# SM216-2's five reason codes, kept here as the vocabulary rather than as a
# matcher: honeypot, too_fast, expired, token, rate. Each is passed by the
# control that raises the refusal (see `reject` / `reject_user`), and a refusal
# with no code is not an anti-spam control - method, validation, delivery - and
# is deliberately not counted. plugins/stats.pl buckets whatever code arrives
# and has its own `other` fallback, so it needs no matching list.

# SM216-2: append one outcome line so the stats plugin can fold blocked-vs-stored
# counts into its day-buckets. Append-only, one line per event, so concurrent
# POSTs never race (O_APPEND under a lock). Counts only - the form name, an
# outcome (stored|quarantined|blocked) and, for a block, a reason code; never any
# submitted field. Best-effort: a stats hiccup must never fail a submission.
sub _record_form_event {
    my ( $form, $outcome, $reason ) = @_;
    ( my $f = defined $form ? "$form" : '' ) =~ s/[^a-zA-Z0-9_-]//g;
    return unless length $f;
    return unless defined $LAZYSITE_DIR;
    my $dir = "$LAZYSITE_DIR/stats/form-events";
    eval {
        make_path($dir) unless -d $dir;
        my $day = strftime( '%Y-%m-%d', localtime );
        my %ev  = ( t => time(), day => $day, form => $f, outcome => "$outcome" );
        $ev{reason} = "$reason" if defined $reason && length $reason;
        if ( open my $fh, '>>', "$dir/$day.jsonl" ) {
            flock $fh, LOCK_EX;
            print {$fh} encode_json( \%ev ) . "\n";
            close $fh;
        }
        1;
    };
    return;
}

# SM113: raise a sysop notification for a new submission. Append-only store
# the manager reads for its unread badge. Best-effort (never blocks delivery).
sub _notify_submission {
    my ( $form, $notify_off ) = @_;
    return unless defined $LAZYSITE_DIR;
    my $logdir = "$LAZYSITE_DIR/logs";
    return unless -d $logdir;
    ( my $f = defined $form ? "$form" : '' ) =~ s/[\r\n]+/ /g;

    # SM231 emission control, PER FORM. A partner's three-day programme
    # established the scale: 46 form steps per participant across 15
    # participants is 690 notices where five were wanted. Batching them would
    # need pending state and a timer lazysite does not have; the answer is that
    # a form says whether it announces itself.
    #
    # Default ON, so every existing form behaves exactly as before and a site
    # that never sets this notices nothing. `notify: off` in the form's own
    # .conf silences that form alone - the other forty-one steps stay quiet
    # while the five that matter still speak. (Site-wide silencing of the whole
    # type is the separate `emit.submission` key in notify.conf.)
    # The VALUE is passed in, never re-read here: load_form_conf calls reject()
    # on a missing or empty config, and aborting a request from inside a
    # best-effort notification would be a spectacular way to fail.
    return if $notify_off;

    # SM136: prefer the shared notify path (bell + optional XMPP delivery). This
    # plugin ships without `use lib`, so locate the module tree the same way the
    # processor's lazy-require does; on any failure fall through to the plain
    # bell-store append below so a submission notice is never lost.
    my $sent = eval {
        unless ( $INC{'Lazysite/Notify.pm'} ) {
            _locate_lib();
            require Lazysite::Notify;
        }
        Lazysite::Notify::notify( $DOCROOT, {
                type    => 'submission',
                message => "New form submission: $f",
                target  => $f,
                url     => '/manager/plugins',
        } );
    };
    return if $sent;

    my $line = encode_json( {
            ts      => time(),
            type    => 'submission',
            message => "New form submission: $f",
            target  => $f,
            url     => '/manager/plugins',
    } );
    open my $fh, '>>', "$logdir/notices.jsonl" or return;
    print {$fh} "$line\n";
    close $fh;
    return;
}

# Enforce the form's upload constraints; reject() (die) on the first violation.
sub validate_uploads {
    my ( $files, $cfg ) = @_;
    reject_user("Too many files (max $cfg->{max_files}).")
        if @$files > $cfg->{max_files};
    my %ok = map { $_ => 1 } @{ $cfg->{accept} };
    for my $f (@$files) {
        my $kb = int( ( length( $f->{data} ) + 1023 ) / 1024 );
        reject_user("File '$f->{filename}' is too large (max $cfg->{max_kb} KiB).")
            if $kb > $cfg->{max_kb};
        next unless keys %ok;
        my ($ext) = lc( $f->{filename} ) =~ /\.([a-z0-9]+)$/;
        reject_user( "File type not allowed: $f->{filename} (accepted: "
                . join( ', ', @{ $cfg->{accept} } ) . ').' )
            unless $ext && $ok{$ext};
    }
    return;
}

# --- POST parsing ---

sub parse_post {
    my $len  = $ENV{CONTENT_LENGTH} || 0;
    my $type = $ENV{CONTENT_TYPE}   || '';
    my $data = '';

    reject('Upload too large') if $len > $MAX_POST_BYTES;

    binmode STDIN;    # binary-safe: file parts carry raw bytes
    if ( $len > 0 ) { read( STDIN, $data, $len ); }
    else            { local $/; $data = <STDIN> // ''; }

    my %form;
    my @files;
    if ( $type =~ m{multipart/form-data.*boundary=(.+)}i ) {
        my $boundary = $1;
        $boundary =~ s/^\s+//;
        $boundary =~ s/["\s]+$//;
        for my $part ( split /--\Q$boundary\E/, $data ) {
            # part = optional CRLF, headers, blank line, body, trailing CRLF
            next unless $part =~ /\A\r?\n?(.*?)\r?\n\r?\n(.*)\z/s;
            my ( $head, $body ) = ( $1, $2 );
            next unless $head =~ /name="([^"]*)"/i;
            my $name = $1;
            $body =~ s/\r?\n\z//;    # drop the CRLF that precedes the next boundary
            if ( $head =~ /filename="([^"]*)"/i ) {
                my $filename = $1;
                next unless length $filename;    # an empty file input - skip
                my ($ctype) = $head =~ /Content-Type:\s*([^\r\n]+)/i;
                push @files, {
                    field    => $name,
                    filename => $filename,
                    type     => ( $ctype // 'application/octet-stream' ),
                    data     => $body,
                };
            }
            else {
                _field_add( \%form, _text($name), _text( field_value( $name, $body ) ) );
            }
        }
    }
    else {
        for my $pair ( split /&/, $data ) {
            my ( $k, $v ) = split /=/, $pair, 2;
            next unless defined $k;
            $k =~ s/\+/ /g;
            $k =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
            $v //= '';
            $v =~ s/\+/ /g;
            $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
            _field_add( \%form, _text($k), _text( field_value( $k, $v ) ) );
        }
    }
    # SM523: the engine's status meta is ENGINE-OWNED. Every key that reaches a
    # gate, a target or a stored record with a leading underscore is set HERE
    # or downstream (_files, _quarantined, _spam_reason, _submitted, _ip) -
    # except the five protocol keys the renderer emits. A visitor who posted
    # _quarantined=1 used to mute their own notification and skew the counts,
    # because the SM216 block only ever SET the flags on top of what arrived.
    for my $k ( keys %form ) {
        next unless $k =~ /^_/;
        next if $PROTOCOL_KEY{$k};
        delete $form{$k};
    }
    $form{_files} = \@files if @files;
    _fold_quantities( \%form );
    return %form;
}

# SM904: A FIELD IS DECODED ONCE, HERE, AND NOWHERE ELSE.
#
# %XX becomes chr(hex) above and a multipart text part is taken raw, so every
# field left this sub as BYTES - "Hervé" as six code points, C3 and A9 among
# them. Every consumer then treated a byte as a character and encoded it
# again: the >>:utf8 submissions store, insert_row, the JSON payload to the
# SMTP script, the :utf8 STDOUT the thank-you renders through. A live lead
# was stored as "HervÃ©" on 2026-09-24; the API path (a JSON body, decoded
# by decode_json) was never affected, which is how the fault was placed here.
#
# After field_value, so MAX_FIELD_BYTES keeps counting bytes. A body that is
# not valid UTF-8 is left as it was - utf8::decode leaves the string alone
# and that reads it as Latin-1, which is the one reading of a Latin-1 body
# that loses nothing. File parts are not text and stay raw.
sub _text {
    my ($s) = @_;
    return $s unless defined $s;
    utf8::decode($s);
    return $s;
}

# SM401: a REPEATED key accumulates rather than overwriting.
#
# One name submitted several times is how HTML has always expressed a
# multi-select, and a plain assignment kept only the last one - so a checkbox
# group silently lost every tick but the final one. Silently, because the
# submission still arrived and still looked well-formed. SM539: the multipart
# branch kept that assignment after the urlencoded one had learnt better, so
# a form with an upload lost its ticks; both branches now come through here.
sub _field_add {
    my ( $form, $k, $v ) = @_;
    if ( exists $form->{$k} && length $form->{$k} ) {
        $form->{$k} .= "; $v" if length $v;
    }
    else {
        $form->{$k} = $v;
    }
    return;
}

# SM401: fold `field~qty~OPTION` inputs back into their field.
#
# checklist-qty asks a question the flat name/value shape cannot carry: WHICH
# options, and HOW MANY of each. The alternative was to teach this handler the
# form's field types, which it does not have and should not - the page defines
# the form, the handler receives it. Encoding the relationship in the NAME keeps
# the handler generic: it needs no schema, only a rule.
#
# A quantity is kept only when its option was actually ticked, so unticking a box
# and leaving a number behind - which is exactly what a person does when they
# change their mind - does not submit a quantity for something they deselected.
sub _fold_quantities {
    my ($form) = @_;
    my %qty;
    for my $k ( keys %$form ) {
        next unless $k =~ /\A(.+)~qty~(.+)\z/s;
        my ( $base, $opt ) = ( $1, $2 );
        my $v = $form->{$k};
        delete $form->{$k};
        next unless defined $v && $v =~ /\A\s*\d+\s*\z/ && $v + 0 > 0;
        $qty{$base}{$opt} = $v + 0;
    }
    for my $base ( keys %qty ) {
        my @ticked = grep { length } split /\s*;\s*/, ( $form->{$base} // '' );
        my @out;
        for my $opt (@ticked) {
            push @out, exists $qty{$base}{$opt} ? "$opt=$qty{$base}{$opt}" : $opt;
        }
        $form->{$base} = join '; ', @out if @out;
    }
    return;
}

# --- Security ---

sub check_honeypot {
    my ($hp) = @_;
    reject( 'Spam detected', 'honeypot' ) if defined $hp && length $hp;
}

sub check_timestamp {
    my ( $ts, $tk, $secret, $window ) = @_;
    reject( 'Invalid submission', 'token' ) unless $ts && $tk;
    reject( 'Invalid submission', 'token' ) unless $ts =~ /^\d+$/;
    my $expected = hmac_sha256_hex( $ts, $secret );
    reject( 'Invalid submission', 'token' ) unless $tk eq $expected;
    my $age = time() - $ts;

    # SM888 A7: THE TIMING REFUSALS ARE SHOWN; THE TOKEN ONES ARE NOT.
    #
    # The field reported "a form posted within a second of page load fails with
    # a generic error". It was refusing correctly - the floor is real - and the
    # reason was discarded one word from being shown: reject() dies plain,
    # reject_user() dies USER:, and only USER: reaches the submitter.
    #
    # The two kinds of refusal above and below are not the same kind of event,
    # which is why this is not "make them all visible":
    #
    #   The three `Invalid submission` refusals are TOKEN failures - missing,
    #   malformed, wrong HMAC - and they are what an attacker drives. Telling
    #   them apart tells a forger which half of the attempt was wrong, so they
    #   stay generic.
    #
    #   Too fast and expired happen to REAL PEOPLE holding a token this site
    #   issued: the HMAC has already matched. Nothing is being probed - the
    #   visitor typed quickly or left the page open. Telling them costs nothing
    #   (the floor is three seconds and it is in this file) and saves them
    #   retyping a form they believe ate their answer.
    reject_user( 'That was too quick - please try again in a moment.', 'too_fast' )
        if $age < 3;

    # SM501: per-form, defaulting to the shipped two hours. 0 disables the age
    # ceiling only - the HMAC above still has to match, so a submission cannot
    # be forged or replayed from another form, and the too-fast floor still
    # applies. Undef is the default rather than "no limit", so a malformed value
    # in a form conf tightens nothing and loosens nothing.
    $window = 7200 unless defined $window;
    # Shown, for the same reason as the floor above: this is a page that sat
    # open, not a token that failed. A visitor told only "an error occurred"
    # re-submits the same stale page and is refused identically.
    reject_user(
        'This form was open too long and has expired - please reload the page '
            . 'and send it again.', 'expired' )
        if $window && $age > $window;
}

# SM401: the limit is PER FORM, and the default is unchanged.
#
# Five an hour per address is right for a public contact form and wrong for an
# authenticated office team working through twenty-five data-entry pages from one
# office address - which is a real deployment, not a hypothetical.
#
# WHY NOT "EXEMPT LOGGED-IN USERS" ON A HEADER - AND WHY THE COOKIE PATH NOW
# DOES (SM425). This handler is NOT behind the auth wrapper: the templates
# front only lazysite-processor.pl and lazysite-manager-api.pl with it, and
# /cgi-bin/ is otherwise a plain ScriptAlias. So HTTP_X_REMOTE_USER arrives
# here exactly as the client sent it, and exempting on it would mean any
# request carrying `X-Remote-User: anything` skipped the limit - a spam
# control one header away from useless. That refusal STANDS for headers. The
# SM425 exemption above is different in kind: it verifies the session COOKIE
# cryptographically (SM411's shared verifier - HMAC, registry, account
# checks), which no client can mint without the site secret. The identity it
# yields is used as a boolean for the limiter and recorded nowhere, so the
# SM402 line holds unchanged: nothing here is recorded as an actor, and the
# audit entry a submission writes carries none (t/unit/forms/07 asserts it).
#
# An operator setting `rate_limit:` on the one gated form they built is explicit,
# auditable, and needs no trust decision about a header nobody verified.
sub check_rate_limit {
    my ( $ip, $limit ) = @_;

    # Absent = 5, the shipped default. 0 or `off` = no limit, for a form whose
    # access is already controlled by something better than an address count.
    $limit = defined $limit ? $limit : 5;
    return if $limit <= 0;
    _ensure_dir_for("$FORMS_DIR/.rate-limit.db");
    my %db;
    tie( %db, 'DB_File', "$FORMS_DIR/.rate-limit.db",
        O_RDWR | O_CREAT, 0o600, $DB_HASH ) or return;
    my $hour  = int( time() / 3600 );
    my $key   = "$ip:$hour";
    my $count = $db{$key} || 0;
    if ( $count >= $limit ) { untie %db; reject( 'Rate limit exceeded', 'rate' ); }
    $db{$key} = $count + 1;

    # Purge the stale hours ONCE PER HOUR, not once per submission. The keys
    # deleted are a function of $hour alone, so a second pass within the same
    # hour can only find what the first already removed - and this walks every
    # key in the DB, which is the one unbounded thing on the submission path.
    # The marker carries no colon, so it can never look like an "ip:hour" key.
    if ( ( $db{_purged_hour} // -1 ) != $hour ) {
        for my $k ( keys %db ) {
            delete $db{$k} if $k =~ /:(\d+)$/ && $1 < $hour - 1;
        }
        $db{_purged_hour} = $hour;
    }
    untie %db;
}

sub load_form_secret {
    my $secret_path = "$FORMS_DIR/.secret";
    _ensure_dir_for($secret_path);
    if ( -f $secret_path ) {
        open( my $fh, '<', $secret_path ) or die "Cannot read form secret\n";
        chomp( my $s = <$fh> );
        close($fh);
        return $s if $s;
    }
    die "Form secret not found - render a form page first to generate it\n";
}

# --- Response ---

# SM415: a post WITHOUT JavaScript used to land on raw JSON - with HTTP 200
# on failure. The JS path declares Accept: application/json and keeps
# today's reply byte-for-byte; a native post (a browser says text/html) is
# answered the way login answers: a redirect back to the page it came from,
# carrying the outcome for the form renderer to show as a banner. The page
# rides in the _page hidden field the renderer embeds - validated here as a
# same-site absolute path (no scheme, no protocol-relative, no CRLF), and
# ABSENT means JSON: a stale cached page without the field must never be
# redirected to nowhere.
sub _wants_json {
    return 1 if ( $ENV{HTTP_ACCEPT} // '' ) =~ m{application/json};
    return 1 unless length $REDIRECT_PAGE;
    return 0;
}

sub _redirect_back {
    my ($outcome) = @_;
    $outcome =~ s/([^A-Za-z0-9\-. _])/sprintf '%%%02X', ord $1/ge;
    $outcome =~ tr/ /+/;
    my $to = $REDIRECT_PAGE . '?form=' . $REDIRECT_FORM . '&outcome=' . $outcome;
    print "Status: 303 See Other\r\n";
    print "Location: $to\r\n\r\n";
}

sub respond_ok {
    my ( $msg, $outcome ) = @_;
    $outcome = 'ok' unless defined $outcome && exists $OUTCOME_SAID{$outcome};
    binmode( STDOUT, ':utf8' );
    return _redirect_back($outcome) unless _wants_json();
    print "Status: 200 OK\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json( { ok => 1, message => $msg } );
}

sub respond_error {
    my ($msg) = @_;
    binmode( STDOUT, ':utf8' );
    return _redirect_back($msg) unless _wants_json();
    print "Status: 200 OK\r\n";
    print "Content-Type: application/json; charset=utf-8\r\n\r\n";
    print encode_json( { ok => 0, error => $msg } );
}

# SM888 A7 (second half): A REFUSAL CARRIES ITS OWN REASON CODE.
#
# `_block_reason` used to recover the code by matching the refusal's PROSE -
# /Submission too fast/, /Submission expired/ and three more. The first half of
# A7 reworded two of those messages so a real visitor could read them, and left
# the matcher looking for words that no longer exist anywhere in the tree. Both
# refusals then fell through to '' , which the caller reads as "not an anti-spam
# control" and records NOTHING - so the report's "controls stopped N" silently
# dropped two of its five reasons, and no test noticed because none existed.
#
# The fix is not a better regex. The code is now SET where the refusal is
# raised, by the line that knows which control fired, and read once at the
# catch. Rewording a message cannot break it, because nothing reads the words.
#
# $BLOCK_REASON is declared at the top of the file, beside $REDIRECT_PAGE and
# for the same file-order reason stated there.

sub reject {
    $BLOCK_REASON = defined $_[1] ? $_[1] : '';
    die "$_[0]\n";
}

# Like reject(), but the message IS shown to the submitter (upload limits etc.).
sub reject_user {
    $BLOCK_REASON = defined $_[1] ? $_[1] : '';
    die "USER:$_[0]\n";
}

# --- Utilities ---

sub sanitise_header {
    my ( $val, $max ) = @_;
    $max //= 1000;
    $val =~ s/[\r\n]/ /g;
    $val = substr( $val, 0, $max ) if length($val) > $max;
    return $val;
}

# N141B: a submitted field's VALUE - refused when too long, never truncated.
#
# sanitise_header is for header-shaped values, where silently cutting an
# over-long string is the safe thing to do and nobody is storing the result.
# Calling it on every submitted field applied that reasoning to the data, and
# the data is the one place truncation is unsafe: the row is kept, reported ok,
# and nothing downstream can tell the value is not what was typed.
#
# N141C: AND THE NEWLINES ARE KEPT. sanitise_header also folded CR and LF to
# spaces, so a message typed as three paragraphs was stored as one line and the
# visitor was never told. That is the same mistake as the truncation above,
# applied to structure instead of length: a header-shaped rule imposed on the
# data, silently, where the result IS kept.
#
# WHY IT IS SAFE TO STOP. Three consumers, checked rather than assumed:
#
#   * the submission STORE is JSONL, and JSON escapes a newline - a multi-line
#     value has always been representable there, it simply never arrived;
#   * the mail SUBJECT keeps its own fold, in form-smtp.pl, one line before it
#     is used (`$subject =~ s/[\r\n]/ /g`). That is where a header truly cannot
#     hold a newline, and the guard belongs there rather than three layers away
#     on every field that will never become a header;
#   * the mail BODY and the Submissions page want the breaks - showing them is
#     the point.
#
# So the header rule now lives with the header, and the data keeps its shape.
sub field_value {
    my ( $name, $val ) = @_;
    $val = '' unless defined $val;
    if ( length($val) > $MAX_FIELD_BYTES ) {
        my $kb = int( $MAX_FIELD_BYTES / 1024 );
        reject_user( "The '$name' field is too long (limit ${kb} KB). "
                . 'Nothing was saved - shorten it and send the form again.' );
    }

    # A lone CR (an old Mac line ending, and what a CRLF leaves if the LF is
    # taken separately) is normalised to LF so the store holds one spelling of
    # "line break" rather than three.
    $val =~ s/\r\n?/\n/g;
    return $val;
}

sub _ensure_dir_for {
    my ($path) = @_;
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
}

sub log_event {
    my ( $level, $context, $message, %extra ) = @_;
    my $min_level = $ENV{LAZYSITE_LOG_LEVEL} // 'INFO';
    my %rank      = ( DEBUG => 0, INFO => 1, WARN => 2, ERROR => 3 );
    return if ( $rank{$level} // 1 ) < ( $rank{$min_level} // 1 );
    my $ts     = strftime( '%Y-%m-%d %H:%M:%S', localtime );
    my $format = $ENV{LAZYSITE_LOG_FORMAT} // 'text';
    if ( $format eq 'json' ) {
        my $pairs = join ',',
            map { '"' . _json_str($_) . '":"' . _json_str( $extra{$_} ) . '"' }
            keys %extra;
        my $json = '{"ts":"' . $ts . '"'
            . ',"level":"' . _json_str($level) . '"'
            . ',"component":"' . _json_str($LOG_COMPONENT) . '"'
            . ',"context":"' . _json_str($context) . '"'
            . ',"message":"' . _json_str($message) . '"'
            . ( $pairs ? ",$pairs" : '' )
            . '}';
        print STDERR "$json\n";
        _forward_diag( $level, $json );
    }
    else {
        my $extras = join ' ',
            map { "$_=" . $extra{$_} } keys %extra;
        my $line = "[$ts] [$level] [$LOG_COMPONENT] [$context] $message";
        $line .= " $extras" if $extras;
        print STDERR "$line\n";
        _forward_diag( $level, $line );
    }
}

# SM540: a best-effort copy of the line to syslog through Lazysite::Util's
# forward_line, so `forward_diagnostics: true` covers this plugin's
# diagnostics as the docs promise. The module tree is located at runtime (the
# SM473 lesson: `prove -l` puts lib/ on @INC and a real install does not) and
# the require is eval-guarded, the SM425 posture: a missing lib costs the
# sysop a syslog copy, never a submission - STDERR has the line either way.
sub _forward_diag {
    my ( $level, $line ) = @_;
    my %prio = ( DEBUG => 'debug', INFO => 'info', WARN => 'warning', ERROR => 'err' );
    eval {
        unless ( $INC{'Lazysite/Util.pm'} ) {
            _locate_lib();
            require Lazysite::Util;
        }
        Lazysite::Util::forward_line( 'diag', $prio{$level} // 'info', $line );
        1;
    };
    return;
}

# Put the engine's module tree on @INC, if it is findable from here - relative
# to the real file, so the cgi-bin symlink finds the lib beside plugins/. The
# SM473 lesson is why it is needed at all: `prove -l` puts lib/ on @INC and a
# real install does not. It runs once at start-up (SM842: delivery needs the
# tree); the notify and forward helpers still call it, harmlessly, for the
# case where that first attempt found nothing.
sub _locate_lib {
    require Cwd;
    require File::Basename;
    my $bin = File::Basename::dirname( Cwd::abs_path(__FILE__) );
    for my $cand ( "$bin/lib", "$bin/../lib", "$bin/../../lib" ) {
        if ( -d "$cand/Lazysite" ) { unshift @INC, $cand; last }
    }
    return;
}

# The answers a visitor actually gave. Underscore-prefixed keys are the
# handler's own bookkeeping (_form, _files, _page, _quarantined) and never
# belong in a delivered record - which is why _auth_user was harmless when it
# existed, and why every delivery target skips them the same way.
sub _visible_fields {
    my ($form) = @_;
    my %visible;
    for my $k ( sort keys %$form ) {
        next if $k =~ /^_/;
        $visible{$k} = $form->{$k};
    }
    return %visible;
}

sub _json_str {
    my ($s) = @_;
    $s //= '';
    $s =~ s/\\/\\\\/g;
    $s =~ s/"/\\"/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    return $s;
}
