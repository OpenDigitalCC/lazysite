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
use Digest::SHA      ();
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
    my (%o) = @_;
    my $need = "the Odoo extension needs $OOM_PACKAGE (>= $OOM_MIN)";

    # SM1180: `light` is the daemon path's question - is OOM installed, and new enough
    # - answered from Odoo::Ops::Version, which loads nothing else, so a call that
    # oomd answers never loads the registry, the runner or the plan. An OOM with no
    # such module has no daemon either, and gets the full check below.
    if ( $o{light} && eval { require Odoo::Ops::Version; 1 } ) {
        require version;
        my $have = $Odoo::Ops::Version::VERSION;
        return ( 1, '' ) if defined $have && eval { version->parse($have) >= version->parse($OOM_MIN) };
        return ( 0, "$need - this host has " . ( $have // 'unversioned' ) . ', which does not carry what the extension calls' );
    }
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

# ( $resolved_path, '' ) or ( undef, why ): one odoo_pack_dirs entry.
# The packaged packs (odoo-oom-packs): the one directory outside the site that
# odoo_pack_dirs may name. t/lint/262 allows this declaration line, and only it,
# to name the deb's data directory (release manager, 2026-10-18): production code
# must say where the packs are, and no test may use it.
our $PACKAGED_PACKS = '/usr/share/odoo-oom/packs';
sub _pack_dir {
    my ($d) = @_;
    require Cwd;
    return ( undef, 'is not a full path' ) if $d =~ /[\x00-\x1f\x7f]/ || $d !~ m{\A/};
    my $real = Cwd::abs_path($d);
    return ( undef, 'is not a directory' ) unless defined $real && -d $real;
    my @ok = grep { defined } map { Cwd::abs_path($_) } grep { length } $DOCROOT, _lz();
    my $packaged = Cwd::abs_path($PACKAGED_PACKS);
    return ( $real, '' ) if defined $packaged && $real eq $packaged;
    for my $root (@ok) {
        return ( $real, '' ) if $real eq $root || index( $real, "$root/" ) == 0;
    }
    return ( undef, "is not under this site's tree or $PACKAGED_PACKS - a pack is code, "
            . 'and is not loaded from anywhere else' );
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

    # SM1149 (OOM Lab L-1): A PRIVATE CA FOR THIS CONNECTION, AND NO OTHER. An
    # internal Odoo reached over https:// to its private name is signed by the
    # operator's own authority. The lab got past that with SSL_CERT_FILE for the
    # whole server, which replaces the system store for every connection the
    # process makes. This is the connection's own setting: OOM's `ssl_ca_file`,
    # which becomes HTTP::Tiny's SSL_ca_file for the Odoo client alone. Checked
    # here, once, like every other value: an absolute path to a readable file, so a
    # CGI's working directory cannot change what it names.
    my $ca = $kv->{odoo_ca_file};
    if ( defined $ca && length $ca ) {
        return ( undef, 'odoo_ca_file must be one line, a full path to a PEM file' )
            if $ca =~ /[\x00-\x1f\x7f]/ || $ca !~ m{\A/};
        return ( undef, "odoo_ca_file '$ca' is not a file" ) unless -f $ca;
        return ( undef, "odoo_ca_file '$ca' cannot be read by this process" ) unless -r _;
        $c{ca_file} = $ca;
    }

    # WRITES ARE OFF UNLESS SAID. OOM refuses to apply a plan without
    # allow_writes = 1, and this is the operator's one switch for it.
    $c{allow_writes} = ( ( $kv->{odoo_allow_writes} // '' ) =~ /\A\s*(?:1|true|yes|on)\s*\z/i ) ? 1 : 0;

    # "Remember this device" at the sign-in's code step (SM1157) is the SITE's
    # decision and OFF unless said: on a shared tablet the person who is signed in
    # is responsible for what that device can reach (L3), and a site that has
    # not chosen to offer it does not.
    $c{remember_device} = ( ( $kv->{odoo_remember_device} // '' ) =~ /\A\s*(?:1|true|yes|on)\s*\z/i ) ? 1 : 0;

    # The operation packs beyond OOM's own, by Perl namespace. Not Odoo
    # knowledge: a namespace names where the knowledge is, which is the point.
    my @packs = grep { length } split /\s*,\s*/, ( $kv->{odoo_packs} // '' );
    for (@packs) {
        return ( undef, "odoo_packs: '$_' is not a Perl namespace" )
            unless /\A[A-Z][A-Za-z0-9_]*(?:::[A-Za-z0-9_]+)*\z/;
    }
    $c{packs} = \@packs;

    # SM1164 D0: DIRECTORIES OF PACKS, WHICH ARE CODE. OOM 0.30+ loads a pack's
    # Perl from a directory named in `pack_dirs`; a path an operator can type is
    # not a path the site can be trusted to have written, so each directory is
    # resolved (symlinks and `..` included) and must be the site's own tree or the
    # packaged the packaged packs directory. Refused here, by name, when the config
    # loads - never discovered at a visitor's request.
    my @dirs;
    for my $d ( grep { length } split /\s*:\s*/, ( $kv->{odoo_pack_dirs} // '' ) ) {
        my ( $real, $dwhy ) = _pack_dir($d);
        return ( undef, "odoo_pack_dirs: '$d' $dwhy" ) if length $dwhy;
        push @dirs, $real;
    }
    $c{pack_dirs} = \@dirs;

    # SM1164 D1/D3: the resident OOM. `odoo_daemon` is off (the default), on
    # (used when it is running, the in-process path when it is not) or required
    # (a down daemon refuses the call); `odoo_daemon_workers` is oomd's pool,
    # default 4, which the operator sets to match Odoo's own workers.
    require Lazysite::Odoo::Daemon;
    my ( $dmode, $dwhy ) = Lazysite::Odoo::Daemon::mode_from( $kv->{odoo_daemon} );
    return ( undef, $dwhy ) unless defined $dmode;
    $c{daemon} = $dmode;
    my ( $dw, $dwwhy ) = Lazysite::Odoo::Daemon::workers_from( $kv->{odoo_daemon_workers} );
    return ( undef, $dwwhy ) unless defined $dw;
    $c{daemon_workers} = $dw;
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
    'idem-mismatch' => [ 'refused', 'that Idempotency-Key was used for a different request - give this request a key of its own' ],
    'idem-withdrawn' => [ 'refused', 'the plan made with that Idempotency-Key was withdrawn - give the request a new key' ],
    'run-gone' => [ 'not-found', 'this plan is no longer held by the Odoo daemon - make the plan again' ], # SM1261
);

# SM1186: the text of an OOM `usage` error, as far as a page may have it, or undef
# (the caller then says the generic sentence). OOM's usage messages are written
# for the caller, but a few carry what a page must never receive: "cannot read
# $path: $!" and "cannot load mapping $path: $@ at FILE line N" (a host path),
# "no run '$id' in $dir" (the runs directory), "dbi reader: key column ... (columns:
# ...)" (another database's columns), and a message quoting a token or a
# credential the caller was sent. So: control characters become spaces and runs of
# space one space; a message with a path, a perl "at X line N", a long token (a key,
# a session id, a hash), a traceback or the word of a secret is WITHHELD whole, not
# redacted, because a redacted path still says a file exists; and what is left is
# cut at $USAGE_TEXT_MAX characters. A caller's own input echoed in the message
# (a bad date) is in the JSON answer as a string, as every error is; a page puts
# it in text, never markup.
our $USAGE_TEXT_MAX = 300;

# SM1218: what an apply says when a change was sent and no answer came (see _add_unknown).
our $UNKNOWN_ANSWER = 'the plan may not have applied completely: a change was sent to Odoo and no answer came, so it is not known whether Odoo made it - read it back in Odoo before repeating it';

sub _usage_text {
    my ($t) = @_;
    return undef unless defined $t && !ref $t;
    $t =~ s/[\x00-\x1f\x7f]+/ /g;
    $t =~ s/\s+/ /g;
    $t =~ s/\A | \z//g;
    return undef unless length $t;
    # A path, perl's own location, a long key-like token, a traceback or a secret's
    # name: any of them and the message is withheld.
    for my $re ( qr{(?:\A|[\s'"(=:,\[])~?/[^\s'"]*[\w.-]}, qr{[A-Za-z]:\\},
        qr{\b[\w.-]+(?:/[\w.-]+)+\.\w{1,6}\b}, qr/\bat \S+ line \d+/, qr{[A-Za-z0-9_+/=-]{25,}},
        qr/traceback | api[_ -]?key | passw | secret | token | session[_ -]?id | cookie | authorization | bearer/ix )
    {
        return undef if $t =~ $re;
    }
    $t = substr( $t, 0, $USAGE_TEXT_MAX - 3 ) . '...' if length $t > $USAGE_TEXT_MAX;
    return $t;
}

# fault( $err, %ctx ) -> { ok => 0, kind, error }
#
# THE TEXT IS LOGGED, NEVER RETURNED. Odoo's own message can carry a traceback,
# a module path, a SQL fragment or the name of a record the caller may not see;
# OOM's carries the URL. What goes back is one of the sentences above.
sub fault {
    my ( $err, %ctx ) = @_;
    my ( $kind, $said, %why, %extra );
    if ( ref $err && eval { $err->isa('Odoo::Error') } ) {
        my $k = $err->kind // '';
        %why = ( oom_kind => $k, code => ( $err->code // '' ),
            category => ( $err->fault_category // '' ) );
        if ( $k eq 'fault' ) {
            ( $kind, $said ) = @{ $FAULT_KIND{ $err->fault_category // 'other' } // $FAULT_KIND{other} };
        }
        elsif ( $k eq 'transport' && ( $err->code // '' ) eq 'daemon-down' ) {
            # SM1164 D3: odoo_daemon: required and the daemon is not there. OOM's own
            # code, said by name, so a page can tell it from Odoo being unreachable.
            ( $kind, $said ) = ( 'daemon-down', 'the Odoo daemon is not running, and this site requires it (odoo_daemon: required)' );
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
            # SM1186 (OOM Lab L-18): only OOM's `usage` kind is the operation's own
            # statement about the caller's input ("date 'x' is not a date"), written
            # for the caller. Nothing else comes this way: an unknown kind keeps the
            # sentence.
            if ( $k eq 'usage' ) {
                my $m = _usage_text( $err->message );
                if ( defined $m ) {
                    $said = $m;
                    my $x = _usage_text( $err->fix );
                    $extra{fix} = $x if defined $x;
                }
            }
        }
        $why{detail} = $err->message // '';
    }
    else {
        ( $kind, $said ) = ( 'internal', 'the Odoo call failed inside the engine - see the event log' );
        ( $why{detail} = "$err" ) =~ s/\s+\z//;
    }
    log_event( 'WARN', 'odoo', 'odoo call failed', kind => $kind, %why,
        map { ( $_ => $ctx{$_} ) } grep { defined $ctx{$_} } qw(binding operation mode) );
    return { ok => 0, kind => $kind, error => $said, %extra };
}

# What a fault kind means for the call record's outcome (OB8's four states).
sub outcome_of {
    my ($kind) = @_;
    return 'answered' unless defined $kind && length $kind;
    return 'unanswered' if $kind eq 'transport-failure' || $kind eq 'daemon-down';
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
# SM1223: `idem` is the key OOM holds for the call (derived, never the caller's own),
# `repeat` that the answer was the first one again.
our @CALL_FIELDS = qw(at call_id actor visitor ip login binding operation mode phase
    outcome kind ms via decl idem repeat);
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

    # SM1180: with the daemon on, the call is oomd's and OOM is not loaded here
    # unless a fallback or a stale declaration needs it (binding_class, _run).
    my ( $have, $missing ) = oom_check( light => _daemon_wanted() );
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

        # SM1161: a scheduled run on its binding's own key is `scheduled:<binding>`
        # in the record and the audit, not the job account that fired it.
        actor => ( length( $ctx{scheduled_as} // '' ) ? "scheduled:$ctx{scheduled_as}" : $ctx{actor} // '' ),
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

# SM1164 D3: WHICH PATH THE LAST ENGINE CALL TOOK - `daemon` (oomd answered) or
# `in-process` - for the call record's `via` and SM1144's `call` phase, whose
# Server-Timing description says which. Undef until a call reaches the engine.
our $LAST_VIA;
sub last_via  { return $LAST_VIA }
sub reset_via { $LAST_VIA = undef; return }

# The OOM client for this site's daemon, ( $client ) when the call should be
# tried there, () when it should run in-process (odoo_daemon off, or on without
# a client). With `required` and no client the call is refused with OOM's
# daemon-down code.
sub _daemon_for {
    my ($conn) = @_;
    my $mode = $conn->{daemon} // 'off';
    return if $mode eq 'off';
    require Lazysite::Odoo::Daemon;
    my ( $cl, $why ) = Lazysite::Odoo::Daemon::client( $DOCROOT, $conn );
    return $cl if $cl;
    return     if $mode eq 'on';
# The kind is OOM's own (Odoo::Error), not a refusal kind lazysite emits to a caller (t/lint/139):
    my $oom_kind = 'transport';
    die Odoo::Error->new( kind => $oom_kind, code => 'daemon-down', message => $why );
}

sub _daemon_down {
    my ($e) = @_;
    return ref $e && eval { $e->isa('Odoo::Error') } && ( $e->code // '' ) eq 'daemon-down' ? 1 : 0;
}

# Who the request is, as the daemon is told: the connection user's label (or the
# grant's or schedule's own, named like its key account), or the person's session
# id, which goes with the request and is stored nowhere new.
sub _daemon_credential {
    my ( $b, $conn, $c ) = @_;
    return { session => $c->{odoo_session} } if session_binding($b);
    return { label   => ( $conn->{key_account} // 'conn' ) };
}

sub plans_dir   { return store_dir() . '/plans' }
sub recent_file { return store_dir() . '/recent.jsonl' }

# The operations OOM offers: its own packs plus the site's (odoo_packs). The
# registry is OOM's, and so is every name in it.
#
# SM1179 (inbox 2026-10-18-odoo-endpoint-builds-the-oom-registry-twice-per-request.md):
# "operation_class is called twice per request and each call ... builds a new
# Odoo::Ops::Registry (loading every operation module of every namespace) ...
# 210-240 ms per build". Built once per process for one site configuration and
# held in %REGISTRY, keyed on everything that changes what it contains: the
# docroot, the namespaces (odoo_packs), the pack directories, the cache directory
# and OOM's version. A config save changes the key, so it reads afresh; a second
# site in the same process (the pool, the dev server, lazysited) has its own key.
# The value is OOM's operation classes and nothing about a person (t/lint/269).
# OOM's Runner->apply still builds its own registry from the environment
# (with_site_ops, SM1170); that is OOM's, and is left.
my %REGISTRY;

sub registry {
    my ($conn) = @_;
    my $key = join "\0", $DOCROOT, store_dir() . '/cache', ( Odoo::Ops->VERSION // '' ),
        join( ',', @{ $conn->{packs} || [] } ), join( ':', @{ $conn->{pack_dirs} || [] } );
    return $REGISTRY{$key} //= _build_registry($conn);
}

sub _build_registry {
    my ($conn) = @_;
    return with_site_ops( $conn, sub {
            # SM1164 D0: the site's pack directories, and a cache of its own beside the
            # store (the default is under HOME, which a CGI user may not have). Without
            # odoo_pack_dirs OOM reads its environment and the packaged packs, as before.
            my @dirs = @{ $conn->{pack_dirs} || [] };
            return Odoo::Ops::Registry->new( @dirs ? ( pack_dirs => \@dirs, cache_dir => store_dir() . '/cache' ) : () );
    } );
}

# SM1170 (inbox L-12, 2026-10-17): runs $code with everything OOM reads from the
# environment for THIS site's operations set, and puts it back after. OOM's
# Runner->apply finds a `custom` change's class with Registry->new and no
# arguments, which reads the environment alone; so registry(), which planned the
# operation, and every apply must run inside this, or a site pack's custom
# change ends apply-incomplete "no operation '<op>'". `local`, never process-wide:
# one request must not hand its site's packs to another (OOM could take the
# registry as an argument to apply instead; this does not need it).
sub with_site_ops {
    my ( $conn, $code ) = @_;
    local $ENV{ODOO_OPS_NAMESPACES} = join ',', @{ $conn->{packs} || [] };
    my @dirs = @{ $conn->{pack_dirs} || [] };
    local $ENV{ODOO_OOM_PACK_DIRS} = join ':', @dirs if @dirs;
    local $ENV{XDG_CACHE_HOME} = store_dir() . '/cache' if @dirs; # OOM's cache, as registry() gives it
    return $code->();
}

# SM1180: whether odoo_daemon is on or required, from the config file alone.
sub _daemon_wanted {
    my $kv = read_conf() or return 0;
    require Lazysite::Odoo::Daemon;
    my ($mode) = Lazysite::Odoo::Daemon::mode_from( $kv->{odoo_daemon} );
    return ( $mode // 'off' ) ne 'off' ? 1 : 0;
}

# SM1180: THE OPERATION A BINDING NAMES, AS THE REQUEST PATH NEEDS IT.
#
# ( $class, $why, $how ). With odoo_daemon off it is operation_class, as it was,
# and $how is undef. With the daemon on it is the declaration stored when the
# binding was saved (Lazysite::Odoo::Decl) when its stamp - the OOM version and the
# site's packs - still fits, and then OOM is not loaded at all ($how 'stored').
# Otherwise (OOM upgraded, packs changed, a binding saved before this release) the
# registry is read in-process ONCE, the declaration is stored again and the call
# goes on ($how 'rechecked'); the call record's `decl` says which.
sub binding_class {
    my ( $b, $conn ) = @_;
    return operation_class( $conn, $b->{operation} ) if ( $conn->{daemon} // 'off' ) eq 'off';
    require Lazysite::Odoo::Decl;
    my ( $d, $why ) = Lazysite::Odoo::Decl::fetch( store_dir(), $b, $conn );
    return ( $d, '', 'stored' ) if $d;
    my ( $have, $missing ) = oom_check();
    return ( undef, $missing ) unless $have;
    my ( $class, $cwhy ) = operation_class( $conn, $b->{operation} );
    return ( undef, $cwhy ) unless $class;
    log_event( 'INFO', 'odoo', 'a binding\'s operation declaration is read again',
        binding => $b->{id}, because => $why );
    my $new = Lazysite::Odoo::Decl::capture( $class, $b->{operation}, $conn );
    Lazysite::Odoo::Decl::store( store_dir(), $b->{id}, $new ) if $new;
    return ( $class, '', 'rechecked' );
}

# The declaration stored for a binding, at save: what binding_class will find.
# Called where a binding is validated against the registry (Handlers).
sub store_decl {
    my ( $id, $class, $op, $conn ) = @_;
    require Lazysite::Odoo::Decl;
    my $d = Lazysite::Odoo::Decl::capture( $class, $op, $conn ) or return 0;
    return Lazysite::Odoo::Decl::store( store_dir(), $id, $d );
}

sub forget_decl {
    my ($id) = @_;
    require Lazysite::Odoo::Decl;
    return Lazysite::Odoo::Decl::forget( store_dir(), $id );
}

# OOM loaded in full, for the in-process path a daemon that is down falls back to.
sub _load_oom {
    my ( $have, $why ) = oom_check();
    die "$why\n" unless $have;
    return;
}

# The class that runs, from what binding_class gave: itself, or for a stored
# declaration the registry's class, loading OOM now.
sub _real_class {
    my ($class) = @_;
    require Lazysite::Odoo::Decl;
    return Lazysite::Odoo::Decl::is_decl($class) ? $class->real : $class;
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
            ( $conn->{ca_file} ? ( ssl_ca_file => $conn->{ca_file} ) : () ),    # SM1149
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
        ( $conn->{ca_file} ? ( ssl_ca_file => $conn->{ca_file} ) : () ),    # SM1149
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
        my ($have) = oom_check( light => _daemon_wanted() );
        my ($conn) = $have ? connection() : ();
        return undef unless $conn;
        my ($class) = binding_class( $b, $conn ); # SM1180: the stored declaration, with the daemon on
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

    # SM1161: a scheduled run on a binding's own Odoo login is OOM's actor too.
    return "scheduled:$c{scheduled_as}" if length( $c{scheduled_as} // '' );
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

# --- SM1223: the caller's idempotency key ------------------------------------------
#
# RULING (2026-10-20, "OOM Lab questions"): "build the pass-through (page-chosen key
# -> OOM idem, scoped to binding and person, format-checked, recorded)". An offline
# queue that flushes on reconnect sends one key per queued item; a repeat of the
# key answers as OOM answers a repeat (the first result, nothing sent to Odoo
# again) instead of writing twice.
#
# THE CALLER'S KEY NEVER REACHES OOM AS IT IS. It is checked (8 to 128 characters,
# letters, digits and . _ : -), then hashed with the binding and WHO sent it into the
# key OOM holds, so the same key from another person or to another binding is
# another key. For a session binding the person is the Odoo user, which OOM adds to
# its own scope (the uid), so a person who signs in again is still the same person.
our $IDEM_RE = qr/\A[A-Za-z0-9][A-Za-z0-9._:-]{7,127}\z/;

sub idem_problem {
    my ($k) = @_;
    return 'the Idempotency-Key must be text' if !defined $k || ref $k;
    return ''                                 if $k =~ $IDEM_RE;
    return 'the Idempotency-Key must be 8 to 128 characters - letters, digits and . _ : - (a UUID is one) - and start '
        . 'with a letter or digit';
}

# The key OOM is given, or ( undef, why ) when nobody can own it. The owner is the
# account or the visitor key's hash; a request with neither has nobody a key could
# be scoped to, and a key shared by every such caller would let one replay another.
sub idem_derive {
    my ( $b, $caller, %c ) = @_;
    my $who = session_binding($b) ? 'session' : _owner(%c);
    return ( undef, 'an Idempotency-Key is scoped to who sent it, and this request is from nobody - sign in, or '
            . 'fetch a visitor token first' )
        unless length $who;
    return ( 'lz1-' . Digest::SHA::sha256_hex( join "\x1f", 'lazysite-odoo-idem', $b->{id}, $who, $caller ), '' );
}

# The plan folder a key makes: the same key, the same folder, so a repeat finds the
# plan it made. 128 bits of a hash of a hash of the caller's key - not a name anyone
# else can reach, and the owner check on a confirm is unchanged.
sub _idem_pid { return substr( Digest::SHA::sha256_hex( 'plan|' . $_[0] ), 0, 32 ) }

# Whose key OOM counts it as in the registry of an in-process run (the daemon's side
# is OOM's own _owner): the person's Odoo user for a session, else the login.
sub _idem_owner {
    my ( $ctx, $b, $c ) = @_;
    return eval { 'uid:' . $ctx->client->uid } // ( $c->{actor} // '' ) if session_binding($b);
    return $ctx->login;
}

# A result kept in a plan folder, as OOM's own repeat answers it.
sub _idem_result {
    my ( $dir, $run ) = @_;
    my $h = _read_json_file("$dir/result.json");
    $h ||= { applied => 1, op => $run->{op}, plan_fingerprint => $run->{fingerprint}, total => $run->{changes},
        counts => $run->{result}{counts} // {}, by_bucket => {}, verified => 0, not_verified => 0,
        journal => $run->{result}{journal}, created => {}, written => {}, unlinked => {}, custom => [],
        failed_changes => [], unknown_changes => [], invariants => [], invariants_failed => 0 };
    return bless( {%$h}, 'Odoo::Ops::Result' );
}

sub _idem_error {
    my ( $code, $msg ) = @_;
    return Odoo::Error->new( kind => 'refused', code => $code, message => $msg );
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
    $LAST_VIA = undef;    # SM1164: until a call reaches the engine it took no path

    # B: a sign-in is what a session binding runs on, and ONLY that: a connection
    # binding handed one anyway ignores it, so what runs as the connection user
    # is never labelled, owned or recorded as a person.
    delete $ctx{odoo_session} unless session_binding($b);

    # SM1162: the files of a multipart request, taken out of the context at once:
    # the bytes go to assemble() and to the operation and to nothing that copies
    # the context (the gate, the record, a log line).
    my $files = delete $ctx{files};
    my $idem_in = delete $ctx{idem_key};    # SM1223: the caller's own key
    my %c = _with_visitor(%ctx);
    my ( $ok, $conn ) = gate( $b, %c );
    return $conn unless $ok;

    # SM1161 (L5, "Scheduled keys now, person keys later"): a scheduled run uses
    # the Odoo login the operator set for THIS binding, when one is set. A map
    # that cannot be read refuses, for the reason a grant map does: running as the
    # connection user instead would widen the run exactly when its own, narrower
    # login could not be checked.
    my $account = $ctx{account};
    if ( !$account && ( $c{mode} // '' ) eq 'scheduled' ) {
        my ( $sa, $swhy ) = account_for_scheduled( $b->{id} );
        if ( length $swhy ) {
            my %r0 = _rec_base( $b, %c );
            return ( _refusal( \%r0, 'cannot-tell', $swhy ) )[1];
        }
        if ($sa) { $account = $sa; $c{scheduled_as} = $b->{id} }
    }
    $conn = _as_account( $conn, $account );
    my %rec = ( _rec_base( $b, %c ), login => $conn->{login} );

    my ( $class, $refusal ) = _ready( $b, $conn, \%rec );
    return $refusal unless $class;

    # SM1223: the caller's key, checked and made OOM's before anything else is read
    # of the request, so a bad key is refused whole and names itself.
    if ( defined $idem_in ) {
        my $bad = idem_problem($idem_in);
        $bad = 'an Idempotency-Key is for a binding that writes; this one reads' if !length $bad && !$class->writes;
        return ( _refusal( \%rec, 'invalid', $bad ) )[1] if length $bad;
        my ( $dk, $dwhy ) = idem_derive( $b, $idem_in, %c );
        return ( _refusal( \%rec, 'invalid', $dwhy ) )[1] unless defined $dk;
        $c{idem} = $rec{idem} = $dk;
    }

    require Lazysite::Odoo::Binding;
    my ( $params, $pwhy, $pkind ) = Lazysite::Odoo::Binding::assemble( $b, $class, $input,
        visitor => $ctx{visitor_key}, strict => $ctx{strict}, ( $files ? ( files => $files ) : () ) );
    return ( _refusal( \%rec, $pkind // 'invalid', $pwhy ) )[1] unless $params;

    if ( $class->writes && $b->{apply} ne 'immediate' && !length _owner(%c) ) {
        return ( _refusal( \%rec, 'no-owner',
                'this binding plans a change for somebody to confirm, and the caller is '
                    . 'nobody who could - a signed-in account or a visitor with a key' ) )[1];
    }

    my ( $capok, $capwhy ) = _take_cap( $b, $class, %c );
    return ( _refusal( \%rec, 'rate', $capwhy ) )[1] unless $capok;

    _log_files( \%rec, $params ) if $files;

    my $t0  = _now_hires();
    my $res = eval { _run( $b, $class, $conn, $params, \%c ) };
    return _session_end( $b,
        _finish( \%rec, $res, $@, $t0, $class->writes ? ( $b->{apply} eq 'immediate' ? 'apply' : 'plan' ) : 'run' ) );
}

# SM1162: what a binding's files weigh at the endpoint, BEFORE the body is read.
# ( the cap on one file in bytes, the most files the binding can be given ). The
# count comes from the operation's own declaration where the registry can be read
# (a `file` parameter takes one, a `files` parameter its `max`), else OOM's
# ten-per-list rule is assumed, which can only be too generous, never too tight.
sub upload_budget {
    my ($b) = @_;
    require Lazysite::Odoo::Binding;
    my $cap = ( $b->{file_max_kb} // 0 ) * 1024;
    my ($conn) = eval { connection() };
    # SM1180: with the daemon on, the declaration stored at save, so a file call that
    # oomd answers is weighed without loading OOM (binding_class).
    my $class = $conn  ? eval { ( binding_class( $b, $conn ) )[0] } : undef;
    my $spec  = $class ? ( eval { $class->params } || {} )          : {};
    my $n     = 0;
    for my $p ( values %{ $b->{file_params} || {} } ) {
        my $d = Lazysite::Odoo::Binding::param_decl( $spec, $p ) || {};
        my $t = $d->{type} // ( $class ? 'file' : 'files' );
        if ( $t eq 'files' ) {
            my $m = defined $d->{max} && $d->{max} =~ /\A[0-9]+\z/ ? $d->{max} : $Lazysite::Odoo::Binding::MAX_FILES;
            $n += $m > $Lazysite::Odoo::Binding::MAX_FILES ? $Lazysite::Odoo::Binding::MAX_FILES : $m;
        }
        else { $n += 1 }
    }
    return ( $cap, $n || 1 );
}

# SM1224: what a JSON request for this binding may weigh, in bytes - 64 KB, or
# more when a rows key of its operation declares a larger `max` (see
# Binding::json_budget). Known before the body is read; the binding is named in
# the query for a request over 64 KB.
sub json_budget {
    my ($b) = @_;
    require Lazysite::Odoo::Binding;
    my ($conn) = eval { connection() };
    my $class  = $conn  ? eval { ( binding_class( $b, $conn ) )[0] } : undef;
    my $spec   = $class ? ( eval { $class->params } || {} ) : {};
    return Lazysite::Odoo::Binding::json_budget( $b, $spec );
}

# SM1162: one log line per file an operation is given - name, size, sha256 and
# type, and never the bytes, which are in the call and nowhere else. The call_id
# ties the line to the call record.
sub _log_files {
    my ( $rec, $params ) = @_;
    require Digest::SHA;
    my @files;
    my $walk;
    $walk = sub {
        my ($v) = @_;
        if ( ref $v eq 'HASH' && defined $v->{bytes} && !ref $v->{bytes} && defined $v->{name} ) { push @files, $v; return }
        $walk->($_) for ref $v eq 'HASH' ? values %$v : ref $v eq 'ARRAY' ? @$v : ();
    };
    $walk->($params);
    for my $f (@files) {
        log_event( 'INFO', 'odoo', 'a file was given to an operation',
            call_id => $rec->{call_id}, binding => $rec->{binding}, operation => $rec->{operation},
            name => $f->{name}, bytes => length $f->{bytes}, sha256 => Digest::SHA::sha256_hex( $f->{bytes} ),
            mimetype => $f->{mimetype} // '' );
    }
    return;
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
    $LAST_VIA = undef;

    # B: a person's sign-in applies only to a plan made by a session binding, and
    # only that person's: the owner is the hash of the session.
    my $sess = delete $ctx{odoo_session};
    my $idem_in = delete $ctx{idem_key};       # SM1223
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
        unless ref $meta eq 'HASH' && !$meta->{withdrawn}
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

    # SM1223: the plan keeps the key it was made with, and the confirm uses it, so a
    # confirm sent twice (a queue that flushed again) answers with the first result.
    # A key on the confirm itself is for a plan made without one; against a plan
    # made with another it is refused.
    my $idem = $meta->{idem};
    if ( defined $idem_in ) {
        my $bad = idem_problem($idem_in);
        return ( _refusal( \%rec, 'invalid', $bad ) )[1] if length $bad;
        my ( $k2, $kwhy ) = idem_derive( $b, $idem_in, %c );
        return ( _refusal( \%rec, 'invalid', $kwhy ) )[1] unless defined $k2;
        return ( _refusal( \%rec, 'invalid', 'this plan was made with another Idempotency-Key' ) )[1]
            if defined $idem && $idem ne $k2;
        $idem = $k2;
    }
    $c{idem} = $rec{idem} = $idem if defined $idem;
    my ( $capok, $capwhy ) = _take_cap( $b, $class, %c );
    return ( _refusal( \%rec, 'rate', $capwhy ) )[1] unless $capok;

    my $t0  = _now_hires();
    my $res = eval {
        $LAST_VIA = undef;
        if ( $meta->{run_id} && $meta->{run_id} =~ /\A[A-Za-z0-9][\w.-]{0,127}\z/ ) {
            if ( my $cl = _daemon_for($conn) ) {
                my $r = eval { _confirm_daemon( $cl, $meta, $pid, $b, { %c, conn => $conn } ) };
                if ( ref $r eq 'HASH' ) { $LAST_VIA = 'daemon'; return $r }
                my $e = $@;
                die _idem_error( 'run-gone', 'the daemon holds no plan for this run' )
                    if _daemon_run_gone( $e, $meta->{run_id} );
                die $e unless _daemon_down($e) && ( $conn->{daemon} // '' ) eq 'on';
                log_event( 'WARN', 'odoo', 'the Odoo daemon is not answering; this confirm runs in-process',
                    binding => $b->{id} );
            }
        }
        $LAST_VIA = 'in-process';
        _load_oom();    # SM1180: the gate loaded only the version when the daemon was on
        my $plan = Odoo::Ops::Plan->load("$dir/plan.json");
        my $ctx  = context( $conn, actor => _actor_label(%c),
            ( session_binding($b) ? ( session => $c{odoo_session} ) : () ) );
        $ctx->use_run_dir($dir);
        my $claim;
        if ( defined $idem ) {
            require Odoo::Ops::Runs;
            $claim = Odoo::Ops::Runs->idem_claim( plans_dir(), instance => $ctx->instance,
                owner => _idem_owner( $ctx, $b, \%c ), key => $idem );
            if ( -e "$dir/result.json" ) { # already applied under this key: the first result
                my $first = _idem_result( $dir, $claim->run || {} );
                return { ok => ( $first->ok ? 1 : 0 ), applied => 1, plan => $pid, repeat => 1,
                    result => _result_summary($first) };
            }
            $claim->bind( $pid, undef ) unless $claim->run;
        }
        _approve( $dir, $plan, $meta->{owner}, 'confirmed in lazysite by its maker' );
        my $result = with_site_ops( $conn, sub { Odoo::Ops::Runner->apply( $ctx, $plan, dir => $dir ) } );
        $result->save("$dir/result.json") if $claim;
        { ok => ( $result->ok ? 1 : 0 ), applied => 1, plan => $pid, result => _result_summary($result) };
    };
    my $err = $@;

    # SM1162 (release manager, 2026-10-19: "When the plan is applied or withdrawn"): a
    # plan that has been applied (fully or partly) or refused as no longer
    # applicable will never run again, so the file bytes it holds go now.
    purge_plan_blobs( $pid, $meta ) if _plan_spent( $res, $err );
    return _session_end( $b, _finish( \%rec, $res, $err, $t0, 'apply' ) );
}

# SM1261 (release manager, 2026-10-22): the daemon finds a confirm's plan by path,
# lazysite/odoo/runs/<run_id>/plan.json (Odoo::Ops::Service _plan_path). With that
# folder or file gone OOM fails in Plan->load as `config`, which would tell the page
# the connection is misconfigured. A `config` failure with the plan file absent is
# that, and is answered `not-found` (make the plan again).
sub _daemon_run_gone {
    my ( $e, $run ) = @_;
    return 0 unless ref $e && eval { $e->isa('Odoo::Error') } && ( $e->kind // '' ) eq 'config';
    require Lazysite::Odoo::Daemon;
    return -e Lazysite::Odoo::Daemon::runs_dir($DOCROOT) . "/$run/plan.json" ? 0 : 1;
}

# Is the plan SPENT after this confirm: it was applied (the result says so, whole or
# partial), or OOM refused it for a reason that does not pass (the data moved on, the
# plan was edited, it was already applied, it is another Odoo's). A refusal that can
# be tried again (a rate cap, a sign-in) leaves it waiting.
sub _plan_spent {
    my ( $res, $err ) = @_;
    return 1 if ref $res eq 'HASH' && $res->{applied};
    return 0 unless ref $err && eval { $err->isa('Odoo::Error') } && ( $err->kind // '' ) eq 'refused';
    return ( ( $err->code // '' ) =~ /\A(?:stale|fingerprint|applied|instance)\z/ ) ? 1 : 0;
}

# SM1162: remove the bytes of the files a plan holds - OOM keeps a file once, in the
# plan's blobs/ folder, so a confirm can apply it - from the plan's folder here and,
# for a plan the daemon made, from the daemon's run folder. By OOM's own
# Odoo::Ops::Blob->purge (it removes the blobs/ folder and nothing else); the plan
# record, the journal and the meta stay, and the record names each file by name,
# size and sha256. Returns how many blobs went.
sub purge_plan_blobs {
    my ( $pid, $meta ) = @_;
    return 0 unless defined $pid && $pid =~ /\A[0-9a-f]{32}\z/;
    return 0 unless eval { require Odoo::Ops::Blob; Odoo::Ops::Blob->can('purge') };
    my $n    = 0;
    my @dirs = ( plans_dir() . "/$pid" );
    my $run  = ref $meta eq 'HASH' ? ( $meta->{run_id} // '' ) : '';
    push @dirs, store_dir() . "/runs/$run" if $run =~ /\A[A-Za-z0-9][\w.-]{0,127}\z/;
    for my $dir (@dirs) {
        next unless -d "$dir/blobs";
        $n += eval { Odoo::Ops::Blob->purge($dir) } // 0;
    }
    log_event( 'INFO', 'odoo', 'the file bytes of a spent plan were removed', plan => $pid, blobs => $n ) if $n;
    return $n;
}

# withdraw( $plan_id, %ctx ) -> { ok, withdrawn } or a refusal
#
# SM1162: the maker of an unapplied plan gives it up. Its file bytes go at once, it
# can no longer be confirmed (a confirm answers as for a plan that does not exist),
# and the record stays until the plan's days are out. A plan that is not yours does
# not exist here either; one already applied cannot be withdrawn.
sub withdraw {
    my ( $pid, %ctx ) = @_;
    my $sess = delete $ctx{odoo_session};
    my $swho = length( $sess // '' ) ? do { require Lazysite::Odoo::Session; Lazysite::Odoo::Session::session_label($sess) } : '';
    my %c    = _with_visitor(%ctx);
    my %base = ( call_id => new_call_id(), actor => $c{actor} // '',
        ( length( $c{visitor} // '' ) ? ( visitor => $c{visitor} ) : () ),
        ip => $c{ip} // '', mode => $c{mode} // '', phase => 'withdraw' );
    my $nf = 'no such plan, or not yours to withdraw';
    return ( _refusal( \%base, 'not-found', $nf ) )[1] unless defined $pid && $pid =~ /\A[0-9a-f]{32}\z/;
    my $dir  = plans_dir() . "/$pid";
    my $meta = _read_json_file("$dir/meta.json");
    my $who  = _owner(%c);
    return ( _refusal( \%base, 'not-found', $nf ) )[1]
        unless ref $meta eq 'HASH' && !$meta->{withdrawn}
        && ( ( length $who && ( $meta->{owner} // '' ) eq $who ) || ( length $swho && ( $meta->{owner} // '' ) eq $swho ) );
    return ( _refusal( { %base, binding => $meta->{binding} // '' }, 'applied', 'this plan has already been applied' ) )[1]
        if -e "$dir/journal.jsonl";
    $meta->{withdrawn} = time;
    _write_json_file( "$dir/meta.json", $meta );
    my $n = purge_plan_blobs( $pid, $meta );
    record_call( %base, binding => $meta->{binding} // '', operation => $meta->{operation} // '',
        outcome => 'answered' );
    return { ok => 1, withdrawn => 1, plan => $pid };
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
                    ( $conn->{key_kind} && $conn->{key_kind} eq 'scheduled' ? 'this binding\'s own Odoo login has no API key set'
                        : $conn->{key_account} ? 'this grant\'s Odoo account has no API key set'
                        : 'the connection user has no API key set' ) . ' - a sysop sets it on the Odoo page' ) )[1] )
            unless $has;
    }
    my ( $class, $why, $how ) = binding_class( $b, $conn );
    $rec->{decl} = $how if defined $how;  # SM1180: stored | rechecked, in the call record
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
    if ( my $cl = _daemon_for($conn) ) {
        my $r = eval { _run_daemon( $cl, $b, $class, $conn, $params, $c ) };
        if ( ref $r eq 'HASH' ) { $LAST_VIA = 'daemon'; return $r }
        my $e = $@;
        die $e unless _daemon_down($e) && ( $conn->{daemon} // '' ) eq 'on';
        log_event( 'WARN', 'odoo', 'the Odoo daemon is not answering; this call runs in-process',
            binding => $b->{id}, operation => $b->{operation} );
    }
    $LAST_VIA = 'in-process';
    $class    = _real_class($class);    # SM1180: a stored declaration cannot run anything
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

    # SM1223: a key already used answers from its run, before the operation is
    # planned again (no read of Odoo, nothing written). The claim holds the key's
    # lock until this call ends, so two requests with one key go one after the other.
    my $idem = $c->{idem};
    my ( $claim, $digest );
    if ( defined $idem ) {
        require Odoo::Ops::Runs;
        $digest = Odoo::Ops::Runs->request_digest( $b->{operation}, $params );
        $claim  = Odoo::Ops::Runs->idem_claim( plans_dir(), instance => $ctx->instance,
            owner => _idem_owner( $ctx, $b, $c ), key => $idem );
        if ( my $run = $claim->run ) {
            die _idem_error( 'idem-mismatch', "idem belongs to run $run->{id}, which was a different request" )
                if ( $claim->request // '' ) ne $digest;
            my $dir0 = plans_dir() . "/$run->{id}";
            my $meta = _read_json_file("$dir0/meta.json");
            die _idem_error( 'idem-withdrawn', "the plan of run $run->{id} was withdrawn" )
                if ref $meta eq 'HASH' && $meta->{withdrawn};
            if ( -e "$dir0/result.json" || -e "$dir0/journal.jsonl" ) {
                my $result = _idem_result( $dir0, $run );
                return { ok => ( $result->ok ? 1 : 0 ), applied => 1, plan => $run->{id}, repeat => 1,
                    result => _result_summary($result) };
            }
            my $again = Odoo::Ops::Plan->load("$dir0/plan.json");
            return { ok => 1, planned => 1, plan => $run->{id}, preview => _preview($again), repeat => 1 }
                if $b->{apply} ne 'immediate';

            # an immediate apply that was planned and not finished: finish it
            $ctx->use_run_dir($dir0);
            _approve( $dir0, $again, "binding:$b->{id}", 'apply: immediate on the binding' );
            my $result = with_site_ops( $conn, sub { Odoo::Ops::Runner->apply( $ctx, $again, dir => $dir0 ) } );
            $result->save("$dir0/result.json");
            return { ok => ( $result->ok ? 1 : 0 ), applied => 1, plan => $run->{id}, repeat => 1,
                result => _result_summary($result) };
        }
    }

    my $plan = $op->run;
    my ( $pid, $dir ) = _new_plan_dir( defined $idem ? _idem_pid($idem) : undef );
    $ctx->use_run_dir($dir);
    $plan->save("$dir/plan.json");
    _write_json_file( "$dir/meta.json",
        { binding => $b->{id}, operation => $b->{operation}, owner => _owner(%$c),
            created => time, fingerprint => $plan->fingerprint, ( defined $idem ? ( idem => $idem ) : () ) } );
    $claim->bind( $pid, $digest ) if $claim;
    if ( $b->{apply} eq 'immediate' ) {
        _approve( $dir, $plan, "binding:$b->{id}", 'apply: immediate on the binding' );
        my $result = with_site_ops( $conn, sub { Odoo::Ops::Runner->apply( $ctx, $plan, dir => $dir ) } );
        $result->save("$dir/result.json") if $claim;
        return { ok => ( $result->ok ? 1 : 0 ), applied => 1, plan => $pid,
            result => _result_summary($result) };
    }
    return { ok => 1, planned => 1, plan => $pid, preview => _preview($plan) };
}

# SM1164 D3: THE SAME CALL, ANSWERED BY oomd. Same arguments as in-process (the
# operation, the parameters assembled against its declaration), the person's
# session id or the account's label for the credential, and the ACTOR the
# in-process context gives OOM's audit. A write is planned by the daemon; the
# plan is saved in the plan store beside lazysite's own meta.json, which names
# the daemon's run so a confirm can approve and apply it there. Nothing the
# daemon answers is returned to a page beyond what the in-process path returns.
sub _run_daemon {
    my ( $cl, $b, $class, $conn, $params, $c ) = @_;
    my %req = ( credential => _daemon_credential( $b, $conn, $c ), actor => _actor_label(%$c) );

    # SM1223: the key OOM holds is sent on the run and, for an immediate apply, on
    # the approve and the apply of the same run, which OOM binds to the one key.
    my $idem = $class->writes ? $c->{idem}        : undef;
    my %ik   = defined $idem  ? ( idem => $idem ) : ();
    my $r    = $cl->run( $b->{operation}, $params, %req, %ik );
    unless ( $class->writes ) {
        my $report = $r->{report};
        require Lazysite::Odoo::Fields;
        my ( $fields, $refused ) = Lazysite::Odoo::Fields::present($report);
        return { ok => 1, report => $report, ( $fields ? ( fields => $fields, refused => $refused ) : () ) };
    }
    my $again = $r->{repeat} ? 1 : 0;
    if ( $again && ref $r->{result} ) { # applied already: the first result, nothing sent to Odoo
        my $m = _read_json_file( plans_dir() . '/' . _idem_pid($idem) . '/meta.json' );
        die _idem_error( 'idem-withdrawn', 'the plan of this key was withdrawn' ) if ref $m eq 'HASH' && $m->{withdrawn};
        return _applied_answer( _idem_pid($idem), $r );
    }
    my $plan = $r->{plan}
        or die "the daemon answered a write without a plan\n";
    my $run_id = $r->{run_id} // '';
    my ( $pid, $dir, $reuse );
    if ( defined $idem ) {
        ( $pid, $dir ) = ( _idem_pid($idem), plans_dir() . '/' . _idem_pid($idem) );
        my $m = _read_json_file("$dir/meta.json");
        if ( ref $m eq 'HASH' && length $run_id && ( $m->{run_id} // '' ) eq $run_id ) {
            die _idem_error( 'idem-withdrawn', 'the plan of this key was withdrawn' ) if $m->{withdrawn};
            $reuse = 1;    # the plan it made is still here, with its age
        }
        else { ( $pid, $dir ) = _new_plan_dir($pid) }
    }
    else { ( $pid, $dir ) = _new_plan_dir() }
    my $res = eval {
        unless ($reuse) {
            $plan->save("$dir/plan.json");
            _write_json_file( "$dir/meta.json",
                { binding => $b->{id}, operation => $b->{operation}, owner => _owner(%$c),
                    created => time, fingerprint => $plan->fingerprint,
                    ( length $run_id ? ( run_id => $run_id ) : () ), ( defined $idem ? ( idem => $idem ) : () ) } );
        }
        if ( $b->{apply} eq 'immediate' ) {
            $cl->approve( $run_id, %req, %ik, actor => "binding:$b->{id}", note => 'apply: immediate on the binding' );
            my $ar = $cl->apply( $run_id, %req, %ik );
            my $a  = _applied_answer( $pid, $ar );
            $a->{repeat} = 1 if $again;
            return $a;
        }
        { ok => 1, planned => 1, plan => $pid, preview => _preview($plan), ( $again ? ( repeat => 1 ) : () ) };
    };
    unless ($res) {
        my $e = $@;
        unless ($reuse) {
            require File::Path;
            File::Path::remove_tree($dir);
        }
        die $e;
    }
    return $res;
}

# An apply's answer as the page is given it. A plan with nothing in it answers
# `nothing` and no result.
sub _applied_answer {
    my ( $pid, $ar ) = @_;
    return { ok => 1, applied => 1, plan => $pid,
        result => { total => 0, counts => {}, by_bucket => {}, verified => 0, changes => [] } }
        unless ref $ar eq 'HASH' && $ar->{result};
    return { ok => ( $ar->{result}->ok ? 1 : 0 ), applied => 1, plan => $pid,
        ( $ar->{repeat} ? ( repeat => 1 ) : () ), result => _result_summary( $ar->{result} ) };
}

# A confirm through the daemon: approve in the daemon's run (the actor on the
# approval is the plan's owner, as the in-process approval records it), then apply.
sub _confirm_daemon {
    my ( $cl, $meta, $pid, $b, $c ) = @_;
    my %req = ( credential => _daemon_credential( $b, $c->{conn}, $c ), actor => _actor_label(%$c) );
    my $run = $meta->{run_id};
    my %ik = defined $c->{idem} ? ( idem => $c->{idem} ) : (); # SM1223: the plan's key, or the confirm's own
    $cl->approve( $run, %req, %ik, actor => $meta->{owner}, note => 'confirmed in lazysite by its maker' );
    return _applied_answer( $pid, $cl->apply( $run, %req, %ik ) );
}

sub _finish {
    my ( $rec, $res, $err, $t0, $phase ) = @_;
    my $ms = int( ( _now_hires() - $t0 ) * 1000 );
    unless ( ref $res eq 'HASH' ) {
        my $f = fault( $err, binding => $rec->{binding}, operation => $rec->{operation},
            mode => $rec->{mode} );
        record_call( %$rec, phase => $phase, outcome => outcome_of( $f->{kind} ),
            kind => $f->{kind}, ms => $ms, ( defined $LAST_VIA ? ( via => $LAST_VIA ) : () ) );
        return $f;
    }
    record_call( %$rec, phase => $phase, outcome => 'answered', ms => $ms, ( $res->{repeat} ? ( repeat => 1 ) : () ),
        ( defined $LAST_VIA ? ( via => $LAST_VIA ) : () ),
        ( $res->{ok} ? () : ( kind => 'apply-incomplete' ) ) );
    unless ( $res->{ok} ) {
        # SM1218: a change whose request was sent and whose answer never came is not
        # known to have failed. Same kind (a page that checks ok or kind still
        # refuses it), but `unknown` says how many, and the sentence does not
        # suggest the change did not happen.
        my $u = ref $res->{result} eq 'HASH' && ref $res->{result}{counts} eq 'HASH' ? $res->{result}{counts}{unknown} : 0;
        if ($u) {
            $res->{unknown} = $u + 0;
            $res->{error}   = $UNKNOWN_ANSWER;
        }
        else { $res->{error} = 'the plan did not apply completely - see the counts' }
        $res->{kind} = 'apply-incomplete';
    }
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
        changes => [ map { _change_view($_) } @{ $h->{changes} || [] } ],
    };
}

# What apply did, without the journal's host path. `created` and `written`
# (model to ids, this plan's own changes) go on so a page can open the record
# its write made without reading it back (SM1165, OOM Lab L-10); `unlinked` is
# not passed - a page has nothing to open. `changes` (SM1171, L-13) says per
# change what became of it - see _applied_changes.
sub _result_summary {
    my ($r) = @_;
    my $h   = $r->to_hash;
    my %out = map { ( $_ => $h->{$_} ) } qw(total counts by_bucket verified stopped_by created written);
    $out{changes} = _applied_changes( $h->{journal} );
    _add_failures( $out{changes}, $h->{failed_changes} );
    _add_unknown( $out{changes}, $h->{unknown_changes} );
    return \%out;
}

# SM1193 (OOM Lab L-19: "A failed apply reaches the page as `apply-incomplete`, with
# counts and no message. Odoo's refusal is in the journal only"; OOM's answer, inbox
# 2026-10-20: the result carries `failed_changes`, each with key, model, action and
# Odoo's `message`, and from 0.36 a `code`). ONE SHAPE: the failed change's entry in
# `changes` (SM1171, outcome `failed`) gains `key`, `message` and `code`; there is
# no second list. Odoo's message is validation text for the person's own action, so
# it is shown, through SM1186's _usage_text (cap, control characters; a path, a
# trace or a secret's name withholds it whole). A withheld message is replaced by a
# plain sentence and `withheld => 1`, so a page can tell. A failure whose journal
# could not be read still gets its entry.
my $WITHHELD = 'Odoo refused this change; its reason is kept for the operator';

sub _add_failures {
    my ( $changes, $failed ) = @_;
    return unless ref $failed eq 'ARRAY' && ref $changes eq 'ARRAY';
    for my $f (@$failed) {
        next unless ref $f eq 'HASH';
        my ($c) = grep { defined $f->{seq} && ( $_->{seq} // '' ) eq $f->{seq} } @$changes;
        unless ($c) {
            $c = { map { ( $_ => $f->{$_} ) } grep { defined $f->{$_} } qw(seq action model id) };
            $c->{outcome} = 'failed';
            push @$changes, $c;
        }
        $c->{key}  = $f->{key}  if defined $f->{key}  && !ref $f->{key};
        $c->{code} = $f->{code} if defined $f->{code} && !ref $f->{code};
        my $m = _usage_text( $f->{message} );
        $c->{message}  = defined $m ? $m : $WITHHELD;
        $c->{withheld} = 1 unless defined $m;
    }
    return;
}

# SM1218 (OOM 0.38; edge walk 0.15.11 G-1: "a write that timed out is reported as
# failed, though Odoo did it"). OOM answers a write whose request was sent and
# whose answer never came as UNKNOWN: `counts.unknown` and `unknown_changes`, each
# with key, message and a `reason`. The change's entry in `changes` has outcome
# `unknown` (SM1171) and gains `key`, `code`, `message` (through _usage_text, the
# same withholding as a failure's) and `reason` (OOM's own sentence), and
# `unknown => 1`. The reason says "Odoo may have made this change"; a page reads it
# back before it does anything again, and is never told to try again.

sub _add_unknown {
    my ( $changes, $unknown ) = @_;
    return unless ref $unknown eq 'ARRAY' && ref $changes eq 'ARRAY';
    for my $f (@$unknown) {
        next unless ref $f eq 'HASH';
        my ($c) = grep { defined $f->{seq} && ( $_->{seq} // '' ) eq $f->{seq} } @$changes;
        unless ($c) {
            $c = { map { ( $_ => $f->{$_} ) } grep { defined $f->{$_} } qw(seq action model id) };
            push @$changes, $c;
        }
        $c->{outcome} = 'unknown';
        $c->{unknown} = 1;
        $c->{key}     = $f->{key}  if defined $f->{key}  && !ref $f->{key};
        $c->{code}    = $f->{code} if defined $f->{code} && !ref $f->{code};
        my $m = _usage_text( $f->{message} );
        $c->{message}  = $m if defined $m;
        $c->{withheld} = 1 unless defined $m;
        my $r = _usage_text( $f->{reason} );
        $c->{reason} = defined $r ? $r : 'the request was sent and no answer came; Odoo may have made this change';
    }
    return;
}

# A change as a page may see it: where it sits and why it was held. NOT its
# values or before-image - the preview's rule - so a reason (the operation's
# own words for why) is the only prose that goes (SM1171, OOM Lab L-13: "the
# hold REASON ... never reach the page").
sub _change_view {
    my ($c) = @_;
    return { map { ( $_ => $c->{$_} ) } grep { defined $c->{$_} } qw(seq bucket action reason) };
}

# `returned` is whatever the operation's handler answered (a backorder's name, a
# mailing's send state), so it has no size of its own: past 4 KB of JSON it is
# cut and says so, so one change cannot make the answer as large as the handler
# chose.
my $RETURNED_CAP = 4096;

sub _capped {
    my ($v) = @_;
    my $json = JSON::PP->new->canonical->allow_nonref->encode($v);
    return $v if length $json <= $RETURNED_CAP;
    my $text = ref $v ? $json : "$v"; # a string is cut as the string it is, a structure as its JSON
    return substr( $text, 0, $RETURNED_CAP ) . '...[truncated, ' . length($text) . ' bytes]';
}

# Per change of the apply, from the journal OOM kept of it (the result holds
# only counts, and its path is the host's and stays here): seq, bucket, action,
# model, the record id if there is one, the outcome, `reason` for a held or
# skipped change and `returned` for a custom one. Nothing else of the entry -
# its vals, before-image and handler stay in the journal for the operator. A
# journal that cannot be read answers no list; the counts still stand.
sub _applied_changes {
    my ($path) = @_;
    return [] unless defined $path && length $path;
    my $rows = eval { require Odoo::Ops::Journal; ( Odoo::Ops::Journal->read($path) )[1] };
    return [] unless ref $rows eq 'ARRAY';
    my @out;
    for my $e (@$rows) {
        my %c = map { ( $_ => $e->{$_} ) } grep { defined $e->{$_} } qw(seq bucket action model id outcome);
        $c{reason} = $e->{reason} if defined $e->{reason} && ( $e->{outcome} // '' ) =~ /\A(?:held|skipped)\z/;
        $c{returned} = _capped( _journal_value( $path, $e->{returned} ) )
            if ( $e->{action} // '' ) eq 'custom' && defined $e->{returned};
        push @out, \%c;
    }
    return \@out;
}

# Since OOM 0.32 a journal keeps a value over `blob_min` (64 KiB by default) in
# its folder's blobs/ and the line carries a reference ({blob, bytes, type})
# in its place. A `returned` that large is read back so it is capped as the
# value it is; a reference that cannot be read answers the marker alone, never
# the reference.
sub _journal_value {
    my ( $path, $v ) = @_;
    return $v unless ref $v;
    return $v unless eval { require Odoo::Ops::Blob; 1 } && _holds_blob_ref($v); # before 0.32: no blobs
    my $full = eval {
        require File::Basename;
        Odoo::Ops::Blob->source( dirs => [ File::Basename::dirname($path) ] )->resolve($v);
    };
    return $full if defined $full;
    my $bytes = ref $v eq 'HASH' && defined $v->{bytes} ? $v->{bytes} : 0;
    return "...[truncated, $bytes bytes]";
}

sub _holds_blob_ref {
    my ($v) = @_;
    return 1 if Odoo::Ops::Blob->is_ref($v);
    return scalar grep { _holds_blob_ref($_) } values %$v if ref $v eq 'HASH';
    return scalar grep { _holds_blob_ref($_) } @$v        if ref $v eq 'ARRAY';
    return 0;
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
    my ( $b, $class, %c ) = @_;
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

    # SM1173: the default is the operation's own - reads 2,000 / 20,000, writes 20 / 200.
    require Lazysite::Odoo::Binding;
    my ( $lim_who, $lim_all ) = Lazysite::Odoo::Binding::rate_limits( $b, $class->writes );

    my ( $ok, $why ) = Lazysite::Egress::within_caps(
        what => 'Odoo binding',
        axes => [
            { name => ( $who =~ /\Avisitor:/ ? 'per-visitor' : 'per-caller' ),
                limit   => $lim_who, used => $n_who,
                setting => "rate_per_visitor_hour on the binding '$b->{id}'" },
            { name => 'per-binding', limit => $lim_all, used => $n_all,
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

    # The trusted-device cookie (SM1157) goes back to Odoo only where the site offers
    # the choice; a site that has switched it off sends nothing, and the endpoint
    # clears a cookie it no longer honours.
    my $device = ( $conn->{remember_device} && $a{trusted_device} ) ? $a{trusted_device} : undef;
    my $stale = ( $a{trusted_device} && !defined $device ) ? 1 : 0; # a cookie this site no longer honours
    my $r = Lazysite::Odoo::Session::sign_in( $conn, $login, $a{password},
        ( defined $device ? ( trusted_device => $device ) : () ) );
    if ( $r->{pending} ) {
        my $pc = Lazysite::Odoo::Session::mint_pending_cookie( $r->{session_id} );
        unless ( defined $pc ) {
            Lazysite::Odoo::Session::sign_out( $conn, $r->{session_id} );
            return ( _refusal( \%rec, 'unavailable', 'a sign-in cookie cannot be made on this host - see the event log' ) )[1];
        }
        record_call( %rec, actor => Lazysite::Odoo::Session::session_label( $r->{session_id} ),
            outcome => 'answered', kind => 'second-factor-required' );
        return { ok => 1, second_factor => 'totp', pending_cookie => $pc,
            remember_offered => ( $conn->{remember_device} && $a{secure} ? 1 : 0 ),

            # Odoo did not honour the device cookie this request sent (or the site
            # no longer offers the choice): the browser is told to drop it.
            ( $stale || defined $device ? ( clear_device => 1 ) : () ) };
    }
    unless ( $r->{ok} ) {
        record_call( %rec, outcome => outcome_of( $r->{kind} ), kind => $r->{kind} );
        return { ok => 0, kind => $r->{kind}, error => $r->{error} };
    }
    my $cookie = Lazysite::Odoo::Session::mint_cookie( $r->{session_id} );
    unless ( defined $cookie ) {
        Lazysite::Odoo::Session::sign_out( $conn, $r->{session_id} );
        return ( _refusal( \%rec, 'unavailable', 'a sign-in cookie cannot be made on this host - see the event log' ) )[1];
    }
    # SM1160: on a site that opted in, the Odoo sign-in is the site sign-in
    my ( $site, $sfail ) = site_session_start( $r, $conn, %a );
    return { %{ ( _refusal( \%rec, 'unavailable', $sfail ) )[1] }, ( $stale ? ( clear_device => 1 ) : () ) } if defined $sfail;
    record_call( %rec, actor => Lazysite::Odoo::Session::session_label( $r->{session_id} ), outcome => 'answered' );
    return { ok => 1, cookie => $cookie, identity => $r->{identity},
        identity_cookie => _identity_cookie( $r->{identity_all} ), ( $stale ? ( clear_device => 1 ) : () ),
        ( $site ? ( site_cookie => $site ) : () ) };
}

# sign_in_code( pending_session, code, remember, user_agent, ip, secure ) -> { ok, cookie, identity[, trusted_device] }
#                                                             or { ok => 0, kind, error[, clear_pending] }
#
# The second request of a two-factor sign-in (SM1157, OOM 0.27). The pending
# session is the one the first request left in its signed cookie; the code is an
# argument that goes to Odoo through OOM and nowhere else. A wrong code answers
# kind `second-factor` and changes nothing, so the person tries again (Odoo counts
# the tries). `remember` is honoured only where the site offers it and the request
# came over HTTPS; the device value comes back for the endpoint to put in its own
# cookie and is in no record, log or store. The record names the pending session
# by a hash, with the phase and the outcome and nothing typed.
sub sign_in_code {
    my (%a) = @_;
    require Lazysite::Odoo::Session;
    require Lazysite::Odoo::Visitor;
    no warnings q{once};
    local $Lazysite::Odoo::Visitor::DOCROOT = $DOCROOT;
    my %rec = ( call_id => new_call_id(), actor => Lazysite::Odoo::Session::session_label( $a{pending_session} ),
        ip => $a{ip} // '', mode => 'public', phase => 'signin-code', binding => '', operation => '' );
    return ( _refusal( \%rec, 'disabled',
            'the Odoo extension is switched off - a sysop can enable it on the Extensions page' ) )[1]
        unless _extension_enabled();
    my ( $have, $missing ) = oom_check();
    return ( _refusal( \%rec, 'unavailable', $missing ) )[1] unless $have;
    my ( $conn, $cwhy ) = connection();
    return ( _refusal( \%rec, 'config', $cwhy ) )[1] unless $conn;
    return { %{ ( _refusal( \%rec, 'signin-required', 'the sign-in has run out - enter the password again' ) )[1] }, clear_pending => 1 }
        unless defined $a{pending_session} && length $a{pending_session};

    my $code = ( defined $a{code} && !ref $a{code} && length $a{code} <= 32 ) ? $a{code} : '';
    $code =~ s/\s+//g;    # an authenticator app shows "123 456"
    return ( _refusal( \%rec, 'invalid', 'enter the 6-digit code from your authenticator app' ) )[1]
        unless $code =~ /\A[0-9]{6}\z/;

    my $remember = ( $a{remember} && $conn->{remember_device} && $a{secure} ) ? 1 : 0;
    my $r = Lazysite::Odoo::Session::complete_totp( $conn, $a{pending_session}, $code,
        remember => $remember, user_agent => $a{user_agent} );
    unless ( $r->{ok} ) {
        record_call( %rec, outcome => outcome_of( $r->{kind} ), kind => $r->{kind} );
        return { ok => 0, kind => $r->{kind}, error => $r->{error}, ( $r->{clear_pending} ? ( clear_pending => 1 ) : () ) };
    }
    my $cookie = Lazysite::Odoo::Session::mint_cookie( $r->{session_id} );
    unless ( defined $cookie ) {
        Lazysite::Odoo::Session::sign_out( $conn, $r->{session_id} );
        return { %{ ( _refusal( \%rec, 'unavailable', 'a sign-in cookie cannot be made on this host - see the event log' ) )[1] }, clear_pending => 1 };
    }
    # SM1160: the site session is minted only here, after Odoo accepted the code
    my ( $site, $sfail ) = site_session_start( $r, $conn, %a );
    return { %{ ( _refusal( \%rec, 'unavailable', $sfail ) )[1] }, clear_pending => 1 } if defined $sfail;
    record_call( %rec, actor => Lazysite::Odoo::Session::session_label( $r->{session_id} ), outcome => 'answered' );
    return { ok => 1, cookie => $cookie, identity => $r->{identity},
        identity_cookie => _identity_cookie( $r->{identity_all} ),
        ( defined $r->{trusted_device} ? ( trusted_device => $r->{trusted_device} ) : () ),
        ( $site                        ? ( site_cookie    => $site ) : () ) };
}

# --- C: the identity cookie ----------------------------------------------------
#
# How long an identity cookie lasts: `odoo_identity_ttl` (OB1), seconds, 60 to
# 86400, default 900. Groups and companies change in Odoo and the cookie does not
# know, so it is short, and refreshed from the session when it has ended.
sub identity_ttl {
    require Lazysite::Odoo::Identity;
    require Lazysite::Odoo::Visitor;
    no warnings 'once';
    local $Lazysite::Odoo::Visitor::DOCROOT = $DOCROOT;
    return Lazysite::Odoo::Identity::configured_ttl(); # SM1147: one reader, shared with ?csrf=1
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
    return { ok => 1, identity_cookie => $c, name => $r->{identity}{name} };
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

# --- SM1160: THE ODOO SIGN-IN AS THE SITE SIGN-IN ---------------------------------
#
# (inbox L3; rulings 2026-10-18; docs/feature-requests/SM1160.) Off unless the site's
# Odoo config says `odoo_site_signin: on`. The configuration is Lazysite::Odoo::SiteSignin's,
# the session is Lazysite::Auth::Session's (the identity is `odoo:<login>`, the groups are in
# the server-side record), and this is the part that talks to Odoo: who the person is, which
# of the mapped groups they hold (OOM core.has_groups, run on THEIR OWN session), and the
# moments that start, renew and end the site session.

sub site_signin_enabled {
    require Lazysite::Odoo::SiteSignin;
    return Lazysite::Odoo::SiteSignin::enabled( _lz() );
}

# site_groups( session_id ) -> { ok, groups => [lazysite groups] }
#                           or { ok => 0, kind, error[, clear_session] }
#
# One question per mapped xml id, asked of Odoo AS THE PERSON: the answer is Odoo's own
# has_group for the signed-in user, so no administrator right is used and nothing about
# another user can be learned. An xml id Odoo does not know holds nothing; from OOM 0.37
# it is answered 0 like one not held, and is not named (SM1217, SiteSignin::report says
# so). With nothing mapped Odoo is not asked.
sub site_groups {
    my (%a) = @_;
    require Lazysite::Odoo::SiteSignin;
    require Lazysite::Odoo::Session;
    my ($map) = Lazysite::Odoo::SiteSignin::group_map( _lz() );
    return { ok => 1, groups => [] } unless %$map;
    my ($have) = oom_check();
    my ($conn) = $have ? connection() : ();
    return { ok => 0, kind => 'config', error => 'the Odoo connection is not available' } unless $conn;
    my ($class) = operation_class( $conn, 'core.has_groups' );
    return { ok => 0, kind => 'unavailable', error => 'the Odoo extension needs OOM 0.33 or later to read a person\'s groups' }
        unless $class;
    my $report = eval {
        my $ctx = context( $conn, actor => Lazysite::Odoo::Session::session_label( $a{session_id} ), session => $a{session_id} );
        $class->new( ctx => $ctx, params => { groups => [ sort keys %$map ] } )->run;
    };
    my $err = $@;
    unless ( ref $report eq 'HASH' && ref $report->{groups} eq 'HASH' ) {
        return { ok => 0, kind => 'signin-required', clear_session => 1,
            error => 'your Odoo sign-in has ended - sign in again' }
            if ref $err && eval { $err->isa('Odoo::Error') } && $err->is_session_expired;
        log_event( 'WARN', 'odoo', 'the person\'s groups could not be read', who => Lazysite::Odoo::Session::session_label( $a{session_id} ) );
        return { ok => 0, kind => 'transport-failure', error => 'Odoo could not be asked which groups the person holds' };
    }
    return { ok => 1, groups => Lazysite::Odoo::SiteSignin::groups_held( $report->{groups}, $map ) };
}

# site_session_start( $signin_result, $conn, ip =>, user_agent => ) -> ( $cookie ) | () | ( undef, $refusal )
# Nothing (off); the cookie value of the new site session; or why there is none - in which
# case the Odoo session is ended too, so nobody is left signed in to half a login.
sub site_session_start {
    my ( $r, $conn, %a ) = @_;
    return () unless site_signin_enabled();
    require Lazysite::Auth::Session;
    require Lazysite::Auth::Settings;
    require Lazysite::Odoo::SiteSignin;
    my $login = ref $r->{identity} eq 'HASH' ? $r->{identity}{login} : undef;
    my $fail  = sub {
        my ($why) = @_;
        Lazysite::Odoo::Session::sign_out( $conn, $r->{session_id} );
        log_event( 'WARN', 'odoo', 'site sign-in refused', why => $why );
        return ( undef, $why );
    };
    return $fail->('Odoo did not say which login this is, so no site sign-in can be made')
        unless Lazysite::Odoo::SiteSignin::login_ok($login);
    {
        no warnings 'once';
        local $Lazysite::Auth::Settings::AUTH_DIR = _lz() . '/auth';
        return $fail->( 'this site has no group that grants manager access, so it is unsecured; '
                . 'the Odoo sign-in can be the site sign-in only on a secured site' )
            unless Lazysite::Auth::Settings::site_grants_manager();
    }
    my $g = site_groups( session_id => $r->{session_id} );

    # Groups that cannot be read are no groups, never a guess: the person is signed in and
    # holds nothing a mapping would give. A session Odoo has already ended is no sign-in.
    return $fail->('your Odoo sign-in has ended - sign in again') if $g->{clear_session};
    no warnings 'once';
    local $Lazysite::Auth::Session::LAZYSITE_DIR = _lz();
    my ($cookie) = Lazysite::Auth::Session::mint_odoo_session(
        login => $login, name => ( $r->{identity}{name} // '' ), groups => ( $g->{ok} ? $g->{groups} : [] ),
        ip => $a{ip}, ua => $a{user_agent} );
    return $fail->( 'a site session cannot be made on this host - the auth secret is missing or the session '
            . 'registry cannot be written; see the event log' )
        unless defined $cookie;
    _site_audit( "odoo:$login", 'login', 'ok', $a{ip}, 'odoo sign-in' );
    return ($cookie);
}

# site_session_renew( session_id =>, site_sid =>, login => ) -> { ok, identity_cookie, name, groups }
#                                                            or { ok => 0, kind, error[, clear_session] }
# The ?csrf=1 refresh (ruling 3): Odoo is asked ONCE whether the session is still the
# person's and which mapped groups they hold; the record is renewed. Odoo having ended the
# session is clear_session - the caller ends the site session.
sub site_session_renew {
    my (%a) = @_;
    my $f = refresh_identity( session_id => $a{session_id} );
    return $f unless $f->{ok};
    my $g = site_groups( session_id => $a{session_id} );
    return $g unless $g->{ok};
    require Lazysite::Auth::Session;
    no warnings 'once';
    local $Lazysite::Auth::Session::LAZYSITE_DIR = _lz();
    return { ok => 0, kind => 'unavailable', error => 'the site session record cannot be renewed' }
        unless Lazysite::Auth::Session::renew_odoo_session( sid => $a{site_sid}, name => $f->{name}, groups => $g->{groups} );
    return { ok => 1, identity_cookie => $f->{identity_cookie}, name => $f->{name}, groups => $g->{groups} };
}

# site_session_end( sid =>, user =>, ip => ): the site session is signed out - its sid
# revoked by the mechanism the manager's Sessions page and the wrapper's logout use.
sub site_session_end {
    my (%a) = @_;
    return 0 unless defined $a{sid} && $a{sid} =~ /\A[0-9a-f]{16}\z/;
    require Lazysite::Manager::Sessions;
    no warnings 'once';
    local $Lazysite::Manager::Sessions::LAZYSITE_DIR = _lz();
    local $Lazysite::Manager::Sessions::auth_user    = $a{user} // '';
    my $r = Lazysite::Manager::Sessions::action_session_revoke( $a{sid} );
    log_event( 'WARN', 'odoo', 'a site session could not be revoked', error => ( $r->{error} // '' ) ) unless $r->{ok};
    _site_audit( $a{user}, 'logout', ( $r->{ok} ? 'ok' : 'fail' ), $a{ip}, $a{why} // 'odoo sign-out' );
    return $r->{ok} ? 1 : 0;
}

# The audit trail's actor for these is `odoo:<login>`: the identity that acted.
sub _site_audit {
    my ( $user, $act, $status, $ip, $detail ) = @_;
    require Lazysite::Audit;
    no warnings 'once';
    local $Lazysite::Audit::LAZYSITE_DIR = _lz();
    ( my $host = lc( $ENV{HTTP_HOST} // '' ) ) =~ s/:\d+\z//;
    $host =~ s/[^a-z0-9.-]//g;
    Lazysite::Audit::audit_log( $user, $act, $host, $ip // '', $status, 'odoo', $detail );
    return;
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
    my ($given) = @_;    # SM1223: the folder an idempotency key makes, else a random one
    require Lazysite::Odoo::Visitor;
    my $pid = $given // Lazysite::Odoo::Visitor::random_hex(16)
        or die Odoo::Error->new( kind => 'config', message => 'no CSPRNG for a plan id' );
    my $dir = plans_dir() . "/$pid";

    # a key's folder that is here while its key is free is a run that was closed:
    # it is replaced, not mixed with the new plan
    if ( defined $given && -d $dir ) {
        require File::Path;
        File::Path::remove_tree($dir);
    }
    make_path( $dir, { mode => 0770 } );
    _prune_plans();
    return ( $pid, $dir );
}

sub _prune_plans {
    my $root = plans_dir();
    _prune_runs();
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

# SM1164 D3: the daemon's run folders (plans it made, journals it kept) go on the
# plans' schedule - a run older than the keep is removed.
sub _prune_runs {
    my $root = store_dir() . '/runs';
    opendir my $dh, $root or return;
    my $cut = time - $PLAN_KEEP_DAYS * 86400;
    for my $e ( grep { !/\A\./ } readdir $dh ) {
        my @st = stat "$root/$e" or next;
        next unless $st[9] < $cut;
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
        ? { map { ( $_ => $conn->{$_} ) } qw(url db login timeout max_kb allow_writes packs pack_dirs) }
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
    $out{scheduled} = _scheduled_status( $have && $conn ? $conn : undef );    # SM1161
     # SM1164 D4: the resident OOM - name, health, version, packs, workers, uptime, and the supervisor's reason when it has given up.
    require Lazysite::Odoo::Daemon;
    $out{daemon} = Lazysite::Odoo::Daemon::status($DOCROOT);
    # SM1160: the Odoo sign-in as the site sign-in - off, or the map as it loaded and
    # the entries refused by name; SM1217: an xml id Odoo does not know is not named,
    # and the report says so (unknown_named, unknown_note)
    require Lazysite::Odoo::SiteSignin;
    $out{site_signin} = Lazysite::Odoo::SiteSignin::report( _lz() );
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
    my $r = _secret_set(@_);
    _daemon_refresh() if ref $r eq 'HASH' && $r->{ok};
    return $r;
}

# SM1164 D1: a key set or cleared is a label that appears in, or leaves, the
# daemon's config. Rewritten and the daemon told; nothing when the daemon is off.
sub _daemon_refresh {
    require Lazysite::Odoo::Daemon;
    return unless -e Lazysite::Odoo::Daemon::conf_path($DOCROOT) || ( ( read_conf() || {} )->{odoo_daemon} // '' ) =~ /\S/;
    eval { Lazysite::Odoo::Daemon::refresh($DOCROOT) };
    return;
}

sub _secret_set {
    my ( $secret, %o ) = @_;
    require Lazysite::Odoo::Secret;
    no warnings 'once';
    local $Lazysite::Odoo::Secret::DOCROOT = $DOCROOT;
    my $grant = $o{grant} // '';
    my $sched = $o{scheduled} // '';
    return { ok => 0, kind => 'invalid', field => 'scheduled',
        error => 'grant and scheduled name different accounts - set one at a time' }
        if length $grant && length $sched;
    return _set_scheduled_key( $sched, $o{login}, $secret ) if length $sched;
    return _set_grant_key( $grant, $o{login}, $secret ) if length $grant;
    my ( $ok, $why ) = Lazysite::Odoo::Secret::set_key( $ACCOUNT, $secret );
    return { ok => 0, kind => 'invalid', field => 'secret', error => $why } unless $ok;
    return { ok => 1, has_secret => 1 };
}

sub action_odoo_secret_clear {
    my $r = _secret_clear(@_);
    _daemon_refresh() if ref $r eq 'HASH' && $r->{ok};
    return $r;
}

sub _secret_clear {
    my (%o) = @_;
    require Lazysite::Odoo::Secret;
    no warnings 'once';
    local $Lazysite::Odoo::Secret::DOCROOT = $DOCROOT;
    my $grant = $o{grant} // '';
    my $sched = $o{scheduled} // '';
    return { ok => 0, kind => 'invalid', field => 'scheduled',
        error => 'grant and scheduled name different accounts - clear one at a time' }
        if length $grant && length $sched;
    return _clear_scheduled_key($sched) if length $sched;
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
sub read_grants { return _read_map( grants_file(), 'the Odoo grant accounts' ) }

sub _read_map {
    my ( $f, $what ) = @_;
    open my $fh, '<:raw', $f or do {
        return {} if $!{ENOENT};
        cannot_read( $what, $f );
        return undef;
    };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $d = eval { JSON::PP::decode_json( $raw // '' ) };
    return ref $d eq 'HASH' ? $d : undef;
}

sub _write_grants { return _write_map( $_[0], grants_file(), 'odoo/grants.json' ) }

sub _write_map {
    my ( $all, $f, $name ) = @_;
    my $dir = store_dir();
    eval { make_path($dir) unless -d $dir; 1 } or return ( 0, 'cannot make the Odoo store' );
    open my $fh, '>:raw', "$f.tmp.$$" or return ( 0, "cannot write $name: $!" );
    print {$fh} JSON::PP->new->canonical->pretty->encode($all);
    close $fh or return ( 0, "cannot write $name: $!" );
    secure_write_perms( "$f.tmp.$$", 0660 );
    rename "$f.tmp.$$", $f or return ( 0, "cannot write $name: $!" );
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

# --- SM1161 (L5): an Odoo login per SCHEDULED binding ----------------------------
#
# Release manager, 2026-10-18: "Scheduled keys now, person keys later". A
# scheduled binding runs as the connection user unless the operator sets a
# named Odoo login and its API key for THAT binding. lazysite/odoo/scheduled.json
# maps the binding to { id, login } - the id of its key file, derived from the
# binding as a grant's is, so the key is held by the same writer and reader
# (Lazysite::Odoo::Secret): its own 0600 file, written alone, never returned.
# The map holds no secret.
#
# lazysite/odoo/scheduled-expiry.json is what odoo-status last read of each key's
# expiry, so `lazysite check` can warn without a network call. It holds dates,
# never a key.

sub scheduled_file        { return store_dir() . '/scheduled.json' }
sub scheduled_expiry_file { return store_dir() . '/scheduled-expiry.json' }

sub _scheduled_id {
    my ($binding) = @_;
    require Digest::SHA;
    return 'sched-' . substr( Digest::SHA::sha256_hex("scheduled|$binding"), 0, 16 );
}

sub read_scheduled { return _read_map( scheduled_file(), 'the Odoo scheduled-binding accounts' ) }

# ( \%binding, '' ) when $id names an Odoo binding that may run on the schedule.
# Switched off is allowed: an operator sets the key before switching it on.
sub _scheduled_binding {
    my ($id) = @_;
    return ( undef, 'scheduled must be a binding id' )
        unless defined $id && $id =~ /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/;
    require Lazysite::Handlers;
    require Lazysite::Odoo::Binding;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $DOCROOT;
    my $all = Lazysite::Handlers::read_handlers();
    return ( undef, 'the handler store cannot be read - see the event log' ) unless defined $all;
    my $h = Lazysite::Handlers::find_handler( $all, $id );
    return ( undef, "no Odoo binding '$id'" ) unless $h && ( $h->{type} // '' ) eq 'odoo';
    my ($b) = Lazysite::Odoo::Binding::parse($h);
    return ( undef, "the Odoo binding '$id' cannot be used" ) unless $b;
    return ( undef, "the Odoo binding '$id' does not run on the schedule (modes: scheduled)" )
        unless $b->{modes}{scheduled};
    return ( $b, '' );
}

sub _set_scheduled_key {
    my ( $id, $login, $secret ) = @_;
    my ( $b, $bwhy ) = _scheduled_binding($id);
    return { ok => 0, kind => 'invalid', field => 'scheduled', error => $bwhy } unless $b;
    return { ok => 0, kind => 'invalid', field => 'login',
        error => 'login is required with scheduled - the Odoo login this binding runs as' }
        unless defined $login && length $login;
    return { ok => 0, kind => 'invalid', field => 'login', error => 'login must be one line of at most 128 characters' }
        if length $login > 128 || $login =~ /[\r\n]/;
    my $all = read_scheduled();
    return { ok => 0, error => 'the scheduled accounts exist and cannot be read - nothing was written' }
        unless defined $all;
    my $kid = _scheduled_id($id);
    my ( $ok, $why ) = Lazysite::Odoo::Secret::set_key( $kid, $secret );
    return { ok => 0, kind => 'invalid', field => 'secret', error => $why } unless $ok;
    $all->{$id} = { id => $kid, login => $login };
    my ( $wok, $wwhy ) = _write_map( $all, scheduled_file(), 'odoo/scheduled.json' );
    return { ok => 0, error => $wwhy } unless $wok;
    _forget_expiry($id);    # a new key: what was read of the old one says nothing of it
    log_event( 'INFO', 'odoo', 'odoo scheduled account set', binding => $id, login => $login );
    return { ok => 1, binding => $id, login => $login, has_secret => 1 };
}

sub _clear_scheduled_key {
    my ($id) = @_;
    return { ok => 0, kind => 'invalid', field => 'scheduled', error => 'scheduled must be a binding id' }
        unless $id =~ /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/;
    my $all = read_scheduled();
    return { ok => 0, error => 'the scheduled accounts exist and cannot be read - nothing was removed' }
        unless defined $all;
    my ( $ok, $why ) = Lazysite::Odoo::Secret::clear_key( _scheduled_id($id) );
    return { ok => 0, error => $why } unless $ok;
    if ( exists $all->{$id} ) {
        delete $all->{$id};
        my ( $wok, $wwhy ) = _write_map( $all, scheduled_file(), 'odoo/scheduled.json' );
        return { ok => 0, error => $wwhy } unless $wok;
    }
    _forget_expiry($id);
    log_event( 'INFO', 'odoo', 'odoo scheduled account cleared', binding => $id );
    return { ok => 1, binding => $id, has_secret => 0 };
}

# The account a scheduled run uses: ( { id, login, kind }, '' ), ( undef, '' )
# when the binding has none (it runs as the connection user), or ( undef, why )
# when the map cannot be read.
sub account_for_scheduled {
    my ($binding) = @_;
    my $all = read_scheduled();
    return ( undef, 'the Odoo scheduled accounts cannot be read - see the event log' ) unless defined $all;
    my $g = $all->{ $binding // '' } or return ( undef, '' );
    return ( { id => $g->{id}, login => $g->{login}, source => 'scheduled' }, '' );
}

# What odoo-status last read of each key's expiry, { binding => { login, key,
# read_at, expires_by } }; {} when none, undef when the file cannot be read.
sub read_expiry_cache { return _read_map( scheduled_expiry_file(), 'the Odoo scheduled-key expiry record' ) }

sub _forget_expiry {
    my ($id) = @_;
    my $c = read_expiry_cache() // return;
    return unless exists $c->{$id};
    delete $c->{$id};
    _write_map( $c, scheduled_expiry_file(), 'odoo/scheduled-expiry.json' );
    return;
}

# An Odoo date-time ('YYYY-MM-DD HH:MM:SS', UTC) as epoch seconds, undef when it
# is not one.
sub _odoo_epoch {
    my ($t) = @_;
    return undef unless defined $t && !ref $t && $t =~ /\A(\d{4})-(\d\d)-(\d\d)(?:[ T](\d\d):(\d\d):(\d\d))?/;
    require Time::Local;
    my $e = eval { Time::Local::timegm( $6 // 0, $5 // 0, $4 // 0, $3, $2 - 1, $1 ) };
    return $e;
}

# What OOM reports of the expiry of the key a scheduled binding holds, asked of
# Odoo as that login (OOM's core.whoami lists the login's own key rows with
# `expiration_date` on the series that give a key a date). OOM does NOT say which
# of the rows is the key in use, so the answer is exact only when the login has a
# single key row:
#
#   exact          one row: its date (or 'never')
#   latest-of      several rows, all dated: the held key expires by the latest
#   unknown-which  several rows, one with no date: nothing can be said
#   not-reported   this Odoo series gives a key no date
#   unreadable     Odoo refused this login the read of its own keys
#   failed         the question could not be put (the cause is in the event log)
#
# ( { expiry, keys, expires, epoch } ) - `epoch` is set only where a date can be
# stood behind, and is what `lazysite check` warns on.
sub _read_key_expiry {
    my ( $conn, $account ) = @_;
    my $r = eval {
        my ($class) = operation_class( $conn, 'core.whoami' );
        return { expiry => 'failed' } unless $class;
        my $ctx = context( _as_account( $conn, $account ), actor => 'odoo-status' );
        return $class->new( ctx => $ctx, params => {} )->run;
    };
    if ( !ref $r || ref $r ne 'HASH' ) {
        log_event( 'WARN', 'odoo', 'a scheduled key\'s expiry could not be read',
            detail => ( ref $@ && eval { $@->can('message') } ? $@->message : "$@" ) =~ s/\s+\z//r );
        return { expiry => 'failed' };
    }
    return $r if $r->{expiry};
    return { expiry => 'unreadable' } unless $r->{keys_readable};
    my @rows = @{ $r->{keys} || [] };
    return { expiry => 'failed', keys => 0 } unless @rows;
    return { expiry => 'not-reported', keys => scalar @rows } unless grep { exists $_->{expiration_date} } @rows;
    my @dates = map { $_->{expiration_date} ? $_->{expiration_date} : undef } @rows;
    if ( @rows == 1 ) {
        return { expiry => 'exact', keys => 1, expires => 'never' } unless defined $dates[0];
        return { expiry => 'exact', keys => 1, expires => $dates[0], epoch => _odoo_epoch( $dates[0] ) };
    }
    return { expiry => 'unknown-which', keys => scalar @rows } if grep { !defined } @dates;
    my ($latest) = sort { $b cmp $a } @dates;
    return { expiry => 'latest-of', keys => scalar @rows, expires => $latest, epoch => _odoo_epoch($latest) };
}

# The scheduled keys as odoo-status shows them: binding, login, has_secret (1, 0
# or null) and the expiry as OOM reports it - never the key. Where a key is held
# and the connection can be asked, the expiry is read now and recorded for
# `lazysite check`.
sub _scheduled_status {
    my ($conn) = @_;
    my $all = read_scheduled();
    return undef unless defined $all;
    my $cache = read_expiry_cache();
    my $dirty = 0;
    my @rows;
    for my $id ( sort keys %$all ) {
        my $g   = $all->{$id};
        my $has = Lazysite::Odoo::Secret::has_key( $g->{id} );
        my %row = ( binding => $id, login => $g->{login}, has_secret => $has );
        if ( $has && $conn ) {
            my $e = _read_key_expiry( $conn, { id => $g->{id}, login => $g->{login}, source => 'scheduled' } );
            @row{qw(expiry keys expires)} = @$e{qw(expiry keys expires)};
            delete $row{$_} for grep { !defined $row{$_} } qw(keys expires);
            if ( ref $cache eq 'HASH' ) {
                my %old = ref $cache->{$id} eq 'HASH' ? %{ $cache->{$id} } : ();
                my $new = { login => $g->{login}, key => $g->{id}, read_at => time, expiry => $e->{expiry},
                    ( defined $e->{epoch} ? ( expires_by => $e->{epoch}, expires => $e->{expires} ) : () ) };
                $cache->{$id} = $new;
                $dirty = 1;
            }
        }
        push @rows, \%row;
    }
    if ( ref $cache eq 'HASH' ) {
        for my $id ( grep { !exists $all->{$_} } keys %$cache ) { delete $cache->{$id}; $dirty = 1 }
        _write_map( $cache, scheduled_expiry_file(), 'odoo/scheduled-expiry.json' ) if $dirty;
    }
    return \@rows;
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
    return { %$conn, login => $account->{login}, key_account => $account->{id},
        ( $account->{source} ? ( key_kind => $account->{source} ) : () ) };
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
