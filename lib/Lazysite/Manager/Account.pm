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
    action_me_notices dispatch_me_notices_seen);

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
    my $ip_ok   = Lazysite::Auth::LoginRate::check_login_rate( _request_ip(), %ctx );
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
    my %users = Lazysite::Auth::Verify::read_users();
    return {
        ok           => 1,
        user         => $auth_user,
        display_name => $s->{display_name},
        email        => $s->{email},
        has_password => ( length( $users{$auth_user} // "" ) ? JSON::PP::true() : JSON::PP::false() ),
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
