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
    check_declared declared_entry mirror mirror_index unmirror run_action
    index_failed_path note_index_failure declared_refusal_status);

# The hook vocabulary. `hook` is the proposal's H-n, `slice` the slice that
# builds its consumer. A live kind carries its shape:
#
#   form       functions - a list of function names
#              record    - one map
#              records   - a list of maps
#   functions  the keys of a map whose values are function names
#   fields     the other keys a map may carry, each a plain value
#   required   the keys a map must carry
#
# The names of the kinds that are not live are the proposal's; a slice may
# rename its kind before making it live, since nothing can declare it until then.
our %KINDS = (
    identity_provider => { hook => 'H-1',  slice => 'X4' },
    page_sources      => { hook => 'H-2',  slice => 'X3' },
    handler_types     => { hook => 'H-3',  slice => 'X3' },
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
    assets            => { hook => 'H-10', slice => 'X5' },
    components        => { hook => 'H-10', slice => 'X5' },
    template_vars     => { hook => 'H-10', slice => 'X5' },
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
        else {
            push @bad, _err( $id, "hooks.$kind", "unknown key '$k' in $where (expected: "
                    . join( ', ', sort( keys %fn, keys %fld ) ) . ')' );
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
        my $spec = $KINDS{$kind};
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
            push @bad, _validate_map( $id, $kind, $spec, $v->[$_], "$kind\[$_\]" ) for 0 .. $#$v;
        }
        else {
            push @bad, _err( $id, "hooks.$kind", "hook '$kind' has no shape in this engine" );
        }
    }
    return @bad;
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
        my @maps = $form eq 'record' ? ($v) : $form eq 'records' && ref $v eq 'ARRAY' ? @$v : ();
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
        return ( 0, "$function died" );
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
        if ( _nonempty( $m->{section} ) ) {
            require Lazysite::Capabilities;
            push @bad, _err( $id, $k, "$cap: section '$m->{section}' is not one of "
                    . join( ', ', @Lazysite::Capabilities::SECTIONS ) )
                unless grep { $_ eq $m->{section} } @Lazysite::Capabilities::SECTIONS;
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

# THE CROSS-CHECKS, once the kinds validate on their own: every capability the
# extension owns is described and every description names an owned capability;
# nothing declared shadows a core name (a capability, an action, a refusal
# kind); a gate names capabilities that exist (core's or the extension's own).
# Returns problems in Owns' shape. Run at the index build and by the lints.
sub check_declared {
    my ( $id, $owns ) = @_;
    return () unless ref $owns eq 'HASH';
    my $hooks = ref $owns->{hooks} eq 'HASH' ? $owns->{hooks} : {};
    my @bad;
    my @caps = ref $owns->{capabilities} eq 'ARRAY' ? grep { _plain($_) } @{ $owns->{capabilities} } : ();
    my $info  = ref $hooks->{capability_info} eq 'HASH' ? $hooks->{capability_info} : {};
    my $rows  = ref $hooks->{api_actions} eq 'ARRAY'    ? $hooks->{api_actions}     : [];
    my $kinds = ref $hooks->{refusal_kinds} eq 'HASH'   ? $hooks->{refusal_kinds}   : {};
    return () unless @caps || %$info || @$rows || %$kinds;

    my %own = map { $_ => 1 } @caps;
    if ( %$info || @$rows ) {
        push @bad, _err( $id, 'capabilities', "'$_' is owned and not described in hooks.capability_info" )
            for grep { !exists $info->{$_} } @caps;
    }
    push @bad, _err( $id, 'hooks.capability_info', "'$_' is described and not in owns.capabilities" )
        for grep { !$own{$_} } sort keys %$info;

    require Lazysite::Auth::Settings;
    my %core_cap = map { $_ => 1 } Lazysite::Auth::Settings::core_capability_keys();
    push @bad, _err( $id, 'capabilities', "'$_' is a core capability, which an extension can never own or shadow" )
        for grep { $core_cap{$_} } @caps;
    for my $cap ( sort keys %$info ) {
        my $m = ref $info->{$cap} eq 'HASH' ? $info->{$cap} : {};
        push @bad, _err( $id, 'hooks.capability_info', "$cap: top_up_from names '$_', which is no capability" )
            for grep { !$core_cap{$_} && !$own{$_} } @{ ref $m->{top_up_from} eq 'ARRAY' ? $m->{top_up_from} : [] };
    }

    require Lazysite::ControlApi::Actions;
    for my $r ( grep { ref $_ eq 'HASH' } @$rows ) {
        my $name = _plain( $r->{name} ) ? $r->{name} : next;
        push @bad, _err( $id, 'hooks.api_actions', "'$name' is a core action, which an extension can never shadow" )
            if Lazysite::ControlApi::Actions::is_core_action($name);
        push @bad, _err( $id, 'hooks.api_actions', "'$r->{mcp}' is a core tool, which an extension can never shadow" )
            if _plain( $r->{mcp} ) && Lazysite::ControlApi::Actions::is_core_tool( $r->{mcp} );
        if ( ref $r->{gate} eq 'ARRAY' ) {
            push @bad, _err( $id, 'hooks.api_actions', "'$name' is gated on '$_', which is no capability of core's or this extension's" )
                for grep { _plain($_) && !$core_cap{$_} && !$own{$_} } @{ $r->{gate} };
        }
    }

    if (%$kinds) {
        require Lazysite::Manager::Common;
        no warnings 'once';
        push @bad, _err( $id, 'hooks.refusal_kinds', "'$_' is a core refusal kind, which an extension can never redefine" )
            for grep { exists $Lazysite::Manager::Common::REFUSAL_STATUS{$_} } sort keys %$kinds;
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

# ---- the mirror ----
my %MIRROR;     # sig => the index mirrored, ids => the extensions it carried
my %REFUSAL;    # kind => status, from the mirrored declarations

sub declared_refusal_status {
    my ($kind) = @_;
    return defined $kind ? $REFUSAL{$kind} : undef;
}

# The api and mcp halves of a capability's `unlocks`, derived from the rows
# whose gate names it (the gate is what decides, so the map cannot over- or
# under-claim - lint 90's two directions, by construction).
sub _unlocks_of {
    my ( $cap, $info, $rows ) = @_;
    my ( @api, @mcp );
    for my $r ( grep { ref $_ eq 'HASH' && ref $_->{gate} eq 'ARRAY' } @$rows ) {
        next unless grep { $_ eq $cap } @{ $r->{gate} };
        push @api, $r->{name};
        push @mcp, $r->{mcp} if defined $r->{mcp};
    }
    my %u  = ( api => \@api, mcp => \@mcp );
    my $ui = ref $info->{unlocks} eq 'HASH' ? $info->{unlocks}{ui} : undef;
    $u{ui} = [@$ui] if ref $ui eq 'ARRAY' && @$ui;
    return \%u;
}

# Fill the runtime tables from an index (its `declared` view). Replaces what an
# earlier mirror put there, so a rebuilt index is read whole. Returns the ids
# mirrored. A declaration the build let through that the tables refuse
# (a core name, from a hand-edited index) is skipped with a WARN: the refusal
# is the closed side, and the build is where it is said properly.
sub mirror_index {
    my ( $index, $sig ) = @_;
    unmirror();
    my $decl = ref $index eq 'HASH' && ref $index->{declared} eq 'HASH' ? $index->{declared} : {};
    require Lazysite::Auth::Settings;
    require Lazysite::Capabilities;
    require Lazysite::ControlApi::Actions;
    my @ids;
    for my $id ( sort keys %$decl ) {
        my $e = $decl->{$id};
        next unless ref $e eq 'HASH';
        my @caps = ref $e->{capabilities} eq 'ARRAY'   ? @{ $e->{capabilities} } : ();
        my $info = ref $e->{capability_info} eq 'HASH' ? $e->{capability_info}   : {};
        my $rows = ref $e->{api_actions} eq 'ARRAY'    ? $e->{api_actions}       : [];
        my @why;
        push @why, Lazysite::Auth::Settings::declare_capabilities( $id, \@caps );
        for my $cap ( grep { ref $info->{$_} eq 'HASH' } sort keys %$info ) {
            push @why, Lazysite::Capabilities::declare_capability( $id, $cap,
                { %{ $info->{$cap} }, unlocks => _unlocks_of( $cap, $info->{$cap}, $rows ) } );
        }
        push @why, Lazysite::ControlApi::Actions::declare_action( $id, $_ ) for grep { ref $_ eq 'HASH' } @$rows;
        my $kinds = ref $e->{refusal_kinds} eq 'HASH' ? $e->{refusal_kinds} : {};
        for my $kind ( sort keys %$kinds ) {
            if ( exists $REFUSAL{$kind} ) { push @why, "refusal kind '$kind' is declared twice"; next }
            $REFUSAL{$kind} = $kinds->{$kind};
        }
        _log( 'WARN', 'a declaration in the index was not mirrored', extension => $id, why => join( '; ', @why ) )
            if @why;
        push @ids, $id;
    }
    %MIRROR = ( sig => $sig, ids => \@ids );
    return @ids;
}

sub unmirror {
    return unless %MIRROR;
    require Lazysite::Auth::Settings;
    require Lazysite::Capabilities;
    require Lazysite::ControlApi::Actions;
    Lazysite::Auth::Settings::undeclare_capabilities();
    Lazysite::Capabilities::undeclare_capabilities();
    Lazysite::ControlApi::Actions::undeclare_actions();
    %REFUSAL = ();
    %MIRROR  = ();
    return;
}

# Mirror a site's index into this process, once per index: a second call with
# the same file is a stat. Returns 1 when the tables changed.
sub mirror {
    my ($lz) = @_;
    return 0 unless defined $lz && length $lz;
    my $index = read_index($lz);
    my $path  = index_path($lz);
    my $sig   = ( $CACHE{$path} ? $CACHE{$path}{sig} : 'none' ) . '@' . $path;
    return 0 if defined $MIRROR{sig} && $MIRROR{sig} eq $sig;
    mirror_index( $index, $sig );
    return 1;
}

# RUN ONE DECLARED ACTION, from either door. $name is the control-API action
# (the twin's row is the same row); \%params are its declared parameters as the
# door read them; \%ctx is who is asking (user, caps, groups, ip, channel,
# reach), to which the docroot, the extension and the action are added. The
# extension must be on NOW and its hooks indexed; call_hook checks the rest.
# Answers a result hash in the doors' shape, always.
sub run_action {
    my ( $docroot, $name, $params, $ctx ) = @_;
    require Lazysite::ControlApi::Actions;
    no warnings 'once';
    my $spec = $Lazysite::ControlApi::Actions::ACTION{ $name // '' };
    my $id   = ref $spec eq 'HASH' ? $spec->{extension} : undef;
    return { ok => 0, kind => 'not-found', error => 'Unknown action: ' . ( $name // '' ) } unless defined $id;
    my $lz    = Lazysite::Paths::lazysite_dir($docroot);
    my $index = read_index($lz);
    my $decl  = ref $index->{declared} eq 'HASH' ? $index->{declared}{$id}     : undef;
    my $key   = ref $decl eq 'HASH'              ? $decl->{key}                : undef;
    my $label = ref $decl eq 'HASH' && _plain( $decl->{name} ) ? $decl->{name} : $id;
    unless ( defined $key && enabled_keys($lz)->{$key} ) {
        return { ok => 0, kind => 'disabled',
            error => "This extension ($label) is off, so $name cannot run - a sysop can enable it on the Extensions page." };
    }
    my ( $ok, @out ) = call_hook( $docroot, $id, $spec->{handler}, $params // {},
        { %{ $ctx || {} }, docroot => $docroot, extension => $id, action => $name } );
    unless ($ok) {
        return { ok => 0, kind => 'cannot-tell',
            error => "$name cannot run now: $out[0]. Enabling, saving or upgrading the extension rebuilds its index." };
    }
    return $out[0] if ref $out[0] eq 'HASH';
    return { ok => 0, kind => 'internal', error => "$name answered nothing this door can send" };
}

1;
