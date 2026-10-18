package Lazysite::Manager::Sessions;

# SM141 phase 1: session registry listing + revocation for the manager API.
#
# Sessions remain signed cookies (the source of truth); this module reads the
# two small side structures the auth wrapper maintains/consults:
#
#   lazysite/auth/sessions.jsonl - advisory registry, one {sid,user,t,ip,ua}
#     line per login, self-pruned by the wrapper (24h bound). Losing it only
#     degrades the listing.
#   lazysite/auth/revoked.json - { sids => { sid => revoked_at },
#     not_before => { user => epoch } }. Enforced in ONE place: the auth
#     wrapper's cookie-verify path (the processor never validates the cookie;
#     it trusts the X-Remote-* headers the wrapper sets).
#
# All three actions are gated on manage_users in lazysite-manager-api.pl and
# are NOT in the token-client %need set, so only cookie managers reach them.
# SM991: a revoke that reaches the operator's account is the operator's alone
# (_revoke_target_refusal).

use strict;
use warnings;
use Fcntl          qw(:flock);
use JSON::PP       qw(encode_json decode_json);
use Lazysite::Util qw(log_event);
use Exporter       qw(import);
our @EXPORT_OK = qw(action_sessions_list action_session_revoke action_user_revoke sweep_expired
    dispatch_sessions_keys revoke_account_sessions session_is_kept);

# SM944 S33: dispatch_sessions_keys reads the request's door, action and body.
use Lazysite::Manager::Common qw($token_auth $action _user_caps _json_body _operator);

our $LAZYSITE_DIR = '';
our $auth_user    = '';

# SM614: was a DUPLICATE of the auth wrapper's 24 hours, with a comment asking
# that the two be kept in step - which is a request, not a mechanism, and the
# operator found it by asking whether the lifetime could be changed at all. One
# source now: Lazysite::Auth::Session::session_lifetime(), read from
# lazysite.conf. This module sets the same $LAZYSITE_DIR that reader uses, so it
# gets the same answer the wrapper does by construction rather than by promise.
sub _cookie_max {
    require Lazysite::Auth::Session;
    return Lazysite::Auth::Session::session_lifetime($LAZYSITE_DIR);
}

sub _registry_path { return "$LAZYSITE_DIR/auth/sessions.jsonl" }
sub _revoked_path  { return "$LAZYSITE_DIR/auth/revoked.json" }

# Read revoked.json into its canonical shape, or undef when the store exists
# and cannot be read or decoded.
#
# SM1024 (ruled 2026-10-12, "Close all three"): a broken store was "treated as
# empty", matching the wrapper's old fail-open decision - so the list showed
# signed-out sessions as live and a revoke REWROTE the store from {}, wiping
# every other revocation. The wrapper now refuses every session on a broken
# store; here the readers answer cannot-tell (_revoked_refusal) and nothing is
# written over it. An ABSENT store is an empty one: nothing revoked.
sub _read_revoked {
    my $path = _revoked_path();
    my $data;
    if ( open my $fh, '<:raw', $path ) {
        my $raw = do { local $/; <$fh> };
        close $fh;
        $data = eval { decode_json( $raw // '' ) };
        unless ( ref $data eq 'HASH' ) {
            log_event( 'WARN', $auth_user, 'revoked.json does not decode - refusing until it is repaired' );
            return undef;
        }
    }
    elsif ( !$!{ENOENT} ) {
        my $err = "$!";
        log_event( 'WARN', $auth_user, 'revoked.json cannot be read - refusing until it is repaired',
            error => $err );
        return undef;
    }
    $data               = {} unless ref $data eq 'HASH';
    $data->{sids}       = {} unless ref $data->{sids} eq 'HASH';
    $data->{not_before} = {} unless ref $data->{not_before} eq 'HASH';
    $data->{kept}       = {} unless ref $data->{kept} eq 'HASH';
    return $data;
}

# SM1040: the one read-modify-write of revoked.json, under an exclusive lock.
#
# Two revocations at once - a logout and a password change, say - each read the
# file, added their entry and renamed their copy over it, and the second rename
# dropped the first's entry. For a logout that was a session that stayed signed
# in; for "sign the others out" it would be the stolen session the change was
# made to end. The lock is a sibling file, so the rename the writer does cannot
# release it. Returns the writer's ( ok, error ).
sub _update_revoked {
    my ($change) = @_;
    my $lock = _revoked_path() . '.lock';
    open my $lfh, '>>', $lock or return ( 0, "Cannot open $lock: $!" );
    chmod 0o660, $lock;
    flock( $lfh, LOCK_EX ) or return ( 0, "Cannot lock $lock: $!" );
    # SM1024: a broken store is refused, never written over; the third value
    # tells the caller to answer cannot-tell.
    my $rev = _read_revoked();
    unless ($rev) { close $lfh; return ( 0, _revoked_refusal()->{error}, 1 ) }
    $change->($rev);
    my ( $ok, $err ) = _write_revoked($rev);
    close $lfh;
    return ( $ok, $err );
}

# SM1024: the one answer every Sessions action gives on a broken store.
sub _revoked_refusal {
    return {
        ok     => 0,
        kind   => 'cannot-tell',
        store  => 'lazysite/auth/revoked.json',
        repair => 'lazysite check --docroot <docroot>',
        error => 'Cannot tell which sessions are signed out: lazysite/auth/revoked.json exists and '
            . 'cannot be read or does not decode. Every session is refused until it is repaired, '
            . 'and nothing is written over it; `lazysite check --docroot <docroot>` names the fault.',
    };
}

# Write revoked.json atomically (temp+rename, 0660), pruning entries older
# than COOKIE_MAX on the way out: a sid revoked (or a not_before set) more
# than 24h ago can only match cookies that have already expired, so the file
# never grows. Returns ( ok, error ).
sub _write_revoked {
    my ($data) = @_;
    my $cutoff = time() - _cookie_max();
    for my $bucket (qw(sids not_before)) {
        for my $k ( keys %{ $data->{$bucket} } ) {
            delete $data->{$bucket}{$k}
                if ( $data->{$bucket}{$k} || 0 ) < $cutoff;
        }
    }
    # SM1040: a kept session ages out with the not_before it is exempt from.
    for my $k ( keys %{ $data->{kept} || {} } ) {
        my $e = $data->{kept}{$k};
        delete $data->{kept}{$k}
            unless ref $e eq 'HASH' && ( $e->{nb} || 0 ) >= $cutoff;
    }
    my $path = _revoked_path();
    my $tmp  = "$path.tmp.$$";
    open my $fh, '>:raw', $tmp or return ( 0, "Cannot write $tmp: $!" );
    chmod 0o660, $tmp;
    print {$fh} encode_json($data);
    unless ( close $fh ) { my $e = $!; unlink $tmp; return ( 0, "Cannot finish $tmp: $e" ) }
    unless ( rename $tmp, $path ) {
        my $e = $!;
        unlink $tmp;
        return ( 0, "Cannot replace $path: $e" );
    }
    return ( 1, '' );
}

# SM944 S33, held branch (2) (approved 2026-10-11, "Approve all three"): the
# sessions-and-keys dispatch branch (sessions-list, session-revoke,
# user-revoke, keys-list, key-revoke), moved here from lazysite-manager-api.pl.
# Its statements are the branch's but four: this module keeps its own
# $auth_user (a log copy the dispatcher, the auth CGI and the daemon set), so
# the empty-account refusal and the cookie gate read Manager::Common's by full
# name (the S27 ruling, "Read Common's value"); and it does not load
# Manager::Users, which loads six other area modules, into the auth CGI and the
# daemon, so the keys arms call Users' _users_tool_call by full name (the
# manager API, the one caller, has loaded it). It reads the request's action,
# door and body from Common's context; outside a request nobody is asking and
# the refusal answers first.
sub dispatch_sessions_keys {
    my $result;
    # SM141/SM145: session AND access-key visibility + revocation are all
    # user-management powers. Cookie (manager) callers need the manage_users
    # capability - same strict cookie-side gate pattern as the audit trail;
    # token clients cannot reach these at all (not in the %need set above).
    # (A denied revoke is still audited: the generic POST audit block below
    # records the fail with kind 'forbidden'; the -list actions are GET reads.)
    #
    # SM944 S33, held branch (2) (approved 2026-10-11): THE EMPTY-ACCOUNT
    # REFUSAL FIRST, the established fail-closed pattern. The gate below passes
    # a token client, which the dispatcher's token gate has already refused -
    # and the request context's reset leaves a token client, so moved as it is
    # to Manager::Sessions this branch listed the access keys and revoked an
    # account's sessions for nobody outside a request
    # (tmp/sm944-n347-probe.out). Inside a request the dispatcher has refused an
    # empty $auth_user before this runs, so the answer there is unchanged.
    if ( !length $Lazysite::Manager::Common::auth_user ) {
        $result = { ok => 0, kind => 'forbidden',
            error => 'Sessions and access keys are managed by a signed-in account, and no account is asking.' };
    }
    elsif ( !$token_auth && !_user_caps($Lazysite::Manager::Common::auth_user)->{manage_users} ) {
        $result = { ok => 0, kind => 'forbidden',
            error => "Managing sessions and keys requires the 'Users & groups' permission. "
                . "An administrator can grant it on the Groups page." };
    }
    elsif ( my $r = _revoke_target_refusal() ) { $result = $r }
    elsif ( $action eq 'sessions-list' ) { $result = action_sessions_list() }
    elsif ( $action eq 'keys-list' ) {
        # SM145: the access-key inventory lives in the users tool (it reads the
        # credential store); forward the read.
        $result = Lazysite::Manager::Users::_users_tool_call( { action => 'keys-list' } ); ## no critic (Subroutines::ProtectPrivateSubs)
    }
    elsif ( $action eq 'key-revoke' ) {
        my $req = _json_body();
        $result = Lazysite::Manager::Users::_users_tool_call( { action => 'key-revoke', username => $req->{username} } ); ## no critic (Subroutines::ProtectPrivateSubs)
    }
    else {
        my $req = _json_body();
        $result = $action eq 'session-revoke'
            ? action_session_revoke( $req->{sid} )
            : action_user_revoke( $req->{username} );
    }
    return $result;
}

# SM991, ruled 2026-10-12 ("Yes, protect operator sessions too"): THE
# OPERATOR'S SESSIONS AND ACCESS KEYS ARE THE OPERATOR'S. manage_users manages
# every other account, and the operator is no longer whoever holds it, so a
# holder could sign the operator out everywhere, or strip its OAuth grants, and
# keep it out by repeating that. A refusal for a caller who is neither `local`
# nor the operator when a revoke would reach an account that is the operator;
# undef otherwise. The rule is Manager::Users::_operator_target_refusal, the
# one the users tool's verbs ask, handed the account each revoke reaches:
#   user-revoke     the username, cleaned as action_user_revoke cleans it, so
#                   the account checked is the account signed out
#   key-revoke      the username, as the users tool receives it
#   session-revoke  every account the registry records for the sid. A sid in
#                   the right shape that the registry does not hold cannot be
#                   placed, and may be the operator's (the registry is
#                   advisory), so it is refused: fail closed.
# A malformed sid or an empty username passes on to the action's own refusal.
sub _revoke_target_refusal {
    return undef unless $action =~ /\A(?:session-revoke|user-revoke|key-revoke)\z/;
    return undef if $Lazysite::Manager::Common::auth_user eq 'local' || _operator();
    my $req = _json_body();
    $req = {} unless ref $req eq 'HASH';
    my @who;
    if ( $action eq 'session-revoke' ) {
        my $sid = $req->{sid};
        return undef unless defined $sid && !ref $sid && $sid =~ /\A[0-9a-f]{16}\z/;
        @who = _sid_owners($sid);
        return { ok => 0, kind => 'forbidden',
            error => 'That session is not in the session registry, so whose it is cannot be told. '
                . 'Only the operator signs out a session that may be the operator\'s.' }
            unless @who;
    }
    elsif ( $action eq 'user-revoke' ) {
        @who = ( _clean_username( $req->{username} ) );
    }
    else {
        @who = ( $req->{username} );
    }
    for my $u (@who) {
        my $r = Lazysite::Manager::Users::_operator_target_refusal( $action, { username => $u } ); ## no critic (Subroutines::ProtectPrivateSubs)
        return $r if $r;
    }
    return undef;
}

# Every account the registry records against a sid, live or not.
sub _sid_owners {
    my ($sid) = @_;
    my %who;
    if ( open my $fh, '<:raw', _registry_path() ) {
        while ( my $l = <$fh> ) {
            my $s = eval { decode_json($l) };
            next unless ref $s eq 'HASH' && defined $s->{sid} && defined $s->{user};
            $who{ $s->{user} } = 1 if $s->{sid} eq $sid;
        }
        close $fh;
    }
    my @who = sort keys %who;
    return @who;
}

# The account name user-revoke writes into not_before, and the one its refusal
# asks about: one cleaning, so the two cannot differ.
sub _clean_username {
    my ($username) = @_;
    $username = '' unless defined $username && !ref $username;
    $username =~ s/[^a-zA-Z0-9_.-]//g;
    return $username;
}

# Live sessions only - issued within COOKIE_MAX, sid not revoked, and not
# before the user's not_before - never a raw registry dump. `current` marks
# the caller's own session via LAZYSITE_AUTH_SID (set by the auth wrapper).
sub action_sessions_list {
    my $now = time();
    my $rev = _read_revoked() or return _revoked_refusal();
    my $cur = $ENV{LAZYSITE_AUTH_SID} // '';
    my @sessions;
    if ( open my $fh, '<:raw', _registry_path() ) {
        while ( my $l = <$fh> ) {
            my $s = eval { decode_json($l) };
            next unless ref $s eq 'HASH' && defined $s->{sid} && defined $s->{user};
            next if $s->{renew}; # SM1160: a renewal of an Odoo-minted session already listed by its first line
            my $t = ( $s->{t} || 0 ) + 0;
            next unless $now - $t < _cookie_max();       # expired cookie
            next if exists $rev->{sids}{ $s->{sid} };    # session signed out
            my $nb = $rev->{not_before}{ $s->{user} };
            next if defined $nb && $t < $nb              # user signed out everywhere
                && !session_is_kept( $rev, $s->{user}, $s->{sid} );    # SM1040
            push @sessions, {
                sid     => $s->{sid},
                user    => $s->{user},
                ip      => $s->{ip} // '',
                ua      => $s->{ua} // '',
                issued  => $t,
                current => ( length($cur) && $s->{sid} eq $cur )
                ? JSON::PP::true()
                : JSON::PP::false(),
            };
        }
        close $fh;
    }
    @sessions = sort { $b->{issued} <=> $a->{issued} } @sessions;
    return { ok => 1, sessions => \@sessions };
}

# Sign out ONE session: the revoked sid is rejected by the auth wrapper on
# its next request, whatever cookie carries it.
sub action_session_revoke {
    my ($sid) = @_;
    $sid = '' unless defined $sid;
    return { ok => 0, error => 'A session id (16 hex characters) is required' }
        unless $sid =~ /\A[0-9a-f]{16}\z/;
    my ( $ok, $err, $broken ) = _update_revoked( sub { $_[0]{sids}{$sid} = time() } );
    return _revoked_refusal() if $broken;
    return { ok => 0, error => $err } unless $ok;
    log_event( 'WARN', $auth_user, 'session revoked', sid => substr( $sid, 0, 8 ) );
    return { ok => 1, sid => $sid };
}

# Sign a user out EVERYWHERE: every cookie issued before now - including
# legacy pre-sid cookies, which carry their issued-at - fails verification.
# The account itself is untouched; the user can sign straight back in.
sub action_user_revoke {
    my $username = _clean_username( $_[0] );
    return { ok => 0, error => 'A username is required' } unless length $username;
    # SM1040: everywhere means the session a credential change kept, too.
    my ( $ok, $err, $broken ) = _update_revoked( sub {
            $_[0]{not_before}{$username} = time();
            delete $_[0]{kept}{$username};
    } );
    return _revoked_refusal() if $broken;
    return { ok => 0, error => $err } unless $ok;
    log_event( 'WARN', $auth_user, 'all sessions revoked for user', user => $username );
    return { ok => 1, user => $username };
}

# SM1040 (ruled 2026-10-12, "Fix now"): A CHANGED CREDENTIAL ENDS THE ACCOUNT'S
# OTHER SESSIONS. Any password change - the account's own, an operator's passwd,
# a redeemed setup or reset link - and any 2FA disable signs out every session of
# that account except the one making the change. Before this a password change
# signed nothing out, so a stolen session survived the change it prompted.
#
# The mechanism is the one "sign out everywhere" already uses, not_before, which
# also ends legacy cookies that carry no session id. The session that made the
# change is KEPT by naming it beside the not_before it is exempt from: the
# exemption holds only while not_before is the one it was written with, so a
# later sign-out-everywhere ends it too, without anything having to remember to.
# A legacy cookie has no id and cannot be kept; a keep_sid that is not 16 hex
# keeps nothing.
#
# keep_sid comes from the caller's VERIFIED session (LAZYSITE_AUTH_SID, which the
# auth wrapper sets from the cookie), never from a request body: whoever passes
# it is engine code that has checked the session belongs to $user.
#
#   revoke_account_sessions( dir => $LAZYSITE_DIR, user => $name,
#       keep_sid => $sid )  ->  { ok, user, kept }  |  { ok => 0, error }
sub revoke_account_sessions {
    my (%o) = @_;
    local $LAZYSITE_DIR = $o{dir} if defined $o{dir} && length $o{dir};
    my $user = $o{user} // '';
    return { ok => 0, error => 'An account is required' }
        unless length $user && $user =~ /\A[a-zA-Z0-9_.-]+\z/;
    my $keep = $o{keep_sid} // '';
    $keep = '' unless $keep =~ /\A[0-9a-f]{16}\z/;
    my ( $ok, $err, $broken ) = _update_revoked( sub {
            my $now = time();
            $_[0]{not_before}{$user} = $now;
            if ( length $keep ) { $_[0]{kept}{$user} = { sid => $keep, nb => $now } }
            else                { delete $_[0]{kept}{$user} }
    } );
    return _revoked_refusal() if $broken;
    return { ok => 0, error => $err } unless $ok;
    log_event( 'WARN', ( length $auth_user ? $auth_user : $user ),
        'other sessions revoked for user',
        user => $user, kept => ( length $keep ? substr( $keep, 0, 8 ) : 'none' ) );
    return { ok => 1, user => $user, kept => ( length $keep ? 1 : 0 ) };
}

# SM1040: is this the session a credential change kept? True only for the sid
# named beside the CURRENT not_before. Lazysite::Auth::Session asks the same
# question of the same file when it verifies a cookie; t/unit/auth/40 holds the
# listing and the verifier to one answer.
sub session_is_kept {
    my ( $rev, $user, $sid ) = @_;
    return 0 unless defined $sid && length $sid;
    my $k  = ref $rev->{kept} eq 'HASH'       ? $rev->{kept}{$user}       : undef;
    my $nb = ref $rev->{not_before} eq 'HASH' ? $rev->{not_before}{$user} : undef;
    return ( ref $k eq 'HASH'
            && defined $k->{sid} && $k->{sid} eq $sid
            && defined $nb && defined $k->{nb} && $k->{nb} == $nb ) ? 1 : 0;
}


# SM666: the registry's retention, as a callable.
#
# Until now the ONLY thing that pruned sessions.jsonl was a login: the auth
# wrapper rewrites the file when it appends a fresh line and finds a stale one.
# That is a retention that runs when there is new data to write - and a site
# nobody signs in to for a month keeps a month of expired rows, each carrying
# a visitor's IP and user agent (lazysite-check names them as personal data),
# for no reason a reader could defend. The stats plugin states the rule this
# breaks: a retention that only runs when there is fresh data is not a
# retention.
#
# The rule applied is the reader's own (action_sessions_list): a row older
# than the session lifetime is dead by definition, because no cookie it
# describes can still verify. Revocations get the same treatment through the
# writer that already prunes them, so the two files age out together.
#
# Returns { ok, removed, kept, revocations_pruned } for the record; the caller
# is the scheduler, which names the actor in its own audit row.
sub sweep_expired {
    my $now    = time();
    my $cutoff = $now - _cookie_max();
    my $path   = _registry_path();

    my @keep;
    my $removed = 0;
    if ( open my $rfh, '<:raw', $path ) {
        while ( my $l = <$rfh> ) {
            my ($t) = $l =~ /"t":(\d+)/;
            if ( defined $t && $t <= $cutoff ) { $removed++; next }
            push @keep, $l;
        }
        close $rfh;
    }

    if ($removed) {
        my $tmp = "$path.tmp.$$";
        open my $wfh, '>:raw', $tmp
            or return { ok => 0, error => "Cannot write $tmp: $!" };
        chmod 0o660, $tmp;
        print {$wfh} @keep;
        unless ( close $wfh ) {
            my $e = $!;
            unlink $tmp;
            return { ok => 0, error => "Cannot finish $tmp: $e" };
        }
        unless ( rename $tmp, $path ) {
            my $e = $!;
            unlink $tmp;
            return { ok => 0, error => "Cannot replace $path: $e" };
        }
    }

    # revoked.json prunes on write. Count what the write will drop so the
    # record says so, and write only when there is something to drop - a
    # rewrite that changes nothing is a modification time that lies.
    my $pruned = 0;
    if ( -f _revoked_path() ) {
        # SM1024: a broken store is left as it is, for its repair.
        my $rev = _read_revoked()
            or return { ok => 0, removed => $removed, kept => scalar @keep, %{ _revoked_refusal() } };
        for my $bucket (qw(sids not_before)) {
            $pruned += grep { ( $rev->{$bucket}{$_} || 0 ) < $cutoff }
                keys %{ $rev->{$bucket} };
        }
        $pruned += grep {    # SM1040: as _write_revoked prunes them
            ref $rev->{kept}{$_} ne 'HASH' || ( $rev->{kept}{$_}{nb} || 0 ) < $cutoff
        } keys %{ $rev->{kept} };
        if ($pruned) {
            my ( $ok, $err ) = _write_revoked($rev);
            return { ok => 0, error => $err } unless $ok;
        }
    }

    return {
        ok                 => 1,
        removed            => $removed,
        kept               => scalar @keep,
        revocations_pruned => $pruned,
    };
}

1;
