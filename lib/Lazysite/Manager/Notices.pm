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
use JSON::PP       qw(encode_json decode_json);
use Exporter 'import';
use Lazysite::Util  qw(cannot_read);
use Lazysite::Paths ();

our @EXPORT_OK = qw(action_notices action_notices_seen);

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
        push @notices, $n if ref $n eq 'HASH';
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

# $principal is the account whose unread count this is - $auth_user on the
# cookie path, the partner's own login over a token. Passed in rather than read
# from a global, because the two callers name it differently and a module that
# reaches for one CGI's variable only works in that CGI.
sub action_notices {
    my ($principal) = @_;

    my $notices = _read_notices();
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

    my $seen = 0;
    $seen = $seen_map->{$principal}
        if defined $principal && length $principal && $seen_map->{$principal};

    $out{last_seen} = $seen;
    $out{unread} = scalar grep { ( $_->{ts} // 0 ) > $seen } @{ $out{notices} };
    return \%out;
}

# Operator-only, and that is a decision rather than an omission. The marker
# drives a HUMAN's unread badge; an agent has no badge, and giving each partner
# its own read cursor here is the first half of an inbox - which is not what
# notifications are for. Machine-to-machine messaging is SM646's XMPP
# connectors, not a cursor grown quietly on the side of this store.
# t/lint/23 carries that as the reason this action is one-sided, and
# Lazysite::ControlApi::Actions has always left it out of the token map.
sub action_notices_seen {
    my ($principal) = @_;
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

    $h->{$principal} = time();
    if ( open my $wf, '>', _notices_seen_path() ) {
        print {$wf} encode_json($h);
        close $wf;
    }
    return { ok => 1, unread => 0 };
}

1;
