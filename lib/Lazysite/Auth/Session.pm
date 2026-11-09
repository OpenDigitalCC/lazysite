package Lazysite::Auth::Session;

# Manager CSRF tokens (SM079) and, since SM411, THE session-cookie verifier.
#
# CSRF: an HMAC over "csrf:$user:$hourbucket" keyed by the site secret, with a
# one-hour grace window and constant-time compare. The secret reuses
# lazysite/auth/.secret if present, else a dedicated minted manager secret.
#
# verify_session_cookie: the FULL verification chain that lazysite-auth.pl's
# wrapper performs - parse, HMAC, payload shape, expiry, account-exists
# (SM1070), account-disabled, session-revoked, and a FRESH group resolution (SEC-2026-07 M5: never the
# groups baked into the cookie). Extracted so that a surface that cannot sit
# behind the wrapper can still hold a real identity: SM402 measured what
# happens otherwise - the form handler trusted X-Remote-User as the client
# sent it. The data endpoint (SM410 DP-3) is the second caller by design.
# One chain, one module; lazysite-auth.pl delegates to it.
#
# Context is $LAZYSITE_DIR, set by the script.

use strict;
use warnings;
use Digest::SHA    qw(hmac_sha256_hex);
use Fcntl          ();
use JSON::PP       ();
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use Lazysite::Util qw(const_eq log_event cannot_read write_private_atomic);
use Exporter 'import';

our @EXPORT_OK = qw(generate_csrf_token verify_csrf_token
    verify_session_cookie request_session account_disabled load_user_groups session_revoked session_store_fault
    mint_provider_session renew_provider_session session_cookie_headers session_clear_headers
    provider_login_of require_provider_reauth SESSION_COOKIE_NAME SESSION_COOKIE_MAX);

# One name, one lifetime, stated once. lazysite-auth.pl mints with these and
# this module verifies with them; a drift between the two is a login that
# cannot be verified, so they live where the verifier lives.
# Plain subs, not the constant pragma: the house perlcritic profile forbids
# `use constant` (PBP p.55), and a nullary sub inlines identically while
# staying exportable.
sub SESSION_COOKIE_NAME { return 'lazysite_auth' }

# SM1390: the first field of the preview cookie's payload (Manager::Preview
# mints `v1:...`, gates.pm's check_preview reads it), which a session payload
# may never begin with; and how far ahead of this host's clock a session's
# issue time may be before it is refused as not yet valid.
sub PREVIEW_MARKER { return 'v1' }
sub CLOCK_SKEW     { return 300 }

our $LAZYSITE_DIR;    # the engine tree (Lazysite::Paths::lazysite_dir), set by the script

# SM614: the session lifetime is a SETTING, and this is the one place it is
# read. It was a constant here and a second constant in Manager/Sessions.pm,
# with a comment asking that the two be kept in step - which is a request, not a
# mechanism. The sysop asked whether the lifetime could be set for one user
# or all; the answer is now yes, for all, in lazysite.conf.
#
# The default is the 24 hours it has always been, so an instance that sets
# nothing behaves exactly as before.
#
# Read once per process: this is on the request path and lazysite.conf does not
# change under a running request.
# Keyed by DIRECTORY, not a single scalar. One process normally serves one site
# and a bare cache would be correct - but Manager::Sessions localises
# $LAZYSITE_DIR to ask on another site's behalf, and a global cache would have
# answered for whichever site asked first. That is the sort of thing that is
# right in every test and wrong on a multi-site instance.
our %LIFETIME_CACHE;

sub session_lifetime {

    # The directory may be passed IN. verify_session_cookie takes no arguments
    # and uses the module's own $LAZYSITE_DIR, which is why this defaults to it
    # - but a caller asking on another site's behalf should say so plainly
    # rather than localise a global in another package. Manager::Sessions does
    # exactly that, and reaching into $Lazysite::Auth::Session::LAZYSITE_DIR
    # from outside earned a used-only-once warning that t/lint/04 refuses:
    # a variable mentioned once in a file is indistinguishable from a typo.
    my ($dir) = @_;
    local $LAZYSITE_DIR = $dir if defined $dir && length $dir;
    my $key = $LAZYSITE_DIR // '';
    return $LIFETIME_CACHE{$key} if defined $LIFETIME_CACHE{$key};
    # $LAZYSITE_DIR is what this module already has - the scripts set it - so
    # this needs no argument threaded through verify_session_cookie, which takes
    # none by design.
    my ( $v, $bad ) = _session_lifetime_read();

    # A zero or a nonsense value is not "never expires": it is a typo, and a
    # session store that honoured it would hand an operator an immortal cookie
    # for a missing digit. Ruling 206: nor is it the default - an invalid value
    # is refused (session_lifetime_fault, asked by the sign-in gate and the
    # verifier). The default here is only what a caller that displays the
    # lifetime is shown; no session is minted or honoured on it.
    return $LIFETIME_CACHE{$key} = ( defined $bad ? 86400 : ( $v // 86400 ) );
}

# ( $seconds, undef ) for a valid session_lifetime, ( undef, undef ) for none,
# or ( undef, $raw ) for a value that is not a whole number of seconds from 300
# to 31536000 - the raw text, for the refusal to name.
sub _session_lifetime_read {
    return ( undef, undef ) unless defined $LAZYSITE_DIR && length $LAZYSITE_DIR;
    open my $fh, '<', "$LAZYSITE_DIR/lazysite.conf" or return ( undef, undef ); # not a store
    my $raw;
    while ( my $l = <$fh> ) {
        next unless $l =~ /^\s*session_lifetime\s*:\s*(.*?)\s*$/;
        $raw = $1;
        last;
    }
    close $fh;
    return ( undef,    undef ) unless defined $raw && length $raw; # an empty key is unset
    return ( $raw + 0, undef ) if $raw =~ /\A\d+\z/ && $raw >= 300 && $raw <= 31_536_000;
    return ( undef,    $raw );
}

# Ruling 206 (item 8 of the 0.16.9 fault survey): '' or the sentence naming an
# invalid session_lifetime. Out of range used to become the default in silence.
# Read once per process per site, as session_lifetime is (%LIFETIME_CACHE).
our %LIFETIME_FAULT_CACHE;

sub session_lifetime_fault {
    my ($dir) = @_;
    local $LAZYSITE_DIR = $dir if defined $dir && length $dir;
    my $key = $LAZYSITE_DIR // '';
    return $LIFETIME_FAULT_CACHE{$key} if defined $LIFETIME_FAULT_CACHE{$key};
    my ( undef, $bad ) = _session_lifetime_read();
    return $LIFETIME_FAULT_CACHE{$key} = defined $bad
        ? "session_lifetime in lazysite.conf is '$bad', which is not a whole number of "
        . 'seconds from 300 to 31536000'
        : '';
}

# Kept for callers that have no docroot to hand, and as the default. NOT the
# source of truth any more - session_lifetime() is.
sub SESSION_COOKIE_MAX { return 86400 }    # 24 hours, the default


sub _csrf_secret {

    # DA-25: the first branch WAS _auth_secret_read, written out again. The
    # copy also chomped an undef read from an empty file; the shared reader
    # defaults it to '', which is the same answer without the warning.
    my $auth = _auth_secret_read();
    return $auth if length $auth;
    # Dedicated manager secret (only used if the auth secret is missing).
    my $mpath = "$LAZYSITE_DIR/manager/.csrf-secret";
    # SM917: -f guard gone (subtest 3's rule), and the failure reported. The mint
    # below is right for a site that has no manager secret yet; it is wrong for
    # one whose secret exists and cannot be read, because a SECOND secret
    # invalidates every CSRF token already issued against the first - every open
    # manager tab starts refusing its own forms, with nothing saying why.
    if ( open my $mfh, '<', $mpath ) {
        chomp( my $s = <$mfh> );
        close $mfh;
        return $s if length $s;
    }
    else { cannot_read( 'the manager CSRF secret', $mpath ) }
    # Mint one - fail closed if the CSPRNG is unavailable (M-6).
    make_path( dirname($mpath) ) unless -d dirname($mpath);
    open my $rand, '<:raw', '/dev/urandom'
        or die "Cannot open /dev/urandom - no CSPRNG available: $!\n";
    my $raw = '';
    my $got = read( $rand, $raw, 32 );
    close $rand;
    die "Short read from /dev/urandom\n" unless $got == 32;
    my $s = unpack( 'H*', $raw );
    # 0660: identity-shared secret (site-user CLI + www-data CGI) - see the
    # auth-secret mint in lazysite-auth.pl. Never any world bits (SM1183: not
    # in the file's first instant either - it is created 0660).
    my ( $wok, $werr ) = write_private_atomic( $mpath, "$s\n", 0660 );
    die "$werr\n" unless $wok;
    return $s;
}

sub generate_csrf_token {
    my ($user) = @_;
    my $ts = int( time() / 3600 );        # rotates hourly
    return hmac_sha256_hex( "csrf:$user:$ts", _csrf_secret() );
}

sub verify_csrf_token {
    my ( $token, $user ) = @_;
    return 0 unless defined $token && length $token;
    return 0 unless defined $user  && length $user;
    my $secret = _csrf_secret();
    for my $ts ( int( time() / 3600 ), int( time() / 3600 ) - 1 ) {
        my $expected = hmac_sha256_hex( "csrf:$user:$ts", $secret );
        return 1 if const_eq( $token, $expected );
    }
    return 0;
}



# --- SM411: the session-cookie verification chain ---------------------------

sub _auth_dir { return "$LAZYSITE_DIR/auth" }

# Read-only, deliberately. login mints the secret (with the shared-group mode
# the setgid auth dir needs); VERIFICATION must never create state - a missing
# secret simply means no cookie can verify, which is already true.
sub _auth_secret_read {
    my $path = _auth_dir() . '/.secret';
    # SM770: the open decides; a stat guard hides a permissions fault as absence.
    open my $fh, '<', $path or return ( cannot_read( '.secret', $path ) // '' );
    chomp( my $s = <$fh> // '' );
    close $fh;
    return $s;
}

# SM1181: the Cookie header may be passed in (request_session's `cookie`); the
# environment is read only when it is not.
sub _read_cookie {
    my ( $name, $header ) = @_;
    my $cookies = ( @_ > 1 ? $header : $ENV{HTTP_COOKIE} ) // '';
    for my $pair ( split /;\s*/, $cookies ) {
        my ( $k, $v ) = split /=/, $pair, 2;
        $k =~ s/^\s+|\s+$//g if defined $k;
        return $v            if defined $k && $k eq $name;
    }
    return '';
}

sub _uri_decode {
    my ($str) = @_;
    $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $str;
}

# DA-22: the open-slurp-decode-is-it-a-hash read, once for this file's two
# JSON stores. ADR 0001: RAW OCTETS - decode_json expects UTF-8 bytes, and
# reading through a :utf8 layer first hands it a character string that dies on
# any non-ASCII content.
#
# SM1024 (ruled 2026-10-12, "Close all three"): THREE ANSWERS, not two. It
# returned undef for absent, unreadable and undecodable alike, and the callers
# told them apart by reading $! after cannot_read had clobbered it. Both read a
# broken store as the permissive answer - a broken revoked.json revoked
# nothing, a broken user-settings.json disabled nobody. Now ( $hash, 'ok' ),
# ( undef, 'absent' ) - a fresh site, which is an answer - or ( undef,
# 'broken' ): the store exists and cannot be opened or decoded, which is
# cannot-tell. Errno is read before cannot_read.
sub _json_store_state {
    my ($path) = @_;
    open my $fh, '<:raw', $path or do {
        my $absent = $!{ENOENT} ? 1 : 0;
        cannot_read( 'session', $path );
        return ( undef, $absent ? 'absent' : 'broken' );
    };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $data = eval { JSON::PP::decode_json( $raw // '' ) };
    return ref $data eq 'HASH' ? ( $data, 'ok' ) : ( undef, 'broken' );
}

# The docroot-relative name of the session store the last account_disabled or
# session_revoked found broken, for verify_session_cookie's cannot-tell answer.
our $STORE_FAULT = '';

# A broken store fails CLOSED: the account reads as disabled (1), and
# $STORE_FAULT names the store so the caller can say cannot-tell rather than
# "disabled". Absent: nobody is disabled.
sub account_disabled {
    my ($username) = @_;
    my $path = _auth_dir() . '/user-settings.json';
    my ( $data, $state ) = _json_store_state($path);
    if ( $state eq 'broken' ) {
        $STORE_FAULT = 'lazysite/auth/user-settings.json';
        log_event( 'WARN', $username // '-',
            'user-settings.json cannot be read or does not decode - refusing sign-in and every '
                . 'session until it is repaired (lazysite check --docroot names it)' );
        return 1;
    }
    return 0 unless $data;
    my $s = $data->{$username};
    return ( ref $s eq 'HASH' && $s->{disabled} ) ? 1 : 0;
}

# SM141 / SM1024: a broken revoked.json fails CLOSED - every session reads as
# revoked, and $STORE_FAULT names the store. It used to read as "nothing is
# revoked" with a WARN, which let a signed-out session straight back in. No
# revocations file at all is the ordinary state of a site that has never
# revoked anything.
sub session_revoked {
    my ( $user, $ts, $sid ) = @_;
    my $path = _auth_dir() . '/revoked.json';
    my ( $data, $state ) = _json_store_state($path);
    return 0 if $state eq 'absent';
    unless ($data) {
        $STORE_FAULT = 'lazysite/auth/revoked.json';
        log_event( 'WARN', $user,
            'revoked.json cannot be read or does not decode - refusing every session until it '
                . 'is repaired (lazysite check --docroot names it)' );
        return 1;
    }

    my $sids = ref $data->{sids} eq 'HASH' ? $data->{sids} : {};
    return 1 if length($sid) && exists $sids->{$sid};

    my $nb = ref $data->{not_before} eq 'HASH' ? $data->{not_before} : {};
    return 0
        unless defined $nb->{$user}
        && $nb->{$user} =~ /^\d+$/
        && $ts < $nb->{$user};

    # SM1040: a credential change signs the account's OTHER sessions out and
    # keeps the one that made it, named beside the not_before it is exempt
    # from. The exemption holds only while that not_before stands, so a later
    # sign-out-everywhere ends it too. A legacy cookie has no sid to name.
    # Lazysite::Manager::Sessions::session_is_kept is the listing's copy of
    # this rule; t/unit/auth/40 holds the two to one answer.
    my $kept = ref $data->{kept} eq 'HASH' ? $data->{kept}{$user} : undef;
    return 0
        if length $sid
        && ref $kept eq 'HASH'
        && defined $kept->{sid} && $kept->{sid} eq $sid
        && defined $kept->{nb}  && $kept->{nb} =~ /^\d+$/
        && $kept->{nb} == $nb->{$user};
    return 1;
}

# SM1070 (n562, ruled 2026-10-13): is this account still in lazysite/auth/users?
# Returns ( 'ok', $no_password ), ( 'absent' ) - the store answered and the name
# is not in it, an absent store included (a site with no accounts) - or
# ( 'broken' ): the store exists and cannot be opened, which is cannot-tell
# (SM1024), never "exists". One open and a scan that stops at the account's own
# line; the hash is read only to say whether it is empty, which the auth wrapper
# flags as a passwordless account, so the wrapper reads the store once, here.
sub _account_state {
    my ($username) = @_;
    my $path = _auth_dir() . '/users';
    open my $fh, '<:utf8', $path or do {
        my $absent = $!{ENOENT} ? 1 : 0;    # errno first: cannot_read clobbers $!
        cannot_read( 'users', $path );
        return $absent ? ('absent') : ('broken');
    };
    while ( defined( my $line = <$fh> ) ) {
        chomp $line;
        $line =~ s/^\s+|\s+$//g;
        next if $line =~ /^#/ || !length $line;
        my ( $u, $hash ) = split /:/, $line, 2;
        next unless defined $u && defined $hash && $u eq $username;
        close $fh;
        return ( 'ok', length $hash ? 0 : 1 );
    }
    close $fh;
    return ('absent');
}

# SM1024: the first session store that exists and cannot be read or decoded,
# docroot-relative, or '' - asked by the sign-in gate before a cookie issues,
# so a sign-in is refused as cannot-tell rather than reported as a bad password
# or a disabled account. Opens each store itself (SM770: the open decides).
#
# Ruling 206 (item 6 of the 0.16.9 fault survey): and the `groups` file. One
# that exists and will not open read as "no groups", so a session was minted
# carrying none - which lifts every rule that DENIES by group (a locked group,
# an address-limited one) - and every request on an existing session lost its
# groups the same way. Absent is a site with no groups: no fault.
sub session_store_fault {
    for my $name (qw(user-settings.json revoked.json)) {
        my ( undef, $state ) = _json_store_state( _auth_dir() . "/$name" );
        return "lazysite/auth/$name" if $state eq 'broken';
    }
    return 'lazysite/auth/groups' if _groups_unreadable();
    # Ruling 206 (item 8): and the setting that says how long a session lasts.
    return 'lazysite/lazysite.conf (session_lifetime)' if session_lifetime_fault();
    return '';
}

# 1 when lazysite/auth/groups exists and cannot be opened (SM770: the open
# decides; ENOENT is an answer). Errno is read before cannot_read clobbers it.
sub _groups_unreadable {
    my $path = _auth_dir() . '/groups';
    open( my $fh, '<:utf8', $path ) or do {
        my $absent = $!{ENOENT} ? 1 : 0;
        cannot_read( 'groups', $path );    # silent for ENOENT
        return $absent ? 0 : 1;
    };
    close $fh;
    return 0;
}

sub load_user_groups {
    local $_;    # SM420: while(<>) assigns the GLOBAL $_
    my ($username) = @_;
    my $path = _auth_dir() . '/groups';
    # SM770: the open decides. A caller that must not mint or honour a session
    # on a broken store asks session_store_fault (or _groups_unreadable) first.
    open( my $fh, '<:utf8', $path ) or return ( cannot_read( 'groups', $path ) // '' );
    my @groups;
    while (<$fh>) {
        chomp;
        s/^\s+|\s+$//g;
        next if /^#/ || !length;
        my ( $group, $members ) = split /:\s*/, $_, 2;
        next unless defined $members;
        my @m = map { s/^\s+|\s+$//gr } split /,/, $members;
        push @groups, $group if grep { $_ eq $username } @m;
    }
    close $fh;
    return join( ',', @groups );
}

# The full chain, and the ONLY correct way to turn a session cookie into an
# identity. Returns ( $ident, $why, %detail ):
#
#   $ident   { user, sid, groups, no_password } on success, undef on any failure
#   $why     no-cookie | malformed | signature | expired | no-account |
#            disabled | revoked | cannot-tell
#   %detail  user => ..., ts => ... where the failing stage knew them, so the
#            caller can log what the wrapper has always logged
#
# groups are resolved FRESH from the groups file, never taken from the cookie
# (SEC-2026-07 M5: a demoted admin must not keep privileged groups for the
# cookie's remaining life). The sid is '' for a legacy pre-SM141 cookie -
# valid until natural expiry, revocable only via not_before.
sub verify_session_cookie {
    my (%opt) = @_; # SM1160, X4: stale_ok => 1 - a provider's own refresh asks about a session that needs one

    # SM1181: $STORE_FAULT is this call's answer, cleared before anything else. The
    # stages below clear it before they set it, but a call that returned before them
    # (no cookie, a bad signature) left the LAST call's fault standing - harmless in
    # a CGI that verifies once, not in a process that verifies request after request.
    $STORE_FAULT = '';

    # SM1181: `cookie => $header` is the request's Cookie header, given by a caller
    # that holds it (request_session); without it the environment's.
    my $cookie = exists $opt{cookie}
        ? _read_cookie( SESSION_COOKIE_NAME, $opt{cookie} )
        : _read_cookie(SESSION_COOKIE_NAME);
    return ( undef, 'no-cookie' ) unless $cookie;

    my ( $payload, $sig ) = $cookie =~ /^(.+):([a-f0-9]{64})$/;
    return ( undef, 'malformed' ) unless $payload && $sig;
    $payload = _uri_decode($payload);

    my $secret = _auth_secret_read();
    return ( undef, 'signature' )
        unless length($secret)
        && const_eq( $sig, hmac_sha256_hex( $payload, $secret ) );

    # Ruling 206 (item 8): with session_lifetime invalid, when this session
    # expires cannot be told - cannot-tell, never the default.
    if ( my $why = session_lifetime_fault() ) {
        log_event( 'WARN', '-', "session refused: cannot tell - $why "
                . '(lazysite check --docroot names it)' );
        return ( undef, 'cannot-tell', store => 'lazysite/lazysite.conf' );
    }

    # SM1390 (ruling 147): A VALUE SIGNED FOR ANOTHER PURPOSE IS NOT A SESSION.
    # The preview cookie is signed with the same key over
    # `v1:<exp>:<layout>:<theme>:<user>`, and that parsed here as a legacy
    # session for an account named `v1` with the preview's expiry as its issue
    # time (found at the SM1383 walk). The preview marker is refused as a first
    # field before anything else is read; the preview verifier refuses a
    # session shape the same way (lazysite-processor/gates.pm check_preview).
    # Chosen over a purpose prefix in the signed text because a prefix changes
    # the format every cookie in flight carries; this changes nothing a
    # sign-in issues.
    return ( undef, 'malformed' ) if $payload =~ /\A\Q${\ PREVIEW_MARKER()}\E:/;

    # SM141: two payload shapes are valid. Current cookies are
    # user:ts:sid:groups (sid exactly 16 hex); legacy cookies minted before
    # the session registry are user:ts:groups and stay valid until natural
    # expiry. Groups can contain commas but never colons, so the split plus
    # the sid shape check disambiguates. SM1390: the limit is 5, not 4, so the
    # five-field branch below is REACHABLE - with a limit of 4 it never ran,
    # and the sliding cookie it was written for verified as legacy with no
    # sid (found at the SM1383 walk; t/unit/auth/76 drives it).
    my @f = split /:/, $payload, 5;
    my ( $user, $ts, $sid );
    # SM614: THE READER UNDERSTANDS THREE SHAPES, and only two are ever issued
    # today. This is deliberate groundwork, not speculation.
    #
    #   user|ts             legacy, pre-sid
    #   user|ts|sid|sig     what is issued now
    #   user|ts|seen|sid|sig  what SLIDING will issue
    #
    # Sliding expiry needs a last-seen time that MOVES while `ts` stays put -
    # `ts` is the issue time, and session_revoked compares it against
    # not_before, so overwriting it would silently defeat "sign out everywhere".
    # Teaching the reader the five-field shape NOW means the day sliding is
    # switched on there is no flag day: every running instance already accepts
    # the cookie the new writer will produce. Readers before writers.
    #
    # Nothing issues five fields yet. Until the writer exists this branch is
    # unreachable in production and exercised only by t/unit/auth/... - which is
    # the point: the migration is proved before it is needed rather than during.
    my $seen;
    if ( @f == 5 && defined $f[3] && $f[3] =~ /\A[0-9a-f]{16}\z/ ) {
        ( $user, $ts, $seen, $sid ) = @f[ 0, 1, 2, 3 ];
        undef $seen unless defined $seen && $seen =~ /^\d+$/;
    }
    elsif ( @f == 4 && defined $f[2] && $f[2] =~ /\A[0-9a-f]{16}\z/ ) {
        ( $user, $ts, $sid ) = @f[ 0, 1, 2 ];
    }
    else {
        ( $user, $ts ) = @f[ 0, 1 ];
        $sid = '';
    }

    return ( undef, 'expired', ts => $ts // 'undef' )
        unless defined $ts && $ts =~ /^\d+$/;

    # A cookie carrying no last-seen time is its own last-seen time - which is
    # exactly today's behaviour, so a four-field cookie expires when it always
    # did. One expression answers for both shapes rather than two branches that
    # can drift.
    $seen = $ts unless defined $seen;

    # SM1390 (ruling 147): A TIMESTAMP IN THE FUTURE IS REFUSED. The lifetime
    # check below only asks whether the cookie is too OLD, so a value stamped
    # years ahead verified for years; the preview cookie's expiry was one such
    # value. CLOCK_SKEW is the allowance for a cookie minted on another host of
    # the same site whose clock runs ahead; it is stated in the contract
    # (docs/architecture/session-cookie-contract.md).
    return ( undef, 'expired', ts => $ts )
        if $ts > time() + CLOCK_SKEW() || $seen > time() + CLOCK_SKEW();

    return ( undef, 'expired', ts => $ts )
        if ( time() - $seen ) >= session_lifetime();

    # SM1160, SM1369 X4: a session an identity provider minted (`<id>=<login>`) has no
    # account to look up. Its groups and its freshness are in the server-side record,
    # and that record is the authority. A local name cannot hold '=', so no local
    # payload is ever read as a provider's.
    return _verify_provider_session( $user, $ts, $sid, %opt ) if defined $user && index( $user, '=' ) >= 0;

    # SM1070: a cookie for an account that is no longer in the store is not an
    # identity. Removing an account deletes its line, its groups and its
    # settings - its disabled flag with them - so without this the cookie went
    # on verifying as that name until it expired. Asked FIRST, so a removed
    # account answers no-account whatever its revocations say. An unreadable
    # store is cannot-tell (SM1024), never "exists".
    $STORE_FAULT = '';
    my ( $account, $no_password ) = _account_state($user);
    return ( undef, 'cannot-tell', user => $user, store => 'lazysite/auth/users' )
        if $account eq 'broken';
    return ( undef, 'no-account', user => $user ) if $account eq 'absent';

    # SM071: an existing cookie for a now-disabled account is not an identity.
    # SM1024: and one whose store cannot be read is not one either - answered
    # as cannot-tell, naming the store, never as "disabled" or "revoked".
    my $disabled = account_disabled($user);
    return ( undef, 'cannot-tell', user => $user, store => $STORE_FAULT ) if length $STORE_FAULT;
    return ( undef, 'disabled', user => $user ) if $disabled;

    # SM141: a sysop signed this session out (revoked sid) or signed the
    # user out everywhere (not_before). Legacy cookies carry no sid but do
    # carry ts, so not_before kills them too.
    my $revoked = session_revoked( $user, $ts, $sid );
    return ( undef, 'cannot-tell', user => $user, store => $STORE_FAULT ) if length $STORE_FAULT;
    return ( undef, 'revoked', user => $user ) if $revoked;

    # Ruling 206: a groups file that will not open is cannot-tell, never "no groups".
    return ( undef, 'cannot-tell', user => $user, store => 'lazysite/auth/groups' )
        if _groups_unreadable();

    return (
        { user => $user, sid => $sid, groups => load_user_groups($user),
            no_password => $no_password },
        undef );
}

# SM1181 S1 (SM1082 C2, ruled 2026-10-19 R2): WHO THIS REQUEST IS, DECIDED ONCE, AS A
# VALUE.
#
# The auth wrapper's handle_request and the data endpoint each held SM1130's rule in
# a copy of their own - a trusted proxy's user wins and the cookie is not consulted;
# otherwise the session cookie, through the verifier above - and the pool's front
# door would have been a third copy. This is the rule, and every caller asks it, so
# the CGI path and the pool cannot come to decide differently (SM1181 T10,
# t/integration/290).
#
#   request_session( lazysite_dir => $lz, cookie => $header [, proxy => $pid ]
#                    [, pool => 1 ] )
#     -> ( $ident, undef ) or ( undef, $why, %detail )
#
#   $ident = { user, groups => [ ... ], name, email, sid, no_password, provider, stale,
#              source => 'cookie' | 'proxy' }
#
# `provider` is the id of the identity provider that minted the session (X4), ''
# for any other.
#
# `cookie` is the request's Cookie header and is REQUIRED: a worker serving many
# requests holds the header, not an environment it may trust, so the caller says
# which header it means ('' for none) and nothing here falls back to %ENV.
# `proxy` is Lazysite::Util::proxy_identity's answer for this request when the
# caller already holds it (SM1129: the request is judged once); else it is asked.
# `pool => 1` says the caller is a FastCGI worker (the pool's front door), and is
# passed to the identity reader. SM1181 S5, the open point S4 found: without it a
# LAZYSITE_AUTH_TRUSTED FastCGI parameter made the reader take the fixed names as a
# wrapper-vouched identity, so a listed proxy's user was passed over and the
# cookie decided. That failed closed, but broke R3 (the pool never believes the
# sentinel from %ENV) and SM1130's order. Plain CGI passes nothing, as before.
#
# A proxy identity is the identity reader's (SM1131: the configured header names,
# the group map). A cookie identity is the verifier's, groups FRESH (SEC-2026-07 M5)
# and then less any group this address is refused for (SM1140) - the filter the
# reader applies to every answer, so a value and the headers made from it give one
# answer. $why and %detail are the verifier's, for the caller's log lines.
#
# stale_ok is NOT passed through: a stale provider session is the provider's own
# endpoint's question (SM1160), and it asks the verifier directly (SM1181 T8).
sub request_session {
    my (%opt) = @_;
    $STORE_FAULT = '';
    for my $k (qw(lazysite_dir cookie)) {
        die "request_session: `$k` is required (the request's "
            . ( $k eq 'cookie' ? "Cookie header, '' for none" : 'lazysite directory' ) . ")\n"
            unless exists $opt{$k};
    }
    my $dir = $opt{lazysite_dir};
    local $LAZYSITE_DIR = $dir;
    require Lazysite::Auth::Identity;

    my $pid = ref $opt{proxy} eq 'HASH' ? $opt{proxy} : Lazysite::Util::proxy_identity($dir);
    if ( $pid->{trusted} ) {
        # SM297: `identity => undef` - this decides the value, so it reads the
        # request, never a value a converted surface already holds.
        my $pi = Lazysite::Auth::Identity::request_identity( lazysite_dir => $dir, proxy => $pid,
            pool => $opt{pool} ? 1 : 0, identity => undef );
        if ( $pi->{source} eq 'proxy' && length $pi->{user} ) {
            return (
                { user => $pi->{user}, groups => [ @{ $pi->{groups} } ],
                    name => $pi->{name} // '', email => $pi->{email} // '',
                    sid => '', no_password => 0, provider => '', stale => 0, source => 'proxy' },
                undef );
        }
    }

    my ( $s, $why, %detail ) = verify_session_cookie( cookie => $opt{cookie} // '' );
    return ( undef, $why, %detail ) unless $s;

    my %seen;
    my @groups = grep { length && !$seen{$_}++ } split /,/, ( $s->{groups} // '' );
    my $allowed = Lazysite::Auth::Identity::address_allowed_groups( \@groups, lazysite_dir => $dir );
    return (
        { user => $s->{user}, groups => $allowed, name => $s->{name} // '', email => '',
            sid => $s->{sid} // '', no_password => $s->{no_password} ? 1 : 0,
            provider => $s->{provider} // '', stale => $s->{stale} ? 1 : 0, source => 'cookie' },
        undef );
}

# SM297 (ruling 206, ruling 217): A SIGNED-IN REQUEST WHOSE SESSION STORE CANNOT BE
# READ IS REFUSED, never rendered as anonymous. request_session's `cannot-tell`
# (with `store`) is the fault value; the auth wrapper (CGI) and the pool's front
# door both answer it with this sentence and a 503, and the log line above names
# the store and this repair. Only an unreadable or undecodable store is a fault: no
# cookie, an expired cookie or a missing record is an ordinary signed-out visitor.
sub SESSION_FAULT_REPAIR {
    return 'lazysite check --docroot <docroot> names it; repair it from the command line';
}

sub session_fault_text {
    my ($store) = @_;
    $store = 'its session store' unless defined $store && length $store && $store ne '-';
    return "This page cannot be served right now: the site cannot read $store, so it "
        . "cannot tell who is signed in. This is a fault on the host, not a decision about "
        . "this request; the site operator can repair it from the command line "
        . "(lazysite check names it).\n";
}

# SM1181 S3 (T11): THE LOG LINE FOR WHAT request_session DECIDED, one for each
# outcome, at the level each has always had. The auth wrapper wrote these in its
# handle_request; the pool's front door now decides a signed-in page in the worker
# and must leave the same evidence, so both take the line from here and neither can
# come to log differently.
#
#   session_log_line( $ident, $why, \%detail, cookie_sent => 0|1 )
#     -> ( $level, $message, %fields ) or () when nothing is logged
#
# No cookie value is ever a field. SM1099: the ordinary cases (a valid session, no
# cookie, a provider's session not accepted) are DEBUG, so a site's traffic does not fill
# the web server's error log; a cookie that should have worked and did not is WARN.
sub session_log_line {
    my ( $ident, $why, $detail, %o ) = @_;
    my %d = %{ $detail || {} };
    if ($ident) {
        # SM1130: a trusted proxy's user wins; worth a line only when a cookie was
        # set aside for it.
        return () if $ident->{source} eq 'proxy' && !$o{cookie_sent};
        return ( 'DEBUG', 'auth: proxy identity wins, cookie ignored', proxy_user => $ident->{user} )
            if $ident->{source} eq 'proxy';
        return ( 'DEBUG', 'auth: cookie valid',
            user => $ident->{user}, groups => join( ',', @{ $ident->{groups} || [] } ) );
    }
    $why //= '';
    return ( 'DEBUG', 'auth: no cookie' )          if $why eq 'no-cookie';
    return ( 'WARN',  'auth: cookie malformed' )   if $why eq 'malformed';
    return ( 'WARN',  'auth: signature mismatch' ) if $why eq 'signature';
    return ( 'WARN', 'auth: cookie expired or malformed ts', ts => $d{ts} // 'undef' ) if $why eq 'expired';
    # SM1070: the account was removed (or renamed) after this cookie was issued.
    return ( 'WARN', 'auth: account does not exist', user => $d{user} ) if $why eq 'no-account';
    # SM071: an existing cookie for a now-disabled account.
    return ( 'WARN', 'auth: account disabled', user => $d{user} ) if $why eq 'disabled';
    # SM1024: a session store cannot be read or decoded, so whether this session is
    # disabled or signed out is unknown - refused, as no identity.
    return ( 'WARN', 'auth: cannot tell - session refused until the store is repaired',
        user => $d{user}, store => $d{store}, repair => SESSION_FAULT_REPAIR() )
        if $why eq 'cannot-tell';
    # SM1160, X4: a provider-minted session that is not an identity: the provider is
    # off (its extension, or its own sign-in), the site is unsecured, the provider has
    # not been asked within its time (stale), a provider function failed, or the
    # server-side record is gone. The why is `<id>-<state>`, so Odoo's keep their names
    # (odoo-off, odoo-unsecured, odoo-stale).
    if ( $why eq 'no-record' || $why =~ /\A([a-z][a-z0-9-]{0,31})-(?:off|unsecured|stale|failed)\z/ ) {
        my $p = $d{provider} // ( $why ne 'no-record' && $why =~ /\A(.+)-[a-z]+\z/ ? $1 : 'provider' );
        return ( 'DEBUG', "auth: $p session not accepted ($why)", user => $d{user} );
    }
    # SM141: an operator signed this session out (revoked sid) or signed the user out
    # everywhere (not_before). Legacy cookies carry no sid but do carry ts, so
    # not_before ends them too.
    return ( 'WARN', 'auth: session revoked', user => $d{user} ) if $why eq 'revoked';
    return ();
}


# =============================================================================
# SM1160 (inbox L3, rulings 2026-10-18), SM1369 X4 (H-1, ruling 55): A SESSION AN
# IDENTITY PROVIDER MINTS.
#
# An identity provider is an extension that signs a person in by its own means -
# Odoo's login was the first (SM1160), and this is its session made generic in
# place - and declares `owns.hooks.identity_provider` (Lazysite::Extensions::Hooks,
# "X4"). Its id is the extension's id, and the identity is `<id>:<login>`; no
# lazysite account exists or is made. It is a session like any other for
# everything downstream: the same cookie (name, flags, lifetime), the same
# signature, the same sid in the same registry (auth/sessions.jsonl), the same
# revocation (revoked.json by sid), the same CSRF token keyed on the user name.
# What differs is only what the verifier consults.
#
# ONLY CORE SIGNS (G-2). The provider asks for a session (mint_provider_session)
# and never sees the key; core writes the record and the cookie.
#
# THE COOKIE PAYLOAD stays user:ts:sid:groups, whose parse is a split on ':', so a
# ':' in the user would break it. The user field is therefore `<id>=<login,
# percent-encoded>`: every byte outside [A-Za-z0-9._@+-] (so ':' and '%' too) is
# %XX. The '=' cannot occur in a local account name (sign-in strips all but
# [a-zA-Z0-9_.-]), so no local payload is ever read as a provider's, and the decoded
# identity `<id>:<login>` holds a ':' that no local name can. An `odoo=` cookie
# minted before X4 is exactly this shape, so it verifies unchanged.
#
# THE GROUPS are never in the cookie (SEC-2026-07 M5 stands): the field is empty.
# They are in the registry record, which the provider's sign-in writes and each
# renewal replaces. The record is the authority: no record, or a record for another
# user or another provider, is no session. At each verification the provider says
# which of the record's groups it still grants (its `groups` hook, its current map),
# and core then refuses any of them that carries a capability (G-3) - unless the
# provider declares `grants`, which only an OIDC provider will (ruling 186); every
# sign-in or renewal through such a provider is audited with the groups it granted.
#
# HOW LONG A SESSION LASTS WITHOUT THE PROVIDER BEING ASKED: the provider's
# `still_valid` hook decides from the record (Odoo: its `checked` time plus
# odoo_identity_ttl). A stale session grants nothing (why `<id>-stale`, with the
# provider's `renew` path) until the provider's endpoint asks again and renews it.
#
# A PROVIDER THAT IS OFF, OR FAILS, SIGNS NOBODY IN (G-1, G-9). The extension must
# be enabled and indexed at the call (Hooks::identity_provider reads lazysite.conf
# again), the provider's `on` must say yes, and any of its functions that cannot be
# called, dies or answers something else refuses the session.
# =============================================================================

# The login a payload's user field names, as ( $provider_id, $login ), or () when
# it is not one. The login's shape is core's rule (provider_login_ok).
sub provider_login_of {
    my ($field) = @_;
    return () unless defined $field && $field =~ /\A([a-z][a-z0-9-]{0,31})=([A-Za-z0-9._@+%-]{1,762})\z/;
    my $id = $1;
    ( my $l = $2 ) =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
    return provider_login_ok($l) ? ( $id, $l ) : ();
}

# A login an identity `<id>:<login>` may be made of: what the provider reported,
# bounded and free of anything that would break a header, a log line or an audit
# field. (Odoo's SiteSignin::login_ok, the same rule, made core's.)
sub provider_login_ok {
    my ($login) = @_;
    return defined $login && !ref $login && length $login && length $login <= 254
        && $login !~ /[\x00-\x1f\x7f|]/ ? 1 : 0;
}

sub _provider_enc {
    my ($login) = @_;
    $login =~ s/([^A-Za-z0-9._@+-])/sprintf( '%%%02X', ord $1 )/ge;
    return $login;
}

sub _registry_file { return _auth_dir() . '/sessions.jsonl' }

sub _registry_append {
    my ($rec) = @_;
    my $path  = _registry_file();
    my $line  = JSON::PP->new->canonical->encode($rec) . "\n";
    my $new   = !-e $path;
    sysopen( my $fh, $path, Fcntl::O_WRONLY() | Fcntl::O_APPEND() | Fcntl::O_CREAT(), 0o660 ) or return 0;
    binmode $fh;
    my $ok = defined syswrite( $fh, $line );
    close $fh;
    chmod 0o660, $path if $new;
    return $ok ? 1 : 0;
}

# Which provider a registry record is of. A record written before X4 carries the
# provider's id as a flag (`odoo => 1`, SM1160) and no `provider`: it is that
# provider's, so a session signed in before the upgrade stays one.
sub _record_provider {
    my ( $r, $id ) = @_;
    return $r->{provider} if defined $r->{provider} && !ref $r->{provider};
    return $id            if defined $id            && ( $r->{$id} // '' ) eq '1';
    return '';
}

# The newest registry line for a sid that is a provider session's, or undef. With
# $id, only that provider's.
sub _provider_record {
    my ( $sid, $id ) = @_;
    my $path = _registry_file();
    open my $fh, '<:raw', $path or do { cannot_read( 'session registry', $path ); return undef };
    my $found;
    while ( my $l = <$fh> ) {
        next unless index( $l, $sid ) >= 0;
        my $r = eval { JSON::PP::decode_json($l) };
        next unless ref $r eq 'HASH' && ( $r->{sid} // '' ) eq $sid;
        my $p = _record_provider( $r, $id );
        next unless length $p && ( !defined $id || $p eq $id );
        $found = $r;
    }
    close $fh;
    return $found;
}

sub _session_field {
    my ( $s, $cap ) = @_;
    $s = '' unless defined $s;
    $s =~ s/[\x00-\x1f\x7f]//g;
    return length $s > $cap ? substr( $s, 0, $cap ) : $s;
}

# The provider's declaration, from the index of the enabled extensions, or undef.
sub _provider {
    my ($id) = @_;
    require Lazysite::Extensions::Hooks;
    return Lazysite::Extensions::Hooks::identity_provider( $LAZYSITE_DIR, $id );
}

# Call one of a provider's functions: ( 1, @answer ) or ( 0, $why ).
sub _provider_call {
    my ( $p, $fn, @args ) = @_;
    return ( 0, "the provider declares no $fn" ) unless defined $p->{$fn} && !ref $p->{$fn};
    require Lazysite::Paths;
    my $docroot = Lazysite::Paths::docroot_of($LAZYSITE_DIR);
    return ( 0, 'the site\'s docroot cannot be found from its engine tree' ) unless defined $docroot;
    require Lazysite::Extensions::Hooks;
    # SM1351: an instances provider is told which of its providers is asked.
    my %ctx = ( docroot => $docroot, lazysite_dir => $LAZYSITE_DIR,
        ( defined $p->{instance} ? ( provider => $p->{provider}, instance => $p->{instance} ) : () ) );
    return Lazysite::Extensions::Hooks::call_hook( $docroot, $p->{extension}, $p->{$fn}, \%ctx, @args );
}

# The site's audit trail, for a sign-in through a provider whose groups grant.
sub _audit_grant {
    my ( $user, $act, $id, $groups, $ip ) = @_;
    require Lazysite::Audit;
    no warnings 'once';
    local $Lazysite::Audit::LAZYSITE_DIR = $LAZYSITE_DIR;
    ( my $host = lc( $ENV{HTTP_HOST} // '' ) ) =~ s/:\d+\z//;
    $host =~ s/[^a-z0-9.-]//g;
    Lazysite::Audit::audit_log( $user, $act, $host, $ip // '', 'ok', $id,
        'groups granted: ' . ( @$groups ? join( ',', @$groups ) : '(none)' ) );
    return;
}

# mint_provider_session( provider => id, login, name, groups => [...], ip, ua )
#   -> ( $cookie, $ts, $sid ) or ()
# The provider must be declared and on (G-1). Needs the auth secret, which only a
# login mints; without one no session can be made.
sub mint_provider_session {
    my (%a) = @_;
    my $login = $a{login};
    my $p     = _provider( $a{provider} ) or return ();
    # SM1351: `<id>-<name>` for an instances provider
    my $id = $p->{provider} // $p->{extension};
    return () unless provider_login_ok($login);
    my $secret = _auth_secret_read();
    return () unless length $secret;
    require Lazysite::Auth::Credential;
    my $now     = $a{now} // time;
    my $sid     = Lazysite::Auth::Credential::generate_random_hex(8);
    my $payload = join ':', "$id=" . _provider_enc($login), $now, $sid, '';
    my $sig     = hmac_sha256_hex( $payload, $secret );
    ( my $enc = $payload ) =~ s/([^a-zA-Z0-9_.~:-])/sprintf( '%%%02X', ord $1 )/ge;
    my @groups = grep { defined && !ref } @{ ref $a{groups} eq 'ARRAY' ? $a{groups} : [] };
    _registry_append( {
            sid => $sid, user => "$id:$login", t => $now + 0, provider => $id, checked => $now + 0,
            name => _session_field( $a{name}, 100 ), groups => [@groups],
            ip   => _session_field( $a{ip},   45 ),  ua => _session_field( $a{ua}, 120 ),
    } ) or return ();
    _audit_grant( "$id:$login", 'login-grant', $id, \@groups, $a{ip} ) if ( $p->{grants} // '' ) eq '1';
    return ( "$enc:$sig", $now, $sid );
}

# renew_provider_session( provider => id, sid, name, groups => [...] ) -> 1 | 0
# A newer record for the same session: the provider was asked again. t stays the
# issue time so the wrapper's pruning and the Sessions page treat it as the one
# session it is.
sub renew_provider_session {
    my (%a) = @_;
    my $p   = _provider( $a{provider} ) or return 0;
    my $id  = $p->{provider} // $p->{extension};
    my $old = _provider_record( $a{sid}, $id ) or return 0;
    # SM1351: with `login`, only that person's session is renewed.
    return 0 if defined $a{login} && ( $old->{user} // '' ) ne "$id:$a{login}";
    my @groups = grep { defined && !ref } @{ ref $a{groups} eq 'ARRAY' ? $a{groups} : [] };
    my %rec    = %$old;
    delete $rec{reauth};    # ruling 214: the provider was asked again
    my $ok = _registry_append( {
            %rec, provider => $id, renew => 1, checked => ( $a{now} // time ) + 0,
            name   => _session_field( $a{name} // $old->{name}, 100 ),
            groups => [@groups],
    } );
    _audit_grant( $old->{user}, 'renew-grant', $id, \@groups, $a{ip} ) if $ok && ( $p->{grants} // '' ) eq '1';
    return $ok;
}

# RULING 214 (Q128): "REQUIRE SIGN-IN AGAIN" FOR A PROVIDER'S SESSION.
#
# require_provider_reauth( sid ) -> provider id, or '' when the sid is no
# provider's session. A newer line for the session marks it (`reauth`); the
# verifier then treats it as stale - no groups, refused with the provider's
# `renew` path - until the provider is asked again and renew_provider_session
# writes a line without the mark. No token is stored: the provider is asked by
# signing the person in again. The line carries `renew` so the Sessions page,
# which lists a session by its first line, still lists it once.
sub require_provider_reauth {
    my ($sid) = @_;
    return '' unless defined $sid && $sid =~ /\A[[:xdigit:]]{16}\z/;
    my $old = _provider_record($sid) or return '';
    my $id  = _record_provider($old);
    return '' unless length $id;
    _registry_append( { %$old, provider => $id, renew => 1, reauth => time + 0 } ) or return '';
    return $id;
}

sub _verify_provider_session {
    my ( $field, $ts, $sid, %opt ) = @_;
    my ( $id, $login ) = provider_login_of($field);
    return ( undef, 'malformed' ) unless defined $login && defined $sid && $sid =~ /\A[[:xdigit:]]{16}\z/;
    my $user = "$id:$login";
    my %who  = ( user => $user, provider => $id );

    # Off means off: an extension that is off, or not indexed, verifies nothing, and
    # nor does a provider whose own sign-in is switched off - at the next request.
    my $p = _provider($id) or return ( undef, "$id-off", %who );
    my ( $ok, $on ) = _provider_call( $p, 'on' );
    return ( undef, "$id-failed", %who, error => $on ) unless $ok;
    return ( undef, "$id-off", %who ) unless $on;

    # An unsecured site (no group grants manager access) treats every signed-in user as a
    # manager (SM138). A person a provider signed in is never one that way, so the
    # session is not an identity there at all.
    require Lazysite::Auth::Settings;
    {
        no warnings 'once';
        local $Lazysite::Auth::Settings::AUTH_DIR = _auth_dir();
        return ( undef, "$id-unsecured", %who ) unless Lazysite::Auth::Settings::site_grants_manager();
    }

    $STORE_FAULT = '';
    my $revoked = session_revoked( $user, $ts, $sid );
    return ( undef, 'cannot-tell', user => $user, store => $STORE_FAULT ) if length $STORE_FAULT;
    return ( undef, 'revoked', user => $user ) if $revoked;

    my $rec = _provider_record( $sid, $id );
    return ( undef, 'no-record', %who ) unless $rec && ( $rec->{user} // '' ) eq $user;

    my ( $vok, $state ) = _provider_call( $p, 'still_valid', {%$rec} );
    return ( undef, "$id-failed", %who, error => $state ) unless $vok && defined $state && !ref $state && $state =~ /\A(?:ok|stale)\z/;
    my $stale = $state eq 'stale' ? 1 : 0;
    $stale = 1 if $rec->{reauth};    # ruling 214: marked to sign in again
    # SM1381: the stale verdict says where the session is renewed (the provider's path)
    return ( undef, "$id-stale", %who, sid => $sid, renew => $p->{renew} // '' ) if $stale && !$opt{stale_ok};

    my @groups;
    unless ($stale) {
        my ( $gok, $held ) = _provider_call( $p, 'groups', {%$rec} );
        return ( undef, "$id-failed", %who, error => $held ) unless $gok && ref $held eq 'ARRAY';
        my %seen;
        @groups = grep { defined && !ref && /\A[A-Za-z0-9_-]{1,64}\z/ && !$seen{$_}++ } @$held;
        # G-3: no group that carries a capability, unless the provider's groups grant.
        unless ( ( $p->{grants} // '' ) eq '1' ) {
            no warnings 'once';
            local $Lazysite::Auth::Settings::AUTH_DIR = _auth_dir();
            my @kept;
            for my $g (@groups) {
                my $why = Lazysite::Auth::Settings::group_carries_capability($g);
                if ( length $why ) {
                    log_event( 'WARN', 'auth', 'a provider group is refused: it would grant a capability',
                        provider => $id, group => $g, why => $why );
                    next;
                }
                push @kept, $g;
            }
            @groups = @kept;
        }
    }
    return (
        { user => $user, sid => $sid, groups => join( ',', @groups ), no_password => 0,
            provider => $id, name => $rec->{name} // '', stale => $stale },
        undef );
}

# The two cookies a sign-in sets: the HttpOnly session and the display-only marker
# (SM099), as the wrapper sets them.
sub session_cookie_headers {
    my ( $cookie, %o ) = @_;
    my $max = session_lifetime( $o{dir} );
    my $sec = $o{secure} ? '; Secure' : '';
    return ( "Set-Cookie: ${\ SESSION_COOKIE_NAME()}=$cookie; HttpOnly; SameSite=Lax; Path=/; Max-Age=$max$sec",
        "Set-Cookie: lzs_session=1; SameSite=Lax; Path=/; Max-Age=$max$sec" );
}

sub session_clear_headers {
    my (%o) = @_;
    my $sec = $o{secure} ? '; Secure' : '';
    return ( "Set-Cookie: ${\ SESSION_COOKIE_NAME()}=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0$sec",
        "Set-Cookie: lzs_session=; SameSite=Lax; Path=/; Max-Age=0$sec" );
}

1;
