package Lazysite::Manager::Account;

# SM1043 (SM1034 phase 1a, ruled 2026-10-12 "Accept, build phase 1"): the
# member's own account, as a closed family of `me-*` control-API actions.
#
# THE SUBJECT IS ALWAYS THE CALLER. Not a default, not a parameter that happens
# to be checked - none of these actions reads an account name from the request
# at all. The account is $auth_user, which the dispatcher took from the session
# the auth wrapper verified. A session id handed to me-session-revoke is checked
# to be one of the caller's own live sessions before anything is done, and an id
# that is somebody else's answers exactly as an id that does not exist, so ids
# cannot be probed. Lazysite::ControlApi::Actions declares each of these `self`,
# and t/lint/246 refuses an account, user or name parameter on a self action and
# any read of one in this file.
#
# COOKIE ONLY. A token client is refused: these are a person's own credentials
# and sessions, and SM918 already ruled per-principal state out of the token
# door. No capability is needed and none is granted - every signed-in account
# reaches its own, and only its own.
#
# RE-AUTHENTICATION PER REQUEST (ruled, Q3): a password change carries the
# current password. Every such check counts against the sign-in rate limiter -
# the caller's address and the account both - so a stolen session is not an
# unthrottled way to guess the password behind it.
#
# CSRF and the audit row are the dispatcher's, as for every action: the method-
# keyed gate covers every POST, and the generic audit block records each write
# against the account. Nothing a request carries is recorded - not the password.
#
# `account_page: disabled` in lazysite.conf turns the whole family off (and the
# /account page with it); the refusal names the setting.
#
# Index
#   account_page_enabled       the account_page switch, read once per call
#   action_me                  me: who am I - login, name, address, 2FA, groups
#   dispatch_me_password         me-password: current + new; the others sign out
#   action_me_sessions         me-sessions: my live sessions, this one marked
#   dispatch_me_session_revoke   me-session-revoke: one of MY sessions
#   action_me_sign_out_everywhere  me-sign-out-everywhere: all of mine, this too
#   action_me_notices          me-notices: the notices addressed to me (1b)
#   dispatch_me_notices_seen   me-notices-seen: mark mine read or dismissed (1b)
#   dispatch_me_2fa_enrol      me-2fa-enrol: set up my two-factor (1c)
#   dispatch_me_2fa_confirm    me-2fa-confirm: turn it on with a code (1c)
#   dispatch_me_2fa_disable    me-2fa-disable: turn it off - password and code (1c)
#   dispatch_me_recovery_codes me-recovery-codes: new recovery codes (1c)
#   action_me_passkeys         me-passkeys: my passkeys, and whether this site can use them (SM1352)
#   dispatch_me_passkey_begin  me-passkey-begin: the password, then a challenge to add one
#   dispatch_me_passkey_add    me-passkey-add: the browser's answer, verified and stored
#   dispatch_me_passkey_remove me-passkey-remove: one of mine
#   action_me_push             me-push: may this site push, its key, my devices (SM1363)
#   dispatch_me_push_subscribe   me-push-subscribe: notices on for this device
#   dispatch_me_push_unsubscribe me-push-unsubscribe: notices off for this device
#   dispatch_me_phone          me-phone: my phone, for text notices (ruling 196)

use strict;
use warnings;
use Exporter 'import';
use JSON::PP                   ();
use Lazysite::Util             qw(log_event);
use Lazysite::Auth::Credential qw(verify_password password_policy_refusal password_min_length);
use Lazysite::Auth::LoginRate   ();
use Lazysite::Auth::Verify      ();
use Lazysite::Manager::Sessions ();
use Lazysite::Manager::Notices  ();    # SM1034 phase 1b: the one notice reader
use Lazysite::Manager::Common qw($auth_user $token_auth users_api _request_ip _json_body);

our @EXPORT_OK = qw(account_page_enabled action_me dispatch_me_password action_me_sessions
    dispatch_me_session_revoke action_me_sign_out_everywhere me_refusal
    action_me_notices dispatch_me_notices_seen
    dispatch_me_2fa_enrol dispatch_me_2fa_confirm dispatch_me_2fa_disable dispatch_me_recovery_codes
    action_me_passkeys dispatch_me_passkey_begin dispatch_me_passkey_add dispatch_me_passkey_remove
    action_me_push dispatch_me_push_subscribe dispatch_me_push_unsubscribe dispatch_me_phone);

our $DOCROOT;                          # set by the script
our $LAZYSITE_DIR;                     # set by the script

# The account_page switch (ruled Q2: on by default, it grants nothing). The one
# reader is Lazysite::Util's, which the processor asks for /account, so the page
# and its actions cannot disagree.
sub account_page_enabled {
    my ($lazysite_dir) = @_;
    return Lazysite::Util::account_page_enabled( $lazysite_dir // $LAZYSITE_DIR );
}

# The one gate every me-* action passes first: undef to proceed, a refusal
# otherwise. Outside a request $auth_user is '' and the answer is a refusal.
sub me_refusal {
    return { ok => 0, kind => 'forbidden',
        error => 'Your account page answers for a signed-in account, and no account is asking.' }
        unless length $auth_user;
    return { ok => 0, kind => 'forbidden',
        error => 'Your account is managed in a signed-in browser session, not with an access key.' }
        if $token_auth;
    return { ok => 0, kind => 'disabled',
        error => 'The account page is turned off on this site (account_page: disabled in lazysite.conf).' }
        unless account_page_enabled();
    return undef;
}

# Count one password or code check against the sign-in rate limiter, by the
# caller's address and by the account. Both are asked every time, so a run of
# guesses is stopped whichever of the two it spreads across.
sub _rate_refusal {
    my %ctx     = ( auth_dir => "$LAZYSITE_DIR/auth", docroot => $DOCROOT );
    my $ip_ok = Lazysite::Auth::LoginRate::check_login_rate( _request_ip(), %ctx );
    # Ruling 206: a limiter that cannot count refuses as cannot-tell.
    return Lazysite::Auth::LoginRate::fault_refusal()
        if length $Lazysite::Auth::LoginRate::FAULT;
    my $acct_ok = Lazysite::Auth::LoginRate::check_login_rate( "account=$auth_user", %ctx );
    return undef if $ip_ok && $acct_ok;
    log_event( 'WARN', $auth_user, 'account page: re-authentication rate limit exceeded',
        ip => _request_ip() );
    return { ok => 0, kind => 'rate',
        error => 'Too many attempts. Wait a few minutes and try again.' };
}

# Is this the caller's current password? Counted against the limiter first.
# Returns undef when it is, a refusal otherwise. A wrong password pauses before
# answering, as a wrong sign-in does.
sub _reauth_refusal {
    my ($password) = @_;
    if ( my $r = _rate_refusal() ) { return $r }
    my %users  = Lazysite::Auth::Verify::read_users();
    my $stored = $users{$auth_user};
    return undef
        if defined $password && length $password
        && defined $stored   && length $stored
        && verify_password( $password, $stored );
    log_event( 'WARN', $auth_user, 'account page: current password did not match', ip => _request_ip() );
    sleep 1;
    return { ok => 0, kind => 'forbidden', field => 'current_password',
        error => 'That is not your current password.' };
}

# me: the account asking, as it is - nothing here is editable in phase 1, and
# nothing secret is in it. 2FA is reported as a state, never a secret.
sub action_me {
    if ( my $r = me_refusal() ) { return $r }
    my $s     = Lazysite::Auth::Verify::effective_settings( $DOCROOT, $auth_user ) || {};
    return {
        ok           => 1,
        user         => $auth_user,
        display_name => $s->{display_name},
        email        => $s->{email},
        phone        => $s->{phone},          # SM1363 (ruling 196)
        has_password => ( _has_password() ? JSON::PP::true() : JSON::PP::false() ), # SM1352: not the passkey marker
        mfa_enrolled => ( $s->{mfa_enrolled} ? JSON::PP::true() : JSON::PP::false() ),
        mfa_pending  => ( $s->{mfa_pending}  ? JSON::PP::true() : JSON::PP::false() ),
        groups              => [ @{ $s->{groups} || [] } ],
        password_min_length => password_min_length($LAZYSITE_DIR),
    };
}

# me-password: the current password and a new one. The new one meets the site's
# policy (SM1041); on success every OTHER session of the account ends and this
# one stays (SM1040) - the users tool does both, given this session's verified id.
sub dispatch_me_password {
    if ( my $r = me_refusal() ) { return $r }
    my $req = _json_body() || {};
    my $new = $req->{new_password};
    return { ok => 0, kind => 'invalid', field => 'new_password',
        error => 'new_password is required (in the JSON body).' }
        unless defined $new && !ref $new && length $new;
    if ( my $r = _reauth_refusal( $req->{current_password} ) ) { return $r }
    if ( defined( my $why = password_policy_refusal( $new, $LAZYSITE_DIR ) ) ) {
        return { ok => 0, kind => 'invalid', field => 'new_password', error => $why };
    }
    my $sid = $ENV{LAZYSITE_AUTH_SID} // '';
    $sid = '' unless $sid =~ /\A[0-9a-f]{16}\z/;
    my $r = users_api( {
            action   => 'passwd',
            username => $auth_user,
            password => $new,
            actor    => $auth_user,
            keep_sid => $sid,
    } );
    return { ok => 0, error => ( ref $r eq 'HASH' && $r->{error} ) || 'The password could not be changed.' }
        unless ref $r eq 'HASH' && $r->{ok};
    return { ok => 1, message => 'Password changed. Your other sessions have been signed out.' };
}

# The caller's own live sessions: the Sessions listing's rule (fresh, not
# revoked, not before the account's not_before unless kept), narrowed to the
# account. The registry's address and browser are the caller's own.
sub _my_sessions {
    no warnings 'once';    # set by the dispatcher; read here by full name
    local $Lazysite::Manager::Sessions::LAZYSITE_DIR = $LAZYSITE_DIR;
    my $all = Lazysite::Manager::Sessions::action_sessions_list();
    return [ grep { $_->{user} eq $auth_user } @{ $all->{sessions} || [] } ];
}

sub action_me_sessions {
    if ( my $r = me_refusal() ) { return $r }
    my @rows = map {
        { sid => $_->{sid}, ip => $_->{ip}, ua => $_->{ua}, issued => $_->{issued},
            current => $_->{current} }
    } @{ _my_sessions() };
    return { ok => 1, sessions => \@rows };
}

# One of MY sessions. An id that is not one of the caller's live sessions -
# malformed, expired, somebody else's - gets the same answer, so the action
# says nothing about any session but the caller's own.
sub dispatch_me_session_revoke {
    if ( my $r = me_refusal() ) { return $r }
    my $req  = _json_body() || {};
    my $sid  = $req->{sid};
    my %mine = map { $_->{sid} => 1 } @{ _my_sessions() };
    return { ok => 0, kind => 'not-found',
        error => 'No session of yours has that id. Reload the list and choose one from it.' }
        unless defined $sid && !ref $sid && $mine{$sid};
    no warnings 'once';
    local $Lazysite::Manager::Sessions::LAZYSITE_DIR = $LAZYSITE_DIR;
    local $Lazysite::Manager::Sessions::auth_user    = $auth_user;
    my $r = Lazysite::Manager::Sessions::action_session_revoke($sid);
    return $r unless ref $r eq 'HASH' && $r->{ok};
    return { ok => 1, sid => $sid,
        current => ( ( $ENV{LAZYSITE_AUTH_SID} // '' ) eq $sid ? JSON::PP::true() : JSON::PP::false() ) };
}

# --- SM1042 (SM1034 phase 1c): the member's own two-factor -------------------
#
# Ruled 2026-10-12, "Self-enrol only": the account enrols its own second factor,
# here, and sees its own secret and recovery codes once; a manager can reset it
# and never set it up (Manager::Users refuses the enrolment verbs, and the users
# tool refuses them for any actor that is not the account). Re-authentication
# (Q3): enrolling needs the current password; turning it off or regenerating the
# recovery codes needs the password AND a current code - the authenticator's,
# or one recovery code, which it then uses up. Every check counts against the
# sign-in rate limiter, once per request.

# A current code for the caller: the users tool's mfa-verify, which refuses a
# replayed time-step and consumes a recovery code. undef when it matches.
sub _code_refusal {
    my ($code) = @_;
    $code = '' unless defined $code && !ref $code;
    $code =~ s/[^0-9A-Za-z-]//g;
    my $v = length $code
        ? users_api( { action => 'mfa-verify', username => $auth_user, code => $code } )
        : undef;
    return undef if ref $v eq 'HASH' && $v->{ok};
    log_event( 'WARN', $auth_user, 'account page: 2FA code did not match', ip => _request_ip() );
    sleep 1;
    return { ok => 0, kind => 'forbidden', field => 'code',
        error => 'That code is not right. Use the current code from your app, or one recovery code.' };
}

sub _mfa_state {
    my $s = Lazysite::Auth::Verify::effective_settings( $DOCROOT, $auth_user ) || {};
    return ( $s->{mfa_enrolled} ? 'on' : $s->{mfa_pending} ? 'pending' : 'off' );
}

# Set up: the current password, then a new secret and recovery codes - shown to
# this account, once. Not while 2FA is on: turn it off first, so a stolen
# session holding the password cannot quietly replace the person's authenticator.
sub dispatch_me_2fa_enrol {
    if ( my $r = me_refusal() ) { return $r }
    my $req = _json_body() || {};
    return { ok => 0, kind => 'conflict', field => 'mfa',
        error => 'Two-factor is already on. Turn it off first to set it up again.' }
        if _mfa_state() eq 'on';
    if ( my $r = _reauth_refusal( $req->{current_password} ) ) { return $r }
    my $r = users_api( { action => 'mfa-enroll', username => $auth_user, actor => $auth_user } );
    return { ok => 0, error => ( ref $r eq 'HASH' && $r->{error} ) || 'Two-factor could not be set up.' }
        unless ref $r eq 'HASH' && $r->{ok};
    return { ok => 1, secret => $r->{secret}, otpauth_uri => $r->{otpauth_uri},
        recovery_codes => $r->{recovery_codes}, pending => JSON::PP::true() };
}

# Confirm a pending set-up with a code from the app - only now is it enforced.
sub dispatch_me_2fa_confirm {
    if ( my $r = me_refusal() ) { return $r }
    my $req = _json_body() || {};
    return { ok => 0, kind => 'conflict', field => 'mfa',
        error => 'There is no two-factor set-up waiting to be confirmed.' }
        unless _mfa_state() eq 'pending';
    if ( my $r = _rate_refusal() ) { return $r }
    my $code = $req->{code};
    $code = '' unless defined $code && !ref $code;
    my $r = users_api( { action => 'mfa-confirm', username => $auth_user, code => $code,
            actor => $auth_user } );
    return { ok => 0, kind => 'forbidden', field => 'code',
        error => ( ref $r eq 'HASH' && $r->{error} ) || 'That code did not match.' }
        unless ref $r eq 'HASH' && $r->{ok};
    return { ok => 1, message => 'Two-factor is on. You will be asked for a code when you sign in.' };
}

# Turn it off: the password and a current code. Every OTHER session of the
# account ends and this one stays (SM1040). A set-up never confirmed is
# cancelled with the password alone - nothing was enforced, and its code may
# never have been seen.
sub dispatch_me_2fa_disable {
    if ( my $r = me_refusal() ) { return $r }
    my $req   = _json_body() || {};
    my $state = _mfa_state();
    return { ok => 0, kind => 'conflict', field => 'mfa', error => 'Two-factor is not on.' }
        if $state eq 'off';
    if ( my $r = _reauth_refusal( $req->{current_password} ) ) { return $r }
    if ( $state eq 'on' ) {
        if ( my $r = _code_refusal( $req->{code} ) ) { return $r }
    }
    my $sid = $ENV{LAZYSITE_AUTH_SID} // '';
    $sid = '' unless $sid =~ /\A[0-9a-f]{16}\z/;
    my $r = users_api( { action => 'mfa-disable', username => $auth_user, keep_sid => $sid } );
    return { ok => 0, error => ( ref $r eq 'HASH' && $r->{error} ) || 'Two-factor was not turned off.' }
        unless ref $r eq 'HASH' && $r->{ok};
    return { ok => 1, message => $state eq 'on'
        ? 'Two-factor is off. Your other sessions have been signed out.'
        : 'The two-factor set-up was cancelled.' };
}

# New recovery codes: the password and a current code; the old codes stop
# working. Shown to this account, once.
sub dispatch_me_recovery_codes {
    if ( my $r = me_refusal() ) { return $r }
    my $req = _json_body() || {};
    return { ok => 0, kind => 'conflict', field => 'mfa', error => 'Two-factor is not on.' }
        unless _mfa_state() eq 'on';
    if ( my $r = _reauth_refusal( $req->{current_password} ) ) { return $r }
    if ( my $r = _code_refusal( $req->{code} ) )               { return $r }
    my $r = users_api( { action => 'mfa-recovery-regenerate', username => $auth_user,
            actor => $auth_user } );
    return { ok => 0, error => ( ref $r eq 'HASH' && $r->{error} ) || 'New codes could not be made.' }
        unless ref $r eq 'HASH' && $r->{ok};
    return { ok => 1, recovery_codes => $r->{recovery_codes} };
}

# --- SM1352: the member's own passkeys ------------------------------------------
#
# Listed, added and removed by the account they sign in, here, and by nobody
# else: an operator can only remove them all (the users tool's passkey-wipe, on
# the Users page), for a lost phone. Adding one needs the current password when
# the account has one - a stolen session must not be able to plant a way back in
# - and a challenge issued to this account for enrolment, which the browser's
# answer must carry (Lazysite::Auth::Passkey). Without CryptX each action says
# so, and the list says it too.

sub _has_password {
    my %users = Lazysite::Auth::Verify::read_users();
    my $h     = $users{$auth_user} // '';
    return ( length $h && $h ne '!passkey' ) ? 1 : 0;
}

sub _site_name {
    open my $fh, '<:raw', "$LAZYSITE_DIR/lazysite.conf" or return undef;
    my $text = do { local $/; <$fh> };
    close $fh;
    my $n = Lazysite::Util::conf_text_value( $text, 'site_name' );
    return defined $n && length $n ? $n : undef;
}

sub _passkey_view {
    my ($p) = @_;
    return { id => $p->{id}, label => $p->{label} // '', created => $p->{created},
        used => $p->{used}, alg => $p->{alg} };
}

sub action_me_passkeys {
    if ( my $r = me_refusal() ) { return $r }
    require Lazysite::Auth::Passkey;
    require Lazysite::Crypto;
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = "$LAZYSITE_DIR/auth";
    my $missing = Lazysite::Crypto::cryptx_missing();
    return {
        ok => 1,
        available => ( $missing ? JSON::PP::false() : JSON::PP::true() ),
        ( $missing ? ( needs => $missing ) : () ),
        has_password => ( _has_password() ? JSON::PP::true() : JSON::PP::false() ),
        passkeys => [ map { _passkey_view($_) } @{ Lazysite::Auth::Passkey::passkeys_of($auth_user) } ],
    };
}

# Step one of adding: the current password (when the account has one), then a
# challenge for this account and what the browser needs to make the passkey.
sub dispatch_me_passkey_begin {
    if ( my $r = me_refusal() ) { return $r }
    require Lazysite::Auth::Passkey;
    require Lazysite::Crypto;
    if ( my $m = Lazysite::Crypto::cryptx_missing() ) { return { ok => 0, kind => 'unavailable', error => $m } }
    my $req = _json_body() || {};
    my ( $rp, $origin ) = Lazysite::Auth::Passkey::rp_of();
    # Ruling 199: an account that signs in by passkey only - no password of its own,
    # or a passkey_only group - adds one after a FRESH ASSERTION by a passkey it
    # already holds, never on its session alone. Others give the current password.
    my $only = Lazysite::Auth::Passkey::passkey_only($auth_user);
    if ( _has_password() && defined $only && !$only ) {
        if ( my $r = _reauth_refusal( $req->{current_password} ) ) { return $r }
    }
    elsif ( my $r = _passkey_reauth_refusal( $req->{assertion}, $rp, $origin ) ) { return $r }

    return { ok => 0, error => 'This request has no host a passkey can belong to.' } unless defined $rp;
    my ( $ch, $why ) = Lazysite::Auth::Passkey::issue_challenge( "$LAZYSITE_DIR/auth",
        purpose => 'enrol', user => $auth_user );
    return { ok => 0, error => $why } unless defined $ch;
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = "$LAZYSITE_DIR/auth";
    my $s = Lazysite::Auth::Verify::effective_settings( $DOCROOT, $auth_user ) || {};
    return {
        ok           => 1,
        challenge    => $ch,
        rp_id        => $rp,
        rp_name      => ( _site_name() // $rp ),
        user_id      => Lazysite::Auth::Passkey::b64u_encode($auth_user),
        user_name    => $auth_user,
        user_display => ( $s->{display_name} // $auth_user ),
        algorithms   => [ Lazysite::Auth::Passkey::algorithms() ],
        exclude => [ map { $_->{id} } @{ Lazysite::Auth::Passkey::passkeys_of($auth_user) } ],
        timeout => $Lazysite::Auth::Passkey::CHALLENGE_TTL * 1000,
    };
}

# Ruling 199: undef when the assertion is a fresh one by one of the account's own
# passkeys, answering a re-authentication challenge issued to it; otherwise the
# refusal - which, with no assertion yet, carries that challenge. Counted
# against the sign-in rate limiter like a password check.
sub _passkey_reauth_refusal {
    my ( $as, $rp, $origin ) = @_;
    my $mine = Lazysite::Auth::Passkey::passkeys_of($auth_user);
    return { ok => 0, kind => 'forbidden',
        error => 'This account signs in by passkey only and has none left to confirm with. '
            . 'Ask the site operator for a setup link to add one.' }
        unless @$mine;
    unless ( ref $as eq 'HASH' ) {
        return { ok => 0, error => 'This request has no host a passkey can belong to.' } unless defined $rp;
        my ( $ch, $why ) = Lazysite::Auth::Passkey::issue_challenge( "$LAZYSITE_DIR/auth",
            purpose => 'reauth', user => $auth_user );
        return { ok => 0, error => $why } unless defined $ch;
        return { ok => 0, kind => 'reauth', challenge => $ch, rp_id => $rp,
            allow   => [ map { $_->{id} } @$mine ],
            timeout => $Lazysite::Auth::Passkey::CHALLENGE_TTL * 1000,
            error => 'Confirm it is you with one of your passkeys first: this account signs in by passkey only.' };
    }
    if ( my $r = _rate_refusal() ) { return $r }
    my $v = Lazysite::Auth::Passkey::verify_assertion(
        auth_dir    => "$LAZYSITE_DIR/auth",
        rp          => $rp,
        origin      => $origin,
        purposes    => ['reauth'],
        user        => $auth_user,
        id          => ( ref $as->{id}          ? undef : $as->{id} ),
        client_data => ( ref $as->{client_data} ? undef : $as->{client_data} ),
        authenticator_data => ( ref $as->{authenticator_data} ? undef : $as->{authenticator_data} ),
        signature => ( ref $as->{signature} ? undef : $as->{signature} ),
    );
    unless ( $v->{ok} ) {
        log_event( 'WARN', $auth_user, 'account page: passkey re-authentication refused', why => $v->{error} );
        sleep 1;
        return { ok => 0, kind => ( $v->{kind} // 'forbidden' ), field => 'assertion',
            error => "Your passkey did not confirm it is you: $v->{error}." };
    }
    users_api( { action => 'passkey-used', username => $auth_user, id => $v->{id}, count => $v->{count} } );
    return undef;
}

# Step two: the browser's answer, verified, then stored by the users tool.
sub dispatch_me_passkey_add {
    if ( my $r = me_refusal() ) { return $r }
    require Lazysite::Auth::Passkey;
    my $req = _json_body() || {};
    my %in  = (
        id                 => $req->{id},
        client_data        => $req->{client_data},
        authenticator_data => $req->{authenticator_data},
        public_key         => $req->{public_key},
        alg                => $req->{alg},
        label              => $req->{label},
    );
    ref $in{$_} and $in{$_} = undef for keys %in;    # text values only
    my ( $rp, $origin ) = Lazysite::Auth::Passkey::rp_of();
    my $v = Lazysite::Auth::Passkey::verify_registration(
        auth_dir => "$LAZYSITE_DIR/auth",
        rp       => $rp,
        origin   => $origin,
        purposes => ['enrol'],
        user     => $auth_user,
        %in,
    );
    unless ( $v->{ok} ) {
        log_event( 'WARN', $auth_user, 'account page: passkey not accepted', why => $v->{error} );
        return { ok => 0, kind => ( $v->{kind} // 'invalid' ), error => "The passkey was not added: $v->{error}." };
    }
    my $r = users_api( { action => 'passkey-add', username => $auth_user, actor => $auth_user,
            passkey => $v->{passkey} } );
    return { ok => 0, error => ( ref $r eq 'HASH' && $r->{error} ) || 'The passkey was not added.' }
        unless ref $r eq 'HASH' && $r->{ok};
    return { ok => 1, id => $v->{passkey}{id}, message => 'Passkey added. You can sign in with it now.' };
}

sub dispatch_me_passkey_remove {
    if ( my $r = me_refusal() ) { return $r }
    my $req = _json_body() || {};
    my $id  = $req->{id};
    return { ok => 0, kind => 'invalid', field => 'id', error => 'id is required (one of your passkeys, from me-passkeys).' }
        unless defined $id && !ref $id && length $id;
    my $r = users_api( { action => 'passkey-remove', username => $auth_user, actor => $auth_user, id => $id } );
    return { ok => 0, kind => ( ref $r eq 'HASH' && $r->{kind} ) || 'error',
        error => ( ref $r eq 'HASH' && $r->{error} ) || 'The passkey was not removed.' }
        unless ref $r eq 'HASH' && $r->{ok};
    return { ok => 1, id => $id, message => 'Passkey removed.' };
}

# --- SM1363: app notices on the member's own devices ------------------------------
#
# A device turns notices on by subscribing through the browser (the site's app
# worker) and handing this the endpoint; its notices then come by web push, with
# no content - the worker says something is waiting and opens /account. Turning a
# device on adds `webpush` to the account's notify_routes, the last one off
# removes it (the users tool does both). Without CryptX: unavailable, and said.

sub action_me_push {
    if ( my $r = me_refusal() ) { return $r }
    require Lazysite::WebPush;
    my ( $key, $why ) = Lazysite::WebPush::public_key($DOCROOT);
    my $s = do {
        no warnings 'once';
        local $Lazysite::Auth::Settings::AUTH_DIR = "$LAZYSITE_DIR/auth";
        require Lazysite::Auth::Settings;
        Lazysite::Auth::Settings::read_settings()->{$auth_user} || {};
    };
    my @eps = map { $_->{endpoint} } grep { ref $_ eq 'HASH' } @{ ref $s->{push} eq 'ARRAY' ? $s->{push} : [] };
    return {
        ok => 1,
        available => ( defined $key ? JSON::PP::true() : JSON::PP::false() ),
        ( defined $key ? ( key => $key ) : ( needs => $why ) ),
        devices => \@eps,
        routes  => [ grep { length } split /[,\s]+/, ( $s->{notify_routes} // '' ) ],
    };
}

sub _push_body_endpoint {
    my $req = _json_body() || {};
    my $ep  = $req->{endpoint};
    return ( ref $ep ? undef : $ep );
}

sub dispatch_me_push_subscribe {
    if ( my $r = me_refusal() ) { return $r }
    require Lazysite::Crypto;
    if ( my $m = Lazysite::Crypto::cryptx_missing() ) { return { ok => 0, kind => 'unavailable', error => $m } }
    my $ep = _push_body_endpoint();
    require Lazysite::WebPush;
    if ( my $f = Lazysite::WebPush::endpoint_fault($ep) ) {
        return { ok => 0, kind => 'invalid', field => 'endpoint', error => "This device cannot be added: $f." };
    }
    my $r = users_api( { action => 'push-subscribe', username => $auth_user, actor => $auth_user, endpoint => $ep } );
    return { ok => 0, error => ( ref $r eq 'HASH' && $r->{error} ) || 'Notices were not turned on.' }
        unless ref $r eq 'HASH' && $r->{ok};
    return { ok => 1, devices => $r->{devices}, message => 'Notices are on for this device.' };
}

sub dispatch_me_push_unsubscribe {
    if ( my $r = me_refusal() ) { return $r }
    my $ep = _push_body_endpoint();
    return { ok => 0, kind => 'invalid', field => 'endpoint', error => 'endpoint is required (this device\'s, from me-push).' }
        unless defined $ep && length $ep;
    my $r = users_api( { action => 'push-unsubscribe', username => $auth_user, actor => $auth_user, endpoint => $ep } );
    return { ok => 0, error => ( ref $r eq 'HASH' && $r->{error} ) || 'Notices were not turned off.' }
        unless ref $r eq 'HASH' && $r->{ok};
    return { ok => 1, devices => $r->{devices}, message => 'Notices are off for this device.' };
}

# SM1363 (ruling 196): my phone, for text notices - the webhook route, which the
# operator turns on for an account. An empty value clears it. The users tool
# checks the form and lets the account set its own (a self-service key).
sub dispatch_me_phone {
    if ( my $r = me_refusal() ) { return $r }
    my $req   = _json_body() || {};
    my $phone = $req->{phone};
    $phone = '' unless defined $phone && !ref $phone;
    my $r = users_api( { action => 'settings-set', username => $auth_user, actor => $auth_user,
            key => 'phone', value => $phone } );
    return { ok => 0, kind => 'invalid', field => 'phone',
        error => ( ref $r eq 'HASH' && $r->{error} ) || 'The phone number was not saved.' }
        unless ref $r eq 'HASH' && $r->{ok};
    return { ok => 1, message => ( length $phone ? 'Phone number saved.' : 'Phone number removed.' ) };
}

# SM1034 phase 1b (SM1010 R2): the member's own bell - the notices addressed to
# this account and to no one else, never a broadcast, and their read state. The
# one notice reader is Lazysite::Manager::Notices; `addressed_only` gives the
# account its own window, so a busy site's other notices cannot crowd it out.
# No capability: `notifications` is the operators' bell, and this is not it.
sub action_me_notices {
    if ( my $r = me_refusal() ) { return $r }
    my $r = Lazysite::Manager::Notices::action_notices( $auth_user, addressed_only => 1 );
    delete $r->{unread_by_type};  # the manager's per-type counts; nothing here reads them
    return $r;
}

# Mark one of my notices read, dismiss it, or (no id) mark them all read.
sub dispatch_me_notices_seen {
    if ( my $r = me_refusal() ) { return $r }
    my $req = _json_body() || {};
    my $id  = $req->{id};
    $id = undef if ref $id;
    return Lazysite::Manager::Notices::action_notices_seen( $auth_user,
        id => $id, dismiss => ( $req->{dismiss} ? 1 : 0 ), addressed_only => 1 );
}

# Every session of the caller's account, this one included - what "everywhere"
# says. The page then sends the person to sign in again.
sub action_me_sign_out_everywhere {
    if ( my $r = me_refusal() ) { return $r }
    no warnings 'once';
    local $Lazysite::Manager::Sessions::LAZYSITE_DIR = $LAZYSITE_DIR;
    local $Lazysite::Manager::Sessions::auth_user    = $auth_user;
    my $r = Lazysite::Manager::Sessions::action_user_revoke($auth_user);
    return $r unless ref $r eq 'HASH' && $r->{ok};
    return { ok => 1, message => 'Every session of your account has been signed out, this one too.' };
}

1;
