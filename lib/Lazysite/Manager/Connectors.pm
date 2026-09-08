package Lazysite::Manager::Connectors;

# SM579 phase 1: A SITE SENDS THROUGH A CONNECTOR AND KEEPS WHAT COMES BACK.
#
# A connector is a reusable, credentialed destination: a URL, the header its
# secret travels in, the MODES it permits, the groups that may call it, a
# rate cap, and optionally the data table its answers land in. The engine
# could already POST a form to a URL (the webhook handler); what it could
# not do is hold one credentialed destination that several forms, buttons
# and jobs send through, decide WHO may cause the call, and keep the answer.
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
    return ( \%c, '' );
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
    return { ok => 0, error => 'connector id must be a-z, 0-9, - or _' } unless _valid_id($id);
    my ( $c, $err ) = _normalise($def);
    return { ok => 0, error => $err } unless $c;
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
    return { ok => 0, error => 'connector id must be a-z, 0-9, - or _' } unless _valid_id($id);
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
    return { ok => 0, error => 'connector id must be a-z, 0-9, - or _' } unless _valid_id($id);
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
    return ( 0, "this connector does not permit $mode invocation" . ( $mode eq 'public' ? ' - public is opt-in, set modes.public on the connector' : '' ) )
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
    return;
}

# --- the call ----------------------------------------------------------------

# Sends `payload` (a hash of form fields or a table row - never a file)
# through connector `id`. Returns a hash the caller can show: ok, state,
# http status, the answer (decoded JSON or text, capped), and the call id.
# Every outcome is one line in the call record and one audit event; the
# payload and the answer body are in neither.
sub call {
    my ( $id, $payload, %ctx ) = @_;
    return { ok => 0, state => 'refused', error => 'connector id must be a-z, 0-9, - or _' } unless _valid_id($id);
    my $all = connectors();
    return { ok => 0, state => 'refused', error => _store_unreadable() } unless defined $all;
    my $c = $all->{$id}
        or return { ok => 0, state => 'refused', error => "no connector '$id'" };
    my ( $may, $why ) = may_call( $c, %ctx );
    unless ($may) {
        log_event( 'WARN', 'connectors', 'connector call refused',
            connector => $id, mode => ( $ctx{mode} // '' ), actor => ( $ctx{actor} // '' ), why => $why );
        return { ok => 0, state => 'refused', error => $why };
    }
    if ( $c->{rate_per_hour} ) {
        my $n = _calls_in_last_hour($id);
        if ( !defined $n ) {
            my $msg = _calls_unreadable() . '; the rate cap cannot be checked';
            log_event( 'WARN', 'connectors', 'connector call refused', connector => $id, mode => $ctx{mode}, actor => ( $ctx{actor} // '' ), why => 'call record unreadable' );
            return { ok => 0, state => 'refused', error => $msg };
        }
    }
    if ( $c->{rate_per_hour} && _calls_in_last_hour($id) >= $c->{rate_per_hour} ) {
        my $msg = "rate cap reached: $c->{rate_per_hour} calls in the last hour";
        _record_call( { call_id => _call_id(), connector => $id, mode => $ctx{mode}, actor => ( $ctx{actor} // '' ), at => time, state => 'refused', why => 'rate cap' } );
        log_event( 'WARN', 'connectors', 'connector call refused', connector => $id, mode => $ctx{mode}, actor => ( $ctx{actor} // '' ), why => 'rate cap' );
        return { ok => 0, state => 'refused', error => $msg };
    }
    return { ok => 0, state => 'refused', error => 'a payload must be a hash of fields' } unless ref $payload eq 'HASH';
    for my $v ( values %$payload ) {
        return { ok => 0, state => 'refused', error => 'a payload carries text values only - never a file or a structure' } if ref $v;
    }

    # A call never leaves without a credential this process cannot see.
    my $sec = _secrets();
    unless ( defined $sec ) {
        my $msg = _secrets_unreadable() . '; the call would go without its credential';
        _record_call( { call_id => _call_id(), connector => $id, mode => $ctx{mode}, actor => ( $ctx{actor} // '' ), at => time, state => 'refused', why => 'secret store unreadable' } );
        log_event( 'WARN', 'connectors', 'connector call refused', connector => $id, mode => $ctx{mode}, actor => ( $ctx{actor} // '' ), why => 'secret store unreadable' );
        return { ok => 0, state => 'refused', error => $msg };
    }
    my $secret  = $sec->{$id};
    my $call_id = _call_id();
    my $t0      = Time::HiRes::time();
    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new( timeout => $c->{timeout}, agent => 'lazysite-connector/1' );
    my @hdr = ( 'Content-Type' => 'application/json', 'X-Lazysite-Call' => $call_id );
    push @hdr, ( $c->{secret_header} => ( $c->{secret_prefix} // '' ) . $secret ) if defined $secret && length $secret;
    my $body = JSON::PP->new->canonical->encode($payload);
    my $res
        = $c->{method} eq 'GET'
        ? $ua->get( _with_query( $c->{url}, $payload ), @hdr )
        : $ua->post( $c->{url}, @hdr, Content => $body );
    my $ms = int( ( Time::HiRes::time() - $t0 ) * 1000 );

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
our $ANSWER_CAP = 64 * 1024;
sub _answer_of {
    my ($res) = @_;
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
    my $r = eval { Lazysite::Data::Tables::insert_row( $DOCROOT, $c->{answer_table}, $row ) };
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
    return { ok => 1, calls => \@rows, counts => \%by_state };
}

# The scheduler's job (SM666): expire the record past its keep, and count
# what never answered - so the run record says how many stuck calls there
# are, which is the state an operator has to be able to see.
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
