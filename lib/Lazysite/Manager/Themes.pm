package Lazysite::Manager::Themes;

# SM079: the theming CORE - theme + layout listing, activation, the active
# pointer, validation, backups/snapshots, theme delete/rename/upload, HTML-cache
# invalidation, cache-list/invalidate, and the artifact-manifest actions. The
# layouts-repo install/release subsystem lives in Manager::Layouts (which
# depends one-way on this module); the pure manifest/digest helpers live in
# Manager::Artifact. Context ($DOCROOT, $LAZYSITE_DIR, $auth_user, $action) set
# by the dispatcher; Archive::Zip is required inline.

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Find;
use File::Path                  qw(make_path remove_tree);
use File::Copy                  qw(copy);
use File::Basename              qw(basename dirname);
use Cwd                         qw(realpath);
use POSIX                       qw(strftime);
use Digest::SHA                 qw(sha256_hex);
use Lazysite::Util              qw(log_event);
use Lazysite::Manager::Common   qw(write_file_checked _write_conf_key);
use Lazysite::Manager::Files    qw(acquire_lock release_lock);
use Lazysite::Manager::Artifact qw(_artifact_dir _compute_manifest _artifact_digest);
use Lazysite::Manager::Domains  ();    # SM177: domains_using (delete-safety scan)
use Lazysite::Paths             ();
use Exporter 'import';

our @EXPORT_OK = qw(
    action_theme_list action_themes_list_all action_theme_activate
    action_theme_tokens action_create_theme theme_config_issues
    _layout_declared_tokens _theme_config_tokens _token_mismatch
    _token_warning_list
    action_layout_activate action_theme_delete action_theme_rename
    action_theme_upload action_cache_list action_cache_invalidate
    _read_active_layout_and_theme _install_theme_from_dir
    action_artifact_manifest action_artifact_validate
    _snapshot_artifact _prune_backups _mirror_theme_assets
);

our $DOCROOT;

# SM293: this site's engine tree - beside the docroot once migrated,
# inside it before. Asked, never computed, so both layouts work on one
# code path and a site migrates by moving the directory.
sub _lz { return Lazysite::Paths::lazysite_dir($DOCROOT) }
our $LAZYSITE_DIR;
our $auth_user = '';
our $action    = '';

# SM255 (completion): the pointer setters below used a bare open('>') - not
# atomic, not locked, and unrecorded - on the same file config-set writes
# through the locking writer. Route them through the one writer; this module
# carries its own $DOCROOT and $auth_user (the dispatcher sets both per
# request), so bridge them for the duration of the write or the shared writer
# looks in the wrong docroot and attributes the commit to nobody.
sub _write_conf_content {
    my ( $content, $message ) = @_;
    no warnings 'once';
    local $Lazysite::Manager::Common::DOCROOT   = $DOCROOT;
    local $Lazysite::Manager::Common::auth_user = $auth_user;
    return Lazysite::Manager::Common::write_conf_content( $content, $message );
}

# === moved from lazysite-manager-api.pl (SM079a) ===

sub _read_active_layout_and_theme {
    my $layout = '';
    my $theme  = '';
    if ( open my $fh, '<', _lz() . "/lazysite.conf" ) {
        while (<$fh>) {
            $layout = $1 if /^layout\s*:\s*(\S+)/;
            $theme  = $1 if /^theme\s*:\s*(\S+)/;
        }
        close $fh;
    }
    $layout =~ s/[^a-zA-Z0-9_-]//g;
    $theme  =~ s/[^a-zA-Z0-9_-]//g;
    return ( $layout, $theme );
}

# SM234: which domains resolve to each theme/layout. The delete guard already
# consults this (a theme a registered domain depends on cannot be removed) but the
# LISTING did not, so a theme pinned only by a sub-domain showed a Delete button
# and the operator learned it was protected from the error that followed. One
# parse for the whole listing - see Domains::domain_usage.
sub _usage {
    local $Lazysite::Manager::Domains::DOCROOT = $DOCROOT;
    return Lazysite::Manager::Domains::domain_usage();
}

sub action_theme_list {
    my ( $active_layout, $active_theme ) = _read_active_layout_and_theme();
    my $use = _usage();

    my @themes;
    if ( length $active_layout ) {
        my $themes_dir = _lz() . "/layouts/$active_layout/themes";
        if ( -d $themes_dir ) {
            opendir( my $dh, $themes_dir );
            for my $name ( sort readdir $dh ) {
                next if $name =~ /^\./;
                next unless -d "$themes_dir/$name";
                my $by = $use->{themes}{"$active_layout\0$name"} || [];
                push @themes, {
                    name    => $name,
                    active  => $name eq $active_theme            ? 1 : 0,
                    valid   => -f "$themes_dir/$name/theme.json" ? 1 : 0,
                    used_by => $by,           # SM234: domains that resolve to it
                    in_use  => scalar @$by,
                };
            }
            closedir $dh;
        }
    }

    return {
        ok     => 1,
        themes => \@themes,
        active => $active_theme,
        layout => $active_layout,
    };
}

sub action_themes_list_all {
    my ( $active_layout, $active_theme ) = _read_active_layout_and_theme();
    my $use = _usage();

    my $layouts_dir = _lz() . "/layouts";
    my @themes;

    if ( -d $layouts_dir ) {
        opendir my $ld, $layouts_dir or return {
            ok            => 1, themes => [], active => $active_theme,
            active_layout => $active_layout,
        };
        for my $layout_name ( sort readdir $ld ) {
            next if $layout_name =~ /^\./;
            my $themes_path = "$layouts_dir/$layout_name/themes";
            next unless -d $themes_path;

            opendir my $th, $themes_path or next;
            for my $name ( sort readdir $th ) {
                next if $name =~ /^\./;
                next unless -d "$themes_path/$name";

                my $valid  = -f "$themes_path/$name/theme.json" ? 1 : 0;
                my $active = ( $layout_name eq $active_layout
                        && $name eq $active_theme ) ? 1 : 0;
                my $by = $use->{themes}{"$layout_name\0$name"} || [];
                push @themes, {
                    layout  => $layout_name,
                    name    => $name,
                    active  => $active,
                    valid   => $valid,
                    used_by => $by,            # SM234
                    in_use  => scalar @$by,
                };
            }
            closedir $th;
        }
        closedir $ld;
    }

    return {
        ok            => 1,
        themes        => \@themes,
        active        => $active_theme,
        active_layout => $active_layout,
    };
}

# SM204: read a layout.json under a given layout and return its decoded hash
# (or {} if absent/unparseable). Used by the token-vocabulary tool to read
# default_theme and the optional (SM203) declared `tokens` block.
sub _read_layout_json {
    my ($layout) = @_;
    return {} unless defined $layout && $layout =~ /^[A-Za-z0-9_-]+$/;
    open my $jf, '<:utf8', "$LAZYSITE_DIR/layouts/$layout/layout.json"
        or return {};
    my $raw = do { local $/; <$jf> };
    close $jf;
    my $meta = eval { decode_json($raw) };
    return ( ref $meta eq 'HASH' ) ? $meta : {};
}

# SM204: decode a theme's theme.json under a layout. Returns the parsed hash or
# undef when the theme is missing / unnamed / unparseable.
sub _read_theme_json {
    my ( $layout, $theme ) = @_;
    return undef
        unless defined $layout
        && $layout =~ /^[A-Za-z0-9_-]+$/
        && defined $theme
        && $theme =~ /^[A-Za-z0-9_-]+$/;
    my $path = "$LAZYSITE_DIR/layouts/$layout/themes/$theme/theme.json";
    open my $jf, '<:utf8', $path or return undef;
    my $raw = do { local $/; <$jf> };
    close $jf;
    my $meta = eval { decode_json($raw) };
    return ( ref $meta eq 'HASH' ) ? $meta : undef;
}

# SM268 04-F6: who created a theme, kept where the caller cannot write it.
#
# theme.json is inside the tree manage_themes makes writable, so provenance
# stored there is self-certified by the party the delete rule restricts. This
# store lives in lazysite/auth/, which the blocklist denies on every authoring
# surface. Keyed "<layout>/<theme>", because the same theme name under two
# layouts is two objects.
sub _created_registry_path { return "$LAZYSITE_DIR/auth/themes-created.json" }

sub _read_created_registry {
    my $path = _created_registry_path();
    return {} unless -f $path;
    open my $fh, '<:raw', $path or return {};
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $map = eval { decode_json( $raw // '{}' ) };
    return ( ref $map eq 'HASH' ) ? $map : {};
}

sub _write_created_registry {
    my ($map) = @_;
    my $path = _created_registry_path();
    make_path( dirname($path) ) unless -d dirname($path);
    my $tmp = "$path.tmp.$$";
    open my $fh, '>:raw', $tmp or return 0;
    print {$fh} JSON::PP->new->canonical->pretty->encode($map);
    close $fh;
    chmod 0640, $tmp;
    return rename $tmp, $path;
}

sub _record_theme_creator {
    my ( $layout, $theme, $who ) = @_;
    return unless length( $layout // '' ) && length( $theme // '' );
    return unless length( $who    // '' );
    my $map = _read_created_registry();
    $map->{"$layout/$theme"} = $who;
    _write_created_registry($map);
    return;
}

sub _theme_creator {
    my ( $layout, $theme ) = @_;
    my $map = _read_created_registry();
    my $who = $map->{"$layout/$theme"};
    return ( defined $who && length $who ) ? $who : '';
}

sub _forget_theme_creator {
    my ( $layout, $theme ) = @_;
    my $map = _read_created_registry();
    return unless exists $map->{"$layout/$theme"};
    delete $map->{"$layout/$theme"};
    _write_created_registry($map);
    return;
}

# Carry provenance across a rename, or the theme stops being deletable by the
# account that made it - which would turn this fix into the litter problem
# SM262 set out to solve.
sub _rename_theme_creator {
    my ( $layout, $from, $to ) = @_;
    my $map = _read_created_registry();
    return unless exists $map->{"$layout/$from"};
    $map->{"$layout/$to"} = delete $map->{"$layout/$from"};
    _write_created_registry($map);
    return;
}

# SM204: the config (GROUP->KEY->value) map of a theme.json, keeping only
# scalar leaf values (mirrors generate_theme_css: nested objects under a group
# key are a shape error and skipped).
sub _theme_config_tokens {
    my ($theme_data) = @_;
    my %tokens;
    my $config = ( ref $theme_data eq 'HASH' ) ? $theme_data->{config} : undef;
    return \%tokens unless ref $config eq 'HASH';
    for my $group ( sort keys %{$config} ) {
        next unless ref $config->{$group} eq 'HASH';
        my %kv;
        for my $key ( sort keys %{ $config->{$group} } ) {
            my $val = $config->{$group}{$key};
            next if ref $val;
            $kv{$key} = $val;
        }
        $tokens{$group} = \%kv;
    }
    return \%tokens;
}

# SM203: the declared token vocabulary of a layout as GROUP -> { key => 1 }.
# Reads the OPTIONAL `tokens` block of layout.json (via _read_layout_json).
# Returns an empty hash when the block is absent - callers treat "no declared
# block" as "nothing to compare against" and skip the coverage check.
sub _layout_declared_tokens {
    my ($layout) = @_;
    my $ljson    = _read_layout_json($layout);
    my $decl     = ( ref $ljson eq 'HASH' ) ? $ljson->{tokens} : undef;
    my %declared;
    return \%declared unless ref $decl eq 'HASH';
    for my $group ( sort keys %{$decl} ) {
        my $keys = $decl->{$group};
        my @list =
            ( ref $keys eq 'ARRAY' )  ? @{$keys}
            : ( ref $keys eq 'HASH' ) ? ( sort keys %{$keys} )
            :                           ();
        $declared{$group} = { map { $_ => 1 } @list };
    }
    return \%declared;
}

# SM203/SM205: compare a layout's declared token vocabulary against a theme's
# supplied config. Returns undef when the layout declares no `tokens` block (the
# check is skipped); otherwise a hashref with:
#   declared => 1
#   missing  => [ "group.key", ... ]  # declared but the config omits them
#   extra    => [ "group.key", ... ]  # config supplies them, undeclared
# Warn-only by contract; never used to reject.
sub _token_mismatch {
    my ( $declared, $supplied ) = @_;
    return undef unless ref $declared eq 'HASH' && %{$declared};
    $supplied ||= {};
    my ( @missing, @extra );
    for my $group ( sort keys %{$declared} ) {
        for my $key ( sort keys %{ $declared->{$group} } ) {
            push @missing, "$group.$key"
                unless ref $supplied->{$group} eq 'HASH'
                && exists $supplied->{$group}{$key};
        }
    }
    for my $group ( sort keys %{$supplied} ) {
        next unless ref $supplied->{$group} eq 'HASH';
        for my $key ( sort keys %{ $supplied->{$group} } ) {
            push @extra, "$group.$key" unless $declared->{$group}{$key};
        }
    }
    return { declared => 1, missing => \@missing, extra => \@extra };
}

# SM203: mismatch between a layout's declared tokens and an ON-DISK theme's
# config (used at activation). Returns undef when there is no declared block.
sub _declared_token_mismatch {
    my ( $layout, $theme ) = @_;
    my $declared = _layout_declared_tokens($layout);
    return undef unless %{$declared};
    my $td = _read_theme_json( $layout, $theme );
    return _token_mismatch( $declared, _theme_config_tokens($td) );
}

# SM203/SM205: render a mismatch hashref as a flat list of human-readable
# warning strings for the action's return payload.
sub _token_warning_list {
    my ($tw) = @_;
    my @w;
    push @w, "theme omits declared token '$_' (layout CSS fallback applies)"
        for @{ $tw->{missing} };
    push @w, "config supplies undeclared token '$_'" for @{ $tw->{extra} };
    return \@w;
}

# SM205: eager value/name validation for a theme scaffold. Returns a list of
# specific rule-failure strings (empty = valid). The value rule mirrors the
# render-time emitter generate_theme_css, which strips ; { } < > and any
# non-ASCII from every value; catching those up front tells the author before a
# write rather than letting them be silently stripped at render. Kept in sync
# with that emitter by design (SM205 spec).
sub theme_config_issues {
    my ( $config, $name ) = @_;
    my @issues;
    if ( !defined $name || $name !~ /^[A-Za-z0-9_-]+$/ ) {
        push @issues, "name '" . ( defined $name ? $name : '' )
            . "' must match [A-Za-z0-9_-]+";
    }
    if ( ref $config eq 'HASH' ) {
        for my $group ( sort keys %{$config} ) {
            my $gv = $config->{$group};
            next unless ref $gv eq 'HASH';
            for my $key ( sort keys %{$gv} ) {
                my $v = $gv->{$key};
                next if ref $v;
                next unless defined $v;
                if ( $v =~ /[^\x00-\x7f]/ ) {
                    push @issues,
                        "config value at '$group.$key' contains non-ASCII characters";
                }
                if ( $v =~ /[;{}<>]/ ) {
                    push @issues,
                        "config value at '$group.$key' contains a forbidden character (one of ; { } < >)";
                }
            }
        }
    }
    return @issues;
}

# SM204 (feature theme_tokens): token-vocabulary discovery. A READ tool
# (manage_themes, not audited). Resolves a (layout, theme) pair, then returns
# the theme's config as the token vocabulary plus exemplar values.
#
#   theme given  -> that theme's config (under its layout, else the active one)
#   layout only  -> the layout's declared `tokens` block (SM203, if present)
#                   PLUS its default theme's config as exemplar values; when no
#                   block is declared the vocabulary is DERIVED from that config
#                   (derived => 1).
#   neither      -> the active layout + active theme.
sub action_theme_tokens {
    my ($params) = @_;
    $params ||= {};

    my ( $active_layout, $active_theme ) = _read_active_layout_and_theme();

    my $req_layout = $params->{layout};
    my $req_theme  = $params->{theme};
    $req_layout = undef unless defined $req_layout && length $req_layout;
    $req_theme  = undef unless defined $req_theme  && length $req_theme;

    for my $v ( $req_layout, $req_theme ) {
        next unless defined $v;
        return { ok => 0, error => 'Invalid layout/theme name.' }
            unless $v =~ /^[A-Za-z0-9_-]+$/;
    }

    # Explicit theme wins: report that theme's own config verbatim.
    if ( defined $req_theme ) {
        my $layout = defined $req_layout ? $req_layout : $active_layout;
        return { ok => 0, error => 'No layout to resolve the theme under.' }
            unless length $layout;
        my $td = _read_theme_json( $layout, $req_theme );
        return { ok => 0, error => "No such theme: $req_theme (layout $layout)." }
            unless $td;
        return {
            ok      => 1,
            layout  => $layout,
            theme   => $req_theme,
            derived => JSON::PP::false,
            tokens  => _theme_config_tokens($td),
        };
    }

    # Layout-scoped (or the active pair): resolve the exemplar theme.
    my $layout = defined $req_layout ? $req_layout : $active_layout;
    return { ok => 0, error => 'No layout is active or named.' }
        unless length $layout;

    my $ljson = _read_layout_json($layout);

    # The exemplar theme: the active theme when it is THIS layout's, else the
    # layout's declared default_theme.
    my $exemplar =
        ( $layout eq $active_layout && length $active_theme )
        ? $active_theme
        : ( $ljson->{default_theme} // '' );
    $exemplar = '' unless $exemplar =~ /^[A-Za-z0-9_-]+$/;

    my $td            = length $exemplar ? _read_theme_json( $layout, $exemplar ) : undef;
    my $config_tokens = _theme_config_tokens($td);

    # SM203 declared `tokens` block (GROUP -> [keys]); optional and may be absent.
    my %declared;
    my $decl = $ljson->{tokens};
    if ( ref $decl eq 'HASH' ) {
        for my $group ( sort keys %{$decl} ) {
            my $keys = $decl->{$group};
            $declared{$group} =
                ( ref $keys eq 'ARRAY' )  ? [ @{$keys} ]
                : ( ref $keys eq 'HASH' ) ? [ sort keys %{$keys} ]
                :                           [];
        }
    }

    my %out = (
        ok      => 1,
        layout  => $layout,
        theme   => $exemplar,
        derived => ( %declared ? JSON::PP::false : JSON::PP::true ),
        tokens  => $config_tokens,
    );
    $out{declared} = \%declared if %declared;
    return \%out;
}

sub action_theme_activate {
    my ( $theme_name, $params ) = @_;
    $params ||= {};
    $theme_name =~ s/[^a-zA-Z0-9_-]//g;

    # SM247: deactivation must be ASKED FOR, never inferred from a missing
    # parameter. The control API defaults `path` to '/', which this sanitiser
    # reduces to '', so calling theme-activate with the name in the wrong
    # parameter (theme= instead of path=) used to strip the site's theme and
    # return ok:1. A site agent did exactly that to a live site and only caught
    # it by checking theme-list afterwards; an agent trusting ok:1 would have
    # walked away leaving the site unstyled.
    #
    # An empty name is now an error. A caller that means it passes
    # deactivate => 1, which is a thing you can only do on purpose.
    if ( $theme_name eq '' ) {
        return _set_theme_pointer('') if $params->{deactivate};
        return { ok => 0, kind => 'missing-parameter',
            error => 'No theme name given. The theme name goes in the `path` '
                . 'parameter for this action. To deliberately remove the site\'s '
                . 'theme, pass deactivate=1 - an absent name is treated as a '
                . 'mistake, not as an instruction to de-theme the site.' };
    }

    my ( $active_layout, $old_theme ) = _read_active_layout_and_theme();
    return { ok => 0, error => "No active layout set" } unless length $active_layout;

    my $themes_dir = "$LAZYSITE_DIR/layouts/$active_layout/themes";
    my $theme_dir  = "$themes_dir/$theme_name";
    return { ok => 0, error => "Theme not found" } unless -d $theme_dir;

    # Artifact-level lock across validate -> snapshot -> flip.
    my $lock_rel = "lazysite/layouts/$active_layout/themes/$theme_name";
    my $lk       = acquire_lock( $lock_rel, $auth_user );
    unless ( $lk->{ok} ) {
        return { ok => 0, locked => 1, error => "Theme is locked by "
                . ( $lk->{locked_by} // 'another session' ) };
    }

    my $out = eval {
        my $v = _validate_theme_dir( $theme_dir, $active_layout );
        return { ok => 0, error => "Theme invalid: " . join( '; ', @{ $v->{errors} } ) }
            unless $v->{valid};

        if ( defined $params->{base} && length $params->{base} ) {
            return { ok => 0, conflict => 1,
                error => "Theme changed since the supplied base manifest" }
                if _artifact_digest($theme_dir) ne $params->{base};
        }

        if ( length $old_theme && $old_theme ne $theme_name ) {
            _snapshot_artifact( $themes_dir, $old_theme );
            _prune_backups( $themes_dir, $old_theme );
        }
        my $res = _set_theme_pointer($theme_name);
        my $mirror;
        if ( $res->{ok} ) {
            # SM315: keep the mirror result - zero assets is the signal that the
            # site will render unstyled, and the acknowledgement is the only
            # place a caller will see it.
            $mirror = _mirror_theme_assets( $active_layout, $theme_name );
            # SM203: warn (never reject) when the just-activated theme does not
            # match the layout's declared token vocabulary. The layout.json
            # `tokens` block is OPTIONAL; the check is skipped entirely when it
            # is absent. The fallback chain (var(--theme-*, <fallback>)) makes a
            # mismatch survivable by design, so this is documentation-grade
            # signal only.
            my $tw = _declared_token_mismatch( $active_layout, $theme_name );
            if ( $tw && ( @{ $tw->{missing} } || @{ $tw->{extra} } ) ) {
                log_event( 'WARN', 'theme-activate', 'declared token mismatch',
                    layout     => $active_layout,
                    theme      => $theme_name,
                    missing    => join( ',', @{ $tw->{missing} } ),
                    undeclared => join( ',', @{ $tw->{extra} } ) );
                $res->{token_warnings} = _token_warning_list($tw);
            }
        }

        # SM315: report the mirror, always - a count of zero is the whole point.
        # A theme that declares colours and fonts and mirrors nothing is a site
        # about to render unstyled, and at the HTTP level that is
        # indistinguishable from a working one: every page returns 200.
        if ( ref $mirror eq 'HASH' ) {
            $res->{assets_mirrored} = $mirror->{mirrored};
            if ( !$mirror->{mirrored} ) {
                push @{ $res->{warnings} ||= [] },
                    'no theme assets were mirrored: '
                    . ( $mirror->{reason} // 'unknown' )
                    . ( $mirror->{expected}
                    ? ". Assets belong in $mirror->{expected}"
                    : '' )
                    . ( $mirror->{misplaced}
                    ? ' (found outside it: '
                        . join( ', ', @{ $mirror->{misplaced} } ) . ')'
                    : '' )
                    . '. The site will render with no stylesheet, and every '
                    . 'page will still return 200.';
            }
        }
        return $res;
    };
    my $err = $@;
    release_lock( $lock_rel, $auth_user );
    die $err if $err;
    return $out;
}

# SM205: validated theme scaffolding. Creates
# lazysite/layouts/LAYOUT/themes/NAME/ with a theme.json (layouts:[LAYOUT],
# name, version, author, config) and assets/main.css, optionally activating.
# EAGER validation (name + config value rules, layout installed) returns
# { ok => 0, kind => 'validation', ... } BEFORE writing anything. The
# declared-token coverage check (SM203) is warn-only.
sub action_create_theme {
    my ($params) = @_;
    $params ||= {};

    my $layout = $params->{layout};
    my $name   = $params->{name};
    my $config = $params->{config};
    $config = {} unless ref $config eq 'HASH';

    return { ok => 0, kind => 'validation', error => 'layout is required.' }
        unless defined $layout && length $layout;
    return { ok => 0, kind => 'validation', error => 'name is required.' }
        unless defined $name && length $name;

    # Eager name + value validation (before any write).
    my @issues = theme_config_issues( $config, $name );
    if ( defined $layout && $layout !~ /^[A-Za-z0-9_-]+$/ ) {
        push @issues, "layout '$layout' must match [A-Za-z0-9_-]+";
    }
    return { ok => 0, kind => 'validation',
        error  => 'theme validation failed: ' . join( '; ', @issues ),
        issues => \@issues }
        if @issues;

    my $layout_dir = "$LAZYSITE_DIR/layouts/$layout";
    return { ok => 0, kind => 'validation',
        error => "layout '$layout' is not installed." }
        unless -f "$layout_dir/layout.tt";

    my $theme_dir = "$layout_dir/themes/$name";
    return { ok => 0, kind => 'exists',
        error => "a theme named '$name' already exists under layout '$layout'." }
        if -d $theme_dir;

    # SM203 coverage check (warn, never reject).
    my $declared = _layout_declared_tokens($layout);
    my $tw = _token_mismatch( $declared, _theme_config_tokens( { config => $config } ) );
    my @warnings = $tw ? @{ _token_warning_list($tw) } : ();

    # SM243/SM250: a theme that hides the layout's chrome, or hides content until
    # a script reveals it, is a silent and total failure - and it survives casual
    # checking, because the part above the fold is usually unaffected. Both were
    # paid for on live sites: one left a site's navigation unreachable while
    # looking correct, the other left every section below the hero invisible
    # through four successive visual checks. Warn, never reject: both patterns are
    # legitimate with a fallback, and a platform that refused them would be wrong
    # more often than the authors it protected.
    if ( defined $params->{css} && length $params->{css} ) {
        my $css = $params->{css};
        if ( $css =~ m{ (?:\.site-header|\.site-footer|\bheader\b|\bfooter\b)
                        [^{}]* \{ [^{}]*? display \s*:\s* none }six )
        {
            push @warnings,
                'this theme hides the layout\'s header or footer. If the page '
                . 'content carries its own, the site navigation becomes '
                . 'unreachable - an operator can set nav items that never appear '
                . 'anywhere. Remove the chrome from the content instead.';
        }
        # opacity:0 (or visibility:hidden) revealed by a class a script adds. A
        # rule inside prefers-reduced-motion is NOT a neutraliser - it applies to
        # a minority of visitors, and reading it as one is exactly what caused
        # the reported outage.
        if ( $css =~ m{ opacity \s*:\s* 0 \b }six
            || $css =~ m{ visibility \s*:\s* hidden \b }six )
        {
            push @warnings,
                'this theme sets content invisible by default (opacity:0 / '
                . 'visibility:hidden). If only a script reveals it, then visitors '
                . 'without JavaScript and most crawlers see nothing - and removing '
                . 'that script later hides the site silently. Start from a visible '
                . 'state, or provide a non-script fallback. A rule inside '
                . '@media(prefers-reduced-motion) does NOT count: it applies only '
                . 'to visitors who asked for reduced motion.';
        }
    }

    # Scaffold. theme.json + assets/main.css (never a root-level main.css - it
    # 404s after the asset mirror). CSS: caller-supplied, else copy the layout
    # default theme's main.css as the copy-nearest-and-adapt starting point.
    make_path("$theme_dir/assets");

    my $author = ( defined $auth_user && length $auth_user ) ? $auth_user : 'unknown';
    my $meta   = {
        name    => $name,
        version => ( defined $params->{version} && length $params->{version} )
        ? $params->{version}
        : '1.0.0',
        layouts => [$layout],
        author  => $author,
        # SM262: provenance for the delete rule, kept SEPARATE from `author`.
        # `author` is a descriptive theme.json field the theme itself may carry
        # and edit; this one exists to answer "may this caller remove it", and
        # conflating a description with an authorisation would mean a theme could
        # rewrite its own permissions. Absent means "not created through this
        # path", which is the safe reading: an agent can never delete a theme
        # that predates the field.
        created_by => $author,
        config     => $config,
        ( defined $params->{description} && length $params->{description}
            ? ( description => $params->{description} ) : () ),
        ( ref $params->{tags} eq 'ARRAY' ? ( tags => $params->{tags} ) : () ),
    };

    my @created;
    {
        my $tj  = "$theme_dir/theme.json";
        my $enc = JSON::PP->new->utf8->pretty->canonical->encode($meta);
        open my $fh, '>:raw', $tj
            or return { ok => 0, error => "Cannot write theme.json" };
        print {$fh} $enc;
        close $fh;
        push @created, "lazysite/layouts/$layout/themes/$name/theme.json";
        # SM268 04-F6: the authoritative copy of "who made this", out of reach
        # of the caller. theme.json's created_by above is now description only.
        _record_theme_creator( $layout, $name, $author );
    }

    {
        my $css_path = "$theme_dir/assets/main.css";
        if ( defined $params->{css} ) {
            open my $fh, '>:utf8', $css_path
                or return { ok => 0, error => "Cannot write main.css" };
            print {$fh} $params->{css};
            close $fh;
        }
        else {
            # Copy the layout default theme's main.css as the starting point.
            my $ljson = _read_layout_json($layout);
            my $dt    = ( ref $ljson eq 'HASH' ) ? ( $ljson->{default_theme} // '' ) : '';
            $dt = '' unless $dt =~ /^[A-Za-z0-9_-]+$/;
            my $src =
                length $dt
                ? "$layout_dir/themes/$dt/assets/main.css"
                : '';
            if ( length $src && -f $src ) {
                copy( $src, $css_path );
            }
            else {
                # No default CSS to copy - leave a minimal placeholder so the
                # asset exists (a missing main.css would 404 after the mirror).
                open my $fh, '>:utf8', $css_path
                    or return { ok => 0, error => "Cannot write main.css" };
                print {$fh} "/* $name theme for $layout - starting point */\n";
                close $fh;
            }
        }
        push @created, "lazysite/layouts/$layout/themes/$name/assets/main.css";
    }

    # SM176: record a pristine baseline so an unedited theme does not spawn a
    # pointless backup when switched away from.
    _write_pristine( "$layout_dir/themes", $name, _artifact_digest($theme_dir) );

    log_event( 'INFO', $action, 'theme created',
        layout => $layout, theme => $name, user => $author );

    my %out = ( ok => 1, layout => $layout, theme => $name, created => \@created );
    $out{warnings} = \@warnings if @warnings;

    # Preview guidance: pre-activation, the theme is served from its SOURCE
    # assets path; post-activation (activate:true) from the mirror.
    my $activated = 0;
    if ( $params->{activate} ) {
        my $act = action_theme_activate( $name, {} );
        $out{activation} = $act;
        if ( $act && $act->{ok} ) {
            $activated = 1;
            # Fold activation-time token warnings in too.
            if ( ref $act->{token_warnings} eq 'ARRAY' && @{ $act->{token_warnings} } ) {
                push @{ $out{warnings} }, @{ $act->{token_warnings} };
            }
        }
    }

    $out{preview} = $activated
        ? "Activated. The theme's assets are served from "
        . "/lazysite-assets/$layout/$name/main.css (mirror)."
        : "Not activated. Preview the source CSS at "
        . "/lazysite/layouts/$layout/themes/$name/assets/main.css, "
        . "or call activate_theme to make it live.";

    return \%out;
}

sub _set_theme_pointer {
    my ($theme_name) = @_;
    my $conf_path = _lz() . "/lazysite.conf";
    return { ok => 0, error => "Cannot read conf" } unless -f $conf_path;
    open my $fh, '<:utf8', $conf_path or return { ok => 0, error => "Cannot read conf" };
    my $conf = do { local $/; <$fh> };
    close $fh;
    if    ( $theme_name eq '' )      { $conf =~ s/^theme\s*:.*\n?//m }
    elsif ( $conf =~ /^theme\s*:/m ) { $conf =~ s/^theme\s*:.*$/theme: $theme_name/m }
    else                             { $conf .= "\ntheme: $theme_name\n" }
    my ( $wok, $werr ) = _write_conf_content( $conf,
        ( length $theme_name ? "activate theme $theme_name" : 'deactivate theme' ) );
    return { ok => 0, error => "Cannot write conf: $werr" } unless $wok;
    _invalidate_html_cache();
    return { ok => 1, theme => $theme_name };
}

sub _invalidate_html_cache {
    find( sub {
            return unless /\.html$/;
            my $rel = $File::Find::name;
            $rel =~ s{^\Q$DOCROOT\E/?}{/};
            return if $rel =~ m{^/lazysite/};
            # Only delete a GENERATED cache file: a <page>.html whose <page>.md or
            # <page>.url source exists. An author-supplied .html with no such
            # source (e.g. an include partial) is content, not cache - never
            # delete it (deleting author partials gutted pages, SM072 report).
            ( my $base = $File::Find::name ) =~ s/\.html$//;
            unlink $_ if -f "$base.md" || -f "$base.url";
    }, $DOCROOT );
    # SM110: a theme/layout change re-chromes every page of every host -
    # drop the per-alias-host cache tree wholesale too.
    Lazysite::Util::clear_host_cache($DOCROOT);
    return;
}

# SM080: build the web-served asset mirror at /lazysite-assets/LAYOUT/THEME/ so
# the processor's `theme_assets` variable resolves after ACTIVATION, not only
# after a repo install. Without this a copied-then-activated layout/theme 404s
# its CSS (theme_assets points at a mirror that was never built), which forced
# layout.tt to hardcode the source path and blocked drop-in layout copies.
# Idempotent; a no-op when the theme has no assets/ dir.
# SM315: say how many assets were mirrored, and where they were expected.
#
# This returned nothing and no-opped silently when the theme had no `assets/`
# directory. Put a theme's CSS one level higher - at `themes/<theme>/` beside
# theme.json, which is where an author who has not dissected a working layout
# will naturally put it - and: the upload succeeds, activate_layout returns
# ok:1, the mirror is empty, `theme_assets` resolves to nothing, the stylesheet
# link is never emitted, and every page returns 200 completely unstyled.
#
# Measured on edge/0.10.9 while authoring a layout. The diagnosis took a
# screenshot: at the HTTP level a fully unstyled site is indistinguishable from a
# working one, and an agent building over MCP and WebDAV has no screenshot step.
# It would hand over an unstyled site reporting success.
#
# The tool already knew. It counted nothing and said nothing, and zero assets for
# a theme that declares colours and fonts is almost always a mistake - so the one
# place that can say so is the acknowledgement the caller is already reading.
sub _mirror_theme_assets {
    my ( $layout, $theme ) = @_;
    return { mirrored => 0, reason => 'no layout or theme named' }
        unless length $layout && length $theme;

    my $tdir = "$LAZYSITE_DIR/layouts/$layout/themes/$theme";
    my $src  = "$tdir/assets";
    my $dest = "$DOCROOT/lazysite-assets/$layout/$theme";

    unless ( -d $src ) {
        # Is there something that LOOKS like a misplaced asset? A .css or .js
        # sitting directly in the theme directory beside theme.json is almost
        # certainly meant to be served, and naming it costs one directory read.
        my @misplaced;
        if ( opendir my $dh, $tdir ) {
            @misplaced = sort grep { /\.(?:css|js|woff2?|ttf|png|jpe?g|svg|webp)\z/i }
                readdir $dh;
            closedir $dh;
        }
        return {
            mirrored => 0,
            dest     => $dest,
            expected => $src,
            ( @misplaced ? ( misplaced => \@misplaced ) : () ),
            reason => (
                @misplaced
                ? 'the theme has files that look like assets, but they are not '
                    . "in assets/ - the engine mirrors $src and nothing else, so "
                    . 'the site will render unstyled'
                : 'the theme declares no assets/ directory'
            ),
        };
    }

    make_path($dest) unless -d $dest;
    my $rc = system( 'cp', '-r', "$src/.", $dest );
    if ( $rc != 0 ) {
        log_event( 'WARN', $action, 'theme asset mirror failed',
            layout => $layout, theme => $theme, rc => ( $rc >> 8 ) );
        return { mirrored => 0, dest => $dest, expected => $src,
            reason => 'the copy into the web asset mirror failed' };
    }

    # Count what is actually THERE now, rather than what we believed we copied.
    # A count of intentions is the thing this filing exists to stop.
    my $n = 0;
    File::Find::find(
        { no_chdir => 1, wanted => sub { $n++ if -f $File::Find::name } },
        $dest ) if -d $dest;

    return { mirrored => $n, dest => $dest, expected => $src };
}

sub _validate_theme_dir {
    my ( $dir, $layout ) = @_;
    my $tj = "$dir/theme.json";
    return { valid => 0, errors => ['theme.json missing'] } unless -f $tj;
    open my $fh, '<:utf8', $tj
        or return { valid => 0, errors => ['theme.json unreadable'] };
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $data = eval { decode_json($raw) };
    my @err;
    if ( ref $data ne 'HASH' ) {
        my $why = $@ ? do { ( my $e = $@ ) =~ s/\s+at \S+ line \d+.*//s; $e =~ s/\s+$//; $e }
            :   'top level is not a JSON object';
        push @err, "theme.json invalid: $why";
    }
    elsif ( ref $data->{layouts} ne 'ARRAY' || !@{ $data->{layouts} } ) {
        push @err, 'theme.json layouts[] missing or empty';
    }
    elsif ( !grep { $_ eq $layout } @{ $data->{layouts} } ) {
        push @err, "theme not declared for active layout '$layout'";
    }
    return { valid => ( @err ? 0 : 1 ), errors => \@err };
}

# Strip a trailing -backup-<ts> so a backup OF a backup groups under the original
# base name instead of chaining (foo-backup-T1-backup-T2-backup-T3...).
sub _backup_base {
    ( my $base = $_[0] ) =~ s/-backup-\d{8}T\d{6}Z\z//;
    return $base;
}

sub _latest_backup_dir {
    my ( $parent, $base ) = @_;
    opendir my $dh, $parent or return undef;
    my @b = sort grep { /^\Q$base\E-backup-/ && -d "$parent/$_" } readdir $dh;
    closedir $dh;
    return @b ? "$parent/$b[-1]" : undef;    # timestamps sort lexically; last = newest
}

# SM176: a per-theme "pristine" baseline - the artifact digest captured at
# install. Stored as a dotfile in the themes dir (skipped by the theme listing
# and by the backup scan) and OUTSIDE the theme dir, so it never perturbs the
# theme's own digest. A theme whose current digest still equals this baseline has
# no operator edits, so switching away from it must not spawn a backup.
sub _pristine_path { return "$_[0]/.pristine-$_[1]" }

sub _write_pristine {
    my ( $parent, $name, $digest ) = @_;
    return unless defined $digest && $digest =~ /\A[0-9a-f]{64}\z/;
    if ( open my $fh, '>', _pristine_path( $parent, $name ) ) {
        print {$fh} "$digest\n";
        close $fh;
    }
    return;
}

sub _read_pristine {
    my ( $parent, $name ) = @_;
    open my $fh, '<', _pristine_path( $parent, $name ) or return undef;
    my $d = <$fh>;
    close $fh;
    chomp $d if defined $d;
    return ( defined $d && $d =~ /\A[0-9a-f]{64}\z/ ) ? $d : undef;
}

sub _snapshot_artifact {
    my ( $parent, $name ) = @_;
    my $src = "$parent/$name";
    return unless -d $src;
    my $base = _backup_base($name);
    my $cur  = _artifact_digest($src);
    # SM176: a theme unchanged since it was installed (still at its pristine
    # baseline) has no edits worth preserving - switching away from it must not
    # snapshot it. Themes installed before this baseline existed fall through to
    # the last-backup check below (unchanged pre-SM176 behaviour).
    my $pristine = _read_pristine( $parent, $name );
    return if defined $pristine && $pristine eq $cur;
    # Only snapshot when something actually CHANGED since the last backup. Just
    # trying themes on and off (which edits nothing) must not spawn a pile of
    # identical snapshots.
    if ( my $latest = _latest_backup_dir( $parent, $base ) ) {
        # $latest ne $src: when the source IS itself a backup dir, don't compare
        # it to itself (that would always "match" and wrongly skip).
        return if $latest ne $src && $cur eq _artifact_digest($latest);
    }
    my $dst = "$parent/$base-backup-" . strftime( '%Y%m%dT%H%M%SZ', gmtime );
    return if -e $dst;
    system( 'cp', '-r', $src, $dst );
}

sub _prune_backups {
    my ( $parent, $name ) = @_;
    my $keep = _backup_retention();
    return if $keep <= 0;    # 0 (or negative) = keep all
    my $base = _backup_base($name);
    opendir my $dh, $parent or return;
    my @backups = sort grep { /^\Q$base\E-backup-/ && -d "$parent/$_" } readdir $dh;
    closedir $dh;
    while ( @backups > $keep ) {
        my $old = shift @backups;
        system( 'rm', '-rf', "$parent/$old" );
    }
}

sub _backup_retention {
    my $n = 3;
    if ( open my $fh, '<', _lz() . "/lazysite.conf" ) {
        while (<$fh>) { if (/^backup_retention\s*:\s*(-?\d+)/) { $n = $1; last } }
        close $fh;
    }
    return $n;
}

# The theme a layout should use when none is carried over: its declared
# default_theme if that declares the layout, else the first installed theme that
# declares it, else '' (the layout renders with no theme override).
sub _default_theme_for_layout {
    my ($layout) = @_;
    my $ldir = "$LAZYSITE_DIR/layouts/$layout";
    if ( open my $jf, '<:utf8', "$ldir/layout.json" ) {
        my $raw = do { local $/; <$jf> };
        close $jf;
        my $meta = eval { decode_json($raw) };
        my $dt   = ( ref $meta eq 'HASH' ) ? ( $meta->{default_theme} // '' ) : '';
        return $dt if length $dt && _theme_declares_layout( $layout, $dt );
    }
    if ( opendir my $dh, "$ldir/themes" ) {
        for my $name ( sort readdir $dh ) {
            next if $name =~ /^\./ || $name =~ /-backup-\d/;
            next unless $name =~ /^[A-Za-z0-9_-]+$/;
            next unless -f "$ldir/themes/$name/theme.json";
            if ( _theme_declares_layout( $layout, $name ) ) { closedir $dh; return $name }
        }
        closedir $dh;
    }
    return '';
}

sub action_layout_activate {
    my ( $layout_name, $params ) = @_;
    $params ||= {};
    $layout_name =~ s/[^a-zA-Z0-9_-]//g;
    return { ok => 0, error => "Layout name required" } unless length $layout_name;

    my ( $old_layout, $cur_theme ) = _read_active_layout_and_theme();
    my $layout_dir = "$LAZYSITE_DIR/layouts/$layout_name";
    return { ok => 0, error => "Layout not found" } unless -d $layout_dir;

    my $theme = defined $params->{theme} ? $params->{theme} : $cur_theme;
    $theme = '' unless defined $theme;
    $theme =~ s/[^a-zA-Z0-9_-]//g;
    my $theme_specified = ( defined $params->{theme} && length $params->{theme} ) ? 1 : 0;

    my $lock_rel = "lazysite/layouts/$layout_name";
    my $lk       = acquire_lock( $lock_rel, $auth_user );
    unless ( $lk->{ok} ) {
        return { ok => 0, locked => 1, error => "Layout is locked by "
                . ( $lk->{locked_by} // 'another session' ) };
    }

    my $out = eval {
        my $v = _validate_layout_dir($layout_dir);
        return { ok => 0, error => "Layout invalid: " . join( '; ', @{ $v->{errors} } ) }
            unless $v->{valid};
        my $renders = $v->{renders} || {};

        # Compatible (layout, theme) pair. The live theme name is carried over by
        # default; if it isn't declared for the NEW layout, only refuse when the
        # caller explicitly named it - otherwise fall back to the new layout's own
        # default theme so the switch still succeeds (was: a hard error that made a
        # layout unselectable unless it happened to have a same-named theme).
        if ( length $theme && !_theme_declares_layout( $layout_name, $theme ) ) {
            if ($theme_specified) {
                return { ok => 0, incompatible => 1,
                    error => "Theme '$theme' is not declared for layout '$layout_name'"
                        . " - name a compatible theme to switch to" };
            }
            $theme           = _default_theme_for_layout($layout_name);
            $theme_specified = 1 if length $theme;
        }

        if ( defined $params->{base} && length $params->{base} ) {
            return { ok => 0, conflict => 1,
                error => "Layout changed since the supplied base manifest" }
                if _artifact_digest($layout_dir) ne $params->{base};
        }

        if ( length $old_layout && $old_layout ne $layout_name ) {
            _snapshot_artifact( "$LAZYSITE_DIR/layouts", $old_layout );
            _prune_backups( "$LAZYSITE_DIR/layouts", $old_layout );
        }
        my $res = _set_layout_pointer( $layout_name,
            ( $theme_specified && length $theme ) ? $theme : undef );
        _mirror_theme_assets( $layout_name, ( length $theme ? $theme : $cur_theme ) )
            if $res->{ok};

        # SM337: say what was bound, not merely that something was.
        if ( $res->{ok} ) {
            $res->{renders} = $renders;
            unless ( $renders->{nav} ) {
                # A WARNING, not a refusal. Activating a showcase layout is a
                # legitimate choice; being unable to tell that you have is not.
                $res->{warning} =
                    "'$layout_name' does not render the site's navigation - "
                    . 'it has no [% nav %], so nav.conf will have no effect on '
                    . 'pages using it. Activated anyway; this is a note, not a '
                    . 'refusal.';
            }
        }
        return $res;
    };
    my $err = $@;
    release_lock( $lock_rel, $auth_user );
    die $err if $err;
    return $out;
}

sub _set_layout_pointer {
    my ( $layout, $theme ) = @_;
    my $conf_path = _lz() . "/lazysite.conf";
    return { ok => 0, error => "Cannot read conf" } unless -f $conf_path;
    open my $fh, '<:utf8', $conf_path or return { ok => 0, error => "Cannot read conf" };
    my $conf = do { local $/; <$fh> };
    close $fh;
    if ( $conf =~ /^layout\s*:/m ) { $conf =~ s/^layout\s*:.*$/layout: $layout/m }
    else                           { $conf .= "\nlayout: $layout\n" }
    if ( defined $theme ) {
        if ( $conf =~ /^theme\s*:/m ) { $conf =~ s/^theme\s*:.*$/theme: $theme/m }
        else                          { $conf .= "\ntheme: $theme\n" }
    }
    my ( $wok, $werr ) = _write_conf_content( $conf,
        "activate layout $layout" . ( defined $theme ? " with theme $theme" : '' ) );
    return { ok => 0, error => "Cannot write conf: $werr" } unless $wok;
    _invalidate_html_cache();
    return { ok => 1, layout => $layout, ( defined $theme ? ( theme => $theme ) : () ) };
}

sub _validate_layout_dir {
    my ($dir) = @_;
    my $lt = "$dir/layout.tt";
    return { valid => 0, errors => ['layout.tt missing'] } unless -f $lt;
    # SM337: WHAT DOES THIS LAYOUT ACTUALLY RENDER?
    #
    # The source is already open here, so the answer costs a regex. It was not
    # being asked, and the consequence was that installing a layout, activating
    # it, saving a navigation and fetching the page all returned success while
    # the site's own menu was never rendered - 22 of 23 catalogue layouts carry
    # hard-coded links belonging to the theme gallery they were built for, and
    # one of them renders a fictional company name on whatever site activates it.
    #
    # Every signal said it worked, so the only way to find out was to install a
    # layout, bind it to a domain, render a page and look - a step an agent has
    # no reason to insert after four consecutive ok:1 responses.
    #
    # This does not refuse anything. A showcase layout is a legitimate thing to
    # activate and the caller may want exactly that. What changes is that the
    # acknowledgement stops being indistinguishable from binding a working site
    # layout.
    my $src = '';
    if ( open my $fh, '<:utf8', $lt ) {
        local $/;
        $src = <$fh> // '';
        close $fh;
    }

    # The documented contract is `[% nav %]` and `[% content %]`. Matched
    # loosely on the directive name so `[%nav%]`, `[% nav %]` and a filtered
    # `[% nav | ... %]` all count - a layout that renders the navigation
    # through a filter still renders the navigation.
    #
    # SM362 asks the adjacent question and the same read answers it: the engine
    # resolves page_meta_title and page_meta_desc for the layout to use, and
    # every catalogue layout overwrites them, so those two are reported here
    # too rather than needing a second survey.
    my %renders = (
        nav        => ( $src =~ /\[%[-+]?\s*nav\b/             ? 1 : 0 ),
        content    => ( $src =~ /\[%[-+]?\s*content\b/         ? 1 : 0 ),
        meta_title => ( $src =~ /\[%[-+]?\s*page_meta_title\b/ ? 1 : 0 ),
        meta_desc  => ( $src =~ /\[%[-+]?\s*page_meta_desc\b/  ? 1 : 0 ),
    );

    my $ok = eval {
        require Template::Parser;
        my $p = Template::Parser->new( {} );
        $p->parse($src) or die( $p->error . "\n" );
        1;
    };
    return { valid => 1, errors => [], renders => \%renders } if $ok;
    my $e = $@ || 'parse error';
    return { valid => 1, errors => [], renders => \%renders }
        if $e =~ /Can't locate Template/;
    chomp $e;
    return { valid => 0, errors => ["layout.tt does not compile: $e"],
        renders => \%renders };
}

sub _theme_declares_layout {
    my ( $layout, $theme ) = @_;
    my $tj = "$LAZYSITE_DIR/layouts/$layout/themes/$theme/theme.json";
    return 0 unless -f $tj;
    open my $fh, '<:utf8', $tj or return 0;
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $data = eval { decode_json($raw) };
    return 0 unless ref $data eq 'HASH' && ref $data->{layouts} eq 'ARRAY';
    return ( grep { $_ eq $layout } @{ $data->{layouts} } ) ? 1 : 0;
}

sub action_theme_delete {
    my ( $theme_name, $opts ) = @_;
    $theme_name =~ s/[^a-zA-Z0-9_-]//g;
    $opts ||= {};

    my ( $active_layout, $active_theme ) = _read_active_layout_and_theme();
    return { ok => 0, error => "Cannot delete the active theme" }
        if $theme_name eq $active_theme;
    return { ok => 0, error => "No active layout set" }
        unless length $active_layout;

    # SM177: a sub-domain is a first-class peer - if any registered domain uses
    # this theme (under the active layout, where it lives), deleting it would
    # break that domain. Block and name them, just as the active-theme guard does
    # for the primary. domains_using resolves effective per-host values, so an
    # alias that inherits the active layout but pins this theme is caught.
    local $Lazysite::Manager::Domains::DOCROOT = $DOCROOT;
    my @in_use = Lazysite::Manager::Domains::domains_using(
        theme => $theme_name, layout => $active_layout );
    if (@in_use) {
        return { ok => 0,
            error => "Theme '$theme_name' is in use by "
                . join( ', ', @in_use )
                . ". Repoint or remove those domains first." };
    }

    # D013: delete only from the active layout's themes dir. A theme
    # installed under multiple layouts (via theme.json's layouts[])
    # has copies elsewhere — those remain, and the operator can remove
    # them by switching to each layout in turn.
    my $themes_dir = _lz() . "/layouts/$active_layout/themes";
    my $theme_dir  = "$themes_dir/$theme_name";
    return { ok => 0, error => "Theme not found" } unless -d $theme_dir;

    # SM262: an agent that can create a theme could not remove one, so every
    # experiment it ran was permanent and only the operator could clear it -
    # create-without-delete makes agents into litter generators. The grant is the
    # narrowest that solves that: delete what YOU created, and nothing else. A
    # theme with no created_by predates the field or arrived another way, and is
    # never removable this way, so an agent gains no authority over anything that
    # existed before it did.
    #
    # Applied only when the caller asks for it. The manager UI over a cookie
    # session is a human at the console and keeps the unrestricted delete; the
    # dispatcher sets this for token and MCP clients.
    # SM268 04-F6: provenance comes from a SIDE RECORD, not from theme.json.
    #
    # theme.json lives under lazysite/layouts/**, which the very capability this
    # rule restricts (manage_themes) makes writable through write_file,
    # upload_file and WebDAV - so the restriction was self-certified by data the
    # restricted party controls. An agent rewrote created_by to its own name and
    # deleted any non-active theme on the instance, operator-authored ones
    # included, and the audit line said it had deleted its own.
    #
    # themes-created.json sits in lazysite/auth/, which the blocklist denies on
    # every authoring surface, so the answer is now kept where the caller cannot
    # reach it. theme.json's created_by stays as a description; it is no longer
    # an authorisation. A theme with no side record is never removable this way,
    # which is the same safe reading as before.
    if ( $opts->{restrict_to_creator} ) {
        my $who = $opts->{user} // '';
        my $by  = _theme_creator( $active_layout, $theme_name );
        unless ( length $who && length $by && $by eq $who ) {
            return { ok => 0, kind => 'not-yours',
                error => "Theme '$theme_name' was not created by this account, so "
                    . 'it cannot be removed over this channel. You may delete '
                    . 'themes you created yourself; anything else is an operator '
                    . 'action from the manager.' };
        }
    }

    my $real = realpath($theme_dir);
    return { ok => 0, error => "Invalid theme path" }
        unless $real && index( $real, $themes_dir ) == 0;

    my $rc = system( "rm", "-rf", $theme_dir );
    if ( $rc != 0 ) {
        log_event( 'ERROR', 'theme-delete', 'rm failed',
            path => $theme_dir, rc => ( $rc >> 8 ) );
        return { ok => 0, error => "Delete failed" };
    }
    # The theme is gone; drop its provenance so a later theme reusing the name
    # does not inherit a creator it never had.
    _forget_theme_creator( $active_layout, $theme_name );
    my $assets_dir = "$DOCROOT/lazysite-assets/$active_layout/$theme_name";
    if ( -d $assets_dir ) {
        $rc = system( "rm", "-rf", $assets_dir );
        if ( $rc != 0 ) {
            log_event( 'WARN', 'theme-delete', 'rm assets failed',
                path => $assets_dir, rc => ( $rc >> 8 ) );
        }
    }

    return { ok => 1, deleted => $theme_name };
}

sub action_theme_rename {
    my ( $old_name, $new_name ) = @_;
    $old_name =~ s/[^a-zA-Z0-9_-]//g;
    $new_name =~ s/[^a-zA-Z0-9_-]//g if defined $new_name;
    $new_name = lc( $new_name // '' );

    return { ok => 0, error => "Invalid name" } unless $old_name && $new_name;

    my ($active_layout) = _read_active_layout_and_theme();
    return { ok => 0, error => "No active layout set" }
        unless length $active_layout;

    my $themes_dir = _lz() . "/layouts/$active_layout/themes";
    return { ok => 0, error => "Theme not found" } unless -d "$themes_dir/$old_name";
    return { ok => 0, error => "Name already in use" } if -d "$themes_dir/$new_name";

    rename "$themes_dir/$old_name", "$themes_dir/$new_name";
    _rename_theme_creator( $active_layout, $old_name, $new_name );

    my $old_assets = "$DOCROOT/lazysite-assets/$active_layout/$old_name";
    my $new_assets = "$DOCROOT/lazysite-assets/$active_layout/$new_name";
    rename $old_assets, $new_assets if -d $old_assets;

    return { ok => 1, old => $old_name, new => $new_name };
}

sub action_theme_upload {
    my ( $zip_data, $filename ) = @_;

    # M-4: use Archive::Zip for safe extraction with per-entry path
    # validation, replacing system("unzip") which had to be trusted not
    # to zip-slip. Archive::Zip is an optional dep - install.sh warns if
    # missing, and this action returns a clear error instead of crashing.
    my $have_azip = eval { require Archive::Zip; Archive::Zip->import(qw(:ERROR_CODES)); 1 };
    unless ($have_azip) {
        return { ok => 0,
            error => "Archive::Zip not installed (apt-get install libarchive-zip-perl)" };
    }

    my $tmp_dir = "/tmp/lazysite-theme-$$";
    make_path($tmp_dir);

    my $zip_path = "$tmp_dir/upload.zip";
    open my $fh, '>:raw', $zip_path
        or do { _cleanup_tmp($tmp_dir); return { ok => 0, error => "Cannot write upload" } };
    print $fh $zip_data;
    close $fh;

    my $extract_dir = "$tmp_dir/extracted";
    make_path($extract_dir);

    my $extract_real = realpath($extract_dir);
    unless ( defined $extract_real ) {
        _cleanup_tmp($tmp_dir);
        return { ok => 0, error => "Cannot resolve extract dir" };
    }

    my $zip = Archive::Zip->new();
    unless ( $zip->read($zip_path) == Archive::Zip::AZ_OK() ) {
        _cleanup_tmp($tmp_dir);
        return { ok => 0, error => "Cannot read uploaded zip" };
    }

    # Validate every entry before extracting any.
    for my $member ( $zip->members ) {
        my $name = $member->fileName;
        if ( $name =~ m{\A/} ) {
            _cleanup_tmp($tmp_dir);
            return { ok => 0, error => "Zip entry has absolute path: $name" };
        }
        if ( $name =~ m{(?:^|/)\.\.(?:/|$)} ) {
            _cleanup_tmp($tmp_dir);
            return { ok => 0, error => "Zip slip detected in: $name" };
        }
    }

    # Extract with tree layout under $extract_dir. extractTree returns
    # AZ_OK on full success.
    unless ( $zip->extractTree( '', "$extract_dir/" ) == Archive::Zip::AZ_OK() ) {
        _cleanup_tmp($tmp_dir);
        return { ok => 0, error => "Extraction failed" };
    }

    my $result = _install_theme_from_dir( $extract_dir, $action, $auth_user );
    _cleanup_tmp($tmp_dir);
    return $result;
}

sub _install_theme_from_dir {
    my ( $extract_dir, $action_label, $user, $update ) = @_;

    return { ok => 0, error => "Upload must contain theme.json" }
        unless -f "$extract_dir/theme.json";

    open my $jf, '<:utf8', "$extract_dir/theme.json"
        or return { ok => 0, error => "Cannot read theme.json" };
    my $json = do { local $/; <$jf> };
    close $jf;
    my $meta = eval { decode_json($json) }
        or return { ok => 0, error => "Invalid theme.json" };

    my $theme_name = $meta->{name} // '';
    $theme_name =~ s/[^a-zA-Z0-9_-]//g;
    $theme_name = lc($theme_name);

    return { ok => 0, error => "Invalid theme name in theme.json" }
        unless $theme_name;

    # DP-C: strict reject when layouts[] is missing or empty.
    my $layouts = $meta->{layouts};
    unless ( ref $layouts eq 'ARRAY' && @$layouts ) {
        return { ok => 0,
            error => "Theme theme.json missing required 'layouts' field. Cannot install." };
    }

    my @clean_layouts;
    for my $l (@$layouts) {
        next unless defined $l && length $l;
        ( my $sane = $l ) =~ s/[^a-zA-Z0-9_-]//g;
        next unless length $sane;
        push @clean_layouts, $sane;
    }
    unless (@clean_layouts) {
        return { ok => 0,
            error => "Theme theme.json 'layouts' contains no usable layout names." };
    }

    # Verify every declared layout is installed. Reject the whole
    # upload if any are missing — the theme author explicitly said
    # "install under these" and we shouldn't silently skip.
    my @missing;
    for my $l (@clean_layouts) {
        push @missing, $l
            unless -f _lz() . "/layouts/$l/layout.tt";
    }
    if (@missing) {
        return { ok => 0,
            error => "Theme targets missing layout(s): " . join( ', ', @missing ) };
    }

    # Resolve the on-disk install name once, using the first layout
    # to detect collisions. The same $install_name is reused across
    # every layout so operators can refer to the theme by a single
    # name in lazysite.conf's theme: key.
    my $install_name = $theme_name;
    my $first_dest   = _lz() . "/layouts/$clean_layouts[0]/themes/$theme_name";
    if ( -d $first_dest && !$update ) {
        my @t = localtime( time() );
        $install_name = sprintf( "%04d%02d%02d-%s",
            $t[5] + 1900, $t[4] + 1, $t[3], $theme_name );
    }
    elsif ( -d $first_dest ) {

        # AN UPDATE IS NOT A COLLISION, and treating it as one is what let a
        # layout upgrade report success while changing nothing a visitor sees.
        #
        # Measured on edge after lumen went to catalogue 1.1.0: the template was
        # the new one and /lazysite-assets/lumen/lumen/main.css was
        # byte-identical to a copy taken that morning, with none of the
        # .nav-toggle rules the release added. Below 900px the stale CSS hid the
        # nav with no rule to reveal the toggle.
        #
        # The mechanism was this branch. The new theme installed as
        # 20260817-lumen, the mirror ran for THAT, and the site went on serving
        # lumen - so `themes_installed` named a real theme truthfully and the
        # instance ran half of each one. _install_layout_from_dir has always
        # taken an update flag and written in place; only the theme half was
        # missing one, which is why the template updated and its stylesheet did
        # not.
        #
        # Snapshot first, so an operator who edited the theme still has it. That
        # is what the rename was protecting, and the protection is kept rather
        # than traded away - _snapshot_artifact is a no-op on a theme still at
        # its pristine baseline (SM176), so an unedited theme costs nothing.
        for my $l (@clean_layouts) {
            _snapshot_artifact( _lz() . "/layouts/$l/themes", $theme_name );
        }
    }

    my @installed;
    for my $l (@clean_layouts) {
        my $dest = _lz() . "/layouts/$l/themes/$install_name";
        make_path($dest);
        my $rc = system( "cp", "-r", "$extract_dir/.", $dest );
        if ( $rc != 0 ) {
            log_event( 'ERROR', $action_label, 'cp failed',
                path => $dest, rc => ( $rc >> 8 ) );
            return { ok => 0,
                error => "Install failed (cp theme files to $l)" };
        }

        # Nested asset path: /lazysite-assets/LAYOUT/THEME/
        if ( -d "$extract_dir/assets" ) {
            my $assets_dest = "$DOCROOT/lazysite-assets/$l/$install_name";
            make_path($assets_dest);
            $rc = system( "cp", "-r", "$extract_dir/assets/.", $assets_dest );
            if ( $rc != 0 ) {
                log_event( 'WARN', $action_label, 'cp assets failed',
                    path => $assets_dest, rc => ( $rc >> 8 ) );
            }
        }

        # SM176: record the pristine baseline so switching away from this theme
        # later, if the operator never edited it, does not spawn a pointless backup.
        _write_pristine( _lz() . "/layouts/$l/themes",
            $install_name, _artifact_digest($dest) );

        push @installed, $l;
    }

    log_event( 'INFO', $action_label, 'theme installed',
        name    => $install_name,
        layouts => join( ',', @installed ),
        user    => $user );

    return {
        ok           => 1,
        name         => $install_name,
        installed_as => $install_name,
        layouts      => \@installed,
    };
}

sub _cleanup_tmp {
    my ($dir) = @_;
    system( "rm", "-rf", $dir ) if $dir =~ m{^/tmp/lazysite-theme-\d+$};
}












# The content root a host serves (its alias.<host>.content_root override, else
# the base content_root, else the docroot) - used to check whether a host cache
# entry still has a source page.
sub _host_content_root {
    my ($host) = @_;
    my ( $base, $override ) = ( '', undef );
    if ( open my $fh, '<:raw', _lz() . "/lazysite.conf" ) {
        while ( my $l = <$fh> ) {
            if    ( $l =~ /^content_root\s*:\s*(\S+)/ ) { $base = $1 }
            elsif ( length $host
                && $l =~ /^alias\.\Q$host\E\.content_root\s*:\s*(\S+)/ )
            {
                $override = $1;
            }
        }
        close $fh;
    }
    my $cr = defined $override ? $override : $base;
    return length $cr ? "$DOCROOT/$cr" : $DOCROOT;
}

sub action_cache_list {
    my @cached;
    # Primary host: the .html mirror sits beside its .md in the content tree.
    find(
        sub {
            return unless /\.html$/;
            my $rel = $File::Find::name;
            $rel                            =~ s{^\Q$DOCROOT\E/?}{/};
            return if $rel                  =~ m{^/lazysite/};
            ( my $src = $File::Find::name ) =~ s/\.html$/.md/;
            push @cached, {
                path       => $rel,
                mtime      => ( stat $_ )[9],
                has_source => -f $src ? 1 : 0,
            };
        },
        $DOCROOT
    );

    # SM110: per-alias-host renders live in host-keyed slots under the cache dir
    # (lazysite/cache/hosts/<host>/<page>.html), NOT beside the .md, so the walk
    # above never sees them and the reserved-/lazysite/ skip excludes them. List
    # them too, tagged with their host, so a sub-domain's cached pages are visible
    # and clearable here (rather than an operator resorting to a Files delete under
    # the reserved lazysite/ tree, which is correctly blocked).
    my $cache_base = $ENV{LAZYSITE_CACHE_DIR} || _lz() . "/cache";
    my $hosts_dir  = "$cache_base/hosts";
    if ( -d $hosts_dir ) {
        find(
            sub {
                return unless /\.html$/;
                ( my $rel = $File::Find::name ) =~ s{^\Q$hosts_dir\E/}{};
                my ( $host, $page ) = ( $rel =~ m{\A([^/]+)/(.+)\z} );
                return unless defined $host && defined $page;
                my $url = "/$page";    # keep .html, matching the primary entries
                ( my $src_rel = $page ) =~ s/\.html\z/.md/;
                my $croot = _host_content_root($host);
                push @cached, {
                    path       => $url,
                    host       => $host,
                    mtime      => ( stat $_ )[9],
                    has_source => -f "$croot/$src_rel" ? 1 : 0,
                };
            },
            $hosts_dir
        );
    }

    return { ok => 1, cached => \@cached };
}

sub action_cache_invalidate {
    my ( $rel_path, $host ) = @_;

    # Per-host invalidation: clear only THIS host's copy of the page, so one
    # language/domain sub-site's cache can be dropped from the Cache page without
    # touching its siblings. (The Cache list tags each host entry with its host.)
    if ( defined $host && length $host && $rel_path ne '*' ) {
        ( my $rel = $rel_path ) =~ s{^/+}{};
        $rel =~ s/\.(?:md|html)\z//;
        my $n = Lazysite::Util::unlink_host_page( $DOCROOT, $host, "$rel.html" );
        log_event( 'INFO', $action, 'host cache invalidated',
            path => $rel_path, host => $host, user => $auth_user );
        return { ok => 1, path => $rel_path, host => $host, cleared => $n };
    }

    if ( $rel_path eq '*' ) {
        my $count = 0;
        find(
            sub {
                return unless /\.html$/;
                my $rel = $File::Find::name;
                $rel =~ s{^\Q$DOCROOT\E/?}{/};
                return if $rel =~ m{^/lazysite/};
                # SM133: a bare .html with NO .md sibling is legacy static
                # content (served by the migration fallback), not a render
                # cache - deleting it would destroy the page. Sweep only
                # true caches.
                ( my $src = $File::Find::name ) =~ s/\.html$/.md/;
                return unless -f $src;
                unlink $_;
                $count++;
            },
            $DOCROOT
        );
        # SM110: clear-all also removes the whole per-alias-host cache tree
        # (wholesale - the hosts tree holds only generated renders, never
        # authored content, so the SM133 legacy-page caution doesn't apply).
        Lazysite::Util::clear_host_cache($DOCROOT);
        return { ok => 1, count => $count };
    }

    my $full = "$DOCROOT$rel_path";
    $full =~ s/\.md$/.html/;
    $full .= '.html' unless $full =~ /\.html$/;

    my $real = realpath($full);
    return { ok => 0, error => "Invalid path" }
        unless $real && ( $real eq $DOCROOT || index( $real, "$DOCROOT/" ) == 0 ); # SEC-2026-07 (H3)

    unlink $real if -f $real;
    # SM110: drop the per-alias-host copies of this page's render too.
    Lazysite::Util::unlink_host_copies( $DOCROOT, $real );
    log_event( 'INFO', $action, 'cache invalidated', path => $rel_path, user => $auth_user );
    return { ok => 1, path => $rel_path };
}






sub action_artifact_manifest {
    my ($p) = @_;
    my $a = _artifact_dir($p);
    return $a                                         unless $a->{ok};
    return { ok => 0, error => 'artifact not found' } unless -d $a->{dir};

    my $manifest = _compute_manifest( $a->{dir} );
    # digest is the optimistic-concurrency token: the client passes it back
    # as `base` to activate, which 409s if the artifact drifted since.
    return { ok => 1, layout => $a->{layout}, theme => $a->{theme},
        manifest => $manifest,
        digest   => sha256_hex( JSON::PP->new->canonical->encode($manifest) ) };
}

sub action_artifact_validate {
    my ($p) = @_;
    my $a = _artifact_dir($p);
    return $a unless $a->{ok};
    return { ok => 1, valid => 0, errors => ['artifact not found'] }
        unless -d $a->{dir};

    my @err;
    if ( length $a->{theme} ) {
        my $tj = "$a->{dir}/theme.json";
        if ( !-f $tj ) { push @err, 'theme.json missing' }
        else {
            open my $fh, '<:utf8', $tj or push @err, 'theme.json unreadable';
            if ( @err == 0 ) {
                my $raw = do { local $/; <$fh> };
                close $fh;
                my $data = eval { decode_json($raw) };
                if    ( ref $data ne 'HASH' ) { push @err, 'theme.json invalid' }
                elsif ( ref $data->{layouts} ne 'ARRAY' || !@{ $data->{layouts} } ) {
                    push @err, 'theme.json layouts[] missing or empty';
                }
            }
        }
    }
    else {
        my $v = _validate_layout_dir( $a->{dir} );
        return { ok => 1, valid => $v->{valid}, errors => $v->{errors} };
    }
    return { ok => 1, valid => ( @err ? 0 : 1 ), errors => \@err };
}

1;
