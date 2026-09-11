package Lazysite::Manager::Connectors;

# SM579 phase 1: A SITE SENDS THROUGH A CONNECTOR AND KEEPS WHAT COMES BACK.
#
# A connector is a reusable, credentialed destination: a URL, the header its
# secret travels in, the MODES it permits, the groups that may call it, a
# rate cap, and optionally the data table its answers land in - one
# destination that several forms, buttons and scheduled calls send through,
# deciding WHO may cause the call, and keeping the answer.
#
# SM842: IT IS THE ONLY WAY OUT OVER HTTP. The webhook and api handler types
# were a second outbound path with none of the above - no credential, no
# modes, no rate cap, no record - and they are gone: a form or the schedule
# reaches a remote through a `connector` handler naming a connector. A
# connector with nothing but a URL is the simple case, and `format: slack`
# carries the one thing a webhook could do that a connector could not.
# Scheduling moved out as well: `schedule_every` is refused here, because the
# schedule (Lazysite::Handlers) calls any handler, a connector's included.
#
# THE RULE THAT DECIDES THE DESIGN (the release manager, 2026-09-03): the
# risk of an outbound call is not what the remote does, it is who can cause
# the call. Three modes, and nothing else:
#
#   scheduled      - the timer (SM666) calls it; no request reaches the
#                    remote at all. Phase 2.
#   authenticated  - a logged-in caller in one of the connector's `callers`
#                    groups, or holding manage_connectors. Attributable,
#                    rate-limited per connector, revocable by a grant.
#   public         - a public form may trigger it. OPT-IN and never the
#                    default: the connector says `public: 1` deliberately.
#                    The engine bounds WHO and HOW OFTEN; the implementor
#                    bounds WHAT (a select, not a free textbox) and the
#                    practice docs say so.
#
# The five decisions (2026-09-07): the answer lands in a data-table row;
# form fields and table rows may be sent, never files; configuring a
# connector needs manage_connectors (authority over where data goes);
# every call is one audit row naming connector, trigger, mode and data
# class - never the payload; a call that never answers is `unanswered`,
# not "waiting", and connector-calls lists it.
#
# STORE. lazysite/connectors/connectors.json holds every connector except
# its secret; lazysite/connectors/secrets.json (0600) holds the secrets by
# connector id and is never read by a listing. lazysite/connectors/calls.jsonl
# is the record of every call: one line per outcome, never the payload.
#
# SM768: A STORE THAT EXISTS AND CANNOT BE OPENED IS NOT AN EMPTY STORE.
# The field proved it on edge: with lazysite/connectors/ unwritable after a
# failed install, connector-secret-set refused BY NAME while connector-list
# answered `has_secret: 0` for a secret that was there the whole time - and
# a call would have gone out without its credential. Every reader here
# returns undef for "cannot tell" (cannot_read logs file, error and unix
# user) and every action treats undef as a refusal, never as absence: a
# listing says the store is unreadable, a write never lands on a store it
# could not read, a call never leaves without a credential it cannot see.

use strict;
use warnings;
use JSON::PP        ();
use File::Path      qw(make_path);
use Time::HiRes     ();
use Lazysite::Util  qw(log_event secure_write_perms cannot_read);
use Lazysite::Paths ();
use Lazysite::Fetch ();    # SM790: the SSRF guard, shared with the other egress path

# HOW MUCH OF A REMOTE'S ANSWER THIS INSTANCE WILL HOLD. One number, and since
# SM790 it is both the user agent's max_size - so an oversized body is never
# read into memory in the first place - and the cap on what is stored. It sits
# here, above call(), because the agent is built there.
our $ANSWER_CAP = 64 * 1024;

our $DOCROOT         = '';
our $MODES           = [qw(scheduled authenticated public)];
our $KEEP_CALLS_DAYS = 30;

sub _dir          { return Lazysite::Paths::lazysite_dir($DOCROOT) . '/connectors' }
sub _file         { return _dir() . '/connectors.json' }
sub _secrets_file { return _dir() . '/secrets.json' }
sub _calls_file   { return _dir() . '/calls.jsonl' }

# Returns the store, {} when the file is absent, undef when it exists and
# cannot be opened (logged). No -f guard: a stat the process is not allowed
# to make is the same fault as an open it is not allowed to make.
sub _read_json {
    my ( $path, $what ) = @_;
    open my $fh, '<:raw', $path or do {
        return {} if $!{ENOENT};
        cannot_read( $what, $path );
        return undef;
    };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON::PP::decode_json( $raw // '{}' ) };
    return ref $d eq 'HASH' ? $d : {};
}

sub _write_json {
    my ( $path, $ref, $mode ) = @_;
    make_path( _dir() ) unless -d _dir();
    my $tmp = "$path.tmp.$$";
    open my $fh, '>:raw', $tmp or return ( 0, _cannot_write($path) );
    print {$fh} JSON::PP->new->canonical->pretty->encode($ref);
    close $fh or do { unlink $tmp; return ( 0, _cannot_write($path) ) };
    secure_write_perms( $tmp, $mode );
    rename $tmp, $path or do { unlink $tmp; return ( 0, _cannot_write($path) ) };
    return ( 1, '' );
}

sub _cannot_write {
    my ($path) = @_;
    my $err    = "$!";
    my ($who)  = getpwuid($>);
    ( my $leaf = $path ) =~ s{.*/}{};
    return "cannot write connectors/$leaf: $err (unix user " . ( $who // $> ) . ')';
}

sub connectors { return _read_json( _file(),         'connectors.json' ) }
sub _secrets   { return _read_json( _secrets_file(), 'connectors secrets' ) }

# The one sentence a caller gets when a store cannot be read: what, which
# file (its name under lazysite/connectors/, never the host path), the unix
# user - the three facts that turn "Permission denied" into an instruction.
sub _unreadable {
    my ( $what, $path ) = @_;
    my ($who) = getpwuid($>);
    ( my $leaf = $path ) =~ s{.*/}{};
    return "the $what (connectors/$leaf) exists but cannot be opened by this process (unix user "
        . ( $who // $> ) . ') - see the event log';
}
sub _store_unreadable   { return _unreadable( 'connector store', _file() ) }
sub _secrets_unreadable { return _unreadable( 'secret store',    _secrets_file() ) }
sub _calls_unreadable   { return _unreadable( 'call record',     _calls_file() ) }

# --- validation --------------------------------------------------------------

sub _valid_id { return defined $_[0] && $_[0] =~ /\A[a-z0-9][a-z0-9_-]{0,63}\z/ }

# SM772 (the field's second item): a MISSING id is not an invalid one. The
# refusal for an absent parameter names the parameter and where it goes;
# the charset complaint is kept for a value that is actually there.
sub _id_fault {
    my ($id) = @_;
    return 'id is required (send it in the JSON body)' unless defined $id && length $id;
    return 'connector id must be a-z, 0-9, - or _';
}

# The definition a caller may store. Everything is explicit and bounded:
# an https URL (http only for a loopback address, so a test may stand in),
# POST or GET, the header the secret rides in, the modes as three booleans
# with public defaulting OFF, the caller groups, a rate cap, a timeout, and
# the answer table by name. The secret itself is written by save_secret.
sub _normalise {
    my ($in) = @_;
    return ( undef, 'connector definition required' ) unless ref $in eq 'HASH';
    my %c;
    $c{name} = defined $in->{name} ? substr( "$in->{name}", 0, 80 ) : '';
    my $url = $in->{url} // '';
    return ( undef, 'url must be https:// (http:// only to 127.0.0.1 or localhost)' )
        unless $url =~ m{\Ahttps://[^\s/]+} || $url =~ m{\Ahttp://(?:127\.0\.0\.1|localhost)(?::\d+)?(?:/|\z)};
    $c{url}    = $url;
    $c{method} = ( $in->{method} // 'POST' ) =~ /\AGET\z/i ? 'GET' : 'POST';
    my $h = $in->{secret_header} // 'Authorization';
    return ( undef, 'secret_header must be a header name' ) unless $h =~ /\A[A-Za-z][A-Za-z0-9-]{0,63}\z/;
    $c{secret_header} = $h;
    $c{secret_prefix} = defined $in->{secret_prefix} ? substr( "$in->{secret_prefix}", 0, 32 ) : 'Bearer ';
    my $m = ref $in->{modes} eq 'HASH' ? $in->{modes} : {};
    $c{modes} = {
        scheduled     => $m->{scheduled}            ? 1                               : 0,
        authenticated => exists $m->{authenticated} ? ( $m->{authenticated} ? 1 : 0 ) : 1,
        public        => $m->{public}               ? 1                               : 0,
    };
    my @callers = ref $in->{callers} eq 'ARRAY' ? @{ $in->{callers} } : ();
    for (@callers) { return ( undef, "caller group '$_' is not a group name" ) unless /\A[a-z0-9][a-z0-9_-]{0,63}\z/ }
    $c{callers} = \@callers;
    my $rate = $in->{rate_per_hour} // 60;
    return ( undef, 'rate_per_hour must be a whole number' ) unless $rate =~ /\A\d+\z/;
    $c{rate_per_hour} = 0 + $rate;
    my $t = $in->{timeout} // 10;
    return ( undef, 'timeout must be 1..60 seconds' ) unless $t =~ /\A\d+\z/ && $t >= 1 && $t <= 60;
    $c{timeout} = 0 + $t;
    my $tbl = $in->{answer_table} // '';
    return ( undef, 'answer_table must be a table name' ) unless $tbl eq '' || $tbl =~ /\A[a-z][a-z0-9_]{0,63}\z/;
    $c{answer_table} = $tbl;
    $c{data_class} = ( $in->{data_class} // 'form' ) =~ /\A(?:form|row|fixed)\z/ ? $in->{data_class} // 'form' : 'form';

    # SM579 phase 2: THE ROW SOURCE, AND WHY IT IS A MAP AND NOT A ROW.
    #
    # A connector that could "send the row" would start sending a column the
    # day somebody adds one - a table gaining a field is an ordinary act, and
    # it must not silently widen what leaves the site. So the connector names
    # the table it may take a row from and MAPS each column it sends to the
    # field name the remote expects. An unmapped column is not sent, including
    # one added later, which is the whole point.
    #
    # This is the same reasoning the `db` page binding already gives, and the
    # filing states it as a proving test: "a table-sourced call sends only
    # mapped columns; an unmapped new column is not sent".
    my $rt = $in->{row_table} // '';
    return ( undef, 'row_table must be a table name' )
        unless $rt eq '' || $rt =~ /\A[a-z][a-z0-9_]{0,63}\z/;
    $c{row_table} = $rt;
    my $rm = ref $in->{row_map} eq 'HASH' ? $in->{row_map} : {};
    return ( undef, 'row_map names more than 64 columns' ) if keys %$rm > 64;
    my %map;
    for my $col ( sort keys %$rm ) {
        return ( undef, "row_map: '$col' is not a column name" )
            unless $col =~ /\A[a-z][a-z0-9_]{0,63}\z/;
        my $to = $rm->{$col};
        return ( undef, "row_map: the field '$col' maps to is not a field name" )
            unless defined $to && $to =~ /\A[A-Za-z][A-Za-z0-9_.-]{0,63}\z/;
        $map{$col} = "$to";
    }
    $c{row_map} = \%map;
    return ( undef, 'a row_map needs a row_table to take the row from' )
        if %map && $rt eq '';

    # SM842: THE BODY A WEBHOOK COULD SEND. `json` posts the fields as a JSON
    # object; `slack` posts {"text": "*field*: value" per line}, which is what
    # a Slack incoming webhook takes. A GET carries the fields in the query, so
    # a body format means nothing there and is refused rather than ignored.
    my $fmt = $in->{format} // 'json';
    return ( undef, "format must be json or slack (got '$fmt')" ) unless $fmt =~ /\A(?:json|slack)\z/;
    return ( undef, 'format slack needs method POST - a GET sends no body' )
        if $fmt eq 'slack' && $c{method} eq 'GET';
    $c{format} = $fmt;

    # SM842: THE SCHEDULE IS NOT THE CONNECTOR'S ANY MORE. It was one bounded
    # timer that could call one kind of thing; the schedule now calls any
    # handler, and a connector is reached through a connector handler. Refused
    # by name rather than dropped, because a caller that sends it expects it to
    # do something - a key accepted and never read is the SM772 fault turned
    # round.
    for my $k (qw(schedule_every schedule_payload)) {
        return ( undef, "$k is not a connector setting any more: schedules call handlers (SM842) - "
                . 'make a connector handler for this connector and add it to the schedule' )
            if exists $in->{$k};
    }

    return ( \%c, '' );
}

# The same check the save applies, for the one caller outside this module that
# builds a connector: the SM842 conversion, turning a webhook into one.
sub normalise { return _normalise(@_) }

# Write the whole store. The conversion edits several connectors and writes
# once; everything else goes through the actions above.
sub write_store {
    my ($all) = @_;
    return ( 0, 'the connector store must be a hash' ) unless ref $all eq 'HASH';
    return _write_json( _file(), $all, 0660 );
}

# --- the actions (the control API and the manager call these) ---------------

# has_secret has THREE answers: 1, 0, and null for "cannot tell" - the
# secret store exists and this process cannot open it. Null is the honest
# one there; 0 invites re-entering a credential that is still in place.
sub action_connector_list {
    my $all = connectors();
    return { ok => 0, error => _store_unreadable() } unless defined $all;
    my $sec = _secrets();
    my %out = (
        ok               => 1,
        secrets_readable => ( defined $sec ? 1 : 0 ),
        connectors       => [
            map {
                { id => $_, %{ $all->{$_} },
                    has_secret => !defined $sec ? undef : ( defined $sec->{$_} && length $sec->{$_} ) ? 1 : 0 }
            } sort keys %$all
        ],
    );
    $out{warning} = _secrets_unreadable() . '; has_secret is unknown for every connector' unless defined $sec;
    return \%out;
}

sub action_connector_save {
    my ( $id, $def ) = @_;
    return { ok => 0, error => _id_fault($id) } unless _valid_id($id);
    my ( $c, $err ) = _normalise($def);
    return { ok => 0, error => $err } unless $c;

    # SM807: A MAPPED COLUMN THAT IS NOT A COLUMN IS REFUSED HERE, not at call
    # time. _normalise checks the SHAPE of a name; only the table knows whether
    # it exists. Saving a bogus mapping cleanly and failing at the call is the
    # worst arrangement of the two - the operator is told at the moment a
    # visitor's action fails, rather than at the moment they made the mistake.
    #
    # A table that cannot be read is NOT a refusal: the descriptor may be
    # unreadable for reasons that have nothing to do with this connector, and
    # blocking a save on it would make an unrelated fault look like a bad
    # mapping. Unvalidated is not invalid.
    if ( length( $c->{row_table} // '' ) && %{ $c->{row_map} || {} } ) {
        require Lazysite::Data::Tables;
        my $d = eval { Lazysite::Data::Tables::load_table( $DOCROOT, $c->{row_table} ) };
        if ( ref $d eq 'HASH' && $d->{ok} && ref $d->{fields} eq 'HASH' ) {
            my $key     = $d->{key} // 'id';
            my @unknown = grep { !exists $d->{fields}{$_} && $_ ne $key }
                sort keys %{ $c->{row_map} };
            return { ok => 0, kind => 'invalid', field => 'row_map',
                error => "row_map names "
                    . ( @unknown > 1 ? 'columns' : 'a column' )
                    . " '$c->{row_table}' does not have: "
                    . join( ', ', @unknown )
                    . '. Its columns are: '
                    . join( ', ', sort( keys %{ $d->{fields} }, $key ) ) }
                if @unknown;
        }
    }
    my $all = connectors();
    return { ok => 0, error => _store_unreadable() } unless defined $all;
    my $new = !exists $all->{$id};
    $all->{$id} = $c;
    my ( $ok, $why ) = _write_json( _file(), $all, 0660 );
    return { ok => 0, error => $why } unless $ok;
    log_event( 'INFO', 'connectors', ( $new ? 'connector created' : 'connector updated' ),
        connector => $id, url => $c->{url}, public => $c->{modes}{public} );
    return { ok => 1, id => $id, connector => $c, created => ( $new ? 1 : 0 ) };
}

# The secret is written on its own, never listed, never returned.
sub action_connector_secret_set {
    my ( $id, $secret ) = @_;
    return { ok => 0, error => _id_fault($id) } unless _valid_id($id);
    my $all = connectors();
    return { ok => 0, error => _store_unreadable() }  unless defined $all;
    return { ok => 0, error => "no connector '$id'" } unless exists $all->{$id};
    return { ok => 0, error => 'secret required' } unless defined $secret && length $secret;
    return { ok => 0, error => 'secret must be one line' } if $secret =~ /[\r\n]/;
    my $sec = _secrets();
    # Never written over what could not be read: a store that is unopenable
    # now may hold every other connector's secret.
    return { ok => 0, error => _secrets_unreadable() . '; nothing was written' } unless defined $sec;
    $sec->{$id} = $secret;
    my ( $ok, $why ) = _write_json( _secrets_file(), $sec, 0600 );
    return { ok => 0, error => $why } unless $ok;
    log_event( 'INFO', 'connectors', 'connector secret set', connector => $id );
    return { ok => 1, id => $id };
}

sub action_connector_delete {
    my ($id) = @_;
    return { ok => 0, error => _id_fault($id) } unless _valid_id($id);
    my $all = connectors();
    return { ok => 0, error => _store_unreadable() }  unless defined $all;
    return { ok => 0, error => "no connector '$id'" } unless exists $all->{$id};
    # Both stores must be readable before either is written: deleting the
    # connector while its secret cannot be reached leaves a secret nobody
    # can see for a connector nobody can list.
    my $sec = _secrets();
    return { ok => 0, error => _secrets_unreadable() . '; nothing was deleted' } unless defined $sec;
    delete $all->{$id};
    my ( $ok, $why ) = _write_json( _file(), $all, 0660 );
    return { ok => 0, error => $why } unless $ok;
    if ( exists $sec->{$id} ) { delete $sec->{$id}; _write_json( _secrets_file(), $sec, 0600 ) }
    log_event( 'INFO', 'connectors', 'connector deleted', connector => $id );
    return { ok => 1, id => $id };
}

# --- may this call happen? ----------------------------------------------------

# WHO may invoke, decided before anything is sent. `mode` is what the caller
# IS, not what it asks for: the control API says authenticated, the form
# handler says public, the scheduler says scheduled. The connector's modes
# say what it permits. A caller in authenticated mode must also be in one of
# the connector's `callers` groups or hold manage_connectors.
sub may_call {
    my ( $c, %ctx ) = @_;
    my $mode = $ctx{mode} // '';
    return ( 0, "mode '$mode' is not one of scheduled, authenticated, public" )
        unless grep { $_ eq $mode } @$MODES;
    # SM807: NAME THE MODE THAT WOULD WORK, not only the one that did not.
    # This said what failed and left the caller to guess what would succeed -
    # and for a connector whose whole point is that it runs on a timer, the
    # word `scheduled` is the one that closes the question. The redirect
    # refusal (SM790) sets the standard: give the reader the next step in the
    # same sentence.
    return ( 0,
        "this connector does not permit $mode invocation"
            . ( $mode eq 'public' ? ' - public is opt-in, set modes.public on the connector' : '' )
            . do {
            my @on = grep { $c->{modes}{$_} } @$MODES;
            @on ? ' (it permits: ' . join( ', ', @on ) . ')' : ' (it permits no mode at all)';
            } )
        unless $c->{modes}{$mode};
    if ( $mode eq 'authenticated' ) {
        my $caps   = $ctx{caps} // {};
        my @groups = ref $ctx{groups} eq 'ARRAY' ? @{ $ctx{groups} } : ();
        return ( 1, '' ) if $caps->{manage_connectors};
        my %in = map { $_ => 1 } @groups;
        return ( 1, '' ) if grep { $in{$_} } @{ $c->{callers} || [] };
        return ( 0, 'this account is in none of the groups the connector names as callers'
                . ( @{ $c->{callers} || [] } ? ' (' . join( ', ', @{ $c->{callers} } ) . ')' : ' - and it names none' ) );
    }
    return ( 1, '' );
}

# HOW OFTEN: the connector's own cap, counted from the call record. Applies
# in every mode, because it does not depend on knowing whether the input was
# bounded - this is what stands between a free-textbox mistake and a bill.
sub _calls_in_last_hour {
    my ($id) = @_;
    my $f = _calls_file();
    open my $fh, '<:raw', $f or do {
        return 0 if $!{ENOENT};
        cannot_read( 'connector calls', $f );
        return undef; # cannot tell - and a cap that cannot be checked is a cap that refuses
    };
    my $since = time - 3600;
    my $n     = 0;
    while ( my $l = <$fh> ) {
        my $r = eval { JSON::PP::decode_json($l) } or next;
  # only what went out: a refusal (SM771 records every one) is not a call the cap paid for
        next if ( $r->{state}     // '' ) eq 'refused';
        $n++ if ( $r->{connector} // '' ) eq $id && ( $r->{at} // 0 ) >= $since;
    }
    close $fh;
    return $n;
}

sub _record_call {
    my ($rec) = @_;
    make_path( _dir() ) unless -d _dir();
    my $f = _calls_file();
    open my $fh, '>>:raw', $f or return;
    print {$fh} JSON::PP->new->canonical->encode($rec), "\n";
    close $fh;
    secure_write_perms( $f, 0660 );
    _prune_calls();
    return;
}

# SM822: THE RECORD IS BOUNDED BY AGE, and by nothing else.
#
# It had no retention at all: 47 entries survived on edge from connectors deleted
# days earlier, and every test run added more. The field's own reading was that
# this "is probably right for an audit", which is the crux - a record whose rows
# vanish when their connector is deleted is a record an operator can erase by
# deleting the thing it describes, and SM771 established that every refusal is a
# row.
#
# So: never prune on delete, prune by AGE. A deleted connector's calls outlive it
# and expire on their own schedule, which keeps the audit property while bounding
# a store that otherwise only grows from ordinary use.
#
# CHEAP IN THE COMMON CASE. The file is append-only, so the FIRST line is the
# oldest: read one line, and if it is inside the window there is nothing to do
# and nothing else is read. The full rewrite happens only when something has
# actually expired.
# Read one scalar from lazysite.conf. Util::service_enabled reads the same file
# but answers a boolean, and this needs a number - same shape, different question.
sub _conf_scalar {
    my ($key) = @_;
    my $path = Lazysite::Paths::lazysite_dir($DOCROOT) . '/lazysite.conf';
    open my $fh, '<', $path or do {
        # SM770/SM800: a config that could not be READ is not a config that
        # says nothing. Falling back to the default silently would make an
        # unreadable conf indistinguishable from an unset key.
        cannot_read( 'site config', $path ) unless $!{ENOENT};
        return undef;
    };
    my $val;
    while ( my $l = <$fh> ) {
        if ( $l =~ /^\Q$key\E\s*:\s*(\S+)/ ) { $val = $1; last }
    }
    close $fh;
    return $val;
}

# The window, and why it has a default rather than being required: a store with
# no retention is what this fixes, so an unset key must not mean "keep for ever".
sub _retention_days {
    my $v = _conf_scalar('connector_call_retention_days');
    return 90 unless defined $v && $v =~ /^\d+\z/ && $v > 0;
    return $v + 0;
}

sub _prune_calls {
    my $f      = _calls_file();
    my $cutoff = time - ( _retention_days() * 86400 );

    open my $in, '<:raw', $f or do {
        # Same rule: an unreadable record must not look like a record with
        # nothing to prune. Nothing is pruned either way - this reports and
        # leaves the file alone, which is the safe half.
        cannot_read( 'connector calls', $f ) unless $!{ENOENT};
        return;
    };
    my $first = <$in>;
    unless ( defined $first ) { close $in; return }
    my $rec = eval { JSON::PP->new->decode($first) };

    # A first line that will not parse is not a reason to rewrite the file -
    # that would delete a record because one byte of it is unreadable. Leave it
    # and let the operator see it.
    unless ( ref $rec eq 'HASH' && defined $rec->{at} ) { close $in; return }
    if     ( ( $rec->{at} + 0 ) >= $cutoff )            { close $in; return }

    # Back to the top: the first line was read to date it, and it is a record
    # like any other.
    seek $in, 0, 0;
    my @keep;
    while ( my $l = <$in> ) {
        my $r = eval { JSON::PP->new->decode($l) };

        # KEEP WHAT CANNOT BE DATED. An unparseable line, or one with no
        # timestamp, stays: this prunes what it can date and refuses to discard
        # what it cannot, because dropping a row over one unreadable byte is
        # worse than keeping it.
        if ( ref $r ne 'HASH' || !defined $r->{at} ) {
            push @keep, $l;
            next;
        }
        push @keep, $l if ( $r->{at} + 0 ) >= $cutoff;
    }
    close $in;

    my $tmp = "$f.pruning.$$";
    open my $out, '>:raw', $tmp or return;
    print {$out} @keep;
    close $out;
    secure_write_perms( $tmp, 0660 );
    rename $tmp, $f or unlink $tmp;
    return;
}

# SM579 phase 2: THE PAYLOAD FOR A ROW-SOURCED CALL.
#
# The caller supplies a KEY, never a payload. That is the security shape: a
# page action says "send row 41 of orders", and what is actually sent is
# decided by the connector's map and by what the account may read - not by
# what the caller typed. A caller that could hand over a payload could send
# anything at all under the connector's credential.
#
# The read goes through Data::Tables::read_rows with `as`, so it answers the
# STORE's own rules (SM476): a table the account may not read is not a table
# it can send, and the answer to "may I read it" is the same as the answer to
# "does it exist" for anyone who may not.
#
# Returns ( \%payload, '' ) or ( undef, why ).
sub row_payload {
    my ( $c, $key, %ctx ) = @_;
    my $table = $c->{row_table} // '';
    return ( undef, 'this connector takes no row source - set row_table and row_map on it' )
        unless length $table;
    my %map = %{ $c->{row_map} || {} };
    return ( undef, "this connector maps no columns of '$table', so it would send nothing" )
        unless %map;
    return ( undef, 'a row key is required' ) unless defined $key && length $key;

    require Lazysite::Data::Tables;
    my $d = Lazysite::Data::Tables::load_table( $DOCROOT, $table );
    return ( undef, "no table '$table' is declared" ) unless $d->{ok};
    # SM804: `$d->{key}`, not `$d->{table}{key}`. A loaded descriptor carries
    # its table NAME under `table` - a string - so the old spelling
    # dereferenced a string as a hash, died, and a die in a CGI is an HTTP 500
    # with an HTML body. Every row-sourced call crashed, whatever the
    # destination and whether the key existed or not.
    #
    # The test that should have caught this MOCKED load_table and read_rows,
    # and the mock returned a shape this module invented. It proved the mapping
    # and nothing about the integration. t/unit/manager/164 uses a real
    # descriptor and real rows for exactly that reason.
    my $keycol = $d->{key} // 'id';

    my $r = Lazysite::Data::Tables::read_rows( $DOCROOT, $table,
        as    => ( $ctx{as} // { user => $ctx{actor}, groups => $ctx{groups} } ),
        where => { $keycol => $key }, limit => 2, want_total => 0 );
    return ( undef, $r->{error} // "could not read '$table'" ) unless $r->{ok};
    my @rows = @{ $r->{rows} || [] };
    return ( undef, "no row with $keycol '$key' in '$table'" ) unless @rows;
    my $row = $rows[0];

    # ONLY WHAT IS MAPPED. A column the map does not name never leaves, and a
    # mapped column the row does not have is sent as absent rather than as
    # empty - a field the remote can tell apart from a blank one.
    my %payload;
    for my $col ( sort keys %map ) {
        next unless exists $row->{$col};
        $payload{ $map{$col} } = $row->{$col};
    }
    return ( undef, "row $key of '$table' has none of the mapped columns" )
        unless %payload;
    return ( \%payload, '' );
}

# --- the call ----------------------------------------------------------------

# Sends `payload` (a hash of form fields or a table row - never a file)
# through connector `id`. Returns a hash the caller can show: ok, state,
# http status, the answer (decoded JSON or text, capped), and the call id.
# Every outcome is one line in the call record and one audit event; the
# payload and the answer body are in neither.
sub call {
    my ( $id, $payload, %ctx ) = @_;
    return { ok => 0, state => 'refused', error => _id_fault($id) } unless _valid_id($id);
    my $all = connectors();
    return { ok => 0, state => 'refused', error => _store_unreadable() } unless defined $all;
    my $c = $all->{$id}
        or return { ok => 0, state => 'refused', error => "no connector '$id'" };
    # SM771: EVERY REFUSAL IS A ROW IN THE CONNECTOR'S OWN RECORD. The first
    # version recorded the rate cap and left authorisation and payload
    # refusals to the audit trail alone - so an operator reading a
    # connector's log could not see that an account outside the callers had
    # tried to use it, which is the row they most want. One helper, one
    # shape: `why` is the short reason on the row, `error` the sentence.
    my ( $may, $why ) = may_call( $c, %ctx );
    return _refused( $id, \%ctx, $why, $why ) unless $may;
    if ( $c->{rate_per_hour} ) {
        my $n = _calls_in_last_hour($id);
        return _refused( $id, \%ctx, 'call record unreadable', _calls_unreadable() . '; the rate cap cannot be checked' )
            unless defined $n;
        return _refused( $id, \%ctx, 'rate cap', "rate cap reached: $c->{rate_per_hour} calls in the last hour" )
            if $n >= $c->{rate_per_hour};
    }
    # SM804: THE ROW SOURCE IS RESOLVED HERE, INSIDE call(), so that every one
    # of its outcomes is a row in the connector's own record.
    #
    # It used to be resolved by the CALLER - the control API and the MCP twin
    # each did it before calling in - which put every row-source refusal
    # outside the one place that records anything. `/docs/connectors` states
    # the principle: "Every refusal is a row in the connector's own record."
    # Mine were not, and the field found the record empty after five calls.
    # SM771 made refusals visible on the grounds that an invisible outcome is
    # not manageable; a call that dies inside the engine is the least visible
    # outcome there is.
    #
    # WRAPPED IN eval, and that is not belt-and-braces: this reads a data table
    # through code that can die on a bad descriptor or an unreadable store, and
    # a die here is the 500 that started this. An internal fault is recorded
    # and answered like any other refusal.
    if ( defined $ctx{row} && length $ctx{row} ) {
        my ( $p, $why ) = eval { row_payload( $c, $ctx{row}, %ctx ) };
        if ($@) {
            my $err = $@;
            $err =~ s/\s+\z//;
            log_event( 'ERROR', 'connectors', 'a row-sourced call failed inside the engine',
                connector => $id, error => $err );
            return _refused( $id, \%ctx, 'row source failed',
                "the row could not be assembled into a payload: $err" );
        }
        return _refused( $id, \%ctx, 'row source', $why ) unless $p;
        $payload = $p;
    }

    return _refused( $id, \%ctx, 'payload not a hash', 'a payload must be a hash of fields' ) unless ref $payload eq 'HASH';
    for my $v ( values %$payload ) {
        return _refused( $id, \%ctx, 'payload not flat', 'a payload carries text values only - never a file or a structure' ) if ref $v;
    }

    # A call never leaves without a credential this process cannot see.
    my $sec = _secrets();
    return _refused( $id, \%ctx, 'secret store unreadable', _secrets_unreadable() . '; the call would go without its credential' )
        unless defined $sec;
    my $secret  = $sec->{$id};
    my $call_id = _call_id();
    my $t0      = Time::HiRes::time();
    require LWP::UserAgent;
    # SM790: THE CONNECTOR DOES NOT TRUST WHAT THE REMOTE SENDS BACK.
    #
    # This module's stated model is that the risk of an outbound call is not
    # what the remote does, it is who can cause the call. That is right about
    # the TRIGGER and says nothing about the RESPONSE, and the response is not
    # the operator's choice. Three defaults of LWP were doing the deciding:
    #
    #   * requests_redirectable includes GET, so a GET connector followed a 3xx
    #     up to seven hops into any host at all - a remote that was legitimately
    #     configured, later compromised, could send the call to a link-local
    #     metadata address or a loopback port.
    #   * LWP does not strip custom headers across a redirect, so the
    #     OPERATOR'S CREDENTIAL was presented to whatever host the remote
    #     nominated.
    #   * no max_size, so the answer was read whole into memory - on a path
    #     that since SM579 phase 2 runs UNATTENDED in the long-lived daemon.
    #
    # Lazysite::Fetch was hardened for exactly this under SEC-2026-07 H6 and
    # carries all three. This is a second egress path that never learned what
    # the first one was taught.
    #
    # max_redirect => 0 AND NO MANUAL FOLLOW. Fetch follows redirects manually,
    # re-validating each hop, because it is fetching a document a person asked
    # for and a legitimate http->https hop should still work. A connector is a
    # machine call to a configured endpoint: a 3xx is the endpoint saying
    # something the operator did not configure, and the honest answer is to
    # record it as a failed call rather than to chase it. That also closes the
    # credential leak outright rather than by remembering to strip a header.
    #
    # AND NOT is_safe_url ON THE CONFIGURED URL, deliberately.
    #
    # The obvious fourth change would be to run the SSRF guard over the
    # connector's own URL. It is the wrong change, and the review that found
    # this says so in its own analysis: the private-range policy here is open
    # BY DESIGN - _normalise accepts https:// to any host and http:// to
    # 127.0.0.1 or localhost - because the configured URL is the operator's
    # choice, made in the reserved tree, and a service on this host is a
    # legitimate destination. The 138E-08 field test depends on exactly that
    # carve-out.
    #
    # What was never the operator's choice is the REDIRECT TARGET and the
    # RESPONSE, and those are what the three changes above address. Applying
    # the guard to the configured URL would refuse a destination the operator
    # deliberately configured while closing nothing the redirect refusal has
    # not already closed.
    my $ua = LWP::UserAgent->new(
        timeout      => $c->{timeout},
        agent        => 'lazysite-connector/1',
        max_redirect => 0,
        max_size     => $ANSWER_CAP,
    );
    my @hdr = ( 'Content-Type' => 'application/json', 'X-Lazysite-Call' => $call_id );
    push @hdr, ( $c->{secret_header} => ( $c->{secret_prefix} // '' ) . $secret ) if defined $secret && length $secret;
    my $body
        = ( $c->{format} // 'json' ) eq 'slack'
        ? JSON::PP->new->canonical->encode(
        { text => join "\n", map { "*$_*: $payload->{$_}" } sort keys %$payload } )
        : JSON::PP->new->canonical->encode($payload);
    my $res
        = $c->{method} eq 'GET'
        ? $ua->get( _with_query( $c->{url}, $payload ), @hdr )
        : $ua->post( $c->{url}, @hdr, Content => $body );
    my $ms = int( ( Time::HiRes::time() - $t0 ) * 1000 );

    # SM790: a redirect is not a hop to chase, it is the endpoint answering
    # with something the operator did not configure. Named, so the operator
    # sees WHY rather than a bare 302 - "reconfigure the connector" is the
    # remedy, and "follow it for me" is the thing this refuses to do.
    if ( $res->is_redirect ) {
        my $loc = substr( $res->header('Location') // '', 0, 200 );
        return _refused( $id, \%ctx, 'redirected',
            "the endpoint answered "
                . $res->code
                . " and asked for another address; a connector does not follow a "
                . "redirect, because the credential would travel with it"
                . ( length $loc ? " (it asked for: $loc)" : '' ) );
    }

    my $state
        = $res->is_success ? 'answered'
        : ( $res->code == 500 && ( $res->header('Client-Warning') // '' ) eq 'Internal response'
            && ( $res->message // '' ) =~ /timeout|timed out/i ) ? 'unanswered'
        : ( $res->code == 500 && ( $res->header('Client-Warning') // '' ) eq 'Internal response' ) ? 'unanswered'
        :   'failed';
    my $answer = _answer_of($res);

    my $rec = {
        call_id => $call_id, connector => $id, mode => $ctx{mode}, actor => ( $ctx{actor} // '' ),
        trigger => ( $ctx{trigger} // '' ), data_class => $c->{data_class}, at => time,
        state   => $state, http => $res->code, ms => $ms,
    };
    _record_call($rec);
    log_event( ( $state eq 'answered' ? 'INFO' : 'WARN' ), 'connectors', "connector call $state",
        connector => $id, mode => $ctx{mode}, trigger => ( $ctx{trigger} // '' ),
        data_class => $c->{data_class}, actor => ( $ctx{actor} // '' ), http => $res->code, ms => $ms, call => $call_id );

    my $kept;
    if ( $c->{answer_table} ) {
        $kept = _keep_answer( $c, $rec, $answer );
    }
    return {
        ok      => ( $state eq 'answered' ? 1 : 0 ),
        state   => $state,
        http    => $res->code,
        call_id => $call_id,
        ms      => $ms,
        answer  => $answer,
        ( $state ne 'answered' ? ( error => "the connector call $state (http $res->{_rc})" ) : () ),
        ( defined $kept ? ( kept => $kept ) : () ),
    };
}

sub _call_id {
    my @h = ( 'a' .. 'f', 0 .. 9 );
    return join '', map { $h[ int rand @h ] } 1 .. 16;
}

sub _with_query {
    my ( $url, $payload ) = @_;
    require URI;
    my $u = URI->new($url);
    $u->query_form( $u->query_form, %$payload );
    return "$u";
}

# The answer, decoded when it is JSON, else text; capped so a misbehaving
# remote cannot fill the table.
sub _refused {
    my ( $id, $ctx, $why, $msg ) = @_;
    _record_call( { call_id => _call_id(), connector => $id, mode => ( $ctx->{mode} // '' ), actor => ( $ctx->{actor} // '' ),
            trigger => ( $ctx->{trigger} // '' ), at => time, state => 'refused', why => $why } );
    log_event( 'WARN', 'connectors', 'connector call refused',
        connector => $id, mode => ( $ctx->{mode} // '' ), actor => ( $ctx->{actor} // '' ), why => $msg );
    return { ok => 0, state => 'refused', error => $msg };
}

# SM771: an answer that never came is the library's sentence, not its stack.
# LWP's internal response ("Client-Warning: Internal response") carries the
# transport error as its body, with ` at /usr/share/perl5/LWP/... line N.`
# appended - and an answer can be kept in a table and rendered on a page,
# which puts a host path one template away from the public. Keep the first
# line, without the location.
sub _answer_of {
    my ($res) = @_;
    if ( ( $res->header('Client-Warning') // '' ) eq 'Internal response' ) {
        my ($first) = split /\n/, ( $res->decoded_content // '' );
        $first //= '';
        $first =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*\z//;
        return $first;
    }
    my $body = $res->decoded_content // '';
    $body = substr( $body, 0, $ANSWER_CAP ) if length $body > $ANSWER_CAP;
    if ( ( $res->content_type // '' ) =~ m{json}i ) {
        my $d = eval { JSON::PP::decode_json($body) };
        return $d if defined $d;
    }
    return $body;
}

# THE ANSWER LIVES IN A TABLE ROW (decision 1). The table is the site's own,
# declared through the data plugin, with the columns named here; a missing
# table or column is reported on the call, not silently skipped.
sub _keep_answer {
    my ( $c, $rec, $answer ) = @_;
    require Lazysite::Data::Tables;
    my $row = {
        connector => $rec->{connector},
        call_id   => $rec->{call_id},
        mode      => $rec->{mode},
        actor     => $rec->{actor},
        at        => $rec->{at},
        state     => $rec->{state},
        http      => $rec->{http},
        answer => ( ref $answer ? JSON::PP->new->canonical->encode($answer) : $answer ),
    };
    my $r = eval { Lazysite::Data::Tables::insert_row( $DOCROOT, $c->{answer_table}, $row, actor => $rec->{actor} ) };
    my $err = $@ ? "$@" : ( $r && !$r->{ok} ? ( $r->{error} // 'insert failed' ) : '' );
    if ($err) {
        log_event( 'WARN', 'connectors', 'answer not kept', connector => $rec->{connector}, table => $c->{answer_table}, why => $err );
        return { ok => 0, table => $c->{answer_table}, error => $err };
    }
    return { ok => 1, table => $c->{answer_table}, key => $r->{key} };
}

# --- the record, for the operator -------------------------------------------

sub action_connector_calls {
    my (%o) = @_;
    my $f = _calls_file();
    my @rows;
    if ( open my $fh, '<:raw', $f ) {
        while ( my $l = <$fh> ) {
            my $r = eval { JSON::PP::decode_json($l) } or next;
            next if defined $o{connector} && length $o{connector} && ( $r->{connector} // '' ) ne $o{connector};
            next if defined $o{state} && length $o{state} && ( $r->{state} // '' ) ne $o{state};
            push @rows, $r;
        }
        close $fh;
    }
    elsif ( !$!{ENOENT} ) {
        cannot_read( 'connector calls', $f );
        return { ok => 0, error => _calls_unreadable() };
    }
    my $limit = $o{limit} // 200;
    $limit = 200 unless $limit =~ /\A\d+\z/;
    @rows  = reverse @rows;
    splice @rows, $limit if @rows > $limit;
    my %by_state;
    $by_state{ $_->{state} }++ for @rows;
    return { ok => 1, calls => \@rows, counts => \%by_state,
        retention_days => _retention_days() };    # SM822: say what is kept
}

# The scheduler's job (SM666): expire the record past its keep, and count
# what never answered - so the run record says how many stuck calls there
# are, which is the state an operator has to be able to see.
#
# SM842: a connector on a timer is a schedule entry calling a connector
# handler (Lazysite::Handlers); the call arrives here through call() with mode
# `scheduled`, so a connector that has not opted into it is refused by may_call
# exactly as a request-time caller would be - one gate for all three modes.
sub sweep {
    my ($docroot) = @_;
    local $DOCROOT = $docroot;
    my $f = _calls_file();
    open my $fh, '<:raw', $f or do {
        return { ok => 1, kept => 0, expired => 0, unanswered => 0 } if $!{ENOENT};
        cannot_read( 'connector calls', $f );
        return { ok => 0, error => _calls_unreadable() };
    };
    my $cutoff = time - $KEEP_CALLS_DAYS * 86400;
    my ( @keep, $expired, $unanswered ) = ( (), 0, 0 );
    while ( my $l = <$fh> ) {
        my $r = eval { JSON::PP::decode_json($l) } or next;
        if ( ( $r->{at} // 0 ) < $cutoff ) { $expired++; next }
        $unanswered++ if ( $r->{state} // '' ) eq 'unanswered';
        push @keep, $l;
    }
    close $fh;
    if ($expired) {
        my $tmp = "$f.tmp.$$";
        open my $out, '>:raw', $tmp or return { ok => 0, error => _cannot_write($f) };
        print {$out} @keep;
        close $out;
        secure_write_perms( $tmp, 0660 );
        rename $tmp, $f or unlink $tmp;
    }
    return { ok => 1, kept => scalar @keep, expired => $expired, unanswered => $unanswered };
}

1;
