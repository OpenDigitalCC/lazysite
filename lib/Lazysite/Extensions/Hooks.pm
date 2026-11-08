package Lazysite::Extensions::Hooks;

# SM1369 X1 (ruling 55): HOW CORE FINDS AN EXTENSION'S HOOKS, AND RUNS ONE.
#
# An extension tells core what it needs through its descriptor, never through a
# line in core that knows it by name (t/lint/321). The descriptor's `owns`
# carries a `hooks` map and a `requires` list; this module validates both, reads
# the hook index the manager writes from them, and loads and calls a hook's
# function. The design is tmp/proposal-extension-hooks.md, "How a hook is found
# and run" and "The security model".
#
# THE ORDER IS THE SECURITY MODEL:
#
#   1. A declaration is VALIDATED before anything is indexed (validate_hooks,
#      validate_requires, through Owns::validate_owns). An unknown hook is
#      refused by name, and so is a known hook whose consumer this engine does
#      not have yet: a declaration nothing calls would read as working.
#   2. The INDEX (lazysite/extensions.index.json) is written by the manager when
#      an extension is enabled, disabled, saved or upgraded, from the
#      descriptors of the enabled extensions. The request path reads that one
#      file, cached per process; it never runs --describe (lint 76's rule).
#   3. A hook's function is LOADED lazily, only when it is called, only from the
#      extension's own payload lib (extensions/<stem>/lib), and only while the
#      extension, and every extension it requires, is enabled - checked again
#      at the call, so an index left behind by a failed write cannot run a
#      disabled extension (G-1).
#   4. A hook that cannot be loaded, or dies, FAILS CLOSED: the caller gets
#      ( 0, $why ) and decides the safe answer (signed out, empty, failed
#      delivery, not wanted - G-9).
#
# WHAT THIS DOES NOT CLAIM. An extension is Perl running as the site user. In
# process these rules are a contract, not a sandbox (the proposal's "What the
# model does not claim"): trust comes from what is installed, and ADR 0009 keeps
# out-of-tree extensions aside until a signing story exists.
#
# X1 WIRES NO HOOK. Every kind below is named so a declaration can be refused
# by name, and each says the slice that builds its consumer; until then it is
# not live and a declaration of it is refused. A slice makes its kind live in
# the same change that adds the code calling it.

use strict;
use warnings;
use Exporter 'import';
use Cwd                  ();
use Time::HiRes          ();
use JSON::PP             ();
use Lazysite::Paths      ();
use Lazysite::Extensions ();

our @EXPORT_OK = qw(validate_hooks validate_requires hook_kinds hook_functions
    check_functions index_path read_index enabled_keys call_hook
    declared_entry mirror mirror_index unmirror mirror_state index_signature
    index_failed_path note_index_failure declared_refusal_status
    cross_problems page_sources handler_types check_payload_files names_payload_files
    identity_provider identity_providers);

# The hook vocabulary. `hook` is the proposal's H-n, `slice` the slice that
# builds its consumer. A live kind carries its shape:
#
#   form       functions - a list of function names
#              record    - one map
#              records   - a list of maps
#              named     - a map of names to maps (SM1369 X3), each name
#                          matching the kind's `name` pattern
#   functions  the keys of a map whose values are function names
#   fields     the other keys a map may carry, each a plain value
#   lists      keys whose value is a list of plain values (X3)
#   tables     keys whose value is a list of maps of plain values (X3)
#   required   the keys a map must carry
#   check      a function run over the whole declaration once its shape is
#              sound, for the kind's own vocabulary (X3); returns problems
#   check_values  a function ( id, kind, value ) run once the declaration has no
#              problem, for the values a record names (X5: a file, an
#              attribute, a path); returns problems
#
# The names of the kinds that are not live are the proposal's; a slice may
# rename its kind before making it live, since nothing can declare it until then.
our %KINDS = (
    # SM1369 X4 (n781): H-1 is live - its consumer is Lazysite::Auth::Session
    # (the provider session: mint, renew, verify), with the sign-in page, the
    # login options and the banner in the processor. See "X4" below.
    identity_provider => {
        hook         => 'H-1', slice => 'X4', live => 1, form => 'record',
        functions    => [qw(on still_valid groups login_option banner)],
        fields       => [qw(renew signin_page grants)],
        required     => [qw(on still_valid groups)],
        check_values => \&_check_identity_provider,
    },

    # SM1369 X3 (n769): H-2 and H-3 are live - their consumers are
    # lazysite-processor/sources.pm, Lazysite::Validate and Lazysite::Handlers.
    # The vocabulary each record may use is checked by the X3 block below.
    page_sources => {
        hook      => 'H-2', slice => 'X3', live => 1, form => 'records',
        functions => [qw(resolve check)],
        fields    => [qw(prefix per_viewer live read_only)],
        required  => [qw(prefix resolve read_only)],
        check     => \&_check_page_sources,
    },
    handler_types => {
        hook      => 'H-3', slice => 'X3', live => 1, form => 'named',
        name      => qr/\A[a-z][a-z0-9_]{0,31}\z/,
        functions => [qw(parse on_save on_delete deliver)],
        fields    => [qw(label cap note)],
        lists     => [qw(origins)],
        tables    => [qw(schema)],
        required  => [qw(label cap origins schema deliver)],
        check     => \&_check_handler_types,
    },
    endpoints         => { hook => 'H-4',  slice => 'X5' },
    services          => { hook => 'H-5',  slice => 'X5' },
    checks            => { hook => 'H-6',  slice => 'X6' },
    # SM1369 X2: the three kinds whose consumers are built (see "X2" below). A
    # kind with a `validate` of its own is checked by it, since its rows carry
    # lists and maps the generic shapes above cannot say.
    capability_info => { hook => 'H-7', slice => 'X2', live => 1, form => 'record', validate => \&_validate_capability_info },
    panels            => { hook => 'H-8',  slice => 'X6' },
    api_actions => { hook => 'H-9', slice => 'X2', live => 1, form => 'records', functions => ['handler'],
        validate => \&_validate_api_actions },
    refusal_kinds => { hook => 'H-9', slice => 'X2', live => 1, form => 'record', validate => \&_validate_refusal_kinds },

    # SM1369 X5, the asset part of H-10 (n770). LIVE: the processor serves a
    # declared asset from the extension's payload at /assets/<id>-<file> (and at
    # its alias), adds it to a page whose rendered markup carries the attribute
    # `inject_when` names, finds a declared component in the payload's
    # templates/components, and gives a layout each declared template variable,
    # rendered by its function when a template asks for it. `attrs` is a
    # function returning the data attributes the injected script tag carries.
    # Every file a declaration names must be in the payload (check_payload_files).
    assets => { hook => 'H-10', slice => 'X5', live => 1, form => 'records', check_values => \&_check_assets,
        functions => [qw(attrs)], fields => [qw(file inject_when alias)], required => [qw(file)] },
    components => { hook => 'H-10', slice => 'X5', live => 1, form => 'records', check_values => \&_check_components,
        fields => [qw(file)], required => [qw(file)] },
    template_vars => { hook => 'H-10', slice => 'X5', live => 1, form => 'records', check_values => \&_check_template_vars,
        functions => [qw(render)], fields => [qw(name)], required => [qw(name render)] },

    system_pages      => { hook => 'H-10', slice => 'X5' },
    docs              => { hook => 'H-10', slice => 'X5' },
    tests             => { hook => 'H-12', slice => 'X7' },
);

sub hook_kinds { my @k = sort keys %KINDS; return @k }

# The file the manager writes and the request path reads, under the site's
# lazysite/ tree.
our $INDEX_FILE = 'extensions.index.json';

sub index_path {
    my ($lz) = @_;
    return "$lz/$INDEX_FILE";
}

sub _err {
    my ( $id, $key, $why ) = @_;
    return { extension => $id, key => $key, error => $why };
}

# A function a hook names: a fully qualified Perl name, its module and the
# function. Never a name in main::, CORE:: or UNIVERSAL::, never a name Perl
# calls by itself (import, DESTROY, a phase block), never an inner `'`.
my %RESERVED = map { $_ => 1 } qw(import unimport can isa VERSION DESTROY AUTOLOAD);

sub parse_function {
    my ($name) = @_;
    return () unless defined $name && !ref $name;
    return () unless $name =~ m{\A ( [A-Z][A-Za-z0-9_]* (?: :: [A-Za-z_][A-Za-z0-9_]* )* ) :: ( [a-z_][a-z0-9_]* ) \z}x;
    my ( $module, $fn ) = ( $1, $2 );
    return () if $module =~ /\A(?:main|CORE|UNIVERSAL|SUPER)(?:::|\z)/;
    return () if $RESERVED{$fn};
    return ( $module, $fn );
}

sub _plain {
    my ($v) = @_;
    return defined $v && !ref $v ? 1 : 0;
}

# One map of a live kind: its functions, its fields, nothing else.
sub _validate_map {
    my ( $id, $kind, $spec, $m, $where ) = @_;
    return ( _err( $id, "hooks.$kind", "$where must be a mapping" ) ) unless ref $m eq 'HASH';
    my %fn  = map { $_ => 1 } @{ $spec->{functions} || [] };
    my %fld = map { $_ => 1 } @{ $spec->{fields}    || [] };
    my %lst = map { $_ => 1 } @{ $spec->{lists}     || [] };
    my %tbl = map { $_ => 1 } @{ $spec->{tables}    || [] };
    my @bad;
    for my $k ( sort keys %$m ) {
        if ( $fn{$k} ) {
            push @bad, _err( $id, "hooks.$kind", "$where.$k names no function - it must be a "
                    . 'fully qualified name, Module::Name::function' )
                unless parse_function( $m->{$k} );
        }
        elsif ( $fld{$k} ) {
            push @bad, _err( $id, "hooks.$kind", "$where.$k must be a plain value" )
                unless _plain( $m->{$k} );
        }
        elsif ( $lst{$k} ) {
            push @bad, _err( $id, "hooks.$kind", "$where.$k must be a list of plain values" )
                unless ref $m->{$k} eq 'ARRAY' && !grep { !_plain($_) } @{ $m->{$k} };
        }
        elsif ( $tbl{$k} ) {
            push @bad, _err( $id, "hooks.$kind", "$where.$k must be a list of mappings of plain values" )
                unless ref $m->{$k} eq 'ARRAY'
                && !grep { ref $_ ne 'HASH' || grep { !_plain($_) } values %$_ } @{ $m->{$k} };
        }
        else {
            push @bad, _err( $id, "hooks.$kind", "unknown key '$k' in $where (expected: "
                    . join( ', ', sort( keys %fn, keys %fld, keys %lst, keys %tbl ) ) . ')' );
        }
    }
    for my $k ( @{ $spec->{required} || [] } ) {
        push @bad, _err( $id, "hooks.$kind", "$where must carry '$k'" ) unless exists $m->{$k};
    }
    return @bad;
}

# Returns a LIST of problems, in Owns' shape - empty when the declaration is
# sound. Every problem at once, as Owns does, for a lint or a sysop.
sub validate_hooks {
    my ( $id, $hooks ) = @_;
    return ( _err( $id, 'hooks', 'hooks must be a mapping' ) ) unless ref $hooks eq 'HASH';
    my @bad;
    for my $kind ( sort keys %$hooks ) {
        my $spec   = $KINDS{$kind};
        my $before = @bad;
        unless ($spec) {
            push @bad, _err( $id, "hooks.$kind",
                "unknown hook '$kind' (known: " . join( ', ', hook_kinds() ) . ')' );
            next;
        }
        unless ( $spec->{live} ) {
            push @bad, _err( $id, "hooks.$kind",
                "hook '$kind' ($spec->{hook}) is not built in this engine yet - it lands in slice "
                    . "$spec->{slice}, and nothing would call it, so it is refused rather than ignored" );
            next;
        }
        my $v    = $hooks->{$kind};
        my $form = $spec->{form} // '';
        if ( $spec->{validate} ) {
            push @bad, $spec->{validate}->( $id, $v );
        }
        elsif ( $form eq 'functions' ) {
            if ( ref $v ne 'ARRAY' ) {
                push @bad, _err( $id, "hooks.$kind", "$kind must be a list of function names" );
                next;
            }
            for my $i ( 0 .. $#$v ) {
                push @bad, _err( $id, "hooks.$kind", "$kind\[$i\] names no function - it must be a "
                        . 'fully qualified name, Module::Name::function' )
                    unless parse_function( $v->[$i] );
            }
        }
        elsif ( $form eq 'record' ) {
            push @bad, _validate_map( $id, $kind, $spec, $v, $kind );
        }
        elsif ( $form eq 'records' ) {
            if ( ref $v ne 'ARRAY' ) {
                push @bad, _err( $id, "hooks.$kind", "$kind must be a list of mappings" );
                next;
            }
            my @shape = map { _validate_map( $id, $kind, $spec, $v->[$_], "$kind\[$_\]" ) } 0 .. $#$v;
            push @bad, @shape;
            push @bad, $spec->{check}->( $id, $v ) if !@shape && $spec->{check};
        }
        elsif ( $form eq 'named' ) {
            if ( ref $v ne 'HASH' ) {
                push @bad, _err( $id, "hooks.$kind", "$kind must be a mapping of names to mappings" );
                next;
            }
            my @shape;
            for my $n ( sort keys %$v ) {
                if ( $spec->{name} && $n !~ $spec->{name} ) {
                    push @shape, _err( $id, "hooks.$kind", "'$n' is not a name $kind may use" );
                    next;
                }
                push @shape, _validate_map( $id, $kind, $spec, $v->{$n}, "$kind.$n" );
            }
            push @bad, @shape;
            push @bad, $spec->{check}->( $id, $v ) if !@shape && $spec->{check};
        }
        else {
            push @bad, _err( $id, "hooks.$kind", "hook '$kind' has no shape in this engine" );
        }
        # A kind may check its values beyond their shape (a file name, an
        # attribute, a path), once the shape is sound.
        push @bad, $spec->{check_values}->( $id, $kind, $v ) if $spec->{check_values} && @bad == $before;
    }
    return @bad;
}

# ---- SM1369 X3 (n769): the vocabulary of page sources and handler types ----
#
# The shape above says a record carries the right keys; this says what the
# values may be, so a declaration that core could not use is refused at the
# build, by name, and never indexed (the X1 rule: nothing runs that was not
# checked first).

# The prefixes the processor resolves itself (lazysite-processor/sources.pm,
# resolve_tt_vars, tested before it asks the index) - a source cannot take one.
our @CORE_SOURCE_PREFIXES = qw(scan db json url schedule);    # schedule: SM1356 (n773)

# Where core delivers a handler from: a form's submission
# (extensions/form-handler.pl) and the scheduler's timer (Daemon::Jobs). A type
# names the origins it accepts; a delivery from any other is refused by core
# before the type's own code runs.
our @HANDLER_ORIGINS = qw(form timer);

sub _check_page_sources {
    my ( $id, $list ) = @_;
    my ( @bad, %seen );
    my %core = map { $_ => 1 } @CORE_SOURCE_PREFIXES;
    for my $i ( 0 .. $#$list ) {
        my $s = $list->[$i];
        my $p = $s->{prefix};
        my $w = "page_sources[$i]";
        push @bad, _err( $id, 'hooks.page_sources',
            "$w.prefix '$p' is not a source prefix: lower-case letters, digits and hyphens, no trailing colon" )
            unless defined $p && $p =~ /\A[a-z][a-z0-9-]{0,31}\z/;
        next unless defined $p;
        push @bad, _err( $id, 'hooks.page_sources', "$w.prefix '$p' is the engine's own" ) if $core{ lc $p };
        push @bad, _err( $id, 'hooks.page_sources', "$w.prefix '$p' is declared twice" ) if $seen{ lc $p }++;
        push @bad, _err( $id, 'hooks.page_sources', "$w.read_only must be 1 - a page source is a read" )
            unless ( $s->{read_only} // '' ) eq '1';
        for my $k (qw(per_viewer live)) {
            push @bad, _err( $id, 'hooks.page_sources', "$w.$k must be 0 or 1" )
                if exists $s->{$k} && ( $s->{$k} // '' ) !~ /\A[01]\z/;
        }
    }
    return @bad;
}

sub _check_handler_types {
    my ( $id, $map ) = @_;
    require Lazysite::Handlers;
    require Lazysite::Auth::Settings;
    my %core_type = map { $_ => 1 } Lazysite::Handlers::core_types(), Lazysite::Handlers::retired_types();
    my %field  = map { $_ => 1 } Lazysite::Handlers::field_types();
    my %origin = map { $_ => 1 } @HANDLER_ORIGINS;
    no warnings 'once';
    my %cap = map { $_ => 1 } @Lazysite::Auth::Settings::CAP_KEYS;
    my @bad;
    for my $t ( sort keys %$map ) {
        my $d = $map->{$t};
        my $w = "handler_types.$t";
        push @bad, _err( $id, 'hooks.handler_types', "$w: '$t' is a handler type the engine owns" )
            if $core_type{$t};
        push @bad, _err( $id, 'hooks.handler_types', "$w.cap '" . ( $d->{cap} // '' ) . "' is not a capability"
                . ' - a type runs only under a capability the engine or its extension declares' )
            unless $cap{ $d->{cap} // '' };
        push @bad, _err( $id, 'hooks.handler_types', "$w.label must be one line of at most 80 characters" )
            unless defined $d->{label} && length $d->{label} && length $d->{label} <= 80 && $d->{label} !~ /[\r\n]/;
        push @bad, _err( $id, 'hooks.handler_types', "$w.origins must name at least one of: "
                . join( ', ', @HANDLER_ORIGINS ) )
            unless @{ $d->{origins} };
        push @bad, _err( $id, 'hooks.handler_types', "$w.origins: '$_' is not an origin (the origins are: "
                . join( ', ', @HANDLER_ORIGINS ) . ')' )
            for grep { !$origin{$_} } @{ $d->{origins} };
        my %key;
        for my $i ( 0 .. $#{ $d->{schema} } ) {
            my $f = $d->{schema}[$i];
            my $k = $f->{key} // '';
            push @bad, _err( $id, 'hooks.handler_types', "$w.schema[$i].key '$k' is not a field key" )
                unless $k =~ /\A[a-z][a-z0-9_]{0,63}\z/;
            push @bad, _err( $id, 'hooks.handler_types', "$w.schema[$i].key '$k' is a key every handler carries" )
                if $k =~ /\A(?:id|type|name|enabled|domain|csrf_token)\z/;
            push @bad, _err( $id, 'hooks.handler_types', "$w.schema[$i].key '$k' is declared twice" ) if $key{$k}++;
            push @bad, _err( $id, 'hooks.handler_types', "$w.schema[$i].type '" . ( $f->{type} // '' )
                    . "' is not a field type (the types are: " . join( ', ', Lazysite::Handlers::field_types() ) . ')' )
                unless $field{ $f->{type} // '' };
            push @bad, _err( $id, 'hooks.handler_types', "$w.schema[$i] must carry a label" )
                unless defined $f->{label} && length $f->{label};
            push @bad, _err( $id, 'hooks.handler_types', "$w.schema[$i].slot must be allow, deny or match" )
                if exists $f->{slot} && ( $f->{slot} // '' ) !~ /\A(?:allow|deny|match)\z/;
        }
    }
    return @bad;
}

# WHAT TWO EXTENSIONS CANNOT BOTH DECLARE. Run by the index build over the
# entries that passed their own validation, in id order: the later extension
# loses the clash and is left out, named, so a prefix or a type name has one
# owner, as a config key does. Returns ( id => [ problems ] ) for the losers.
sub cross_problems {
    my ($entries) = @_;
    my ( %owner, %bad );
    for my $id ( sort keys %$entries ) {
        my $hooks = $entries->{$id}{hooks} || {};
        for my $s ( @{ ref $hooks->{page_sources} eq 'ARRAY' ? $hooks->{page_sources} : [] } ) {
            my $p = lc( $s->{prefix} // '' );
            if ( my $o = $owner{"source:$p"} ) {
                push @{ $bad{$id} }, "the page source prefix '$p' is already declared by the extension '$o'";
            }
            else { $owner{"source:$p"} = $id }
        }
        for my $t ( sort keys %{ ref $hooks->{handler_types} eq 'HASH' ? $hooks->{handler_types} : {} } ) {
            if ( my $o = $owner{"type:$t"} ) {
                push @{ $bad{$id} }, "the handler type '$t' is already declared by the extension '$o'";
            }
            else { $owner{"type:$t"} = $id }
        }
        # X4: a sign-in page has one provider.
        my $ip = ref $hooks->{identity_provider} eq 'HASH' ? $hooks->{identity_provider} : {};
        if ( defined( my $p = $ip->{signin_page} ) ) {
            if ( my $o = $owner{"signin:$p"} ) {
                push @{ $bad{$id} }, "the sign-in page '$p' is already declared by the extension '$o'";
            }
            else { $owner{"signin:$p"} = $id }
        }
    }
    return %bad;
}

# ---- SM1369 X4 (n781, H-1): an identity provider ----
#
# A provider is an extension that signs a person in by its own means and asks
# core for a session. The provider's id is the extension's id, and it is the
# session's prefix: the cookie's user field is `<id>=<login>` and the identity
# `<id>:<login>` (Lazysite::Auth::Session). Core signs the cookie and writes the
# record; the provider never sees the key (G-2). The declaration:
#
#   on            ( ctx ) -> 1|0: is the provider's sign-in on for this site
#   still_valid   ( ctx, record ) -> 'ok' | 'stale': is the record fresh enough
#   groups        ( ctx, record ) -> [ groups ]: the record's groups the provider
#                 still grants now (its current map)
#   login_option  ( ctx ) -> { label, path }: what /login offers, optional
#   banner        ( ctx ) -> markup: the `signin_banner` variable, optional
#   renew         the same-site path (with a query) a stale session is renewed at
#   signin_page   a system page name (`/<name>`) served while `on` says so, and
#                 exempt from maintenance
#   grants        1 when the provider's groups may carry capabilities (ruling 186:
#                 an OIDC provider); absent or 0, core refuses any group that
#                 carries one (G-3), the rule Odoo's map always had
#
# ctx is { docroot, lazysite_dir }. Any function that cannot be called, dies or
# answers something else fails closed: the session is not accepted.
our @CORE_SYSTEM_PAGES = qw(login claim forgot logout account maintenance 402 403 404);

my $SAME_SITE_QUERY_PATH = qr{\A/[\w/.-]*\?[\w=&]+\z};

sub _check_identity_provider {
    my ( $id, $kind, $v ) = @_;
    my @bad;
    my %core = map { $_ => 1 } @CORE_SYSTEM_PAGES;
    push @bad, _err( $id, "hooks.$kind", "the provider's id is the extension's id, and '"
            . ( $id // '' ) . "' is not one a session can carry (lower-case letters, digits, hyphens, at most 32)" )
        unless defined $id && $id =~ /\A[a-z][a-z0-9-]{0,31}\z/;
    if ( exists $v->{renew} ) {
        push @bad, _err( $id, "hooks.$kind", 'identity_provider.renew must be a path on this site with a query (/path?a=b)' )
            unless defined $v->{renew} && $v->{renew} =~ $SAME_SITE_QUERY_PATH && $v->{renew} !~ m{//};
    }
    if ( exists $v->{signin_page} ) {
        my $p = $v->{signin_page};
        if ( !defined $p || $p !~ /\A[a-z][a-z0-9-]{0,63}\z/ ) {
            push @bad, _err( $id, "hooks.$kind", 'identity_provider.signin_page must be a page name: lower-case letters, digits, hyphens' );
        }
        elsif ( $core{$p} ) {
            push @bad, _err( $id, "hooks.$kind", "identity_provider.signin_page '$p' is one of the engine's own pages" );
        }
    }
    push @bad, _err( $id, "hooks.$kind", 'identity_provider.grants must be 0 or 1' )
        if exists $v->{grants} && ( $v->{grants} // '' ) !~ /\A[01]\z/;
    return @bad;
}

# THE PROVIDER A SESSION PREFIX NAMES, from the index of the ENABLED
# extensions: { %declaration, extension => $id, key => conf key } or undef.
# Whether it is on NOW is enabled_keys' answer, asked again here, so a
# provider whose extension was turned off mints and verifies nothing (G-1).
sub identity_provider {
    my ( $lz, $id ) = @_;
    return undef unless defined $lz && defined $id && $id =~ /\A[a-z][a-z0-9-]{0,31}\z/;
    my $e = read_index($lz)->{extensions}{$id};
    return undef unless ref $e eq 'HASH' && ref $e->{hooks} eq 'HASH' && ref $e->{hooks}{identity_provider} eq 'HASH';
    my $on = enabled_keys($lz);
    return undef unless $on->{ $e->{key} // '' };
    return undef if grep { !$on->{$_} } @{ ref $e->{requires_keys} eq 'ARRAY' ? $e->{requires_keys} : [] };
    return { %{ $e->{hooks}{identity_provider} }, extension => $id, key => $e->{key} };
}

# Every provider the index declares, enabled now, in id order.
sub identity_providers {
    my ($lz) = @_;
    my @out;
    for my $id ( sort keys %{ read_index($lz)->{extensions} } ) {
        my $p = identity_provider( $lz, $id ) or next;
        push @out, $p;
    }
    return @out;
}

# THE SOURCES THE INDEX DECLARES, for the processor and the validator: one
# record per prefix, the longest prefix first (so `odoo-identity` is tried
# before `odoo`), each carrying the extension that owns it. An index that lists
# a clash (one written by an older engine) keeps the first by id, as the build
# does.
sub page_sources {
    my ($lz) = @_;
    my $index = read_index($lz);
    my ( @out, %seen );
    for my $id ( sort keys %{ $index->{extensions} } ) {
        my $e = $index->{extensions}{$id};
        next unless ref $e eq 'HASH' && ref $e->{hooks} eq 'HASH' && ref $e->{hooks}{page_sources} eq 'ARRAY';
        for my $s ( @{ $e->{hooks}{page_sources} } ) {
            next unless ref $s eq 'HASH' && defined $s->{prefix} && length $s->{prefix};
            next if $seen{ lc $s->{prefix} }++;
            push @out, { %$s, extension => $id };
        }
    }
    @out = sort { length( $b->{prefix} ) <=> length( $a->{prefix} ) || $a->{prefix} cmp $b->{prefix} } @out;
    return @out;
}

# THE HANDLER TYPES THE INDEX DECLARES, for Lazysite::Handlers: type name to
# its record, each carrying the extension that owns it.
sub handler_types {
    my ($lz) = @_;
    my $index = read_index($lz);
    my %out;
    for my $id ( sort keys %{ $index->{extensions} } ) {
        my $e = $index->{extensions}{$id};
        next unless ref $e eq 'HASH' && ref $e->{hooks} eq 'HASH' && ref $e->{hooks}{handler_types} eq 'HASH';
        for my $t ( sort keys %{ $e->{hooks}{handler_types} } ) {
            my $d = $e->{hooks}{handler_types}{$t};
            next unless ref $d eq 'HASH';
            $out{$t} //= { %$d, extension => $id };
        }
    }
    return %out;
}

# ---- SM1369 X5, the asset part of H-10: the values a declaration may carry ----
#
# A file is a plain name with an extension, never a path, so it cannot name a
# file outside the payload directory it is looked up in. `inject_when` is a data
# attribute. An alias is a path under /assets/ that is not one of the engine's
# own assets, which an extension can neither replace nor claim. A template
# variable's name is a plain identifier that no core variable uses.
my %CORE_ASSETS = map { $_ => 1 } qw(lazysite-chrome.css lazysite-chrome.js lazysite-data.js
    lazysite-account.js lazysite-app.js qrcode.js);
my %CORE_VARS = map { $_ => 1 } qw(content page_title page_subtitle page_meta_title page_meta_desc
    page_author page_url page_url_raw page_modified request_uri site_name site_url nav layout_name
    theme_name theme theme_assets theme_css theme_version authenticated auth_user auth_name
    auth_groups manager manager_path lazysite_version enabled_extensions auth_control sections
    editor year search_enabled languages site_lang page_lang t client_ip params
    signin_banner login_options);    # SM1369 X4: the identity providers' (H-1)

sub _plain_file {
    my ($f) = @_;
    return defined $f && !ref $f && $f =~ /\A[A-Za-z0-9_-][A-Za-z0-9_.-]*\.[A-Za-z0-9]+\z/ ? 1 : 0;
}

sub _check_assets {
    my ( $id, $kind, $v ) = @_;
    my ( @bad, %seen );
    for my $i ( 0 .. $#$v ) {
        my $a = $v->[$i];
        push @bad, _err( $id, "hooks.$kind", "assets[$i].file must be a file name with an extension, not a path" )
            unless _plain_file( $a->{file} );
        push @bad, _err( $id, "hooks.$kind", "assets[$i].file '$a->{file}' is declared twice" )
            if _plain_file( $a->{file} ) && $seen{ $a->{file} }++;
        push @bad, _err( $id, "hooks.$kind", "assets[$i].inject_when must be a data attribute (data-...)" )
            if exists $a->{inject_when} && !( defined $a->{inject_when} && $a->{inject_when} =~ /\Adata-[a-z0-9-]+\z/ );
        if ( exists $a->{alias} ) {
            my ($name) = ( $a->{alias} // '' ) =~ m{\A/assets/([A-Za-z0-9_-][A-Za-z0-9_.-]*)\z};
            push @bad, _err( $id, "hooks.$kind", "assets[$i].alias must be a path under /assets/ (one file name, no directory)" )
                unless defined $name && _plain_file($name);
            push @bad, _err( $id, "hooks.$kind", "assets[$i].alias '$a->{alias}' is one of the engine's own assets" )
                if defined $name && $CORE_ASSETS{$name};
        }
    }
    return @bad;
}

sub _check_components {
    my ( $id, $kind, $v ) = @_;
    my ( @bad, %seen );
    for my $i ( 0 .. $#$v ) {
        my $f = $v->[$i]{file};
        push @bad, _err( $id, "hooks.$kind", "components[$i].file must be a component's file name, <name>.tt" )
            unless _plain_file($f) && $f =~ /\A[\w-]+\.tt\z/;
        push @bad, _err( $id, "hooks.$kind", "components[$i].file '$f' is declared twice" )
            if defined $f && !ref $f && $seen{$f}++;
    }
    return @bad;
}

sub _check_template_vars {
    my ( $id, $kind, $v ) = @_;
    my ( @bad, %seen );
    for my $i ( 0 .. $#$v ) {
        my $n = $v->[$i]{name};
        push @bad, _err( $id, "hooks.$kind", "template_vars[$i].name must be a plain identifier (letters, digits, _)" )
            unless defined $n && !ref $n && $n =~ /\A[a-z][a-z0-9_]*\z/;
        push @bad, _err( $id, "hooks.$kind", "template_vars[$i].name '$n' is a variable the engine gives every layout" )
            if defined $n && !ref $n && $CORE_VARS{$n};
        push @bad, _err( $id, "hooks.$kind", "template_vars[$i].name '$n' is declared twice" )
            if defined $n && !ref $n && $seen{$n}++;
    }
    return @bad;
}

# THE FILES A DECLARATION NAMES ARE THE EXTENSION'S OWN, as its hook modules are:
# an asset is a regular file in the payload's assets/, a component one in its
# templates/components/, neither a link. Checked at the index build, so the
# processor serves what the index names from the payload and nothing else.
# Returns ( $payload_dir, @problems ); the dir is undef when nothing is named.
sub check_payload_files {
    my ( $id, $descriptor, $hooks ) = @_;
    return (undef) unless ref $hooks eq 'HASH';
    my @want;
    push @want, map { [ 'asset', "assets/$_->{file}" ] } grep { ref $_ eq 'HASH' && _plain_file( $_->{file} ) }
        @{ ref $hooks->{assets} eq 'ARRAY' ? $hooks->{assets} : [] };
    push @want, map { [ 'component', "templates/components/$_->{file}" ] }
        grep { ref $_ eq 'HASH' && _plain_file( $_->{file} ) }
        @{ ref $hooks->{components} eq 'ARRAY' ? $hooks->{components} : [] };
    return (undef) unless @want;
    my $dir = Lazysite::Extensions::payload_dir($descriptor);
    return ( undef,
        _err( $id, 'hooks', 'the hooks name files, and the extension has no payload '
                . '(a directory, not a link, named for its descriptor)' ) )
        unless defined $dir;
    my @bad;
    for my $w (@want) {
        my ( $what, $rel ) = @$w;
        push @bad, _err( $id, 'hooks', "the $what $rel is not a file in the extension's payload" )
            if -l "$dir/$rel" || !-f "$dir/$rel";
    }
    return ( $dir, @bad );
}

# Does a declaration name files to serve or render, beyond functions to call?
sub names_payload_files {
    my ($hooks) = @_;
    return 0 unless ref $hooks eq 'HASH';
    return ( ref $hooks->{assets} eq 'ARRAY' && @{ $hooks->{assets} } )
        || ( ref $hooks->{components} eq 'ARRAY' && @{ $hooks->{components} } ) ? 1 : 0;
}

# `requires`: the ids of the extensions this one builds on. Enabling it while
# one of them is off is refused by name (the manager), and its hooks do not run
# while one of them is off (call_hook).
sub validate_requires {
    my ( $id, $req ) = @_;
    return ( _err( $id, 'requires', 'requires must be a list' ) ) unless ref $req eq 'ARRAY';
    my ( @bad, %seen );
    for my $r (@$req) {
        unless ( defined $r && !ref $r && $r =~ /\A[a-z][a-z0-9-]*\z/ ) {
            push @bad, _err( $id, 'requires', "'" . ( defined $r && !ref $r ? $r : '(not a name)' )
                    . "' must be an extension id: lower-case letters, digits and hyphens" );
            next;
        }
        push @bad, _err( $id, 'requires', "an extension cannot require itself ('$r')" )
            if defined $id && $r eq $id;
        push @bad, _err( $id, 'requires', "'$r' is listed twice" ) if $seen{$r}++;
    }
    return @bad;
}

# Every function a (validated) declaration names, sorted and once each.
sub hook_functions {
    my ($hooks) = @_;
    return () unless ref $hooks eq 'HASH';
    my %out;
    for my $kind ( keys %$hooks ) {
        my $spec = $KINDS{$kind} or next;
        my $v    = $hooks->{$kind};
        my $form = $spec->{form} // '';
        if ( $form eq 'functions' && ref $v eq 'ARRAY' ) {
            $out{$_} = 1 for grep { parse_function($_) } @$v;
            next;
        }
        my @maps
            = $form eq 'record'                       ? ($v)
            : $form eq 'records' && ref $v eq 'ARRAY' ? @$v
            : $form eq 'named' && ref $v eq 'HASH'    ? ( map { $v->{$_} } sort keys %$v )
            :                                           ();
        for my $m ( grep { ref $_ eq 'HASH' } @maps ) {
            $out{ $m->{$_} } = 1 for grep { exists $m->{$_} && parse_function( $m->{$_} ) }
                @{ $spec->{functions} || [] };
        }
    }
    my @fns = sort keys %out;
    return @fns;
}

# A module's file, relative, as %INC keys it.
sub _module_file {
    my ($module) = @_;
    ( my $f = "$module.pm" ) =~ s{::}{/}g;
    return $f;
}

# Where else on @INC a module file is found, other than $lib. SM1369 X2: the
# same file reached by another spelling of its path (a relative @INC entry, a
# link to the directory) is not another copy - compared as require_payload
# compares, by the file's real path.
sub _shadowed {
    my ( $rel, $lib ) = @_;
    my $mine = Cwd::abs_path("$lib/$rel");
    return grep {
        !ref && length && $_ ne $lib && -e "$_/$rel"
            && ( !defined $mine || ( Cwd::abs_path("$_/$rel") // '' ) ne $mine )
    } @INC;
}

# THE CODE A DECLARATION NAMES IS THE EXTENSION'S OWN. Each function's module
# must be a regular file in the extension's payload lib, beside its descriptor
# (Lazysite::Extensions::payload_lib), and must not also resolve anywhere else
# on @INC - so a hook can neither name core's code (or a system module's) as
# its own, nor shadow it. Checked at the index build and again at the call.
#
# Returns ( \@functions, $lib, @problems ).
sub check_functions {
    my ( $id, $descriptor, $hooks ) = @_;
    my @fns = hook_functions($hooks);
    return ( [], undef ) unless @fns;
    my $lib = Lazysite::Extensions::payload_lib($descriptor);
    return ( \@fns, undef,
        _err( $id, 'hooks', 'the hooks name functions, and the extension has no payload lib '
                . '(a directory, not a link, named for its descriptor, with lib/ in it)' ) )
        unless defined $lib;
    my @bad;
    my %done;
    for my $f (@fns) {
        my ($module) = parse_function($f);
        next if $done{$module}++;
        my $rel = _module_file($module);
        if ( -l "$lib/$rel" || !-f "$lib/$rel" ) {
            push @bad, _err( $id, 'hooks', "$module is not a file in the extension's payload lib" );
            next;
        }
        if ( my @also = _shadowed( $rel, $lib ) ) {
            push @bad, _err( $id, 'hooks', "$module is also found outside the extension ($also[0]); "
                    . 'a hook module must be the extension\'s own' );
        }
    }
    return ( \@fns, $lib, @bad );
}

# THE ENABLED LIST, read fresh at every call: never cached, because a disable
# must stop the next call, whatever second it lands in. The third reader of
# the list, beside Manager::Extensions::_enabled_map and the processor's copy;
# t/lint/125 runs all three on the same conf.
sub enabled_keys {
    my ($lz) = @_;
    my %on;
    open my $fh, '<:utf8', "$lz/lazysite.conf" or return \%on; # not a store - site config
    my $in = 0;
    while ( my $l = <$fh> ) {
        chomp $l;
        if ( $l =~ /^extensions\s*:\s*$/ ) { $in = 1; next }
        if ( $in && $l =~ /^\s+-\s+(.+?)\s*$/ ) { $on{$1} = 1; next }
        $in = 0 if $in && $l !~ /^\s/;
    }
    close $fh;
    return \%on;
}

# THE INDEX, cached per process on the file's identity (device, inode, size and
# the sub-second mtime). The writer renames a new file into place, so a rebuild
# is a new inode. Absent is an empty index - a site whose extensions declare no
# hooks has none - and so is one that cannot be read or decoded, after a WARN:
# an index nobody can read runs nothing, which is the closed side.
my %CACHE;

sub read_index {
    my ($lz) = @_;
    my $path = index_path($lz);
    my @st   = Time::HiRes::stat($path);
    unless (@st) {
        delete $CACHE{$path};
        return { extensions => {} };
    }
    my $sig = join ':', @st[ 0, 1, 7, 9 ];
    return $CACHE{$path}{index} if $CACHE{$path} && $CACHE{$path}{sig} eq $sig;
    my $index = { extensions => {} };
    if ( open my $fh, '<:raw', $path ) {
        my $raw = do { local $/; <$fh> };
        close $fh;
        my $got = eval { JSON::PP->new->utf8->decode($raw) };
        if ( ref $got eq 'HASH' && ( $got->{format} // 0 ) == 1 && ref $got->{extensions} eq 'HASH' ) {
            $index = $got;
        }
        else {
            _log( 'WARN', 'the hook index is not one this engine reads - no hook runs until it is rebuilt',
                file => $path );
        }
    }
    else {
        require Lazysite::Util;
        Lazysite::Util::cannot_read( 'the hook index', $path );
    }
    $CACHE{$path} = { sig => $sig, index => $index };
    return $index;
}

sub _log {
    my ( $level, $message, %extra ) = @_;
    require Lazysite::Util;
    Lazysite::Util::log_event( $level, 'extension-hook', $message, %extra );
    return;
}

# CALL ONE HOOK FUNCTION. Returns ( 1, @what_it_returned ) or ( 0, $why ).
#
# $id is the extension's id and $function one of the functions its indexed
# declaration names; anything else is refused, so this is not a way to call
# arbitrary code by name. The extension and everything it requires must be on
# NOW; its descriptor is found again by the one resolver and its payload lib
# must be the one the index was built from, or the index is stale and nothing
# runs. The module is loaded from the payload lib, which goes on @INC by the one
# rule (Lazysite::Extensions::add_payload_lib), and a function that dies is a
# failure with its reason, never an exception into the caller.
sub call_hook {
    my ( $docroot, $id, $function, @args ) = @_;
    return ( 0, 'no site' ) unless defined $docroot && length $docroot;
    my $lz    = Lazysite::Paths::lazysite_dir($docroot);
    my $entry = read_index($lz)->{extensions}{ $id // '' };
    return ( 0, "the extension '" . ( $id // '' ) . "' has no hooks in the index" )
        unless ref $entry eq 'HASH';
    return ( 0, "'" . ( $function // '' ) . "' is not a function the extension '$id' declares" )
        unless defined $function && grep { $_ eq $function } @{ $entry->{functions} || [] };

    my $on = enabled_keys($lz);
    return ( 0, "the extension '$id' is off" ) unless $on->{ $entry->{key} // '' };
    for my $k ( @{ $entry->{requires_keys} || [] } ) {
        return ( 0, "the extension '$id' requires $k, which is off" ) unless $on->{$k};
    }

    my ($file) = ( $entry->{key} // '' ) =~ m{/([A-Za-z0-9_-][A-Za-z0-9_.-]*\.pl)\z};
    my $base   = Cwd::realpath("$docroot/..");
    my $descriptor = defined $file && defined $base ? Lazysite::Extensions::locate( $file, $base ) : undef;
    return ( 0, "the extension '$id' is not installed" ) unless $descriptor;
    my $lib = Lazysite::Extensions::payload_lib($descriptor);
    return ( 0, "the extension '$id' has no payload lib" ) unless defined $lib;
    return ( 0, "the hook index is stale for '$id' - enable, save or upgrade rebuilds it" )
        unless ( $entry->{lib} // '' ) eq $lib;

    my ( $module, $fn ) = parse_function($function);
    my $rel = _module_file($module);
    return ( 0, "$module is not a file in the extension's payload lib" )
        if -l "$lib/$rel" || !-f "$lib/$rel";
    return ( 0, "$module is also found outside the extension" ) if _shadowed( $rel, $lib );
    return ( 0, "$module is already loaded from outside the extension" )
        if defined $INC{$rel} && $INC{$rel} ne "$lib/$rel";

    Lazysite::Extensions::add_payload_lib($descriptor);
    unless ( eval { require $rel; 1 } ) {
        my $why = $@ =~ s/\s+\z//r;
        _log( 'WARN', 'a hook module did not load', extension => $id, module => $module, why => $why );
        return ( 0, "$module did not load" );
    }
    my $code = $module->can($fn);
    return ( 0, "$module has no function $fn" ) unless $code;

    my @out;
    unless ( eval { @out = $code->(@args); 1 } ) {
        my $why = $@ =~ s/\s+\z//r;
        _log( 'WARN', 'a hook died', extension => $id, function => $function, why => $why );
        return ( 0, "$function died: $why" ); # SM1369 X3: the reason travels, so a caller's own line is complete
    }
    return ( 1, @out );
}

# ---------------------------------------------------------------------------
# SM1369 X2 (H-7, H-9; rulings 71, 135): WHAT AN EXTENSION DECLARES, AND HOW
# CORE'S TABLES COME TO CARRY IT.
#
# Three kinds are live here. `capability_info` is the metadata of each
# capability the extension owns (`owns.capabilities` names them; this says what
# each is): the section and label the Groups and Users grids draw, the title
# and grant sentence describe-capabilities publishes, the UI surfaces it
# unlocks, and the capabilities it is topped up from (ruling 71: a group holding
# manage_connectors gains manage_odoo on next use, so nothing changes for a
# group). `api_actions` is one row per control-API action in the shape of
# Lazysite::ControlApi::Actions' %ACTION, with its gate, its MCP twin's
# description and input schema, and the handler - a function in the extension's
# own payload lib, loaded by call_hook. `refusal_kinds` maps the refusal kinds
# the extension's answers carry to the HTTP status the control API sends.
#
# THE INDEX CARRIES TWO VIEWS. `extensions` (X1) holds the ENABLED extensions'
# hooks, and is the only thing call_hook runs from. `declared` holds every
# INSTALLED extension's declarations, built by the same validation, so that a
# capability is grantable while the extension is installed (H-7), an action of
# an extension that is installed but off is known and answers "this extension
# is off" rather than "no such action" (H-9), and the tool listing does not
# change with the toggle. Whether an action RUNS is decided at the call, from
# lazysite.conf, never from either view (G-1).
#
# THE MIRROR. The runtime tables - @Lazysite::Auth::Settings::CAP_KEYS,
# Capabilities' %ACTION_INFO, ControlApi::Actions' %GATE and %ACTION, and the
# refusal statuses - are literals for what core implements and are filled from
# the index for what an extension declares, by mirror() below, once per process
# per index. Nothing here runs --describe: the index is the one file the request
# path reads (lint 76's rule). A declaration can never shadow a core name: the
# build refuses it (check_declared), and the declare functions refuse it again.
#
# WHAT AN ACTION ROW MAY SAY (the %ACTION shape, plus the twin's half and the handler):
#
#   name           the control-API action; it starts with the extension's id and a hyphen
#   mcp            the MCP twin's name; it starts with the id and an underscore
#   handler        Module::Name::function, in the payload lib; called as
#                  handler( \%params, \%ctx ) and answers the result hash the door sends
#   gate           a list of capabilities (any one admits the caller), or 'ALWAYS'
#   always_reason  why an ALWAYS row needs no capability (required with ALWAYS, as core rows say it)
#   params         [ { name, in => query|body|query_or_body, required => 0|1, note } ]
#   description    the twin's description, for tools/list (required with mcp)
#   input_schema   the twin's JSON Schema (required with mcp); its properties are
#                  declared params, and it requires exactly the params marked required
#   mutates, destructive, open_world, instance_wide, cookie_cap - as %ACTION's
#                  mutates, destructive, mcp_open_world, instance_wide and cookie_cap
#
# A capability's info: section (one of Capabilities' @SECTIONS), label (the grid's
# short name), title, grants, unlocks => { ui => [ sentences ] } - its api and mcp
# lists are DERIVED from the gate rows that name it, so they cannot disagree with
# the gate - and top_up_from => [ capabilities ].

our $INDEX_FAILED = 'extensions.index.failed';

sub index_failed_path {
    my ($lz) = @_;
    return "$lz/$INDEX_FAILED";
}

# A build that could not write the index leaves this note beside it (best
# effort), so `lazysite check` can say the previous index stands and why; a
# build that writes removes it.
sub note_index_failure {
    my ( $lz, $why ) = @_;
    my $p = index_failed_path($lz);
    if ( !defined $why ) {
        unlink $p if -e $p;
        return;
    }
    if ( open my $fh, '>', $p ) {
        print {$fh} scalar( gmtime() ) . " UTC: $why\n";
        close $fh;
    }
    return;
}

my $CAP_NAME    = qr/\A[a-z][a-z0-9_]*\z/;
my $ACTION_NAME = qr/\A[a-z][a-z0-9-]*\z/;
my $TOOL_NAME   = qr/\A[a-z][a-z0-9_]*\z/;
my $PARAM_NAME  = qr/\A[a-z][a-z0-9_]*\z/;
my $KIND_NAME   = qr/\A[a-z][a-z0-9-]*\z/;

sub _nonempty {
    my ($v) = @_;
    return _plain($v) && length $v ? 1 : 0;
}

sub _plain_list {
    my ( $v, $re ) = @_;
    return 0 unless ref $v eq 'ARRAY';
    return 0 if grep { !_plain($_) || ( $re && $_ !~ $re ) } @$v;
    return 1;
}

sub _validate_capability_info {
    my ( $id, $info ) = @_;
    my $k = 'hooks.capability_info';
    return ( _err( $id, $k, 'capability_info must be a mapping of capability name to its metadata' ) )
        unless ref $info eq 'HASH';
    my @bad;
    for my $cap ( sort keys %$info ) {
        unless ( $cap =~ $CAP_NAME ) {
            push @bad, _err( $id, $k, "'$cap' is not a capability name: lower-case letters, digits and underscores" );
            next;
        }
        my $m = $info->{$cap};
        unless ( ref $m eq 'HASH' ) {
            push @bad, _err( $id, $k, "$cap must be a mapping (section, label, title, grants, unlocks, top_up_from)" );
            next;
        }
        for my $f ( sort keys %$m ) {
            push @bad, _err( $id, $k, "unknown key '$f' on $cap (expected: section, label, title, grants, unlocks, top_up_from)" )
                unless $f =~ /\A(?:section|label|title|grants|unlocks|top_up_from)\z/;
        }
        for my $f (qw(section label title grants)) {
            push @bad, _err( $id, $k, "$cap must carry a plain, non-empty '$f'" ) unless _nonempty( $m->{$f} );
        }
        push @bad, _err( $id, $k, "$cap: the label is the grid's short name, at most 40 characters" )
            if _nonempty( $m->{label} ) && length( $m->{label} ) > 40;
        if ( exists $m->{unlocks} ) {
            if ( ref $m->{unlocks} ne 'HASH' ) {
                push @bad, _err( $id, $k, "$cap: unlocks must be a mapping" );
            }
            else {
                for my $ch ( sort keys %{ $m->{unlocks} } ) {
                    if ( $ch eq 'ui' ) {
                        push @bad, _err( $id, $k, "$cap: unlocks.ui must be a list of sentences" )
                            unless _plain_list( $m->{unlocks}{ui} );
                    }
                    else {
                        push @bad, _err( $id, $k, "$cap: unlocks.$ch is derived from the api_actions rows whose gate names "
                                . "$cap, and is not declared (only unlocks.ui is)" );
                    }
                }
            }
        }
        push @bad, _err( $id, $k, "$cap: top_up_from must be a list of capability names" )
            if exists $m->{top_up_from} && !_plain_list( $m->{top_up_from}, $CAP_NAME );
    }
    return @bad;
}

my %ROW_KEY = map { $_ => 1 } qw(name mcp handler gate always_reason params description input_schema
    mutates destructive open_world instance_wide cookie_cap);
my %FLAG = map { $_ => 1 } qw(mutates destructive open_world instance_wide);

sub _validate_api_actions {
    my ( $id, $rows ) = @_;
    my $k = 'hooks.api_actions';
    return ( _err( $id, $k, 'api_actions must be a list of action rows' ) ) unless ref $rows eq 'ARRAY';
    my ( @bad, %seen_name, %seen_mcp );
    for my $i ( 0 .. $#$rows ) {
        my $r     = $rows->[$i];
        my $where = "api_actions[$i]";
        unless ( ref $r eq 'HASH' ) {
            push @bad, _err( $id, $k, "$where must be a mapping" );
            next;
        }
        my $name = _plain( $r->{name} ) ? $r->{name} : undef;
        $where = "api_actions '$name'" if defined $name && length $name;
        for my $f ( sort keys %$r ) {
            push @bad, _err( $id, $k, "unknown key '$f' on $where (expected: " . join( ', ', sort keys %ROW_KEY ) . ')' )
                unless $ROW_KEY{$f};
        }
        if ( !defined $name || $name !~ $ACTION_NAME ) {
            push @bad, _err( $id, $k, "$where must carry a name: lower-case letters, digits and hyphens" );
        }
        else {
            push @bad, _err( $id, $k, "$where: an action's name starts with the extension's id ('$id-')" )
                unless defined $id && $name =~ /\A\Q$id\E-./;
            push @bad, _err( $id, $k, "$where is declared twice" ) if $seen_name{$name}++;
        }
        if ( exists $r->{mcp} ) {
            if ( !_plain( $r->{mcp} ) || $r->{mcp} !~ $TOOL_NAME ) {
                push @bad, _err( $id, $k, "$where: mcp must be a tool name: lower-case letters, digits and underscores" );
            }
            else {
                push @bad, _err( $id, $k, "$where: a tool's name starts with the extension's id ('${id}_')" )
                    unless defined $id && $r->{mcp} =~ /\A\Q$id\E_./;
                push @bad, _err( $id, $k, "$where: the tool '$r->{mcp}' is named by two rows" ) if $seen_mcp{ $r->{mcp} }++;
            }
            push @bad, _err( $id, $k, "$where: a row with an mcp twin carries the twin's description" )
                unless _nonempty( $r->{description} );
            if ( ref $r->{input_schema} ne 'HASH' || ( $r->{input_schema}{type} // '' ) ne 'object' ) {
                push @bad, _err( $id, $k, "$where: a row with an mcp twin carries the twin's input_schema, a JSON Schema of type object" );
            }
        }
        else {
            push @bad, _err( $id, $k, "$where: $_ belongs to the mcp twin, and the row names none" )
                for grep { exists $r->{$_} } qw(description input_schema open_world);
        }
        push @bad, _err( $id, $k, "$where must name its handler, a fully qualified function in the payload lib" )
            unless parse_function( $r->{handler} );
        my $g = $r->{gate};
        if ( !defined $g ) {
            push @bad, _err( $id, $k, "$where has no gate row: a list of capabilities, or 'ALWAYS' with its always_reason" );
        }
        elsif ( !ref $g && $g eq 'ALWAYS' ) {
            push @bad, _err( $id, $k, "$where is gated ALWAYS and gives no always_reason - a core row says why it needs no capability, and so does this one" )
                unless _nonempty( $r->{always_reason} );
        }
        elsif ( ref $g eq 'ARRAY' && @$g && _plain_list( $g, $CAP_NAME ) ) {
            push @bad, _err( $id, $k, "$where: always_reason belongs to an ALWAYS gate" ) if exists $r->{always_reason};
            if ( exists $r->{cookie_cap} ) {
                my %gate = map { $_ => 1 } @$g;
                my @ck = _plain( $r->{cookie_cap} ) ? split( /\|/, $r->{cookie_cap} ) : ();
                push @bad, _err( $id, $k, "$where: cookie_cap names the same capabilities as the gate, '|' between them, "
                        . 'so neither door is the weaker one' )
                    unless @ck && @ck == keys %gate && !grep { !$gate{$_} } @ck;
            }
        }
        else {
            push @bad, _err( $id, $k, "$where: gate must be a non-empty list of capability names, or 'ALWAYS'" );
        }
        for my $f ( grep { exists $r->{$_} } sort keys %FLAG ) {
            push @bad, _err( $id, $k, "$where: $f must be 0 or 1" ) unless _plain( $r->{$f} ) && $r->{$f} =~ /\A[01]\z/;
        }
        push @bad, _err( $id, $k, "$where: destructive needs mutates" ) if $r->{destructive} && !$r->{mutates};
        my %param;
        if ( exists $r->{params} ) {
            if ( ref $r->{params} ne 'ARRAY' ) {
                push @bad, _err( $id, $k, "$where: params must be a list of { name, in, required, note }" );
            }
            else {
                for my $p ( @{ $r->{params} } ) {
                    unless ( ref $p eq 'HASH' && _plain( $p->{name} ) && $p->{name} =~ $PARAM_NAME ) {
                        push @bad, _err( $id, $k, "$where: each param is a mapping with a name" );
                        next;
                    }
                    push @bad, _err( $id, $k, "$where: param '$p->{name}' is listed twice" ) if $param{ $p->{name} }++;
                    push @bad, _err( $id, $k, "$where: param '$p->{name}' says where it is read from: query, body or query_or_body" )
                        unless _plain( $p->{in} ) && $p->{in} =~ /\A(?:query|body|query_or_body)\z/;
                    push @bad, _err( $id, $k, "unknown key '$_' on $where param '$p->{name}'" )
                        for grep { !/\A(?:name|in|required|note)\z/ } sort keys %$p;
                    push @bad, _err( $id, $k, "$where: param '$p->{name}': required must be 0 or 1" )
                        if exists $p->{required} && !( _plain( $p->{required} ) && $p->{required} =~ /\A[01]\z/ );
                    push @bad, _err( $id, $k, "$where: param '$p->{name}': note must be a plain value" )
                        if exists $p->{note} && !_plain( $p->{note} );
                }
            }
        }
        if ( ref $r->{input_schema} eq 'HASH' ) {
            my $s     = $r->{input_schema};
            my $props = ref $s->{properties} eq 'HASH' ? $s->{properties} : {};
            push @bad, _err( $id, $k, "$where: input_schema names '$_', which is not a declared param" )
                for grep { !$param{$_} } sort keys %$props;
            push @bad, _err( $id, $k, "$where: param '$_' is not in the input_schema" )
                for grep { !exists $props->{$_} } sort keys %param;
            my %must = map { $_->{name} => 1 } grep { ref $_ eq 'HASH' && $_->{required} } @{ ref $r->{params} eq 'ARRAY' ? $r->{params} : [] };
            my @sreq = ref $s->{required} eq 'ARRAY' ? @{ $s->{required} } : ();
            my %sreq = map { $_ => 1 } grep { _plain($_) } @sreq;
            push @bad, _err( $id, $k, "$where: the twin requires '$_' and the action does not (SM326: both surfaces require the same)" )
                for grep { !$must{$_} } sort keys %sreq;
            push @bad, _err( $id, $k, "$where: the action requires '$_' and the twin does not (SM326: both surfaces require the same)" )
                for grep { !$sreq{$_} } sort keys %must;
        }
    }
    return @bad;
}

sub _validate_refusal_kinds {
    my ( $id, $map ) = @_;
    my $k = 'hooks.refusal_kinds';
    return ( _err( $id, $k, 'refusal_kinds must be a mapping of kind to HTTP status line' ) ) unless ref $map eq 'HASH';
    my @bad;
    for my $kind ( sort keys %$map ) {
        push @bad, _err( $id, $k, "'$kind' is not a refusal kind: lower-case letters, digits and hyphens" )
            unless $kind =~ $KIND_NAME;
        push @bad, _err( $id, $k, "$kind must map to a status line such as '409 Conflict'" )
            unless _plain( $map->{$kind} ) && $map->{$kind} =~ /\A[1-5][0-9]{2} [A-Z][A-Za-z' -]*\z/;
    }
    return @bad;
}

# The index's `declared` entry for one (validated) descriptor: what the mirror
# needs and nothing it does not.
sub declared_entry {
    my ( $key, $desc ) = @_;
    my $owns  = ref $desc->{owns} eq 'HASH'  ? $desc->{owns}  : {};
    my $hooks = ref $owns->{hooks} eq 'HASH' ? $owns->{hooks} : {};
    my %e = ( key => $key, name => ( _plain( $desc->{name} ) ? $desc->{name} : $desc->{id} ) );
    $e{capabilities} = [ @{ $owns->{capabilities} } ] if ref $owns->{capabilities} eq 'ARRAY' && @{ $owns->{capabilities} };
    $e{capability_info} = $hooks->{capability_info} if ref $hooks->{capability_info} eq 'HASH' && %{ $hooks->{capability_info} };
    $e{api_actions} = $hooks->{api_actions} if ref $hooks->{api_actions} eq 'ARRAY' && @{ $hooks->{api_actions} };
    $e{refusal_kinds} = $hooks->{refusal_kinds} if ref $hooks->{refusal_kinds} eq 'HASH' && %{ $hooks->{refusal_kinds} };
    return keys %e > 2 ? \%e : undef;
}

# ---- the mirror, LIGHT SCOPE ----
#
# The capability names (@CAP_KEYS, through Lazysite::Auth::Settings) and the
# refusal statuses, from the index's `declared` view: what a grant resolver
# (caps_for, the group-settings reads) and a page endpoint need, and nothing
# that would put the capability map or the action tables into the processor's
# pooled workers (t/lint/269). The FULL scope - those two tables as well, for
# the doors, the tools and the lints - is Lazysite::Extensions::Declared, which
# calls this first and fills the rest; nothing here names it.
my %MIRROR; # sig => the index mirrored, scope => light|full, ids => the extensions it carried
my %REFUSAL;    # kind => status, from the mirrored declarations

sub declared_refusal_status {
    my ($kind) = @_;
    return defined $kind ? $REFUSAL{$kind} : undef;
}

# The mirror's record, for the full scope to read and widen.
sub mirror_state { return \%MIRROR }

# The signature a mirror of $lz's index carries: the file's identity, so a
# rebuilt index (a new inode) is read again and an unchanged one is a stat.
sub index_signature {
    my ($lz) = @_;
    my $path = index_path($lz);
    return ( $CACHE{$path} ? $CACHE{$path}{sig} : 'none' ) . '@' . $path;
}

# Fill the light tables from an index. Replaces what an earlier mirror put
# there, so a rebuilt index is read whole. A declaration the build let through
# that the tables refuse (a core name, from a hand-edited index) is skipped with
# a WARN: the refusal is the closed side, and the build is where it is said
# properly. Returns the ids mirrored.
sub mirror_index {
    my ( $index, $sig ) = @_;
    unmirror();
    my $decl = ref $index eq 'HASH' && ref $index->{declared} eq 'HASH' ? $index->{declared} : {};
    require Lazysite::Auth::Settings;
    my @ids;
    for my $id ( sort keys %$decl ) {
        my $e = $decl->{$id};
        next unless ref $e eq 'HASH';
        my @caps  = ref $e->{capabilities} eq 'ARRAY' ? @{ $e->{capabilities} } : ();
        my @why   = Lazysite::Auth::Settings::declare_capabilities( $id, \@caps );
        my $kinds = ref $e->{refusal_kinds} eq 'HASH' ? $e->{refusal_kinds} : {};
        for my $kind ( sort keys %$kinds ) {
            if ( exists $REFUSAL{$kind} ) { push @why, "refusal kind '$kind' is declared twice"; next }
            $REFUSAL{$kind} = $kinds->{$kind};
        }
        _log( 'WARN', 'a declaration in the index was not mirrored', extension => $id, why => join( '; ', @why ) )
            if @why;
        push @ids, $id;
    }
    %MIRROR = ( sig => $sig, scope => 'light', ids => \@ids );
    return @ids;
}

# Take the light tables back to core's. The full scope's own undo runs first
# (Declared::unmirror), where it was mirrored.
sub unmirror {
    return unless %MIRROR;
    require Lazysite::Auth::Settings;
    Lazysite::Auth::Settings::undeclare_capabilities();
    %REFUSAL = ();
    %MIRROR  = ();
    return;
}

# Mirror a site's index into this process, light scope, once per index: a
# second call with the same file is a stat. Returns 1 when the tables changed.
sub mirror {
    my ($lz) = @_;
    return 0 unless defined $lz && length $lz;
    my $index = read_index($lz);
    my $sig   = index_signature($lz);
    return 0 if defined $MIRROR{sig} && $MIRROR{sig} eq $sig;
    mirror_index( $index, $sig );
    return 1;
}

1;
