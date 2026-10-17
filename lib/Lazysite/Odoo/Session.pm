package Lazysite::Odoo::Session;

# SM747 B (release manager 2026-10-13, B-Q1 as recommended): A PERSON SIGNS IN TO
# ODOO THROUGH A LAZYSITE PAGE, AND THEIR OWN SESSION IS WHAT RUNS THEIR CALLS.
#
# The mechanism is OOM's (Odoo::Transport::Session, 0.03): the password goes to
# Odoo ONCE, Odoo answers with a session id, and the page carries the id from
# then on. Everything Odoo-shaped - the route, the payload, the cookie Odoo sets
# - stays in OOM. What is lazysite's, and what this module is, is how the
# CREDENTIAL IS HANDLED on this side:
#
#   THE PASSWORD     is a function argument. It is handed to OOM and goes no
#                    further: not into a log, an audit row, a call record, an
#                    error message, a cache or a file. No text of an error from
#                    a sign-in is returned or logged, only its kind.
#   THE SESSION ID   is a credential - whoever holds it is that person in Odoo.
#                    It lives in memory for the length of a request and in ONE
#                    cookie: signed with the extension's own secret (so a value
#                    this server did not mint names nothing), dated inside the
#                    signature (12 hours, whatever Odoo says), HttpOnly,
#                    SameSite=Strict, Secure over HTTPS, and scoped to the path
#                    of the Odoo endpoint so nothing else on the site receives
#                    it. It is never in a URL, a response body, a log or a
#                    record: a record names a HASH of it.
#   THE SECOND FACTOR (SM1157, OOM 0.27) is Odoo's own authenticator code. The
#                    password step of a two-factor account opens a HALF-OPEN session
#                    at Odoo, and the page carries its id to the code step in a second
#                    cookie of the same kind (signed, HttpOnly, SameSite=Strict, scoped
#                    to the endpoint) that is good for five minutes and is NOT a
#                    session: sid_from_cookie never reads it. The code is a function
#                    argument, as the password is, and goes no further. "Don't ask
#                    again on this device" is Odoo's td_id cookie: OOM hands its value
#                    back and keeps nothing, and it is kept here in one more cookie
#                    (HttpOnly, Secure, SameSite=Strict, the endpoint's path), never in a store.
#   A FAULT          (the session ended, or Odoo no longer accepts it) clears the
#                    cookie and refuses. It never falls back to the connection
#                    user: that account is likely wider than the person.
use strict;
use warnings;
use Digest::SHA    qw(hmac_sha256_hex sha256_hex);
use Lazysite::Util qw(log_event const_eq);

our $COOKIE = 'lzs_odoo_session';
our $TTL    = 12 * 3600;

our $PENDING_COOKIE = 'lzs_odoo_pending';
our $PENDING_TTL    = 300;
our $DEVICE_COOKIE  = 'lzs_odoo_device';
our $DEVICE_AGE = 90 * 86400; # Odoo's own trust period; Odoo is the authority, this only stops the browser keeping it longer

# The HTTP client under OOM's session transport. Unset in production, where OOM
# builds its own; a test puts a stand-in here, as it puts OOM's fake Odoo in
# $Lazysite::Odoo::TRANSPORT.
our $HTTP;

my $ID   = qr/\A[A-Za-z0-9_-]{8,200}\z/;
my $PATH = qr{\A/[A-Za-z0-9._/-]{0,200}\z};

# What a two-factor account is told while the sign-in has no code step.
my $TWO_FACTOR = 'Odoo accepted that sign-in but opened no session. An account with two-factor '
    . 'authentication cannot sign in with a password alone here.';

sub _secret {
    require Lazysite::Odoo::Visitor;

    # The visitor secret, domain-separated below: one secret to protect and
    # rotate for this extension's signed cookies, and no signature from one
    # use can be replayed as the other's.
    return Lazysite::Odoo::Visitor::secret();
}

sub _sig {
    my ( $sid, $at, $secret ) = @_;
    return hmac_sha256_hex( "odoo-session|$sid|$at", $secret );
}

# The cookie value carrying a session id: id, the time it was minted, and a
# signature over both. undef when the id is not the shape of one (so a value
# with a separator in it never reaches a header) or there is no secret.
sub mint_cookie {
    my ( $sid, %o ) = @_;
    return undef unless defined $sid && $sid =~ $ID;
    my $secret = _secret() // return undef;
    my $at     = $o{now}   // time;
    return "$sid.$at." . _sig( $sid, $at, $secret );
}

# The session id a Cookie header carries, when this server minted it and it is
# inside its twelve hours; undef otherwise. Constant-time comparison, so the
# signature cannot be found a byte at a time.
sub sid_from_cookie {
    my ( $header, %o ) = @_;
    return undef unless defined $header && length $header;
    my ($v) = $header =~ m{(?:\A|;\s*) \Q$COOKIE\E = ( [A-Za-z0-9_-]{8,200} [.] [0-9]{1,12} [.] [0-9a-f]{64} ) (?:;|\z)}x;
    return undef unless defined $v;
    my ( $sid, $at, $sig ) = split /\./, $v, 3;
    my $secret = _secret() // return undef;
    return undef unless const_eq( $sig, _sig( $sid, $at, $secret ) );
    my $now = $o{now} // time;
    return undef if $at > $now + 60 || $now - $at > $TTL;
    return $sid;
}

# --- the half-open sign-in (SM1157) ---------------------------------------------
#
# The same cookie as the session's in every way that matters, with its own name
# and its own signature domain ("odoo-pending|"): a pending id cannot be replayed
# as a session cookie, nor a session cookie as a pending one.
sub _psig {
    my ( $sid, $at, $secret ) = @_;
    return hmac_sha256_hex( "odoo-pending|$sid|$at", $secret );
}

sub mint_pending_cookie {
    my ( $sid, %o ) = @_;
    return undef unless defined $sid && $sid =~ $ID;
    my $secret = _secret() // return undef;
    my $at     = $o{now}   // time;
    return "$sid.$at." . _psig( $sid, $at, $secret );
}

# The pending session id a Cookie header carries, inside its five minutes.
sub pending_from_cookie {
    my ( $header, %o ) = @_;
    return undef unless defined $header && length $header;
    my ($v) = $header =~ m{(?:\A|;\s*) \Q$PENDING_COOKIE\E = ( [A-Za-z0-9_-]{8,200} [.] [0-9]{1,12} [.] [0-9a-f]{64} ) (?:;|\z)}x;
    return undef unless defined $v;
    my ( $sid, $at, $sig ) = split /\./, $v, 3;
    my $secret = _secret() // return undef;
    return undef unless const_eq( $sig, _psig( $sid, $at, $secret ) );
    my $now = $o{now} // time;
    return undef if $at > $now + 60 || $now - $at > $PENDING_TTL;
    return $sid;
}

sub set_pending_header {
    my ( $cookie, %o ) = @_;
    return "Set-Cookie: $PENDING_COOKIE=$cookie; Path=" . _path( $o{path} ) . "; Max-Age=$PENDING_TTL; HttpOnly; SameSite=Strict"
        . ( $o{secure} ? '; Secure' : '' );
}

sub clear_pending_header {
    my (%o) = @_;
    return "Set-Cookie: $PENDING_COOKIE=; Path=" . _path( $o{path} )
        . '; HttpOnly; SameSite=Strict; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT'
        . ( $o{secure} ? '; Secure' : '' );
}

# Odoo's trusted-device value, as a browser holds it. Odoo mints it; this checks
# only that it is the shape of a cookie value before it is put in a header or sent
# back, so a value with a separator in it never reaches either.
my $DEVICE = qr/\A[A-Za-z0-9_.~=-]{8,512}\z/;

sub device_from_cookie {
    my ($header) = @_;
    return undef unless defined $header && length $header;
    my ($v) = $header =~ m{(?:\A|;\s*) \Q$DEVICE_COOKIE\E = ( [A-Za-z0-9_.~=-]{8,512} ) (?:;|\z)}x;
    return $v;
}

# Always Secure: the value lets a browser past Odoo's second factor for up to
# ninety days, so it is never set where it would travel in the clear.
sub set_device_header {
    my ( $value, %o ) = @_;
    return undef unless defined $value && $value =~ $DEVICE;
    return "Set-Cookie: $DEVICE_COOKIE=$value; Path=" . _path( $o{path} ) . "; Max-Age=$DEVICE_AGE; HttpOnly; SameSite=Strict; Secure";
}

sub clear_device_header {
    my (%o) = @_;
    return "Set-Cookie: $DEVICE_COOKIE=; Path=" . _path( $o{path} )
        . '; HttpOnly; SameSite=Strict; Secure; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT';
}

sub _path {
    my ($p) = @_;
    return ( defined $p && $p =~ $PATH ) ? $p : '/cgi-bin/lazysite-odoo.pl';
}

sub set_cookie_header {
    my ( $cookie, %o ) = @_;
    return "Set-Cookie: $COOKIE=$cookie; Path=" . _path( $o{path} ) . '; HttpOnly; SameSite=Strict'
        . ( $o{secure} ? '; Secure' : '' );
}

sub clear_cookie_header {
    my (%o) = @_;
    return "Set-Cookie: $COOKIE=; Path=" . _path( $o{path} )
        . '; HttpOnly; SameSite=Strict; Max-Age=0; Expires=Thu, 01 Jan 1970 00:00:00 GMT'
        . ( $o{secure} ? '; Secure' : '' );
}

# What a record names the session by: a hash, never the id.
sub session_label {
    my ($sid) = @_;
    return '' unless defined $sid && length $sid;
    return 'session:' . substr( sha256_hex("odoo-session-id|$sid"), 0, 16 );
}

# What a sign-in names the person by in a record: a hash of the login, so a
# run of refusals can be told apart without writing who was typed.
sub login_label {
    my ($login) = @_;
    return '' unless defined $login && length $login;
    return 'signin:' . substr( sha256_hex( 'odoo-login|' . lc $login ), 0, 16 );
}

# sign_in( \%connection, $login, $password [, trusted_device => VALUE] ) -> { ok, session_id, identity }
# or { ok => 0, kind, error }, or, for an account with Odoo's two-factor on (SM1157),
# { ok => 0, pending => 1, session_id }
#
# OOM does the signing in. Whatever it raises is read for its KIND and category
# and nothing else: the text of a fault is never returned and never logged here
# (a credential check is the one place a message could carry what was typed).
sub sign_in {
    my ( $conn, $login, $password, %o ) = @_;
    my $t = eval { _transport($conn) };
    return _fail( 'config', 'the Odoo connection is not configured correctly - see the event log' ) unless $t;
    my $identity = eval {
        $t->authenticate( $conn->{db}, $login, $password,
            ( defined $o{trusted_device} ? ( trusted_device => $o{trusted_device} ) : () ) );
    };
    my $err      = $@;
    unless ($identity) {
        my ( $kind, $said ) = _classify($err);
        log_event( 'WARN', 'odoo', 'odoo sign-in refused', kind => $kind, who => login_label($login) );
        return _fail( $kind, $said );
    }
    # SM1156/SM1157: OOM 0.27 answers a two-factor account's right password with
    # { second_factor => 'totp', pending => 1 } and a HALF-OPEN session id, where
    # 0.24 and before died. It is not a sign-in - the session runs nothing - so it
    # is returned as what it is, for the engine to carry to the code step. An OOM
    # that cannot finish it (no complete_totp) never answers this way; if one did,
    # the account is refused by name as before and the half-open session ended.
    if ( ref $identity eq 'HASH' && $identity->{pending} ) {
        my $sid = $t->session_id;
        unless ( $t->can('complete_totp') && defined $sid && $sid =~ $ID ) {
            eval { $t->destroy };
            log_event( 'WARN', 'odoo', 'odoo sign-in refused', kind => 'two-factor', who => login_label($login) );
            return _fail( 'two-factor', $TWO_FACTOR );
        }
        return { ok => 0, pending => 1, session_id => $sid, kind => 'second-factor-required' };
    }
    my $sid = $t->session_id;
    unless ( defined $sid && $sid =~ $ID ) {
        eval { $t->destroy };
        return _fail( 'unavailable', 'Odoo opened a session this host cannot carry' );
    }
    return {
        ok         => 1,
        session_id => $sid,

        # What Odoo said about the person, kept to what a page may show (the
        # identity cookie takes it from here); `identity` below is the part the
        # sign-in's own answer tells the person.
        identity_all => _facts($identity),
        identity     => {
            map { ( $_ => $identity->{$_} ) } grep { defined $identity->{$_} && !ref $identity->{$_} } qw(name login lang tz)
        },
    };
}

# The one place a session transport is built, so that what is true of the
# connection is true of every use of it. SM1149: the connection's own CA bundle
# (`odoo_ca_file`) goes to OOM as ssl_ca_file, which OOM hands to HTTP::Tiny for
# THIS client only - never SSL_CERT_FILE in %ENV, which would replace the system
# store for the whole process.
sub _transport {
    my ( $conn, %o ) = @_;
    require Odoo::Transport::Session;
    return Odoo::Transport::Session->new(
        url     => $conn->{url},
        timeout => $conn->{timeout},
        ( $conn->{max_kb}  ? ( max_response_bytes => $conn->{max_kb} * 1024 ) : () ),
        ( $conn->{ca_file} ? ( ssl_ca_file        => $conn->{ca_file} )       : () ),
        ( $HTTP            ? ( http               => $HTTP )                  : () ),
        %o,
    );
}

# complete_totp( \%connection, $pending_sid, $code, remember => 0|1, user_agent => UA )
#   -> { ok, session_id, identity, identity_all[, trusted_device] } or { ok => 0, kind, error[, clear_pending] }
#
# The second step of a sign-in (SM1157): the code goes to Odoo through OOM, once,
# and nowhere else. A WRONG CODE is not the end of the sign-in: Odoo keeps the
# half-open session and counts the tries itself (and says when it has had enough),
# so the answer is kind second-factor with the pending cookie left alone, and the
# person may try again. A pending session Odoo no longer knows is a sign-in to
# make again. The code, like the password, is never in a record, a log or a
# message; neither is Odoo's own wording of a refusal.
sub complete_totp {
    my ( $conn, $pending_sid, $code, %o ) = @_;
    return _fail( 'signin-required', 'the sign-in has run out - enter the password again' )
        unless defined $pending_sid && $pending_sid =~ $ID;
    # Resumed on the one transport _transport builds, so the code step reaches
    # Odoo the way the password step did - its CA bundle (SM1149) included.
    my $t = eval { _transport($conn)->resume_pending( db => $conn->{db}, session => $pending_sid ) };
    return _fail( 'config', 'the Odoo connection is not configured correctly - see the event log' )
        unless $t && $t->can('complete_totp');
    my $remember = $o{remember} ? 1 : 0;
    my $ua       = $o{user_agent};
    $ua = undef unless defined $ua && length $ua && length $ua <= 300 && $ua !~ /[\x00-\x1f\x7f]/;
    my $identity = eval { $t->complete_totp( $code, remember => $remember, ( defined $ua ? ( user_agent => $ua ) : () ) ) };
    my $err = $@;
    unless ( ref $identity eq 'HASH' && $identity->{uid} ) {
        my $cat = ( ref $err && eval { $err->isa('Odoo::Error') } && $err->can('fault_category') ) ? ( $err->fault_category // '' ) : '';
        my $kind;
        if ( $cat eq 'second-factor' ) {
            log_event( 'WARN', 'odoo', 'odoo second-factor code refused', kind => 'second-factor', who => session_label($pending_sid) );
            return _fail( 'second-factor',
                'Odoo did not accept that code. Check the 6-digit code and try again; Odoo limits how many tries it allows.' );
        }
        if ( $cat eq 'session' ) {
            log_event( 'WARN', 'odoo', 'odoo pending sign-in lapsed', kind => 'signin-required', who => session_label($pending_sid) );
            return { %{ _fail( 'signin-required', 'the sign-in has run out - enter the password again' ) }, clear_pending => 1 };
        }
        ( $kind, my $said ) = _classify($err);
        log_event( 'WARN', 'odoo', 'odoo second-factor step failed', kind => $kind, who => session_label($pending_sid) );
        return { %{ _fail( $kind, $said ) }, clear_pending => 1 };
    }
    my $sid = $t->session_id;
    unless ( defined $sid && $sid =~ $ID ) {
        eval { $t->destroy };
        return { %{ _fail( 'unavailable', 'Odoo opened a session this host cannot carry' ) }, clear_pending => 1 };
    }
    my $td = ref $identity->{trusted_device} eq 'HASH' ? $identity->{trusted_device}{value} : undef;
    return {
        ok           => 1,
        session_id   => $sid,
        identity_all => _facts($identity),
        identity     => {
            map { ( $_ => $identity->{$_} ) } grep { defined $identity->{$_} && !ref $identity->{$_} } qw(name login lang tz)
        },
        ( defined $td ? ( trusted_device => $td ) : () ),
    };
}

# What of an OOM identity a page may be shown (Lazysite::Odoo::Identity::present
# keeps it to this and no more): a name, a language, a time
# zone and the companies.
sub _facts {
    my ($id) = @_;
    return { map { ( $_ => $id->{$_} ) } grep { defined $id->{$_} } qw(name lang tz company_id company_ids groups) };
}

# identity_of( \%connection, $sid ) -> { ok, identity } or { ok => 0, kind, error[, clear_session] }
#
# Asks Odoo, through the person's own session, who they are - the refresh of the
# identity cookie, one round trip, made when the cookie has ended. A session that
# Odoo has ended is a sign-in to make again; anything else is a failure to ask,
# which leaves the person signed in and the page with no identity to show.
sub identity_of {
    my ( $conn, $sid ) = @_;
    return _fail( 'signin-required', 'no Odoo sign-in' ) unless defined $sid && $sid =~ $ID;
    my $id = eval {
        require Odoo::Client;
        my $t = _transport( $conn, session => $sid );
        Odoo::Client->new( url => $conn->{url}, db => $conn->{db}, transport => $t, retries => [0] )->session_identity;
    };
    my $err = $@;
    return { ok => 1, identity => _facts($id) } if ref $id eq 'HASH';
    if ( ref $err && eval { $err->isa('Odoo::Error') } && $err->is_session_expired ) {
        return { %{ _fail( 'signin-required', 'your Odoo sign-in has ended - sign in again' ) }, clear_session => 1 };
    }
    log_event( 'WARN', 'odoo', 'odoo identity refresh failed', who => session_label($sid) );
    return _fail( 'transport-failure', 'Odoo could not be reached, or did not answer in a usable way' );
}

sub _fail {
    my ( $kind, $why ) = @_;
    return { ok => 0, kind => $kind, error => $why };
}

# The fault's KIND, said in words that do not depend on its text - except for the
# one case OOM has no category for: a login Odoo accepted and opened no session
# for, which is how a two-factor account answers a password sign-in. OOM names it
# only in its message, so that is read here and nowhere else (asked of OOM).
sub _classify {
    my ($err) = @_;
    if ( ref $err && eval { $err->isa('Odoo::Error') } ) {
        my $k = $err->kind // '';
        return ( 'transport-failure', 'Odoo could not be reached, or did not answer in a usable way' )
            if $k eq 'transport';
        return ( 'config', 'the Odoo connection is not configured correctly - see the event log' )
            if $k eq 'config';
        if ( $k eq 'fault' ) {
            # SM1117: OOM 0.24 gave "accepted, no session opened" its own category
            # (second_factor, is_no_session), no longer a credential fault. SM1156:
            # OOM 0.27 renamed it second-factor-required (is_no_session still reads
            # it) and left the older fault, "authentication did not establish a
            # session" (oom.NoSession), uncategorised ('other') - so the message
            # test below can no longer sit behind the credential test. The signal
            # is read first; the message stays for an OOM before 0.24.
            my $cat = $err->can('fault_category') ? ( $err->fault_category // '' ) : '';
            return ( 'two-factor', $TWO_FACTOR )
                if ( $err->can('is_no_session') && $err->is_no_session )
                || $cat eq 'second_factor' || $cat eq 'second-factor-required'
                || ( $err->message // '' ) =~ /did not establish a session/;
            return ( 'signin-refused', 'Odoo did not accept that sign-in' ) if $err->is_invalid_credential;
        }
    }
    return ( 'internal', 'the sign-in failed inside the engine - see the event log' );
}

# sign_out( \%connection, $sid ) -> 1
#
# Ends the session at Odoo. Idempotent, and never an error: a session Odoo has
# already forgotten is signed out as far as anyone can tell.
sub sign_out {
    my ( $conn, $sid ) = @_;
    return 1 unless defined $sid && $sid =~ $ID;
    eval { _transport( $conn, session => $sid )->destroy };
    return 1;
}

1;
