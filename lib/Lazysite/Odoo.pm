package Lazysite::Odoo;

# SM747: THE ODOO EXTENSION'S ENGINE - A PAGE USES ODOO THROUGH A NAMED
# OPERATION, AND LAZYSITE KNOWS NOTHING ELSE ABOUT ODOO.
#
# THE RULE THAT KEEPS IT GENERAL-PURPOSE (SM747, 2026-10-01): model names, field
# names, domains, the RPC call shapes and the ERP's semantics live in OOM's
# operation packs. Lazysite names an operation, binds its parameters, renders
# the descriptors it is handed and presents a plan for confirmation. That is
# what makes this a facility rather than a connector - an app that needs
# invoices needs an operation pack, not engine work - and t/lint/240 holds it:
# no Odoo model name, RPC method or endpoint path in lazysite's code.
#
# WHAT IS HERE (slice A, 2026-10-12):
#
#   * whether OOM is present and new enough - the extension declares
#     `libodoo-oom-perl (>= 0.03)` and refuses BY NAME when the Ops layer is
#     missing or older, rather than failing at a page;
#   * the connection: odoo_url, odoo_db, odoo_login, odoo_timeout, odoo_max_kb,
#     odoo_allow_writes and odoo_packs in the extension's own config (OB1: "a
#     per-site Odoo connection in the extension's config");
#   * X4-a's URL rule: https:// to any host, http:// to loopback only, and NO
#     plain http:// to a private (RFC1918) address;
#   * OB5's fault kinds: OOM's error kinds and fault categories mapped to
#     { ok: 0, kind, error } - the fault's own text is logged and never
#     returned (SM713, SM738, SM739: three leaks in three passes);
#   * OB8's call record: one line per call, fixed fields, never the payload and
#     never the credential;
#   * the mode gate, through Lazysite::Egress - SM579's three modes, placed as
#     the connector places them: inside the one function that sends, before
#     anything is read or sent, so no caller can forget it.
#
# THE ENDPOINT, AND WHY IT IS NOT A HANDLER FIELD. The filing's slice table says
# "endpoint config as a new handler type", from the 2026-10-02 finding that an
# Odoo endpoint is a handler type rather than a connector format. OB1 and the
# 2026-10-12 ruling (R1: "a site-level Odoo account") put the CONNECTION in the
# extension's config. Both hold: the connection - URL, database, connection
# user - is the extension's, one per site, and the HANDLER TYPE `odoo` is how a
# form, the schedule or a page reaches it, naming an operation (slice CU).
# Repeating a URL and a credential on every handler would be four copies of one
# connection, which is the shape this codebase keeps removing.
#
# NOT HERE: the transport. OOM's own is hardened (no redirects, a size cap, TLS
# verification - the filing's *Engine notes*), so OB6's connection discipline is
# OOM's and only the URL rule, which is about the operator's choice of
# destination, is lazysite's.
use strict;
use warnings;
use JSON::PP         ();
use File::Path       qw(make_path);
use Lazysite::Util   qw(log_event cannot_read secure_write_perms);
use Lazysite::Paths  ();
use Lazysite::Egress ();

our $DOCROOT = '';

# What the extension declares and refuses below. The deb is what an operator
# installs; the version is the first that carries the Ops layer (filed to OOM's
# inbox 2026-10-12: the 0.01 deb carries 8 of the tree's 41 modules).
our $OOM_PACKAGE = 'libodoo-oom-perl';
our $OOM_MIN     = '0.03';

# The capability that stands in for a binding's `callers` groups, and that
# configures Odoo bindings and the connection user's key. manage_odoo (OM3) is
# slice E's; until it exists this is the capability that already governs where
# site data is sent.
our $OVERRIDE_CAP = 'manage_connectors';

sub _lz        { return Lazysite::Paths::lazysite_dir($DOCROOT) }
sub store_dir  { return _lz() . '/odoo' }
sub calls_file { return store_dir() . '/calls.jsonl' }

# The extension's config file (`config_file: lazysite/odoo.conf`), in the
# engine tree as the resolver finds it - as notify-xmpp.conf is read.
sub conf_file { return _lz() . '/odoo.conf' }

# --- is OOM here, and new enough? ---------------------------------------------
#
# ( 1, '' ) or ( 0, why ). The sentence names the PACKAGE and the version,
# because that is what an operator acts on; the module is named beside it so a
# developer running from a tree can tell which file was not found.
#
# The modules required are the ones the engine calls, listed in the 2026-10-12
# filing to OOM. Requiring them here, once, means a host carrying the 0.01 deb
# (the mapper alone) is refused at the first call with this sentence rather
# than failing halfway through an operation with Perl's.
sub oom_check {
    my $need   = "the Odoo extension needs $OOM_PACKAGE (>= $OOM_MIN)";
    my $loaded = eval { require Odoo::Ops; 1 };
    return ( 0, "$need - it is not installed (Odoo::Ops cannot be loaded)" )
        unless $loaded;
    unless ( eval { Odoo::Ops->VERSION($OOM_MIN); 1 } ) {
        my $have = eval { Odoo::Ops->VERSION } // 'unversioned';
        return ( 0, "$need - this host has $have, which does not carry what the "
                . 'extension calls' );
    }
    for my $m ( qw(Odoo::Error Odoo::Ops::Config Odoo::Ops::Context Odoo::Ops::Registry
        Odoo::Ops::Plan Odoo::Ops::Runner) )
    {
        ( my $file = "$m.pm" ) =~ s{::}{/}g;
        next if eval { require $file; 1 };
        my $err = $@ // '';
        log_event( 'WARN', 'odoo', 'an OOM module would not load', module => $m,
            error => ( split /\n/, $err )[0] // '' );
        return ( 0, "$need - $m will not load (see the event log)" );
    }
    return ( 1, '' );
}

# --- the connection -----------------------------------------------------------

# The extension's config as key => value, {} when there is no file, undef when
# it exists and cannot be read (SM768: unopenable is not empty).
sub read_conf {
    my $path = conf_file();
    open my $fh, '<:utf8', $path or do {
        return {} if $!{ENOENT};
        cannot_read( 'the Odoo extension config', $path );
        return undef;
    };
    my %kv;
    while ( my $l = <$fh> ) {
        chomp $l;
        $l =~ s/^\s+|\s+$//g;
        next if $l =~ /^#/ || !length $l;
        my ( $k, $v ) = split /\s*:\s*/, $l, 2;
        $kv{$k} = $v // '' if defined $k && length $k;
    }
    close $fh;
    return \%kv;
}

my %PRIVATE4 = (
    10  => sub { 1 },
    172 => sub { $_[0] >= 16 && $_[0] <= 31 },
    192 => sub { $_[0] == 168 },
);

# X4-a, RULED 2026-09-28: https:// to any host; http:// to loopback only; NO
# plain http:// to an RFC1918 Odoo. '' when the URL may be used, else why.
#
# The private-address refusal is worded on its own, not folded into "loopback
# only", because it is the case an operator with Odoo on an internal network
# will meet, and the remedy - https:// to a private hostname, which IS allowed -
# is the sentence they need.
#
# A user and password in the URL are refused outright: the connection user's
# key is stored as a secret, and a URL is shown on pages and written to logs.
sub check_url {
    my ($url) = @_;
    return 'odoo_url is required' unless defined $url && length $url;
    return 'odoo_url must be one line' if $url =~ /[\r\n]/;
    my ( $scheme, $host ) = $url =~ m{
        \A (https?) ://
        ( \[ [0-9A-Fa-f:.]+ \] | [A-Za-z0-9.-]+ )    # a bracketed IPv6 literal, or a name
        (?: : [0-9]{1,5} )?                          # an optional port
        (?: / \S* )? \z
    }x;
    return 'odoo_url must look like https://odoo.example.com - a scheme, a host and '
        . 'nothing in place of the host but its name (no user or password in it)'
        unless defined $scheme;
    return '' if $scheme eq 'https';

    my $h = lc $host;
    return '' if $h eq 'localhost' || $h eq '[::1]';
    if ( my @o = $h =~ /\A([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\z/ ) {
        return '' if $o[0] == 127;
        return "odoo_url: plain http:// to the private address $host is refused (X4-a) - "
            . 'reach an Odoo on an internal network over https:// to its private '
            . 'hostname, which is allowed'
            if $PRIVATE4{ $o[0] } && $PRIVATE4{ $o[0] }->( $o[1] );
    }
    return 'odoo_url: http:// is allowed only to this host (127.0.0.1 or localhost); '
        . 'anything else must be https://';
}

my %CONN_DEFAULT = ( odoo_timeout => 30, odoo_max_kb => 2048 );

# ( \%connection, '' ) or ( undef, why ). Every value is checked here, once, so
# nothing downstream has to remember to: a connection that reaches OOM is one
# this function accepted.
sub connection {
    my $kv = read_conf();
    return ( undef, 'the Odoo extension config exists but cannot be read by this '
            . 'process - see the event log' )
        unless defined $kv;

    my %c;
    my $why = check_url( $kv->{odoo_url} );
    return ( undef, $why ) if length $why;
    ( $c{url} = $kv->{odoo_url} ) =~ s{/+\z}{};

    my $db = $kv->{odoo_db} // '';
    return ( undef, 'odoo_db is required - the name of the Odoo database' ) unless length $db;
    return ( undef, 'odoo_db must be letters, digits, ., - or _' )
        unless $db =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,62}\z/;
    $c{db} = $db;

    my $login = $kv->{odoo_login} // '';
    return ( undef, 'odoo_login is required - the connection user\'s Odoo login' )
        unless length $login;
    return ( undef, 'odoo_login must be one line of at most 128 characters' )
        if length $login > 128 || $login =~ /[\r\n]/;
    $c{login} = $login;

    for my $k (qw(odoo_timeout odoo_max_kb)) {
        my $v = $kv->{$k};
        $v = $CONN_DEFAULT{$k} unless defined $v && length $v;
        return ( undef, "$k must be a whole number" ) unless $v =~ /\A[0-9]+\z/;
        $c{ $k =~ s/\Aodoo_//r } = 0 + $v;
    }
    return ( undef, 'odoo_timeout must be 1 to 120 seconds' )
        unless $c{timeout} >= 1 && $c{timeout} <= 120;
    return ( undef, 'odoo_max_kb must be 16 to 65536' )
        unless $c{max_kb} >= 16 && $c{max_kb} <= 65536;

    # WRITES ARE OFF UNLESS SAID. OOM refuses to apply a plan without
    # allow_writes = 1, and this is the operator's one switch for it.
    $c{allow_writes} = ( ( $kv->{odoo_allow_writes} // '' ) =~ /\A\s*(?:1|true|yes|on)\s*\z/i ) ? 1 : 0;

    # The operation packs beyond OOM's own, by Perl namespace. Not Odoo
    # knowledge: a namespace names where the knowledge is, which is the point.
    my @packs = grep { length } split /\s*,\s*/, ( $kv->{odoo_packs} // '' );
    for (@packs) {
        return ( undef, "odoo_packs: '$_' is not a Perl namespace" )
            unless /\A[A-Z][A-Za-z0-9_]*(?:::[A-Za-z0-9_]+)*\z/;
    }
    $c{packs} = \@packs;
    return ( \%c, '' );
}

# --- OB5: a fault is named, and its text stays in the log -----------------------
#
# OOM's error kinds and Odoo's fault categories, mapped to the kinds a page or
# an agent acts on. The four OB5 names are the ones the filing fixes; the rest
# say which refusal it was, so a caller can tell "re-plan" from "switch writes
# on" without reading prose.
my %FAULT_KIND = (
    access => [ 'odoo-access-refused', 'Odoo refused this operation: the connection user\'s rights in Odoo do not allow it' ],
    credential => [ 'invalid-credential', 'Odoo did not accept the connection user\'s login or API key' ],
    session    => [ 'session-expired', 'the Odoo session has expired' ],
    validation => [ 'odoo-validation', 'Odoo refused the values the operation sent' ],
    missing => [ 'odoo-missing', 'a record the operation needed is no longer in Odoo' ],
    other   => [ 'odoo-fault',   'Odoo answered with an error' ],
);
my %REFUSED_KIND = (
    scope => [ 'scope-refused', 'the operation asked for something outside its declared scope, so nothing was sent' ],
    redirect => [ 'refused', 'Odoo answered with a redirect, which is never followed - the credential would travel with it' ],
    oversize => [ 'refused', 'Odoo\'s answer was larger than odoo_max_kb allows' ],
    'read-only' => [ 'read-only', 'writes are switched off for this Odoo connection (odoo_allow_writes)' ],
    instance => [ 'instance', 'the plan was made against a different Odoo connection' ],
    applied  => [ 'applied',  'this plan has already been applied' ],
    stale => [ 'stale', 'the plan is stale: the data in Odoo changed after it was made - make it again' ],
    fingerprint => [ 'edited', 'the plan was changed after it was made, so it cannot be applied' ],
    'not-a-plan' => [ 'invalid', 'that is a result, not a plan' ],
);

# fault( $err, %ctx ) -> { ok => 0, kind, error }
#
# THE TEXT IS LOGGED, NEVER RETURNED. Odoo's own message can carry a traceback,
# a module path, a SQL fragment or the name of a record the caller may not see;
# OOM's carries the URL. What goes back is one of the sentences above.
sub fault {
    my ( $err, %ctx ) = @_;
    my ( $kind, $said, %why );
    if ( ref $err && eval { $err->isa('Odoo::Error') } ) {
        my $k = $err->kind // '';
        %why = ( oom_kind => $k, code => ( $err->code // '' ),
            category => ( $err->fault_category // '' ) );
        if ( $k eq 'fault' ) {
            ( $kind, $said ) = @{ $FAULT_KIND{ $err->fault_category // 'other' } // $FAULT_KIND{other} };
        }
        elsif ( $k eq 'transport' ) {
            ( $kind, $said ) = ( 'transport-failure', 'Odoo could not be reached, or did not answer in a usable way' );
        }
        elsif ( $k eq 'refused' ) {
            ( $kind, $said ) = @{ $REFUSED_KIND{ $err->code // '' }
                    // [ 'refused', 'the call was refused before Odoo answered' ] };
        }
        elsif ( $k eq 'config' ) {
            ( $kind, $said ) = ( 'config', 'the Odoo connection is not configured correctly - see the event log' );
        }
        else {
            ( $kind, $said ) = ( 'invalid', 'the operation refused what it was given - see the event log' );
        }
        $why{detail} = $err->message // '';
    }
    else {
        ( $kind, $said ) = ( 'internal', 'the Odoo call failed inside the engine - see the event log' );
        ( $why{detail} = "$err" ) =~ s/\s+\z//;
    }
    log_event( 'WARN', 'odoo', 'odoo call failed', kind => $kind, %why,
        map { ( $_ => $ctx{$_} ) } grep { defined $ctx{$_} } qw(binding operation mode) );
    return { ok => 0, kind => $kind, error => $said };
}

# What a fault kind means for the call record's outcome (OB8's four states).
sub outcome_of {
    my ($kind) = @_;
    return 'answered' unless defined $kind && length $kind;
    return 'unanswered' if $kind eq 'transport-failure';
    return 'odoo-fault'
        if $kind =~ /\A(?:odoo-|invalid-credential\z|session-expired\z)/;
    return 'refused';
}

# --- OB8: one record per call ---------------------------------------------------
#
# FIXED FIELDS, AND THE SINK REFUSES ANY OTHER - the shape OOM's own audit has
# (Odoo::Ops::Audit), for the same reason: a payload or a credential cannot be
# added to the trail by accident if the trail will not take a key it does not
# know. `visitor` is a HASH of the visitor's key, never the key, which is a
# bearer secret.
our @CALL_FIELDS = qw(at call_id actor visitor ip login binding operation mode phase
    outcome kind ms);
my %CALL_FIELD = map { $_ => 1 } @CALL_FIELDS;

sub record_call {
    my (%rec) = @_;
    my @stray = grep { !$CALL_FIELD{$_} } sort keys %rec;
    if (@stray) {
        log_event( 'ERROR', 'odoo', 'a call record carried a field it may not',
            fields => join( ',', @stray ) );
        return 0;
    }
    $rec{at} //= time;
    my $dir = store_dir();
    eval { make_path($dir) unless -d $dir; 1 } or return 0;
    my $f = calls_file();
    open my $fh, '>>:raw', $f or do {
        log_event( 'WARN', 'odoo', 'cannot append the call record', error => "$!" );
        return 0;
    };
    print {$fh} JSON::PP->new->canonical->encode( \%rec ), "\n";
    close $fh;
    secure_write_perms( $f, 0660 );
    _audit_line( \%rec );
    _prune_calls();
    return 1;
}

# SM822's rule for the connector's record, here from the start: bounded by AGE
# and nothing else, cheap when nothing has expired (the first line is the
# oldest), and a line that cannot be dated is kept rather than dropped.
sub _prune_calls {
    my $f = calls_file();
    open my $in, '<:raw', $f or return;
    my $first = <$in>;
    my $rec   = defined $first ? eval { JSON::PP::decode_json($first) } : undef;
    our $CALLS_KEEP_DAYS;
    my $cut = time - $CALLS_KEEP_DAYS * 86400;
    unless ( ref $rec eq 'HASH' && defined $rec->{at} && $rec->{at} < $cut ) { close $in; return }
    seek $in, 0, 0;
    my @keep;
    while ( my $l = <$in> ) {
        my $r = eval { JSON::PP::decode_json($l) };
        push @keep, $l if ref $r ne 'HASH' || !defined $r->{at} || $r->{at} >= $cut;
    }
    close $in;
    open my $out, '>:raw', "$f.pruning.$$" or return;
    print {$out} @keep;
    close $out;
    secure_write_perms( "$f.pruning.$$", 0660 );
    rename "$f.pruning.$$", $f or unlink "$f.pruning.$$";
    return;
}

# The shared audit trail gets one line too, so a site's one place to ask "who
# did what" answers for Odoo calls. Never the payload: the binding, the
# operation, the outcome.
sub _audit_line {
    my ($r) = @_;
    eval {
        require Lazysite::Audit;
        no warnings 'once';
        local $Lazysite::Audit::LAZYSITE_DIR = _lz();
        Lazysite::Audit::audit_log( $r->{actor} // '', 'odoo-call',
            ( $r->{binding} // '' ) . ' -> ' . ( $r->{operation} // '' ),
            $r->{ip} // '', $r->{outcome} // '', $r->{mode} // '', $r->{kind} // '' );
        1;
    };
    return;
}

# The record, newest first, for the operator - what the connector's
# connector-calls is for connectors.
sub read_calls {
    my (%o) = @_;
    my $f = calls_file();
    my @rows;
    if ( open my $fh, '<:raw', $f ) {
        while ( my $l = <$fh> ) {
            my $r = eval { JSON::PP::decode_json($l) } or next;
            next if defined $o{binding} && length $o{binding} && ( $r->{binding} // '' ) ne $o{binding};
            push @rows, $r;
        }
        close $fh;
    }
    elsif ( !$!{ENOENT} ) {
        cannot_read( 'the Odoo call record', $f );
        return undef;
    }
    return [ reverse @rows ];
}

sub new_call_id {
    my @h = ( 'a' .. 'f', 0 .. 9 );
    return join '', map { $h[ int rand @h ] } 1 .. 16;
}

# --- the mode gate (SM579 / X4) --------------------------------------------------
#
# WHO may cause this binding to run. The decision and its wording are
# Lazysite::Egress's, as they are for a connector - the same policy, not a
# copy of it. `mode` is what the caller IS: the endpoint says public for a
# visitor and authenticated for a verified session, the schedule says
# scheduled. A binding that does not permit the mode is refused before
# anything else is looked at.
sub may_call {
    my ( $binding, %ctx ) = @_;

    # B: a session binding is for whoever has signed in to Odoo, and Odoo is what
    # decides what they may do. The mode must still be one it permits (only
    # authenticated), and the override capability does not stand in for a sign-in.
    if ( session_binding($binding) ) {
        return Lazysite::Egress::may_invoke(
            mode    => $ctx{mode},
            what    => 'Odoo binding',
            permits => $binding->{modes},
            callers => ['odoo-session'],
            groups  => ['odoo-session'],
        );
    }
    return Lazysite::Egress::may_invoke(
        mode     => $ctx{mode},
        what     => 'Odoo binding',
        permits  => ( ref $binding eq 'HASH' ? $binding->{modes}   : {} ),
        callers  => ( ref $binding eq 'HASH' ? $binding->{callers} : [] ) || [],
        groups   => $ctx{groups},
        caps     => $ctx{caps} // {},
        override => $OVERRIDE_CAP,
    );
}

# Whether a binding runs as the person signed in to Odoo (credential: session).
sub session_binding { return ( ref $_[0] eq 'HASH' && ( $_[0]{credential} // '' ) eq 'session' ) ? 1 : 0 }

# gate( $binding, %ctx ) -> ( 1, \%connection ) or ( 0, \%refusal )
#
# THE ORDER IS THE POINT, and it is the connector's: WHO first (the mode gate),
# then whether the extension is on, then whether OOM is here, then the
# connection. Each refusal is a row in the call record, because a refusal an
# operator cannot see is one they cannot manage (SM771).
sub gate {
    my ( $binding, %ctx ) = @_;
    my %rec = _rec_base( $binding, %ctx );

    # B: a binding that runs as a person signed in to Odoo has nobody to run as
    # without that sign-in. It is refused - never run as the connection user, whose
    # account is likely wider than the person's.
    return _refusal( \%rec, 'signin-required',
        'this binding runs as a person signed in to Odoo, and the call carries no Odoo sign-in '
            . '- only the Odoo endpoint, for a person who has signed in, carries one' )
        if session_binding($binding) && !length( $ctx{odoo_session} // '' );

    my ( $may, $why ) = may_call( $binding, %ctx );
    return _refusal( \%rec, 'mode', $why ) unless $may;

    my $dwhy = domain_refusal( $binding, %ctx );
    return _refusal( \%rec, 'wrong-domain', $dwhy ) if length $dwhy;

    unless ( _extension_enabled() ) {
        return _refusal( \%rec, 'disabled',
            'the Odoo extension is switched off - a sysop can enable it on the Extensions page' );
    }

    my ( $have, $missing ) = oom_check();
    return _refusal( \%rec, 'unavailable', $missing ) unless $have;

    my ( $conn, $cwhy ) = connection();
    return _refusal( \%rec, 'config', $cwhy ) unless $conn;
    return ( 1, $conn );
}

# E-Q1 (as recommended, approved 2026-10-13): A BINDING WITH A `domain:` RUNS
# ONLY FOR REQUESTS ON THAT DOMAIN; one without stays instance-wide. '' when
# the call may go on, else why not.
#
# SM1051 gave every handler a domain, and it governs who edits a binding and
# which forms bind it. This is the running half, asked inside the gate so every
# door - the page endpoint, the page binding, a form, the control API, MCP, the
# confirm - meets the same rule:
#
#   host    a request on a host: it must be the binding's domain. An alias host
#           is a domain of its own here, as SM1051 names domains.
#   reach   a signed-in caller with no host (the control API, MCP): it must
#           reach the domain by SM976's one rule (Manager::Common::
#           caller_may_use_handler) - { scopes => [...] } for an MCP grant, {}
#           for the manager request, whose own state says who is asking.
#   the schedule has neither: no request was made, and the operator scheduled
#           it, so it runs.
#
# A call that says neither, outside the schedule, is REFUSED: a door that
# forgot to name its domain must not run every domain's binding.
sub domain_refusal {
    my ( $b, %c ) = @_;
    my $dom = lc( ( ref $b eq 'HASH' ? $b->{domain} : '' ) // '' );
    return '' unless length $dom;
    if ( defined $c{host} ) {
        return '' if lc( $c{host} ) eq $dom;
        return "this binding belongs to the domain $dom and runs only for requests there";
    }
    if ( ref $c{reach} eq 'HASH' ) {
        require Lazysite::Manager::Common;
        no warnings 'once';
        local $Lazysite::Manager::Common::DOCROOT = $Lazysite::Manager::Common::DOCROOT // $DOCROOT;
        return '' if Lazysite::Manager::Common::caller_may_use_handler( { domain => $dom }, %{ $c{reach} } );
        return "this binding belongs to the domain $dom, and this account does not reach the domain $dom";
    }
    return '' if ( $c{mode} // '' ) eq 'scheduled';
    return "this binding belongs to the domain $dom, and the call names no domain to check it against";
}

sub _rec_base {
    my ( $binding, %ctx ) = @_;
    return (
        call_id => $ctx{call_id} // new_call_id(),
        actor   => $ctx{actor}   // '',
        ( defined $ctx{visitor} ? ( visitor => $ctx{visitor} ) : () ),
        ip        => $ctx{ip}    // '',
        mode      => $ctx{mode}  // '',
        phase     => $ctx{phase} // 'run',
        binding   => ( ref $binding eq 'HASH' ? $binding->{id}        // '' : '' ),
        operation => ( ref $binding eq 'HASH' ? $binding->{operation} // '' : '' ),
    );
}

sub _refusal {
    my ( $rec, $kind, $why ) = @_;
    record_call( %$rec, outcome => 'refused', kind => $kind );
    log_event( 'WARN', 'odoo', 'odoo call refused', kind => $kind, why => $why,
        binding => $rec->{binding}, mode => $rec->{mode} );
    return ( 0, { ok => 0, kind => $kind, error => $why } );
}

# SM409: the extension is a contract plugin, so off means off - on every path,
# not only the manager's.
sub _extension_enabled {
    my $ok = eval {
        require Lazysite::Manager::Plugins;
        no warnings 'once';
        local $Lazysite::Manager::Plugins::DOCROOT = $DOCROOT;
        Lazysite::Manager::Plugins::plugin_enabled('plugins/odoo.pl');
    };
    return $ok ? 1 : 0;
}

# =============================================================================
# SLICE CU (2026-10-12): THE CONNECTION USER, AND THE CALL ITSELF.
#
# R1: "the connection user is set on odoo with permissions as required by the
# user, which allows some backend activities, without the user logging in". So
# every call below runs as ONE Odoo account whose rights Odoo decides, through
# a named operation whose scope OOM's Guard enforces. Lazysite adds who may
# cause the call, how often, what a request may set, and the record.
# =============================================================================

# THE TRANSPORT, FOR TESTS ONLY. OOM's Context takes an injected transport
# (Odoo::Ops::Context->new(transport => ...)); a test sets this to OOM's fake
# Odoo, and nothing in the product does. Unset, OOM builds its own hardened one.
our $TRANSPORT;

# The connection user's account name in the key store (Lazysite::Odoo::Secret).
# Q2's per-grant MCP accounts are other names beside it.
our $ACCOUNT = 'connection';

# A plan waits this long for its confirm, and is kept this long for the record.
our $PLAN_TTL       = 3600;
our $PLAN_KEEP_DAYS = 7;

# How long a call record is kept, and the rolling window the caps count over.
our $CALLS_KEEP_DAYS = 90;
our $CAP_WINDOW      = 3600;

sub plans_dir   { return store_dir() . '/plans' }
sub recent_file { return store_dir() . '/recent.jsonl' }

# The operations OOM offers: its own packs plus the site's (odoo_packs). The
# registry is OOM's, and so is every name in it.
sub registry {
    my ($conn) = @_;
    local $ENV{ODOO_OPS_NAMESPACES} = join ',', @{ $conn->{packs} || [] };
    return Odoo::Ops::Registry->new;
}

sub operation_class {
    my ( $conn, $name ) = @_;
    my $class = eval { registry($conn)->class_for($name) };
    return ( $class, '' ) if $class;
    my $err = $@;
    log_event( 'WARN', 'odoo', 'operation not found', operation => $name,
        detail => ( ref $err ? $err->message : "$err" ) =~ s/\s+\z//r );
    return ( undef, "no operation '$name' is installed" );
}

# One OOM context per call, built in memory (never a config file), carrying the
# key through OOM's own file strategy so OOM's mode check applies on top of
# ours, and the ACTOR - who caused this - so OOM's audit names them on every
# RPC record (Odoo::Ops::Guard).
#
# ONE ATTEMPT. OOM's default retry ladder sleeps 2, 5 and 15 seconds before
# retrying a transport failure, which is right for a batch run and wrong for a
# page a visitor is waiting on.
sub context {
    my ( $conn, %o ) = @_;
    if ( defined $o{session} ) {

        # B: the call runs as the person, over OOM's session transport, carrying
        # THEIR session. The connection user's key and any injected connection
        # transport play no part: a test that wants to see what a session call does
        # must supply the session's own HTTP, so nothing can fall back by accident.
        my $scfg = Odoo::Ops::Config->new(
            url                => $conn->{url},
            db                 => $conn->{db},
            credential         => 'session',
            session            => $o{session},
            timeout            => $conn->{timeout},
            max_response_bytes => $conn->{max_kb} * 1024,
            allow_writes       => ( $conn->{allow_writes} ? 1 : 0 ),
            runs_dir           => plans_dir(),
        );
        require Lazysite::Odoo::Session;
        my @t;
        if ($Lazysite::Odoo::Session::HTTP) {
            require Odoo::Transport::Session;
            @t = ( transport => Odoo::Transport::Session->new(
                    url => $conn->{url}, session => $o{session}, http => $Lazysite::Odoo::Session::HTTP ) );
        }
        return Odoo::Ops::Context->new(
            config => $scfg, actor => $o{actor} // 'lazysite', retries => [0], @t );
    }
    require Lazysite::Odoo::Secret;
    no warnings 'once';
    local $Lazysite::Odoo::Secret::DOCROOT = $DOCROOT;
    my $cfg = Odoo::Ops::Config->new(
        url        => $conn->{url},
        db         => $conn->{db},
        login      => $conn->{login},
        credential => 'file',
        api_key_file => Lazysite::Odoo::Secret::key_path( $o{account} // $conn->{key_account} // $ACCOUNT ),
        timeout            => $conn->{timeout},
        max_response_bytes => $conn->{max_kb} * 1024,
        allow_writes       => ( $conn->{allow_writes} ? 1 : 0 ),
        runs_dir           => plans_dir(),
    );
    return Odoo::Ops::Context->new(
        config  => $cfg,
        actor   => $o{actor} // 'lazysite',
        retries => [0],
        ( $TRANSPORT ? ( transport => $TRANSPORT ) : () ),
    );
}

# Whether a binding's operation writes: 1, 0, or undef when OOM or the
# connection cannot be asked. A caller that must never write - a page render -
# treats undef as a write.
sub writes_of {
    my ($b) = @_;
    my $w = eval {
        my ($have) = oom_check();
        my ($conn) = $have ? connection() : ();
        return undef unless $conn;
        my ($class) = operation_class( $conn, $b->{operation} );
        return undef unless $class;
        $class->writes ? 1 : 0;
    };
    return $w;
}

# The binding a page, a form or the schedule names - a handler of type odoo.
sub find_binding {
    my ($id) = @_;
    return ( undef, 'a binding id is required' ) unless defined $id && length $id;
    return ( undef, "no Odoo binding '$id'" ) unless $id =~ /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/;
    require Lazysite::Handlers;
    require Lazysite::Odoo::Binding;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $DOCROOT;
    my $all = Lazysite::Handlers::read_handlers();
    return ( undef, 'the handler store cannot be read - see the event log' ) unless defined $all;
    my $h = Lazysite::Handlers::find_handler( $all, $id );
    return ( undef, "no Odoo binding '$id'" ) unless $h && ( $h->{type} // '' ) eq 'odoo';
    return ( undef, "the Odoo binding '$id' is switched off" ) unless Lazysite::Handlers::enabled($h);
    my ( $b, $why ) = Lazysite::Odoo::Binding::parse($h);
    return ( undef, "the Odoo binding '$id' cannot be used: $why" ) unless $b;
    return ( $b,    '' );
}

# WHO caused it, as OOM's audit and OB8 name them. A visitor is the hash of
# their key; an account is its name; the timer is the binding's.
sub _actor_label {
    my (%c) = @_;
    return $c{actor} if ( $c{actor} // '' ) =~ /\Asession:[0-9a-f]{16}\z/;
    return "account:$c{actor}" if ( $c{mode} // '' ) eq 'authenticated' && length( $c{actor} // '' );
    return "visitor:$c{visitor}" if length( $c{visitor} // '' );
    return 'scheduled'           if ( $c{mode}          // '' ) eq 'scheduled';
    return 'public';
}

# Who may confirm a plan: the account or visitor that made it, and nobody else.
sub _owner {
    my (%c) = @_;
    return $c{actor} if ( $c{actor} // '' ) =~ /\Asession:[0-9a-f]{16}\z/;
    return "account:$c{actor}" if ( $c{mode} // '' ) eq 'authenticated' && length( $c{actor} // '' );
    return "visitor:$c{visitor}" if length( $c{visitor} // '' );
    return ( $c{mode} // '' ) eq 'scheduled' ? 'scheduled' : '';
}

# call( \%binding, \%input, %ctx ) -> { ok, ... }
#
#   mode         what the caller IS (scheduled | authenticated | public)
#   actor        the verified account, or '' for a visitor or the timer
#   groups caps  the account's, for the mode gate
#   visitor_key  the visitor's key (Lazysite::Odoo::Visitor), when there is one
#   ip           the request address
#   strict       refuse an input field the binding does not map
#
# THE ONE FUNCTION THAT SENDS. Everything a call must pass is asked here, in
# this order, so no surface can skip a step by calling something lower: the
# gate (mode, switch, OOM, connection), the key, the operation, the binding
# against the operation, the parameters, the caps - and only then OOM. Every
# outcome is one record.
sub call {
    my ( $b, $input, %ctx ) = @_;

    # B: a sign-in is what a session binding runs on, and ONLY that: a connection
    # binding handed one anyway ignores it, so what runs as the connection user
    # is never labelled, owned or recorded as a person.
    delete $ctx{odoo_session} unless session_binding($b);
    my %c = _with_visitor(%ctx);
    my ( $ok, $conn ) = gate( $b, %c );
    return $conn unless $ok;
    $conn = _as_account( $conn, $ctx{account} );
    my %rec = ( _rec_base( $b, %c ), login => $conn->{login} );

    my ( $class, $refusal ) = _ready( $b, $conn, \%rec );
    return $refusal unless $class;

    require Lazysite::Odoo::Binding;
    my ( $params, $pwhy ) = Lazysite::Odoo::Binding::assemble( $b, $class, $input,
        visitor => $ctx{visitor_key}, strict => $ctx{strict} );
    return ( _refusal( \%rec, 'invalid', $pwhy ) )[1] unless $params;

    if ( $class->writes && $b->{apply} ne 'immediate' && !length _owner(%c) ) {
        return ( _refusal( \%rec, 'no-owner',
                'this binding plans a change for somebody to confirm, and the caller is '
                    . 'nobody who could - a signed-in account or a visitor with a key' ) )[1];
    }

    my ( $capok, $capwhy ) = _take_cap( $b, %c );
    return ( _refusal( \%rec, 'rate', $capwhy ) )[1] unless $capok;

    my $t0  = _now_hires();
    my $res = eval { _run( $b, $class, $conn, $params, \%c ) };
    return _session_end( $b,
        _finish( \%rec, $res, $@, $t0, $class->writes ? ( $b->{apply} eq 'immediate' ? 'apply' : 'plan' ) : 'run' ) );
}

# confirm( $plan_id, %ctx ) -> { ok, ... }
#
# Applies a plan this caller made, through the binding as it stands NOW: the
# binding is looked up again and gated again, so switching a binding off, or
# taking public off it, stops every plan waiting on it.
#
# A PLAN THAT IS NOT YOURS DOES NOT EXIST. Wrong owner, unknown id and a
# malformed id get the same answer, so a confirm cannot be used to find out
# which plans there are.
sub confirm {
    my ( $pid, %ctx ) = @_;

    # B: a person's sign-in applies only to a plan made by a session binding, and
    # only that person's: the owner is the hash of the session.
    my $sess = delete $ctx{odoo_session};
    my $swho = length( $sess // '' ) ? do { require Lazysite::Odoo::Session; Lazysite::Odoo::Session::session_label($sess) } : '';
    my %c = _with_visitor(%ctx);
    my $not_found = { ok => 0, kind => 'not-found', error => 'no such plan, or not yours to confirm' };
    my %base = ( call_id => new_call_id(), actor => $c{actor} // '',
        ( length( $c{visitor} // '' ) ? ( visitor => $c{visitor} ) : () ),
        ip => $c{ip} // '', mode => $c{mode} // '', phase => 'confirm' );

    return ( _refusal( \%base, 'not-found', $not_found->{error} ) )[1]
        unless defined $pid && $pid =~ /\A[0-9a-f]{32}\z/;
    my $dir  = plans_dir() . "/$pid";
    my $meta = _read_json_file("$dir/meta.json");
    my $who  = _owner(%c);
    return ( _refusal( \%base, 'not-found', $not_found->{error} ) )[1]
        unless ref $meta eq 'HASH'
        && ( ( length $who && ( $meta->{owner} // '' ) eq $who )
        || ( length $swho && ( $meta->{owner} // '' ) eq $swho ) );
    return ( _refusal( { %base, binding => $meta->{binding} // '' }, 'expired',
            'this plan is more than an hour old - make it again' ) )[1]
        if time - ( $meta->{created} // 0 ) > $PLAN_TTL;

    my ( $b, $bwhy ) = find_binding( $meta->{binding} );
    return ( _refusal( { %base, binding => $meta->{binding} // '' }, 'binding', $bwhy ) )[1] unless $b;
    # The plan's binding says which owner it is: a session binding's plan is the
    # session's, anything else's is the account's or visitor's - never the other.
    my $expect = session_binding($b) ? $swho : $who;
    return ( _refusal( \%base, 'not-found', $not_found->{error} ) )[1]
        unless length $expect && ( $meta->{owner} // '' ) eq $expect;
    %c = ( %c, odoo_session => $sess, actor => $swho, mode => 'authenticated' ) if session_binding($b);
    my ( $ok, $conn ) = gate( $b, %c, phase => 'confirm' );
    return $conn unless $ok;
    $conn = _as_account( $conn, $ctx{account} );
    my %rec = ( _rec_base( $b, %c, phase => 'confirm' ), login => $conn->{login} );
    return ( _refusal( \%rec, 'binding', 'the binding now names a different operation - make the plan again' ) )[1]
        if $b->{operation} ne ( $meta->{operation} // '' );

    my ( $class, $refusal ) = _ready( $b, $conn, \%rec );
    return $refusal unless $class;
    my ( $capok, $capwhy ) = _take_cap( $b, %c );
    return ( _refusal( \%rec, 'rate', $capwhy ) )[1] unless $capok;

    my $t0  = _now_hires();
    my $res = eval {
        my $plan = Odoo::Ops::Plan->load("$dir/plan.json");
        my $ctx  = context( $conn, actor => _actor_label(%c),
            ( session_binding($b) ? ( session => $c{odoo_session} ) : () ) );
        $ctx->use_run_dir($dir);
        _approve( $dir, $plan, $meta->{owner}, 'confirmed in lazysite by its maker' );
        my $result = Odoo::Ops::Runner->apply( $ctx, $plan, dir => $dir );
        { ok => ( $result->ok ? 1 : 0 ), applied => 1, plan => $pid, result => _result_summary($result) };
    };
    return _session_end( $b, _finish( \%rec, $res, $@, $t0, 'apply' ) );
}

# B: a session that has ended - Odoo forgot it, or no longer accepts it - is said as
# a sign-in the person has to make again, and the endpoint clears the cookie. It
# is NOT said as a fault of the connection, and nothing is retried as anyone else.
sub _session_end {
    my ( $b, $r ) = @_;
    return $r unless session_binding($b) && ref $r eq 'HASH' && !$r->{ok};
    return $r unless ( $r->{kind} // '' ) =~ /\A(?:session-expired|invalid-credential)\z/;
    return { ok => 0, kind => 'signin-required', clear_session => 1,
        error => 'your Odoo sign-in has ended - sign in again' };
}

# OOM's Runner applies only an APPROVED plan (its run registry, 2026-10-13; the
# config can say approval = none, which is for tests and trusted batches, and is
# not set here). In lazysite the approval is the act that already exists: the
# account or visitor that made a plan confirming it, or a binding that declares
# `apply: immediate` - the operator's standing say-so for that one operation.
# So it is recorded, by whom and against the plan's own fingerprint, immediately
# before the apply, and OOM's gate stays on for everything else. An OOM that
# predates the registry has no gate and nothing to record.
sub _approve {
    my ( $dir, $plan, $by, $note ) = @_;
    return unless eval { require Odoo::Ops::Runs; Odoo::Ops::Runs->can('approve_plan') };

    # A plan already applied has a journal, and OOM refuses a second apply of it by
    # name (`applied`); approving it again would refuse first, and say something
    # else.
    return if -e "$dir/journal.jsonl";
    Odoo::Ops::Runs->approve_plan( $dir, $plan, by => $by, note => $note );
    return;
}

# What every call needs before its parameters are looked at: the key, the
# operation, and the binding agreeing with the operation's declaration.
sub _ready {
    my ( $b, $conn, $rec ) = @_;
    require Lazysite::Odoo::Secret;
    require Lazysite::Odoo::Binding;
    no warnings 'once';
    local $Lazysite::Odoo::Secret::DOCROOT = $DOCROOT;
    unless ( session_binding($b) ) { # B: a session call runs on the person's own sign-in, not a key
        my $has = Lazysite::Odoo::Secret::has_key( $conn->{key_account} // $ACCOUNT );
        return ( undef, ( _refusal( $rec, 'no-key',
                    'the connection user\'s key cannot be read by this process - see the event log' ) )[1] )
            unless defined $has;
        return ( undef, ( _refusal( $rec, 'no-key',
                    ( $conn->{key_account} ? 'this grant\'s Odoo account has no API key set'
                        : 'the connection user has no API key set' ) . ' - a sysop sets it on the Odoo page' ) )[1] )
            unless $has;
    }
    my ( $class, $why ) = operation_class( $conn, $b->{operation} );
    return ( undef, ( _refusal( $rec, 'no-operation', $why ) )[1] ) unless $class;
    my $cw = Lazysite::Odoo::Binding::check_against( $b, $class );
    return ( undef, ( _refusal( $rec, 'binding', "the binding does not fit its operation: $cw" ) )[1] )
        if length $cw;
    return ( $class, undef );
}

# Runs the operation. A read returns its report. A write returns its plan's
# preview - saved, sealed, owned - or, for `apply: immediate` (Q1), applies it
# in the same request.
sub _run {
    my ( $b, $class, $conn, $params, $c ) = @_;
    my $ctx = context( $conn, actor => _actor_label(%$c),
        ( session_binding($b) ? ( session => $c->{odoo_session} ) : () ) );
    my $op = $class->new( ctx => $ctx, params => $params );
    unless ( $class->writes ) {
        my $report = $op->run;

        # R wiring: a display read's descriptors, drawn or refused by name, beside
        # the report - which stays as the operation returned it.
        require Lazysite::Odoo::Fields;
        my ( $fields, $refused ) = Lazysite::Odoo::Fields::present($report);
        return { ok => 1, report => $report, ( $fields ? ( fields => $fields, refused => $refused ) : () ) };
    }

    my $plan = $op->run;
    my ( $pid, $dir ) = _new_plan_dir();
    $ctx->use_run_dir($dir);
    $plan->save("$dir/plan.json");
    _write_json_file( "$dir/meta.json",
        { binding => $b->{id}, operation => $b->{operation}, owner => _owner(%$c),
            created => time, fingerprint => $plan->fingerprint } );
    if ( $b->{apply} eq 'immediate' ) {
        _approve( $dir, $plan, "binding:$b->{id}", 'apply: immediate on the binding' );
        my $result = Odoo::Ops::Runner->apply( $ctx, $plan, dir => $dir );
        return { ok => ( $result->ok ? 1 : 0 ), applied => 1, plan => $pid,
            result => _result_summary($result) };
    }
    return { ok => 1, planned => 1, plan => $pid, preview => _preview($plan) };
}

sub _finish {
    my ( $rec, $res, $err, $t0, $phase ) = @_;
    my $ms = int( ( _now_hires() - $t0 ) * 1000 );
    unless ( ref $res eq 'HASH' ) {
        my $f = fault( $err, binding => $rec->{binding}, operation => $rec->{operation},
            mode => $rec->{mode} );
        record_call( %$rec, phase => $phase, outcome => outcome_of( $f->{kind} ),
            kind => $f->{kind}, ms => $ms );
        return $f;
    }
    record_call( %$rec, phase => $phase, outcome => 'answered', ms => $ms,
        ( $res->{ok} ? () : ( kind => 'apply-incomplete' ) ) );
    $res->{error} = 'the plan did not apply completely - see the counts' unless $res->{ok};
    $res->{kind}  = 'apply-incomplete' unless $res->{ok};
    return $res;
}

# What a page is shown of a plan: the buckets and how many changes sit in each.
# NOT the values or the before-images: a plan carries Odoo's records as the
# operation saw them, and that is the operator's to read in the store, not a
# visitor's to receive.
sub _preview {
    my ($plan) = @_;
    my $h = $plan->to_hash;
    return {
        buckets => $h->{buckets} // {},
        total   => scalar @{ $h->{changes} || [] },
        changes => [ map { { seq => $_->{seq}, bucket => $_->{bucket}, action => $_->{action} } }
                @{ $h->{changes} || [] } ],
    };
}

# What apply did, without the journal's host path.
sub _result_summary {
    my ($r) = @_;
    my $h = $r->to_hash;
    return { map { ( $_ => $h->{$_} ) } qw(total counts by_bucket verified stopped_by) };
}

sub _with_visitor {
    my (%ctx) = @_;
    require Lazysite::Odoo::Visitor;
    my $vid = Lazysite::Odoo::Visitor::visitor_id( $ctx{visitor_key} );
    my %c   = %ctx;
    delete $c{visitor_key};    # the key itself goes no further than assemble()
    $c{visitor} = $vid if length $vid;

    # B: a record names the person's session by a hash, never by the id, which is
    # a credential.
    if ( length( $c{odoo_session} // '' ) ) {
        require Lazysite::Odoo::Session;
        $c{actor} = Lazysite::Odoo::Session::session_label( $c{odoo_session} );
    }
    return %c;
}

# --- the caps (Q1): per visitor or account, and per binding ------------------
#
# Counted from a ROLLING record of the last hour (recent.jsonl), under a lock,
# and the slot is TAKEN before the call is made - so two requests at once cannot
# both slip under the cap, and an attempt that reaches Odoo counts whether Odoo
# then accepts it or not. That is the point: a flood is measured in attempts.
#
# The decision and its wording are Lazysite::Egress's within_caps, most specific
# axis first. A record that cannot be opened refuses: a cap honoured only while
# its counter is readable is not a cap.
sub _take_cap {
    my ( $b, %c ) = @_;
    require Fcntl;
    my $who = length( $c{visitor} // '' ) ? "visitor:$c{visitor}" : _actor_label(%c);
    my $dir = store_dir();
    eval { make_path($dir) unless -d $dir; 1 } or return _cap_unknown($b);
    my $f = recent_file();
    my $fh;
    unless ( sysopen $fh, $f, Fcntl::O_RDWR() | Fcntl::O_CREAT(), 0660 ) {
        cannot_read( 'the Odoo rate record', $f );
        return _cap_unknown($b);
    }
    flock $fh, Fcntl::LOCK_EX();
    my $now = time;
    my @keep;
    my ( $n_who, $n_all ) = ( 0, 0 );
    while ( my $l = <$fh> ) {
        my $r = eval { JSON::PP::decode_json($l) } or next;
        next if ( $r->{at} // 0 ) < $now - $CAP_WINDOW;
        push @keep, $l;
        next unless ( $r->{binding} // '' ) eq $b->{id};
        $n_all++;
        $n_who++ if ( $r->{who} // '' ) eq $who;
    }
    my ( $ok, $why ) = Lazysite::Egress::within_caps(
        what => 'Odoo binding',
        axes => [
            { name => ( $who =~ /\Avisitor:/ ? 'per-visitor' : 'per-caller' ),
                limit   => $b->{rate_per_visitor_hour}, used => $n_who,
                setting => "rate_per_visitor_hour on the binding '$b->{id}'" },
            { name => 'per-binding', limit => $b->{rate_per_hour}, used => $n_all,
                setting => "rate_per_hour on the binding '$b->{id}'" },
        ],
    );
    if ($ok) {
        push @keep, JSON::PP->new->canonical->encode( { at => $now, binding => $b->{id}, who => $who } ) . "\n";
    }
    seek $fh, 0, 0;
    truncate $fh, 0;
    print {$fh} @keep;
    close $fh;
    return ( $ok, $why );
}

# --- B: signing in, and out --------------------------------------------------------
#
# sign_in( login, password, ip ) -> { ok, cookie, identity } or { ok => 0, kind, error }
#
# The password is an argument and goes to OOM's session transport, once: never
# into a record, a log, an error. What is checked first is the extension and the
# connection, then the shape of what was typed, then THE SAME RATE LIMITER the
# site's own sign-in uses (Auth::LoginRate): five attempts in five minutes, per
# address and per login, counted before Odoo is asked so a guess is counted
# whether or not it was right.
sub sign_in {
    my (%a) = @_;
    require Lazysite::Odoo::Session;
    require Lazysite::Odoo::Visitor;
    no warnings q{once};
    local $Lazysite::Odoo::Visitor::DOCROOT = $DOCROOT; # the cookie is signed with the extension's secret
    my $login = $a{login};
    my %rec = ( call_id => new_call_id(), actor => Lazysite::Odoo::Session::login_label($login),
        ip => $a{ip} // '', mode => 'public', phase => 'signin', binding => '', operation => '' );
    return ( _refusal( \%rec, 'disabled',
            'the Odoo extension is switched off - a sysop can enable it on the Extensions page' ) )[1]
        unless _extension_enabled();
    my ( $have, $missing ) = oom_check();
    return ( _refusal( \%rec, 'unavailable', $missing ) )[1] unless $have;
    my ( $conn, $cwhy ) = connection();
    return ( _refusal( \%rec, 'config', $cwhy ) )[1] unless $conn;

    my $plain = defined $login && length $login && length $login <= 254 && $login !~ /[\x00-\x1f\x7f]/
        && defined $a{password} && length $a{password} && length $a{password} <= 1024 && $a{password} !~ /\x00/;
    return ( _refusal( \%rec, 'invalid', 'a login and a password are both required' ) )[1] unless $plain;

    require Lazysite::Auth::LoginRate;
    my %lim = ( auth_dir => _lz() . '/auth', docroot => $DOCROOT );
    my $by_ip = Lazysite::Auth::LoginRate::check_login_rate( 'odoo-ip=' . ( $a{ip} // '' ), %lim );
    my $by_login = Lazysite::Auth::LoginRate::check_login_rate( 'odoo-login=' . Lazysite::Odoo::Session::login_label($login), %lim );
    return ( _refusal( \%rec, 'rate', 'too many sign-in attempts - wait a few minutes and try again' ) )[1]
        unless $by_ip && $by_login;

    my $r = Lazysite::Odoo::Session::sign_in( $conn, $login, $a{password} );
    unless ( $r->{ok} ) {
        record_call( %rec, outcome => outcome_of( $r->{kind} ), kind => $r->{kind} );
        return { ok => 0, kind => $r->{kind}, error => $r->{error} };
    }
    my $cookie = Lazysite::Odoo::Session::mint_cookie( $r->{session_id} );
    unless ( defined $cookie ) {
        Lazysite::Odoo::Session::sign_out( $conn, $r->{session_id} );
        return ( _refusal( \%rec, 'unavailable', 'a sign-in cookie cannot be made on this host - see the event log' ) )[1];
    }
    record_call( %rec, actor => Lazysite::Odoo::Session::session_label( $r->{session_id} ), outcome => 'answered' );
    return { ok => 1, cookie => $cookie, identity => $r->{identity},
        identity_cookie => _identity_cookie( $r->{identity_all} ) };
}

# --- C: the identity cookie ----------------------------------------------------
#
# How long an identity cookie lasts: `odoo_identity_ttl` (OB1), seconds, 60 to
# 86400, default 900. Groups and companies change in Odoo and the cookie does not
# know, so it is short, and refreshed from the session when it has ended.
sub identity_ttl {
    my $kv = read_conf() // {};
    my $v  = $kv->{odoo_identity_ttl};
    return ( defined $v && $v =~ /\A[0-9]+\z/ && $v >= 60 && $v <= 86400 ) ? 0 + $v : 900;
}

sub _identity_cookie {
    my ($facts) = @_;
    require Lazysite::Odoo::Identity;
    require Lazysite::Odoo::Visitor;
    no warnings 'once';
    local $Lazysite::Odoo::Visitor::DOCROOT = $DOCROOT;
    return Lazysite::Odoo::Identity::mint_cookie($facts);
}

# refresh_identity( session_id ) -> { ok, identity_cookie } or { ok => 0, kind, error[, clear_session] }
#
# The next call after the identity cookie has ended (OI3): ask Odoo who this
# session is, through the session, and mint the cookie again. Nothing here
# refuses or permits anything; it only freshens what a page may show.
sub refresh_identity {
    my (%a) = @_;
    require Lazysite::Odoo::Session;
    my ($have) = oom_check();
    my ($conn) = $have ? connection() : ();
    return { ok => 0, kind => 'config', error => 'the Odoo connection is not available' } unless $conn;
    my $r = Lazysite::Odoo::Session::identity_of( $conn, $a{session_id} );
    return $r unless $r->{ok};
    my $c = _identity_cookie( $r->{identity} );
    return { ok => 0, kind => 'unavailable', error => 'an identity cookie cannot be made on this host' } unless defined $c;
    return { ok => 1, identity_cookie => $c };
}

# sign_out( session_id, ip ) -> { ok }: ends the session at Odoo. Never an error.
sub sign_out {
    my (%a) = @_;
    require Lazysite::Odoo::Session;
    my ($conn) = connection();
    Lazysite::Odoo::Session::sign_out( $conn, $a{session_id} ) if $conn && length( $a{session_id} // '' );
    record_call( call_id => new_call_id(), actor => Lazysite::Odoo::Session::session_label( $a{session_id} ),
        ip => $a{ip} // '', mode => 'authenticated', phase => 'signout', binding => '', operation => '',
        outcome => 'answered' );
    return { ok => 1 };
}

sub _cap_unknown {
    my ($b) = @_;
    return Lazysite::Egress::within_caps( what => 'Odoo binding',
        axes => [ { name => 'per-binding', limit => $b->{rate_per_hour}, used => undef } ] );
}

# --- the plan store ---------------------------------------------------------------
#
# lazysite/odoo/plans/<id>/ - the plan, its owner, and (once applied) OOM's
# journal and audit beside it. PRIVATE: under the engine tree, which the front
# door never serves. The id is 128 random bits, never a timestamp or a counter,
# so a plan cannot be found by counting. Pruned by age on each new plan.
sub _new_plan_dir {
    require Lazysite::Odoo::Visitor;
    my $pid = Lazysite::Odoo::Visitor::random_hex(16)
        or die Odoo::Error->new( kind => 'config', message => 'no CSPRNG for a plan id' );
    my $dir = plans_dir() . "/$pid";
    make_path( $dir, { mode => 0770 } );
    _prune_plans();
    return ( $pid, $dir );
}

sub _prune_plans {
    my $root = plans_dir();
    opendir my $dh, $root or return;
    my $cut = time - $PLAN_KEEP_DAYS * 86400;
    for my $e ( grep { /\A[0-9a-f]{32}\z/ } readdir $dh ) {
        my $m = _read_json_file("$root/$e/meta.json");
        next unless ref $m eq 'HASH' && ( $m->{created} // $cut ) < $cut;
        require File::Path;
        File::Path::remove_tree("$root/$e");
    }
    closedir $dh;
    return;
}

sub _read_json_file {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON::PP::decode_json( $raw // '' ) };
    return ref $d eq 'HASH' ? $d : undef;
}

sub _write_json_file {
    my ( $p, $d ) = @_;
    open my $fh, '>:raw', "$p.tmp.$$" or die Odoo::Error->new( kind => 'config', message => "cannot write $p: $!" );
    print {$fh} JSON::PP->new->canonical->encode($d);
    close $fh;
    rename "$p.tmp.$$", $p or die Odoo::Error->new( kind => 'config', message => "cannot write $p: $!" );
    return;
}

sub _now_hires {
    require Time::HiRes;
    return Time::HiRes::time();
}

# --- the operator's actions (control API, manage_connectors until E) -----------
#
# The connection user's key is SET and CLEARED here and never READ back: the
# status answers has_secret - 1, 0, or null for "cannot tell" - and nothing
# else about it. Config read and save stay open while the extension is off, as
# for every contract extension (SM409): an operator configures before enabling.

sub action_odoo_status {
    require Lazysite::Odoo::Secret;
    no warnings 'once';
    local $Lazysite::Odoo::Secret::DOCROOT = $DOCROOT;
    my %out = ( ok => 1, enabled => _extension_enabled() );
    my ( $have, $why ) = oom_check();
    $out{oom} = $have ? 'present' : $why;
    my ( $conn, $cwhy ) = connection();
    $out{connection}
        = $conn
        ? { map { ( $_ => $conn->{$_} ) } qw(url db login timeout max_kb allow_writes packs) }
        : { problem => $cwhy };
    $out{has_secret} = Lazysite::Odoo::Secret::has_key($ACCOUNT);
    $out{warning} = 'the key file exists and cannot be read by this process - see the event log'
        unless defined $out{has_secret};
    my $grants = read_grants();
    $out{grants} = defined $grants
        ? [ map { { grant => $_, login => $grants->{$_}{login},
                has_secret => Lazysite::Odoo::Secret::has_key( $grants->{$_}{id} ) } }
            sort keys %$grants ]
        : undef;
    if ( $have && $conn ) {
        my $reg = eval { registry($conn) };
        $out{operations} = [
            map {
                my $c = $reg->class_for($_);
                { name => $_, summary => $c->summary, writes => ( $c->writes ? 1 : 0 ),
                    params => $c->params }
            } $reg->names
        ] if $reg;
    }
    return \%out;
}

# action_odoo_secret_set( $secret, grant => $account, login => $odoo_login )
#
# Without `grant`, the connection user's key. With it (Q2, ruled 2026-10-12:
# "MCP will use the default or specified account"), the Odoo account an MCP
# grant acts as: the lazysite account the grant belongs to, the Odoo login, and
# its key - stored as the connection user's is, in a file of its own.
sub action_odoo_secret_set {
    my ( $secret, %o ) = @_;
    require Lazysite::Odoo::Secret;
    no warnings 'once';
    local $Lazysite::Odoo::Secret::DOCROOT = $DOCROOT;
    my $grant = $o{grant} // '';
    return _set_grant_key( $grant, $o{login}, $secret ) if length $grant;
    my ( $ok, $why ) = Lazysite::Odoo::Secret::set_key( $ACCOUNT, $secret );
    return { ok => 0, kind => 'invalid', field => 'secret', error => $why } unless $ok;
    return { ok => 1, has_secret => 1 };
}

sub action_odoo_secret_clear {
    my (%o) = @_;
    require Lazysite::Odoo::Secret;
    no warnings 'once';
    local $Lazysite::Odoo::Secret::DOCROOT = $DOCROOT;
    my $grant = $o{grant} // '';
    return _clear_grant_key($grant) if length $grant;
    my ( $ok, $why ) = Lazysite::Odoo::Secret::clear_key($ACCOUNT);
    return { ok => 0, error      => $why } unless $ok;
    return { ok => 1, has_secret => 0 };
}

# --- Q2: an Odoo account per MCP grant ------------------------------------------
#
# lazysite/odoo/grants.json maps a lazysite account to { id, login }: the Odoo
# login its MCP calls run as, and the id of its key file in the key store. The
# id is derived from the account name, never the name itself, so an account
# name with characters a file name should not carry never reaches the disk.
# The map holds no secret; the keys stay in their own 0600 files.

sub grants_file { return store_dir() . '/grants.json' }

sub _grant_id {
    my ($grant) = @_;
    require Digest::SHA;
    return 'grant-' . substr( Digest::SHA::sha256_hex("grant|$grant"), 0, 16 );
}

# The map, {} when there is none, undef when it exists and cannot be read.
sub read_grants {
    my $f = grants_file();
    open my $fh, '<:raw', $f or do {
        return {} if $!{ENOENT};
        cannot_read( 'the Odoo grant accounts', $f );
        return undef;
    };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON::PP::decode_json( $raw // '' ) };
    return ref $d eq 'HASH' ? $d : undef;
}

sub _write_grants {
    my ($all) = @_;
    my $dir = store_dir();
    eval { make_path($dir) unless -d $dir; 1 } or return ( 0, 'cannot make the Odoo store' );
    my $f = grants_file();
    open my $fh, '>:raw', "$f.tmp.$$" or return ( 0, "cannot write odoo/grants.json: $!" );
    print {$fh} JSON::PP->new->canonical->pretty->encode($all);
    close $fh or return ( 0, "cannot write odoo/grants.json: $!" );
    secure_write_perms( "$f.tmp.$$", 0660 );
    rename "$f.tmp.$$", $f or return ( 0, "cannot write odoo/grants.json: $!" );
    return ( 1, '' );
}

sub _set_grant_key {
    my ( $grant, $login, $secret ) = @_;
    return { ok => 0, kind => 'invalid', field => 'grant', error => 'grant must be a lazysite account name' }
        unless $grant =~ /\A[A-Za-z0-9][A-Za-z0-9_.@-]{0,127}\z/;
    return { ok => 0, kind => 'invalid', field => 'login',
        error => 'login is required with grant - the Odoo login this grant acts as' }
        unless defined $login && length $login;
    return { ok => 0, kind => 'invalid', field => 'login', error => 'login must be one line of at most 128 characters' }
        if length $login > 128 || $login =~ /[\r\n]/;
    my $all = read_grants();
    return { ok => 0, error => 'the grant accounts exist and cannot be read - nothing was written' }
        unless defined $all;
    my $id = _grant_id($grant);
    my ( $ok, $why ) = Lazysite::Odoo::Secret::set_key( $id, $secret );
    return { ok => 0, kind => 'invalid', field => 'secret', error => $why } unless $ok;
    $all->{$grant} = { id => $id, login => $login };
    my ( $wok, $wwhy ) = _write_grants($all);
    return { ok => 0, error => $wwhy } unless $wok;
    log_event( 'INFO', 'odoo', 'odoo grant account set', grant => $grant, login => $login );
    return { ok => 1, grant => $grant, login => $login, has_secret => 1 };
}

sub _clear_grant_key {
    my ($grant) = @_;
    my $all = read_grants();
    return { ok => 0, error => 'the grant accounts exist and cannot be read - nothing was removed' }
        unless defined $all;
    my ( $ok, $why ) = Lazysite::Odoo::Secret::clear_key( _grant_id($grant) );
    return { ok => 0, error => $why } unless $ok;
    if ( exists $all->{$grant} ) {
        delete $all->{$grant};
        my ( $wok, $wwhy ) = _write_grants($all);
        return { ok => 0, error => $wwhy } unless $wok;
    }
    log_event( 'INFO', 'odoo', 'odoo grant account cleared', grant => $grant );
    return { ok => 1, grant => $grant, has_secret => 0 };
}

# The account an MCP call runs as: the grant's own, when one is configured
# with a key; the connection user otherwise (undef). ( $account, '' ), or
# ( undef, why ) when the grant map cannot be read - which refuses, because
# running as the connection user instead would widen what the agent may do
# exactly when its own narrower account could not be checked.
sub account_for_grant {
    my ($grant) = @_;
    my $all = read_grants();
    return ( undef, 'the Odoo grant accounts cannot be read - see the event log' ) unless defined $all;
    my $g = $all->{ $grant // '' } or return ( undef, '' );
    return ( { id => $g->{id}, login => $g->{login} }, '' );
}

# The connection, as a given account sees it: its login and its key.
sub _as_account {
    my ( $conn, $account ) = @_;
    return $conn unless ref $account eq 'HASH' && length( $account->{id} // '' );
    return { %$conn, login => $account->{login}, key_account => $account->{id} };
}

# --- the bound operations, for a signed-in caller or an MCP agent ---------------
#
# R5 (ruled 2026-10-12): "All operations should also be mcp tools." An operation
# reaches a caller through a BINDING, as it reaches a page: the binding's modes,
# callers and caps decide, and a request sets only what the binding maps. These
# are the authenticated door - never a visitor's, so a binding that works on a
# visitor's key is not offered and not run here.
#
#   who: user, groups, caps, ip, channel ('api' | 'mcp')
#
# On the MCP channel the call runs as the grant's own Odoo account when one is
# configured (Q2), else as the connection user.

sub _who_ctx {
    my (%w) = @_;
    my %c = ( mode => 'authenticated', actor => $w{user} // '', groups => $w{groups} || [],
        caps => $w{caps} || {}, ip => $w{ip} // '' );
    # E-Q1: where the caller stands, for a binding that belongs to a domain.
    $c{reach} = $w{reach} if ref $w{reach} eq 'HASH';
    $c{host}  = $w{host}  if defined $w{host};
    if ( ( $w{channel} // '' ) eq 'mcp' ) {
        my ( $acct, $why ) = account_for_grant( $w{user} );
        return ( undef, $why ) if length $why;
        $c{account} = $acct    if $acct;
    }
    return ( \%c, '' );
}

sub action_odoo_bindings {
    my (%w) = @_;
    require Lazysite::Handlers;
    require Lazysite::Odoo::Binding;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $DOCROOT;
    my $all = Lazysite::Handlers::read_handlers();
    return { ok => 0, error => 'the handler store cannot be read - see the event log' } unless defined $all;
    my ($conn) = ( oom_check() )[0] ? connection() : ();
    my @out;
    for my $h ( grep { ( $_->{type} // '' ) eq 'odoo' && Lazysite::Handlers::enabled($_) } @$all ) {
        my ($b) = Lazysite::Odoo::Binding::parse($h);
        next unless $b && !length $b->{visitor_param};
        my ($may) = may_call( $b, mode => 'authenticated', groups => $w{groups}, caps => $w{caps} );
        next unless $may;
        next if session_binding($b);  # B: never offered to a door that carries no sign-in
        next if length domain_refusal( $b, mode => 'authenticated',
            ( ref $w{reach} eq 'HASH' ? ( reach => $w{reach} ) : () ),
            ( defined $w{host}        ? ( host  => $w{host} )  : () ) );
        my %row = ( id => $b->{id}, name => $h->{name} // $b->{id}, operation => $b->{operation},
            apply => $b->{apply} );
        if ($conn) {
            my ($class) = eval { operation_class( $conn, $b->{operation} ) };
            if ($class) {
                require Lazysite::Odoo::Fields;
                $row{summary} = $class->summary;
                $row{writes}  = $class->writes ? 1 : 0;
                $row{params}  = Lazysite::Odoo::Fields::form_fields( $b, $class );
            }
        }
        push @out, \%row;
    }
    return { ok => 1, bindings => \@out };
}

sub action_odoo_run {
    my ( $id, $params, %w ) = @_;
    my ( $b, $why ) = find_binding($id);
    return { ok => 0, kind => 'not-found', error => $why } unless $b;
    return { ok => 0, kind => 'mode',
        error => "the Odoo binding '$id' works on a visitor's key, and this door is never a visitor's" }
        if length $b->{visitor_param};
    return { ok => 0, kind => 'invalid', error => 'params must be an object' }
        if defined $params && ref $params ne 'HASH';
    my ( $c, $cwhy ) = _who_ctx(%w);
    return { ok => 0, kind => 'cannot-tell', error => $cwhy } unless $c;
    return call( $b, $params // {}, %$c, strict => 1 );
}

sub action_odoo_confirm {
    my ( $plan, %w )    = @_;
    my ( $c,    $cwhy ) = _who_ctx(%w);
    return { ok => 0, kind => 'cannot-tell', error => $cwhy } unless $c;
    return confirm( $plan, %$c );
}

sub action_odoo_calls {
    my (%o) = @_;
    my $rows = read_calls( binding => $o{binding} );
    return { ok => 0, error => 'the Odoo call record cannot be read - see the event log' }
        unless defined $rows;
    my $limit = ( $o{limit} // '' ) =~ /\A[0-9]+\z/ ? $o{limit} : 200;
    splice @$rows, $limit if @$rows > $limit;
    return { ok => 1, calls => $rows, retention_days => $CALLS_KEEP_DAYS };
}

1;
