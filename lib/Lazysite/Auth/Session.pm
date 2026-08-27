package Lazysite::Auth::Session;

# Manager CSRF tokens (SM079) and, since SM411, THE session-cookie verifier.
#
# CSRF: an HMAC over "csrf:$user:$hourbucket" keyed by the site secret, with a
# one-hour grace window and constant-time compare. The secret reuses
# lazysite/auth/.secret if present, else a dedicated minted manager secret.
#
# verify_session_cookie: the FULL verification chain that lazysite-auth.pl's
# wrapper performs - parse, HMAC, payload shape, expiry, account-disabled,
# session-revoked, and a FRESH group resolution (SEC-2026-07 M5: never the
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
use JSON::PP       ();
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use Lazysite::Util qw(const_eq log_event);
use Exporter 'import';

our @EXPORT_OK = qw(generate_csrf_token verify_csrf_token
    verify_session_cookie account_disabled load_user_groups session_revoked
    SESSION_COOKIE_NAME SESSION_COOKIE_MAX);

# One name, one lifetime, stated once. lazysite-auth.pl mints with these and
# this module verifies with them; a drift between the two is a login that
# cannot be verified, so they live where the verifier lives.
# Plain subs, not the constant pragma: the house perlcritic profile forbids
# `use constant` (PBP p.55), and a nullary sub inlines identically while
# staying exportable.
sub SESSION_COOKIE_NAME { return 'lazysite_auth' }

our $LAZYSITE_DIR;    # "$DOCROOT/lazysite", set by the script

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
    if ( -f $mpath && open my $mfh, '<', $mpath ) {
        chomp( my $s = <$mfh> );
        close $mfh;
        return $s if length $s;
    }
    # Mint one - fail closed if the CSPRNG is unavailable (M-6).
    make_path( dirname($mpath) ) unless -d dirname($mpath);
    open my $rand, '<:raw', '/dev/urandom'
        or die "Cannot open /dev/urandom - no CSPRNG available: $!\n";
    my $raw = '';
    my $got = read( $rand, $raw, 32 );
    close $rand;
    die "Short read from /dev/urandom\n" unless $got == 32;
    my $s = unpack( 'H*', $raw );
    open my $wfh, '>', $mpath or die "Cannot write $mpath: $!\n";
    # 0660: identity-shared secret (site-user CLI + www-data CGI) - see the
    # auth-secret mint in lazysite-auth.pl. Never any world bits.
    chmod 0o660, $mpath;
    print {$wfh} "$s\n";
    close $wfh;
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
    return '' unless -f $path;
    open my $fh, '<', $path or return '';
    chomp( my $s = <$fh> // '' );
    close $fh;
    return $s;
}

sub _read_cookie {
    my ($name) = @_;
    my $cookies = $ENV{HTTP_COOKIE} // '';
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
# Returns the hashref or undef. Undef covers absent, unreadable, unparseable
# and not-an-object alike; each caller keeps its own default and its own log
# line, because those differ and are what a sysop reads.
sub _read_json_hash {
    my ($path) = @_;
    return undef unless -f $path;
    open my $fh, '<:raw', $path or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $data = eval { JSON::PP::decode_json( $raw // '' ) };
    return ref $data eq 'HASH' ? $data : undef;
}

sub account_disabled {
    my ($username) = @_;
    my $path       = _auth_dir() . '/user-settings.json';
    my $data       = _read_json_hash($path) or return 0;
    my $s          = $data->{$username};
    return ( ref $s eq 'HASH' && $s->{disabled} ) ? 1 : 0;
}

sub session_revoked {
    my ( $user, $ts, $sid ) = @_;
    my $path = _auth_dir() . '/revoked.json';
    return 0 unless -f $path;

    my $data = _read_json_hash($path);
    unless ($data) {
        log_event( 'WARN', $user,
            'revoked.json unreadable or corrupt - treating as empty (NO session is revoked); '
                . 'run lazysite-check and repair or remove the file' );
        return 0;
    }

    my $sids = ref $data->{sids} eq 'HASH' ? $data->{sids} : {};
    return 1 if length($sid) && exists $sids->{$sid};

    my $nb = ref $data->{not_before} eq 'HASH' ? $data->{not_before} : {};
    return 1
        if defined $nb->{$user}
        && $nb->{$user} =~ /^\d+$/
        && $ts < $nb->{$user};
    return 0;
}

sub load_user_groups {
    local $_;    # SM420: while(<>) assigns the GLOBAL $_
    my ($username) = @_;
    my $path = _auth_dir() . '/groups';
    return '' unless -f $path;

    open( my $fh, '<:utf8', $path ) or return '';
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
#   $ident   { user, sid, groups } on success, undef on any failure
#   $why     no-cookie | malformed | signature | expired | disabled | revoked
#   %detail  user => ..., ts => ... where the failing stage knew them, so the
#            caller can log what the wrapper has always logged
#
# groups are resolved FRESH from the groups file, never taken from the cookie
# (SEC-2026-07 M5: a demoted admin must not keep privileged groups for the
# cookie's remaining life). The sid is '' for a legacy pre-SM141 cookie -
# valid until natural expiry, revocable only via not_before.
sub verify_session_cookie {
    my $cookie = _read_cookie(SESSION_COOKIE_NAME);
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

    # SM071: an existing cookie for a now-disabled account is not an identity.
    return ( undef, 'disabled', user => $user ) if account_disabled($user);

    # SM141: a sysop signed this session out (revoked sid) or signed the
    # user out everywhere (not_before). Legacy cookies carry no sid but do
    # carry ts, so not_before kills them too.
    return ( undef, 'revoked', user => $user )
        if session_revoked( $user, $ts, $sid );

    return ( { user => $user, sid => $sid, groups => load_user_groups($user) },
        undef );
}

1;
