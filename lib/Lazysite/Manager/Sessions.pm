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

use strict;
use warnings;
use JSON::PP       qw(encode_json decode_json);
use Lazysite::Util qw(log_event);
use Exporter       qw(import);
our @EXPORT_OK = qw(action_sessions_list action_session_revoke action_user_revoke);

our $LAZYSITE_DIR = '';
our $auth_user    = '';

# Duplicate of the auth wrapper's $COOKIE_MAX (24 hours) - keep in step.
my $COOKIE_MAX = 86400;

sub _registry_path { return "$LAZYSITE_DIR/auth/sessions.jsonl" }
sub _revoked_path  { return "$LAZYSITE_DIR/auth/revoked.json" }

# Read revoked.json into its canonical shape. Corrupt = treated as empty
# with a loud WARN, matching the wrapper's fail-open-with-alarm decision.
sub _read_revoked {
    my $path = _revoked_path();
    my $data;
    if ( -f $path && open my $fh, '<:raw', $path ) {
        my $raw = do { local $/; <$fh> };
        close $fh;
        $data = eval { decode_json( $raw // '' ) };
        log_event( 'WARN', $auth_user,
            'revoked.json unreadable or corrupt - treating as empty' )
            unless ref $data eq 'HASH';
    }
    $data               = {} unless ref $data eq 'HASH';
    $data->{sids}       = {} unless ref $data->{sids} eq 'HASH';
    $data->{not_before} = {} unless ref $data->{not_before} eq 'HASH';
    return $data;
}

# Write revoked.json atomically (temp+rename, 0660), pruning entries older
# than COOKIE_MAX on the way out: a sid revoked (or a not_before set) more
# than 24h ago can only match cookies that have already expired, so the file
# never grows. Returns ( ok, error ).
sub _write_revoked {
    my ($data) = @_;
    my $cutoff = time() - $COOKIE_MAX;
    for my $bucket (qw(sids not_before)) {
        for my $k ( keys %{ $data->{$bucket} } ) {
            delete $data->{$bucket}{$k}
                if ( $data->{$bucket}{$k} || 0 ) < $cutoff;
        }
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

# Live sessions only - issued within COOKIE_MAX, sid not revoked, and not
# before the user's not_before - never a raw registry dump. `current` marks
# the caller's own session via LAZYSITE_AUTH_SID (set by the auth wrapper).
sub action_sessions_list {
    my $now = time();
    my $rev = _read_revoked();
    my $cur = $ENV{LAZYSITE_AUTH_SID} // '';
    my @sessions;
    if ( open my $fh, '<:raw', _registry_path() ) {
        while ( my $l = <$fh> ) {
            my $s = eval { decode_json($l) };
            next unless ref $s eq 'HASH' && defined $s->{sid} && defined $s->{user};
            my $t = ( $s->{t} || 0 ) + 0;
            next unless $now - $t < $COOKIE_MAX;         # expired cookie
            next if exists $rev->{sids}{ $s->{sid} };    # session signed out
            my $nb = $rev->{not_before}{ $s->{user} };
            next if defined $nb && $t < $nb;             # user signed out everywhere
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
    my $rev = _read_revoked();
    $rev->{sids}{$sid} = time();
    my ( $ok, $err ) = _write_revoked($rev);
    return { ok => 0, error => $err } unless $ok;
    log_event( 'WARN', $auth_user, 'session revoked', sid => substr( $sid, 0, 8 ) );
    return { ok => 1, sid => $sid };
}

# Sign a user out EVERYWHERE: every cookie issued before now - including
# legacy pre-sid cookies, which carry their issued-at - fails verification.
# The account itself is untouched; the user can sign straight back in.
sub action_user_revoke {
    my ($username) = @_;
    $username = '' unless defined $username;
    $username =~ s/[^a-zA-Z0-9_.-]//g;
    return { ok => 0, error => 'A username is required' } unless length $username;
    my $rev = _read_revoked();
    $rev->{not_before}{$username} = time();
    my ( $ok, $err ) = _write_revoked($rev);
    return { ok => 0, error => $err } unless $ok;
    log_event( 'WARN', $auth_user, 'all sessions revoked for user', user => $username );
    return { ok => 1, user => $username };
}

1;
