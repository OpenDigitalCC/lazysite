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
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy);
use File::Basename qw(basename dirname);
use Cwd qw(realpath);
use POSIX qw(strftime);
use Digest::SHA qw(sha256_hex);
use Lazysite::Util qw(log_event);
use Lazysite::Manager::Common qw(write_file_checked _write_conf_key);
use Lazysite::Manager::Files qw(acquire_lock release_lock);
use Lazysite::Manager::Artifact qw(_artifact_dir _compute_manifest _artifact_digest);
use Exporter 'import';

our @EXPORT_OK = qw(
    action_theme_list action_themes_list_all action_theme_activate
    action_layout_activate action_theme_delete action_theme_rename
    action_theme_upload action_cache_list action_cache_invalidate
    _read_active_layout_and_theme _install_theme_from_dir
    action_artifact_manifest action_artifact_validate
    _snapshot_artifact _prune_backups _mirror_theme_assets
);

our $DOCROOT;
our $LAZYSITE_DIR;
our $auth_user = '';
our $action    = '';

# === moved from lazysite-manager-api.pl (SM079a) ===

sub _read_active_layout_and_theme {
    my $layout = '';
    my $theme  = '';
    if ( open my $fh, '<', "$DOCROOT/lazysite/lazysite.conf" ) {
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

sub action_theme_list {
    my ( $active_layout, $active_theme ) = _read_active_layout_and_theme();

    my @themes;
    if ( length $active_layout ) {
        my $themes_dir = "$DOCROOT/lazysite/layouts/$active_layout/themes";
        if ( -d $themes_dir ) {
            opendir( my $dh, $themes_dir );
            for my $name ( sort readdir $dh ) {
                next if $name =~ /^\./;
                next unless -d "$themes_dir/$name";
                push @themes, {
                    name   => $name,
                    active => $name eq $active_theme ? 1 : 0,
                    valid  => -f "$themes_dir/$name/theme.json" ? 1 : 0,
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

    my $layouts_dir = "$DOCROOT/lazysite/layouts";
    my @themes;

    if ( -d $layouts_dir ) {
        opendir my $ld, $layouts_dir or return {
            ok => 1, themes => [], active => $active_theme,
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
                            && $name         eq $active_theme ) ? 1 : 0;
                push @themes, {
                    layout => $layout_name,
                    name   => $name,
                    active => $active,
                    valid  => $valid,
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

sub action_theme_activate {
    my ( $theme_name, $params ) = @_;
    $params ||= {};
    $theme_name =~ s/[^a-zA-Z0-9_-]//g;

    # Deactivation: clear the pointer, no validation/backup.
    return _set_theme_pointer('') if $theme_name eq '';

    my ( $active_layout, $old_theme ) = _read_active_layout_and_theme();
    return { ok => 0, error => "No active layout set" } unless length $active_layout;

    my $themes_dir = "$LAZYSITE_DIR/layouts/$active_layout/themes";
    my $theme_dir  = "$themes_dir/$theme_name";
    return { ok => 0, error => "Theme not found" } unless -d $theme_dir;

    # Artifact-level lock across validate -> snapshot -> flip.
    my $lock_rel = "lazysite/layouts/$active_layout/themes/$theme_name";
    my $lk = acquire_lock( $lock_rel, $auth_user );
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
        _mirror_theme_assets( $active_layout, $theme_name ) if $res->{ok};
        return $res;
    };
    my $err = $@;
    release_lock( $lock_rel, $auth_user );
    die $err if $err;
    return $out;
}

sub _set_theme_pointer {
    my ($theme_name) = @_;
    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    return { ok => 0, error => "Cannot read conf" } unless -f $conf_path;
    open my $fh, '<:utf8', $conf_path or return { ok => 0, error => "Cannot read conf" };
    my $conf = do { local $/; <$fh> };
    close $fh;
    if    ( $theme_name eq '' )         { $conf =~ s/^theme\s*:.*\n?//m }
    elsif ( $conf =~ /^theme\s*:/m )    { $conf =~ s/^theme\s*:.*$/theme: $theme_name/m }
    else                                { $conf .= "\ntheme: $theme_name\n" }
    open my $o, '>:utf8', $conf_path or return { ok => 0, error => "Cannot write conf" };
    print $o $conf;
    close $o;
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
}

# SM080: build the web-served asset mirror at /lazysite-assets/LAYOUT/THEME/ so
# the processor's `theme_assets` variable resolves after ACTIVATION, not only
# after a repo install. Without this a copied-then-activated layout/theme 404s
# its CSS (theme_assets points at a mirror that was never built), which forced
# layout.tt to hardcode the source path and blocked drop-in layout copies.
# Idempotent; a no-op when the theme has no assets/ dir.
sub _mirror_theme_assets {
    my ( $layout, $theme ) = @_;
    return unless length $layout && length $theme;
    my $src = "$LAZYSITE_DIR/layouts/$layout/themes/$theme/assets";
    return unless -d $src;
    my $dest = "$DOCROOT/lazysite-assets/$layout/$theme";
    make_path($dest) unless -d $dest;
    my $rc = system( 'cp', '-r', "$src/.", $dest );
    log_event( 'WARN', $action, 'theme asset mirror failed',
        layout => $layout, theme => $theme, rc => ( $rc >> 8 ) )
        if $rc != 0;
    return;
}

sub _validate_theme_dir {
    my ( $dir, $layout ) = @_;
    my $tj = "$dir/theme.json";
    return { valid => 0, errors => ['theme.json missing'] } unless -f $tj;
    open my $fh, '<:utf8', $tj
        or return { valid => 0, errors => ['theme.json unreadable'] };
    my $raw  = do { local $/; <$fh> };
    close $fh;
    my $data = eval { decode_json($raw) };
    my @err;
    if ( ref $data ne 'HASH' ) {
        my $why = $@ ? do { ( my $e = $@ ) =~ s/\s+at \S+ line \d+.*//s; $e =~ s/\s+$//; $e }
                     : 'top level is not a JSON object';
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

sub _snapshot_artifact {
    my ( $parent, $name ) = @_;
    my $src = "$parent/$name";
    return unless -d $src;
    my $base = _backup_base($name);
    my $dst  = "$parent/$base-backup-" . strftime( '%Y%m%dT%H%M%SZ', gmtime );
    return if -e $dst;
    system( 'cp', '-r', $src, $dst );
}

sub _prune_backups {
    my ( $parent, $name ) = @_;
    my $keep = _backup_retention();
    return if $keep <= 0;   # 0 (or negative) = keep all
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
    if ( open my $fh, '<', "$DOCROOT/lazysite/lazysite.conf" ) {
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
        my $dt = ( ref $meta eq 'HASH' ) ? ( $meta->{default_theme} // '' ) : '';
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
    my $lk = acquire_lock( $lock_rel, $auth_user );
    unless ( $lk->{ok} ) {
        return { ok => 0, locked => 1, error => "Layout is locked by "
            . ( $lk->{locked_by} // 'another session' ) };
    }

    my $out = eval {
        my $v = _validate_layout_dir($layout_dir);
        return { ok => 0, error => "Layout invalid: " . join( '; ', @{ $v->{errors} } ) }
            unless $v->{valid};

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
            $theme = _default_theme_for_layout($layout_name);
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
        return $res;
    };
    my $err = $@;
    release_lock( $lock_rel, $auth_user );
    die $err if $err;
    return $out;
}

sub _set_layout_pointer {
    my ( $layout, $theme ) = @_;
    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
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
    open my $o, '>:utf8', $conf_path or return { ok => 0, error => "Cannot write conf" };
    print $o $conf;
    close $o;
    _invalidate_html_cache();
    return { ok => 1, layout => $layout, ( defined $theme ? ( theme => $theme ) : () ) };
}

sub _validate_layout_dir {
    my ($dir) = @_;
    my $lt = "$dir/layout.tt";
    return { valid => 0, errors => ['layout.tt missing'] } unless -f $lt;
    my $ok = eval {
        require Template::Parser;
        open my $fh, '<:utf8', $lt or die "layout.tt unreadable\n";
        my $src = do { local $/; <$fh> };
        close $fh;
        my $p = Template::Parser->new( {} );
        $p->parse($src) or die( $p->error . "\n" );
        1;
    };
    return { valid => 1, errors => [] } if $ok;
    my $e = $@ || 'parse error';
    return { valid => 1, errors => [] } if $e =~ /Can't locate Template/;
    chomp $e;
    return { valid => 0, errors => ["layout.tt does not compile: $e"] };
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
    my ($theme_name) = @_;
    $theme_name =~ s/[^a-zA-Z0-9_-]//g;

    my ( $active_layout, $active_theme ) = _read_active_layout_and_theme();
    return { ok => 0, error => "Cannot delete the active theme" }
        if $theme_name eq $active_theme;
    return { ok => 0, error => "No active layout set" }
        unless length $active_layout;

    # D013: delete only from the active layout's themes dir. A theme
    # installed under multiple layouts (via theme.json's layouts[])
    # has copies elsewhere — those remain, and the operator can remove
    # them by switching to each layout in turn.
    my $themes_dir = "$DOCROOT/lazysite/layouts/$active_layout/themes";
    my $theme_dir  = "$themes_dir/$theme_name";
    return { ok => 0, error => "Theme not found" } unless -d $theme_dir;

    my $real = realpath($theme_dir);
    return { ok => 0, error => "Invalid theme path" }
        unless $real && index( $real, $themes_dir ) == 0;

    my $rc = system( "rm", "-rf", $theme_dir );
    if ( $rc != 0 ) {
        log_event('ERROR', 'theme-delete', 'rm failed',
            path => $theme_dir, rc => ( $rc >> 8 ));
        return { ok => 0, error => "Delete failed" };
    }
    my $assets_dir = "$DOCROOT/lazysite-assets/$active_layout/$theme_name";
    if ( -d $assets_dir ) {
        $rc = system( "rm", "-rf", $assets_dir );
        if ( $rc != 0 ) {
            log_event('WARN', 'theme-delete', 'rm assets failed',
                path => $assets_dir, rc => ( $rc >> 8 ));
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

    my ( $active_layout ) = _read_active_layout_and_theme();
    return { ok => 0, error => "No active layout set" }
        unless length $active_layout;

    my $themes_dir = "$DOCROOT/lazysite/layouts/$active_layout/themes";
    return { ok => 0, error => "Theme not found" } unless -d "$themes_dir/$old_name";
    return { ok => 0, error => "Name already in use" } if -d "$themes_dir/$new_name";

    rename "$themes_dir/$old_name", "$themes_dir/$new_name";

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
    my ( $extract_dir, $action_label, $user ) = @_;

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
            unless -f "$DOCROOT/lazysite/layouts/$l/layout.tt";
    }
    if (@missing) {
        return { ok => 0,
            error => "Theme targets missing layout(s): " . join(', ', @missing) };
    }

    # Resolve the on-disk install name once, using the first layout
    # to detect collisions. The same $install_name is reused across
    # every layout so operators can refer to the theme by a single
    # name in lazysite.conf's theme: key.
    my $install_name = $theme_name;
    my $first_dest   = "$DOCROOT/lazysite/layouts/$clean_layouts[0]/themes/$theme_name";
    if ( -d $first_dest ) {
        my @t = localtime( time() );
        $install_name = sprintf( "%04d%02d%02d-%s",
            $t[5] + 1900, $t[4] + 1, $t[3], $theme_name );
    }

    my @installed;
    for my $l (@clean_layouts) {
        my $dest = "$DOCROOT/lazysite/layouts/$l/themes/$install_name";
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












sub action_cache_list {
    my @cached;
    find(
        sub {
            return unless /\.html$/;
            my $rel = $File::Find::name;
            $rel =~ s{^\Q$DOCROOT\E/?}{/};
            return if $rel =~ m{^/lazysite/};
            ( my $src = $File::Find::name ) =~ s/\.html$/.md/;
            push @cached, {
                path       => $rel,
                mtime      => ( stat $_ )[9],
                has_source => -f $src ? 1 : 0,
            };
        },
        $DOCROOT
    );
    return { ok => 1, cached => \@cached };
}

sub action_cache_invalidate {
    my ($rel_path) = @_;

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
        return { ok => 1, count => $count };
    }

    my $full = "$DOCROOT$rel_path";
    $full =~ s/\.md$/.html/;
    $full .= '.html' unless $full =~ /\.html$/;

    my $real = realpath($full);
    return { ok => 0, error => "Invalid path" }
        unless $real && index( $real, $DOCROOT ) == 0;

    unlink $real if -f $real;
    log_event('INFO', $action, 'cache invalidated', path => $rel_path, user => $auth_user);
    return { ok => 1, path => $rel_path };
}






sub action_artifact_manifest {
    my ($p) = @_;
    my $a = _artifact_dir($p);
    return $a unless $a->{ok};
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
            if (@err == 0) {
                my $raw  = do { local $/; <$fh> };
                close $fh;
                my $data = eval { decode_json($raw) };
                if ( ref $data ne 'HASH' ) { push @err, 'theme.json invalid' }
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
