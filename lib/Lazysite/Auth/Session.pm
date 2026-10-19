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
    mint_odoo_session renew_odoo_session odoo_cookie_headers odoo_clear_headers odoo_login_of
    SESSION_COOKIE_NAME SESSION_COOKIE_MAX);

# One name, one lifetime, stated once. lazysite-auth.pl mints with these and
# this module verifies with them; a drift between the two is a login that
# cannot be verified, so they live where the verifier lives.
# Plain subs, not the constant pragma: the house perlcritic profile forbids
# `use constant` (PBP p.55), and a nullary sub inlines identically while
# staying exportable.
sub SESSION_COOKIE_NAME { return 'lazysite_auth' }

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
    my $v;

    # $LAZYSITE_DIR is what this module already has - the scripts set it - so
    # this needs no argument threaded through verify_session_cookie, which takes
    # none by design.
    if ( defined $LAZYSITE_DIR && length $LAZYSITE_DIR
        && open my $fh, '<', "$LAZYSITE_DIR/lazysite.conf" )
    {
        while ( my $l = <$fh> ) {
            next unless $l =~ /^\s*session_lifetime\s*:\s*(\d+)\s*$/;
            $v = $1 + 0;
            last;
        }
        close $fh;
    }

    # A zero or a nonsense value is not "never expires": it is a typo, and a
    # session store that honoured it would hand an operator an immortal cookie
    # for a missing digit. Out-of-range falls back to the default and says
    # nothing - this is the request path, not a config linter.
    $v = undef unless defined $v && $v >= 300 && $v <= 31_536_000;
    return $LIFETIME_CACHE{$key} = ( $v // 86400 );
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
sub session_store_fault {
    for my $name (qw(user-settings.json revoked.json)) {
        my ( undef, $state ) = _json_store_state( _auth_dir() . "/$name" );
        return "lazysite/auth/$name" if $state eq 'broken';
    }
    return '';
}

sub load_user_groups {
    local $_;    # SM420: while(<>) assigns the GLOBAL $_
    my ($username) = @_;
    my $path = _auth_dir() . '/groups';
    # SM770: the open decides.
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
    my (%opt) = @_; # SM1160: odoo_stale_ok => 1 - the Odoo endpoint's own refresh asks about a session that needs one

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

    # SM141: two payload shapes are valid. Current cookies are
    # user:ts:sid:groups (sid exactly 16 hex); legacy cookies minted before
    # the session registry are user:ts:groups and stay valid until natural
    # expiry. Groups can contain commas but never colons, so a limit-4 split
    # plus the sid shape check disambiguates.
    my @f = split /:/, $payload, 4;
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

    return ( undef, 'expired', ts => $ts )
        if ( time() - $seen ) >= session_lifetime();

    # SM1160: a session the Odoo sign-in minted has no account to look up. Its groups
    # and its freshness are in the server-side record, and that record is the authority.
    return _verify_odoo_session( $user, $ts, $sid, %opt ) if defined $user && $user =~ /\Aodoo=/;

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
#   request_session( lazysite_dir => $lz, cookie => $header [, proxy => $pid ] )
#     -> ( $ident, undef ) or ( undef, $why, %detail )
#
#   $ident = { user, groups => [ ... ], name, email, sid, no_password, odoo, stale,
#              source => 'cookie' | 'proxy' }
#
# `cookie` is the request's Cookie header and is REQUIRED: a worker serving many
# requests holds the header, not an environment it may trust, so the caller says
# which header it means ('' for none) and nothing here falls back to %ENV.
# `proxy` is Lazysite::Util::proxy_identity's answer for this request when the
# caller already holds it (SM1129: the request is judged once); else it is asked.
#
# A proxy identity is the identity reader's (SM1131: the configured header names,
# the group map). A cookie identity is the verifier's, groups FRESH (SEC-2026-07 M5)
# and then less any group this address is refused for (SM1140) - the filter the
# reader applies to every answer, so a value and the headers made from it give one
# answer. $why and %detail are the verifier's, for the caller's log lines.
#
# odoo_stale_ok is NOT passed through: a stale Odoo session is the Odoo endpoint's
# own question (SM1160), and it asks the verifier directly (SM1181 T8).
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
        my $pi = Lazysite::Auth::Identity::request_identity( lazysite_dir => $dir, proxy => $pid );
        if ( $pi->{source} eq 'proxy' && length $pi->{user} ) {
            return (
                { user => $pi->{user}, groups => [ @{ $pi->{groups} } ],
                    name => $pi->{name} // '', email => $pi->{email} // '',
                    sid => '', no_password => 0, odoo => 0, stale => 0, source => 'proxy' },
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
            odoo => $s->{odoo} ? 1 : 0, stale => $s->{stale} ? 1 : 0, source => 'cookie' },
        undef );
}


# =============================================================================
# SM1160 (inbox L3, rulings 2026-10-18): A SESSION THE ODOO SIGN-IN MINTS.
#
# The identity is `odoo:<login>`; no lazysite account exists or is made. It is a
# session like any other for everything downstream: the same cookie (name, flags,
# lifetime), the same signature, the same sid in the same registry
# (auth/sessions.jsonl), the same revocation (revoked.json by sid), the same CSRF
# token keyed on the user name. What differs is only what the verifier consults.
#
# THE COOKIE PAYLOAD stays user:ts:sid:groups, whose parse is a split on ':' (limit
# 4), so a ':' in the user would break it. The user field is therefore
# `odoo=<login, percent-encoded>`: every byte outside [A-Za-z0-9._@+-] (so ':' and '%'
# too) is %XX. The '=' cannot occur in a local account name (sign-in strips all but
# [a-zA-Z0-9_.-]), so no local payload is ever read as an Odoo one, and the decoded
# identity `odoo:<login>` holds a ':' that no local name can.
#
# THE GROUPS are never in the cookie (SEC-2026-07 M5 stands): the field is empty.
# They are the mapped lazysite groups in the registry record, which the Odoo
# endpoint writes at sign-in and at each refresh. The record is the authority:
# no record, or a record for another user, is no session. The verifier also
# re-applies the CURRENT map and the manager-capability refusal to what the record
# holds, so a mapping removed, or a group that has since gained a capability,
# stops counting at once.
#
# HOW LONG A SESSION LASTS WITHOUT ODOO BEING ASKED: the record's `checked` time
# plus odoo_identity_ttl. Past it the session grants nothing (why `odoo-stale`)
# until the Odoo endpoint's ?csrf=1 asks Odoo and renews the record.
# =============================================================================
sub ODOO_PREFIX { return 'odoo=' }

sub _odoo_enc {
    my ($login) = @_;
    $login =~ s/([^A-Za-z0-9._@+-])/sprintf( '%%%02X', ord $1 )/ge;
    return $login;
}

# The login a payload's user field names, or undef when it is not one.
sub odoo_login_of {
    my ($field) = @_;
    return undef unless defined $field && $field =~ /\Aodoo=([A-Za-z0-9._@+%-]{1,762})\z/;
    ( my $l = $1 ) =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
    require Lazysite::Odoo::SiteSignin;
    return Lazysite::Odoo::SiteSignin::login_ok($l) ? $l : undef;
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

# The newest registry line for a sid that is an Odoo session's, or undef.
sub _odoo_record {
    my ($sid) = @_;
    my $path = _registry_file();
    open my $fh, '<:raw', $path or do { cannot_read( 'session registry', $path ); return undef };
    my $found;
    while ( my $l = <$fh> ) {
        next unless index( $l, $sid ) >= 0;
        my $r = eval { JSON::PP::decode_json($l) };
        next unless ref $r eq 'HASH' && ( $r->{sid} // '' ) eq $sid && $r->{odoo};
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

# mint_odoo_session( login, name, groups => [...], ip, ua ) -> ( $cookie, $ts, $sid ) or ()
# Needs the auth secret, which only a login mints; without one no session can be made.
sub mint_odoo_session {
    my (%a) = @_;
    my $login = $a{login};
    require Lazysite::Odoo::SiteSignin;
    return () unless Lazysite::Odoo::SiteSignin::login_ok($login);
    my $secret = _auth_secret_read();
    return () unless length $secret;
    require Lazysite::Auth::Credential;
    my $now     = $a{now} // time;
    my $sid     = Lazysite::Auth::Credential::generate_random_hex(8);
    my $payload = join ':', ODOO_PREFIX() . _odoo_enc($login), $now, $sid, '';
    my $sig     = hmac_sha256_hex( $payload, $secret );
    ( my $enc = $payload ) =~ s/([^a-zA-Z0-9_.~:-])/sprintf( '%%%02X', ord $1 )/ge;
    _registry_append( {
            sid => $sid, user => "odoo:$login", t => $now + 0, odoo => 1, checked => $now + 0,
            name => _session_field( $a{name}, 100 ), groups => [ @{ $a{groups} || [] } ],
            ip   => _session_field( $a{ip},   45 ),  ua => _session_field( $a{ua}, 120 ),
    } ) or return ();
    return ( "$enc:$sig", $now, $sid );
}

# A newer record for the same session: Odoo was asked again. t stays the issue time so the
# wrapper's pruning and the Sessions page treat it as the one session it is.
sub renew_odoo_session {
    my (%a) = @_;
    my $old = _odoo_record( $a{sid} ) or return 0;
    return _registry_append( {
            %$old, renew => 1, checked => ( $a{now} // time ) + 0,
            name   => _session_field( $a{name} // $old->{name}, 100 ),
            groups => [ @{ $a{groups} || [] } ],
    } );
}

sub _verify_odoo_session {
    my ( $field, $ts, $sid, %opt ) = @_;
    my $login = odoo_login_of($field);
    return ( undef, 'malformed' ) unless defined $login && defined $sid && $sid =~ /\A[[:xdigit:]]{16}\z/;
    my $user = "odoo:$login";
    require Lazysite::Odoo::SiteSignin;
    my $dir = $LAZYSITE_DIR;

    # Off means off: turning the opt-in off ends these sessions at the next request.
    return ( undef, 'odoo-off', user => $user ) unless Lazysite::Odoo::SiteSignin::enabled($dir);

    # An unsecured site (no group grants manager access) treats every signed-in user as a
    # manager (SM138). A person who signed in through Odoo is never one, so the session
    # is not an identity there at all.
    require Lazysite::Auth::Settings;
    {
        no warnings 'once';
        local $Lazysite::Auth::Settings::AUTH_DIR = _auth_dir();
        return ( undef, 'odoo-unsecured', user => $user ) unless Lazysite::Auth::Settings::site_grants_manager();
    }

    $STORE_FAULT = '';
    my $revoked = session_revoked( $user, $ts, $sid );
    return ( undef, 'cannot-tell', user => $user, store => $STORE_FAULT ) if length $STORE_FAULT;
    return ( undef, 'revoked', user => $user ) if $revoked;

    my $rec = _odoo_record($sid);
    return ( undef, 'no-record', user => $user ) unless $rec && ( $rec->{user} // '' ) eq $user;

    my $now = time();
    my $age = $now - ( $rec->{checked} // 0 );
    my $stale = ( $age >= Lazysite::Odoo::SiteSignin::identity_ttl($dir) || $age < -60 ) ? 1 : 0;
    return ( undef, 'odoo-stale', user => $user, sid => $sid ) if $stale && !$opt{odoo_stale_ok};

    # the record's groups, less any the current map no longer grants
    my ($map)   = Lazysite::Odoo::SiteSignin::group_map($dir);
    my %granted = map { ( $_ => 1 ) } values %$map;
    my @groups = $stale ? () : grep { $granted{$_} } @{ ref $rec->{groups} eq 'ARRAY' ? $rec->{groups} : [] };
    return (
        { user => $user, sid => $sid, groups => join( ',', @groups ), no_password => 0,
            odoo => 1, name => $rec->{name} // '', stale => $stale },
        undef );
}

# The two cookies a login sets: the HttpOnly session and the display-only marker
# (SM099), as the wrapper sets them.
sub odoo_cookie_headers {
    my ( $cookie, %o ) = @_;
    my $max = session_lifetime( $o{dir} );
    my $sec = $o{secure} ? '; Secure' : '';
    return ( "Set-Cookie: ${\ SESSION_COOKIE_NAME()}=$cookie; HttpOnly; SameSite=Lax; Path=/; Max-Age=$max$sec",
        "Set-Cookie: lzs_session=1; SameSite=Lax; Path=/; Max-Age=$max$sec" );
}

sub odoo_clear_headers {
    my (%o) = @_;
    my $sec = $o{secure} ? '; Secure' : '';
    return ( "Set-Cookie: ${\ SESSION_COOKIE_NAME()}=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0$sec",
        "Set-Cookie: lzs_session=; SameSite=Lax; Path=/; Max-Age=0$sec" );
}

1;
