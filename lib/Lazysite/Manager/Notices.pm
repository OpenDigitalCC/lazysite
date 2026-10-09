package Lazysite::Manager::Notices;

# SM113's sysop notification store, as ONE reader that both doors call.
#
# The store is small and append-only: logs/notices.jsonl, written by producers
# (the first was form submissions, and SM485 made email a second endpoint on the
# same routing mechanism), plus a per-principal last-seen marker in
# logs/notices-seen.json so the manager can show an unread count.
#
# WHY THIS IS A MODULE AND NOT TWO COPIES. The reader lived in
# lazysite-manager-api.pl, and lazysite-mcp.pl cannot call into a sibling CGI.
# Building the MCP twin by writing a second reader is how SM915 happened one
# registry over: four readers of one list, one of them right. A store with two
# readers has two answers the day one of them is edited.
#
# Read only, deliberately. Writing a notice is EMISSION, which routes by type
# through Lazysite::Notify - there is no second place to say where a notice
# goes, and a remote writer is a different question that SM231 declined.
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use Digest::SHA qw(sha1_hex);
use Exporter 'import';
use Lazysite::Util  qw(cannot_read);
use Lazysite::Paths ();
# SM944 S23: the gate reads the request context; Common sets none of it here.
use Lazysite::Manager::Common qw($auth_user $token_auth %token_caps _user_caps);

our @EXPORT_OK = qw(action_notices action_notices_seen _notices_gate);

our $DOCROOT;

# SM293: asked, never computed - the engine tree sits beside the docroot once
# migrated and inside it before, and both layouts take one code path.
sub _lz { return Lazysite::Paths::lazysite_dir($DOCROOT) }

sub _notices_path      { return _lz() . '/logs/notices.jsonl' }
sub _notices_seen_path { return _lz() . '/logs/notices-seen.json' }

# THE FOUR STATES, kept apart. This reader used to be `if ( open ... ) {...}`
# with no else, so a store that exists and cannot be opened produced an empty
# list - "the site has told you nothing" for what is really "I could not look".
# On the manager that is a bell that stays quiet; over MCP it is worse, because
# an agent has no log to go and read afterwards.
#
# ABSENT is a real answer and stays silent: a site that has never emitted a
# notice has no file, and that is not a fault. UNREADABLE returns undef, which
# `cannot_read` logs with the path, errno and the unix user - the three things a
# sysop needs and the SM766 version of this bug threw away.
#
# t/lint/121 could not see the old form: its matcher requires `or` on the open
# line, and a read-open used as an `if` condition has none. SM917 carries the
# measurement (51 such opens across the files that lint scans).
sub _read_notices {
    my @notices;
    open my $fh, '<', _notices_path()
        or return $!{ENOENT} ? \@notices : cannot_read( 'the notice store', _notices_path() );
    my @lines = <$fh>;
    close $fh;
    @lines = @lines[ -100 .. -1 ] if @lines > 100;    # bound: most recent 100
    for my $l ( reverse @lines ) {                    # newest first
        chomp $l;
        my $n = eval { decode_json($l) };
        next unless ref $n eq 'HASH';

        # SM938 D3: A NOTICE HAS AN IDENTITY, so it can be marked on its own.
        #
        # The store has never carried one - a notice is a line - and per-notice
        # read state needs something to key on. The hash of the stored LINE is
        # stable because the store is append-only: nothing rewrites a line, so
        # the same notice gives the same id on every read, by either door. Twelve
        # hex characters is 48 bits over a window of at most 100 notices.
        # Computed, never written, so the store's format is unchanged and every
        # notice already on disk has an id the moment this is deployed.
        $n->{id} = substr( sha1_hex($l), 0, 12 );
        push @notices, $n;
    }
    return \@notices;
}

# The marker is a hash of principal => epoch. Same four states: absent is a
# principal who has never marked anything seen, which is every principal on a
# new site; unreadable is undef and says so.
sub _read_seen_map {
    open my $sf, '<', _notices_seen_path()
        or return $!{ENOENT} ? {} : cannot_read( 'the notice seen-marker', _notices_seen_path() );
    local $/;
    my $h = eval { decode_json(<$sf>) };
    close $sf;
    return ref $h eq 'HASH' ? $h : {};
}

# SM938 D3: ONE PRINCIPAL'S ENTRY, IN EITHER SHAPE.
#
# The marker used to be principal => epoch - one cursor, set by opening the
# panel, which made the badge a has-opened-the-panel indicator rather than an
# outstanding-work one. It is now principal => { mark, read, dismissed }:
#
#   mark       everything at or before this time is read ("mark all read")
#   read       ids read one at a time, so marking one does not mark the rest
#   dismissed  ids dealt with and out of the panel. A second marker, NOT a
#              delete - the store is the record and stays one (the report's
#              own condition for dismissal)
#
# An entry written before this is a bare number and reads as { mark => n }, so
# nobody's position is lost on upgrade and nothing has to migrate the file.
sub _entry {
    my ($v) = @_;
    return { mark => $v + 0, read => {}, dismissed => {} }
        if defined $v && !ref $v && $v =~ /\A\d+\z/;
    my %e = ref $v eq 'HASH' ? %$v : ();
    $e{mark}      = ( $e{mark} // 0 ) + 0;
    $e{read}      = {} unless ref $e{read} eq 'HASH';
    $e{dismissed} = {} unless ref $e{dismissed} eq 'HASH';
    return \%e;
}

sub _is_read {
    my ( $e, $n ) = @_;
    my $ts = $n->{ts} // 0;
    return 1 if $ts <= $e->{mark};
    return 1 if $e->{read}{ $n->{id} // '' } || $e->{dismissed}{ $n->{id} // '' };
    return 0;
}

# $principal is the account whose unread count this is - $auth_user on the
# cookie path, the partner's own login over a token. Passed in rather than read
# from a global, because the two callers name it differently and a module that
# reaches for one CGI's variable only works in that CGI.
sub action_notices {
    my ($principal) = @_;

    my $notices  = _read_notices();
    my $seen_map = _read_seen_map();

    # Either read may have failed, and they fail independently: the store can be
    # unreadable while the marker is fine. Report the store's state, because
    # that is the one that decides whether the notices list means anything.
    my %out = ( ok => 1, notices => $notices || [] );
    if ( !defined $notices ) {
        $out{store_unreadable} = 1;
        $out{error}            = 'The notice store exists and could not be read. '
            . 'This is not an empty bell - the count below is not a fact about the site. '
            . 'The engine log names the file, the error and the unix user.';
    }
    if ( !defined $seen_map ) {
        $out{seen_unreadable} = 1;
        $seen_map = {};
    }

    my $e = _entry(
        ( defined $principal && length $principal ) ? $seen_map->{$principal} : undef );

    # SM938 D3: dismissed notices leave the panel and stay in the store; each
    # remaining one says whether THIS principal has read it, so the panel can
    # show the difference instead of one badge for everything.
    my @all = @{ $out{notices} };
    $out{notices}   = [ grep { !$e->{dismissed}{ $_->{id} // '' } } @all ];
    $out{dismissed} = @all - @{ $out{notices} };
    $_->{read} = _is_read( $e, $_ ) ? JSON::PP::true : JSON::PP::false for @{ $out{notices} };

    $out{last_seen} = $e->{mark};
    $out{unread}    = scalar grep { !_is_read( $e, $_ ) } @{ $out{notices} };

    # SM957: THE SAME COUNT, BY TYPE. The manager's Submissions entry shows how
    # many submission notices THIS principal has not read - the bell's own read
    # state narrowed to one type, so there is one store of what has been read
    # and two places that count from it, never two stores that can disagree.
    my %by_type;
    $by_type{ $_->{type} // '' }++ for grep { !_is_read( $e, $_ ) } @{ $out{notices} };
    $out{unread_by_type} = \%by_type;
    return \%out;
}

# Operator-only, and that is a decision rather than an omission. The marker
# drives a HUMAN's unread badge; an agent has no badge, and giving each partner
# its own read cursor here is the first half of an inbox - which is not what
# notifications are for. Machine-to-machine messaging is SM646's XMPP
# connectors, not a cursor grown quietly on the side of this store.
# t/lint/23 carries that as the reason this action is one-sided, and
# Lazysite::ControlApi::Actions has always left it out of the token map.
# SM938 D3: THREE ACTS ON ONE ENDPOINT, said by the arguments.
#
#   (no id)              mark ALL read - the explicit control that replaces
#                        marking on open. "Opening a list is reading it only when
#                        the list is short" (the report's own words).
#   id => X              mark ONE read, so the rest stay outstanding.
#   id => X, dismiss => 1  take one out of the panel. Implies read.
#
# One endpoint rather than three new actions, deliberately: it is the same
# operator-only, per-principal cursor SM918 decided must not be twinned for
# agents, and three new action names would each be a surface every parity lint
# has to classify for what is one piece of per-user UI state.
#
# An id that names no notice in the current window is REFUSED, by name. Marking
# a stale or mistyped id would answer ok and change nothing, which is the shape
# of reply that makes an operator think a control is broken.
sub action_notices_seen {
    my ( $principal, %o ) = @_;
    return { ok => 0, error => 'A principal is required to mark notices seen' }
        unless defined $principal && length $principal;

    my $h = _read_seen_map();

    # REFUSE rather than overwrite. An unreadable marker file that we replace
    # wholesale would drop every other operator's position - a write that loses
    # other people's state because it could not read it first.
    return { ok => 0, error => 'The notice seen-marker exists and could not be read, '
            . 'so it was not rewritten - replacing it would discard every other '
            . 'operator\'s position. The engine log names the file and the error.' }
        unless defined $h;

    my $notices = _read_notices() || [];
    my %live    = map { ( $_->{id} // '' ) => 1 } @$notices;
    my $e       = _entry( $h->{$principal} );

    my $id = $o{id};
    if ( defined $id && length $id ) {
        return { ok => 0, kind => 'not-found',
            error => "No notice '$id' in the bell. It may have aged out of the "
                . 'most recent 100; reload the list and use an id from it.' }
            unless $id =~ /\A[0-9a-f]{12}\z/ && $live{$id};
        if   ( $o{dismiss} ) { $e->{dismissed}{$id} = 1; }
        else                 { $e->{read}{$id}      = 1; }
    }
    else {
        $e->{mark} = time();
    }

    # Bounded: ids that have aged out of the window can never be shown again, so
    # they are dropped rather than kept for ever in a file every read loads.
    for my $set (qw(read dismissed)) {
        delete @{ $e->{$set} }{ grep { !$live{$_} } keys %{ $e->{$set} } };
    }
    $h->{$principal} = $e;

    if ( open my $wf, '>', _notices_seen_path() ) {
        print {$wf} encode_json($h);
        close $wf;
    }
    my $unread = grep { !$e->{dismissed}{ $_->{id} } && !_is_read( $e, $_ ) } @$notices;
    return { ok => 1, unread => $unread + 0 };
}

# --- SM944 S23: the manager API's gate, moved here from lazysite-manager-api.pl
#
# SM113: sysop notifications. A small append-only store (logs/notices.jsonl)
# that producers (the first is form submissions) append to, plus a per-sysop
# last-seen marker (logs/notices-seen.json) so the manager can show an unread
# count. Poll-based for v1.
#
# THE READERS ABOVE are the one reader both doors call (MCP's read_notices too),
# and the four-state repair is theirs. `notices` is token-reachable with the `notifications`
# capability (it always was, in ControlApi::Actions); `notices-seen` is not, and
# that is the decision recorded in t/lint/23.
#
# The readers take the principal as an argument, so MCP passes its own; the
# manager API's dispatcher calls them with $auth_user directly (SM944 S23 (d),
# ruled 2026-10-09 - the script's same-named wrappers are gone). The gate below
# is the manager API's alone and reads the request context from Common, which
# only the manager API sets: loaded anywhere else it refuses (t/unit/manager/205).

# The one gate both notice actions share: undef to proceed, a refusal otherwise.
sub _notices_gate {
    # SM944 S23 (b), ruled 2026-10-09: a token answers from its own grant. The
    # dispatcher has already required `notifications` of a token for `notices`
    # (and serves `notices-seen` to no token), so inside a request this is the
    # answer it gave. Outside one - the context reset: a token client holding
    # nothing - it refuses; "every token passes" let that call through.
    return undef if $token_auth ? $token_caps{notifications} : _user_caps($auth_user)->{notifications};
    return { ok => 0, kind => 'forbidden',
        error => "Notifications require the 'Notifications' permission. An "
            . "administrator can grant it on the Groups page." };
}

1;
