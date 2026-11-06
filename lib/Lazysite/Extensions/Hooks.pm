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
    check_functions index_path read_index enabled_keys call_hook);

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
    capability_info   => { hook => 'H-7',  slice => 'X2' },
    panels            => { hook => 'H-8',  slice => 'X6' },
    api_actions       => { hook => 'H-9',  slice => 'X2' },
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
        if ( $form eq 'functions' ) {
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

# Where else on @INC a module file is found, other than $lib.
sub _shadowed {
    my ( $rel, $lib ) = @_;
    return grep { !ref && length && $_ ne $lib && -e "$_/$rel" } @INC;
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

1;
