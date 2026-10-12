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
#     `libodoo-oom-perl (>= 0.02)` and refuses BY NAME when the Ops layer is
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
our $OOM_MIN     = '0.02';

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
    return 1;
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

# gate( $binding, %ctx ) -> ( 1, \%connection ) or ( 0, \%refusal )
#
# THE ORDER IS THE POINT, and it is the connector's: WHO first (the mode gate),
# then whether the extension is on, then whether OOM is here, then the
# connection. Each refusal is a row in the call record, because a refusal an
# operator cannot see is one they cannot manage (SM771).
sub gate {
    my ( $binding, %ctx ) = @_;
    my %rec = _rec_base( $binding, %ctx );

    my ( $may, $why ) = may_call( $binding, %ctx );
    return _refusal( \%rec, 'mode', $why ) unless $may;

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

1;
