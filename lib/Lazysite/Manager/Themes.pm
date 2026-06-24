package Lazysite::Manager::Themes;

# SM079: the manager theming subsystem - theme + layout listing, activation,
# delete/rename/upload, the layouts-repo install/release handlers, the active
# pointer, validation, backups/snapshots, the HTML-cache invalidation, and the
# cache-list/invalidate actions. Themes and layouts are deeply coupled (a theme
# is scoped to a layout), so they live in one module. Context ($DOCROOT,
# $LAZYSITE_DIR, $auth_user, $action) set by the dispatcher; Archive::Zip and
# LWP::UserAgent are required inline (optional deps).

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
use Exporter 'import';

our @EXPORT_OK = qw(
    action_theme_list action_themes_list_all action_theme_activate
    action_layout_activate action_theme_delete action_theme_rename
    action_theme_upload action_layouts_releases action_layouts_install
    action_layouts_release_contents action_layouts_available
    action_themes_for_layout action_layouts_repo_get action_layouts_repo_set
    action_cache_list action_cache_invalidate _read_active_layout_and_theme
    action_artifact_manifest action_artifact_validate
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
        return _set_theme_pointer($theme_name);
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

sub _snapshot_artifact {
    my ( $parent, $name ) = @_;
    my $src = "$parent/$name";
    return unless -d $src;
    my $dst = "$parent/$name-backup-" . strftime( '%Y%m%dT%H%M%SZ', gmtime );
    return if -e $dst;
    system( 'cp', '-r', $src, $dst );
}

sub _prune_backups {
    my ( $parent, $name ) = @_;
    my $keep = _backup_retention();
    return if $keep <= 0;   # 0 (or negative) = keep all
    opendir my $dh, $parent or return;
    my @backups = sort grep { /^\Q$name\E-backup-/ && -d "$parent/$_" } readdir $dh;
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

        # Compatible (layout, theme) pair.
        if ( length $theme && !_theme_declares_layout( $layout_name, $theme ) ) {
            return { ok => 0, incompatible => 1,
                error => "Theme '$theme' is not declared for layout '$layout_name'"
                       . " - name a compatible theme to switch to" };
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
        return _set_layout_pointer( $layout_name,
            ( $theme_specified && length $theme ) ? $theme : undef );
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

sub _install_layout_from_dir {
    my ( $layout_source, $layout_name, $action_label, $user ) = @_;

    return { ok => 0, error => 'missing layout.tt in release' }
        unless -f "$layout_source/layout.tt";

    my $target_dir = "$DOCROOT/lazysite/layouts/$layout_name";

    # Collect the release's layout files (layout.tt + layout.json).
    # layout.json is optional; copy if present.
    my @rel_files;
    opendir my $sh, $layout_source
        or return { ok => 0, error => 'Cannot read layout source dir' };
    for my $f ( sort readdir $sh ) {
        next if $f =~ /^\./;
        my $src = "$layout_source/$f";
        # Only copy regular files at the layout root (layout.tt,
        # layout.json). The themes/ subtree is handled by the walker.
        next if $f eq 'themes';
        next unless -f $src;
        push @rel_files, $f;
    }
    closedir $sh;

    # Compare files. If the target directory exists AND every
    # release file is present AND byte-identical, it's a no-op.
    # If anything differs, refuse.
    if ( -d $target_dir ) {
        my @differs;
        for my $f (@rel_files) {
            my $src = "$layout_source/$f";
            my $dst = "$target_dir/$f";
            unless ( -f $dst ) {
                push @differs, $f;
                next;
            }
            # Cheap byte compare.
            my $sb = _slurp_bytes($src);
            my $db = _slurp_bytes($dst);
            if ( !defined $sb || !defined $db || $sb ne $db ) {
                push @differs, $f;
            }
        }
        if (@differs) {
            return { ok => 0,
                error => 'already installed and differs; refusing to overwrite ('
                       . join( ', ', @differs ) . ')' };
        }
        return { ok => 1, action => 'already_installed' };
    }

    # New install.
    make_path($target_dir);
    for my $f (@rel_files) {
        my $rc = system( 'cp', "$layout_source/$f", "$target_dir/$f" );
        if ( $rc != 0 ) {
            log_event( 'ERROR', $action_label, 'cp layout failed',
                file => $f, layout => $layout_name, rc => ( $rc >> 8 ) );
            return { ok => 0,
                error => "Install failed (cp $f to layout $layout_name)" };
        }
    }

    log_event( 'INFO', $action_label, 'layout installed',
        name => $layout_name, files => join( ',', @rel_files ),
        user => $user );

    return { ok => 1, action => 'installed' };
}

sub _slurp_bytes {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    my $data = do { local $/; <$fh> };
    close $fh;
    return $data;
}

sub _layouts_repo {
    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    my $repo;
    if ( -f $conf_path && open my $fh, '<', $conf_path ) {
        while (<$fh>) {
            if (/^layouts_repo\s*:\s*(\S+)/) { $repo = $1; last }
        }
        close $fh;
    }
    # Sensible default so the release browser works out of the box; a
    # layouts_repo key in lazysite.conf overrides it for a custom repo.
    return ( defined $repo && length $repo ) ? $repo
                                             : 'OpenDigitalCC/lazysite-layouts';
}

sub action_layouts_releases {
    my $repo = _layouts_repo();
    return { ok => 0,
        error => 'Unable to fetch releases. Check the Layouts repo setting above.' }
        unless defined $repo && length $repo
            && $repo =~ m{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$};

    require LWP::UserAgent;
    my $ua = LWP::UserAgent->new( timeout => 10, agent => 'lazysite/1.0' );
    my $url = "https://api.github.com/repos/$repo/releases";
    my $res = $ua->get( $url, 'Accept' => 'application/vnd.github+json' );

    return { ok => 0,
        error => 'Unable to fetch releases. Check the Layouts repo setting above.' }
        unless $res->is_success;

    my $data = eval { decode_json( $res->decoded_content ) };
    return { ok => 0,
        error => 'Unable to fetch releases. Check the Layouts repo setting above.' }
        unless ref $data eq 'ARRAY';

    my @releases;
    for my $r (@$data) {
        push @releases, {
            tag_name     => $r->{tag_name}     // '',
            name         => $r->{name}         // '',
            published_at => $r->{published_at} // '',
            body         => $r->{body}         // '',
        };
    }
    return { ok => 1, repo => $repo, releases => \@releases };
}

sub action_layouts_install {
    my ($request_body) = @_;
    my $req = eval { decode_json( $request_body // '{}' ) } // {};
    my $tag = $req->{tag} // '';

    # Tags can hold versioned names like v1.2.0 or release-2026-04-01
    # (and optionally refs/tags-style slashes). Reject any ".." sequence
    # to stop URL traversal into other GitHub API endpoints.
    return { ok => 0, error => 'Invalid tag' }
        unless length $tag
            && $tag =~ m{^[A-Za-z0-9._/-]+$}
            && $tag !~ m{\.\.};

    my $repo = _layouts_repo();
    return { ok => 0, error => 'layouts_repo not set or invalid in lazysite.conf' }
        unless defined $repo && length $repo
            && $repo =~ m{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$};

    my $have_azip = eval { require Archive::Zip; Archive::Zip->import(qw(:ERROR_CODES)); 1 };
    return { ok => 0,
        error => 'Archive::Zip not installed (apt-get install libarchive-zip-perl)' }
        unless $have_azip;

    require LWP::UserAgent;
    # Zipballs are larger than the releases JSON; allow more time.
    my $ua  = LWP::UserAgent->new( timeout => 30, agent => 'lazysite/1.0' );
    my $url = "https://api.github.com/repos/$repo/zipball/$tag";
    my $res = $ua->get($url);
    return { ok => 0, error => 'Failed to fetch zipball: ' . $res->status_line }
        unless $res->is_success;

    my $tmp_dir = "/tmp/lazysite-layouts-$$";
    make_path($tmp_dir);

    my $zip_path = "$tmp_dir/release.zip";
    unless ( open my $zfh, '>:raw', $zip_path ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Cannot write zipball' };
    }
    else {
        print $zfh $res->content;
        close $zfh;
    }

    my $extract_dir = "$tmp_dir/extracted";
    make_path($extract_dir);

    my $zip = Archive::Zip->new();
    unless ( $zip->read($zip_path) == Archive::Zip::AZ_OK() ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Cannot read zipball' };
    }

    for my $member ( $zip->members ) {
        my $name = $member->fileName;
        if ( $name =~ m{\A/} ) {
            _cleanup_tmp_layouts($tmp_dir);
            return { ok => 0, error => "Zip entry has absolute path: $name" };
        }
        if ( $name =~ m{(?:^|/)\.\.(?:/|$)} ) {
            _cleanup_tmp_layouts($tmp_dir);
            return { ok => 0, error => "Zip slip detected in: $name" };
        }
    }

    unless ( $zip->extractTree( '', "$extract_dir/" ) == Archive::Zip::AZ_OK() ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Extraction failed' };
    }

    # GitHub zipballs nest everything under a single top-level wrapper
    # dir named OWNER-REPO-SHA. Strip it so the theme subdirs sit at
    # the top of our walk.
    my @top;
    unless ( opendir my $dh, $extract_dir ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Cannot read extracted dir' };
    }
    else {
        for my $e ( readdir $dh ) {
            next if $e =~ /^\./;
            push @top, $e if -d "$extract_dir/$e";
        }
        closedir $dh;
    }

    unless ( @top == 1 ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0,
            error => 'Unexpected zipball layout (expected single wrapper dir)' };
    }
    my $wrapper = "$extract_dir/$top[0]";

    # SM046: LL v0.3.0+ release shape. Themes live nested at
    # $wrapper/layouts/LAYOUT/themes/THEME/, with theme.json at each
    # theme root. Pre-LL-v0.3.0 flat shape (theme.json in a top-level
    # subdir) is rejected — that shape pre-dates D013 and would fail
    # _install_theme_from_dir's layouts[] check anyway.
    my $layouts_dir = "$wrapper/layouts";
    unless ( -d $layouts_dir ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0,
            error => 'Release does not contain a layouts/ directory '
                   . '(repo must follow D013 nested shape: layouts/LAYOUT/themes/THEME/)' };
    }

    my @results;
    my @layout_results;    # SM060: per-layout install outcomes
    unless ( opendir my $ld, $layouts_dir ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Cannot read layouts dir' };
    }
    else {
        for my $layout_name ( sort readdir $ld ) {
            next if $layout_name =~ /^\./;
            my $layout_path = "$layouts_dir/$layout_name";
            next unless -d $layout_path;

            # SM060: install the layout itself before its themes, so
            # _install_theme_from_dir's target-site check finds the
            # expected layout.tt on disk. A layout without a themes/
            # subdir still gets installed — operators can publish a
            # release with just a layout update.
            my $layout_src_rel = "layouts/$layout_name";
            my $layout_had_tt  = -f "$layout_path/layout.tt";
            my $layout_ok      = 1;
            if ($layout_had_tt) {
                my $lr = _install_layout_from_dir(
                    $layout_path, $layout_name,
                    'layouts-install', $auth_user );
                push @layout_results,
                    { source => $layout_src_rel, %$lr };
                $layout_ok = $lr->{ok} ? 1 : 0;
            }
            # If there's no layout.tt in the release for this layout
            # dir, we don't record a layout entry — this is common
            # for release repos that ship only themes, and the
            # existing theme-level error ('Theme targets missing
            # layout(s): X') carries the useful message when the
            # target site doesn't have the layout either.

            my $themes_path = "$layout_path/themes";
            next unless -d $themes_path;

            # Per-layout failure: don't install orphaned themes under
            # a layout we couldn't successfully place or verify.
            unless ($layout_ok) {
                if ( opendir my $th_skip, $themes_path ) {
                    for my $theme_name ( sort readdir $th_skip ) {
                        next if $theme_name =~ /^\./;
                        my $theme_path = "$themes_path/$theme_name";
                        next unless -d $theme_path;
                        push @results, {
                            source => "layouts/$layout_name/themes/$theme_name",
                            ok     => JSON::PP::false(),
                            error  => "Skipped: layout $layout_name install did "
                                   . "not succeed",
                        };
                    }
                    closedir $th_skip;
                }
                next;
            }

            opendir my $th, $themes_path or next;
            for my $theme_name ( sort readdir $th ) {
                next if $theme_name =~ /^\./;
                my $theme_path = "$themes_path/$theme_name";
                next unless -d $theme_path;

                my $source_rel = "layouts/$layout_name/themes/$theme_name";

                unless ( -f "$theme_path/theme.json" ) {
                    push @results, {
                        source => $source_rel,
                        ok     => JSON::PP::false(),
                        error  => 'Missing theme.json',
                    };
                    next;
                }

                # SM046 consistency check: theme.json's layouts[] must
                # include the source-path LAYOUT. Catches repo-author
                # mistakes (theme filed under the wrong layout dir) at
                # install time rather than at render time. Does NOT
                # replace _install_theme_from_dir's target-site check
                # — that validates every declared layout exists on
                # this install.
                my $mismatch;
                if ( open my $jf, '<:utf8', "$theme_path/theme.json" ) {
                    my $raw = do { local $/; <$jf> };
                    close $jf;
                    my $meta = eval { decode_json($raw) };
                    if ( ref $meta eq 'HASH' && ref $meta->{layouts} eq 'ARRAY' ) {
                        unless ( grep { $_ eq $layout_name } @{ $meta->{layouts} } ) {
                            $mismatch = sprintf(
                                "Theme %s under %s declares layouts: [%s], "
                                . "mismatching source path",
                                $theme_name, $source_rel,
                                join( ', ', @{ $meta->{layouts} } )
                            );
                        }
                    }
                }
                if ($mismatch) {
                    push @results, {
                        source => $source_rel,
                        ok     => JSON::PP::false(),
                        error  => $mismatch,
                    };
                    next;
                }

                my $r = _install_theme_from_dir(
                    $theme_path, 'layouts-install', $auth_user );
                push @results, { source => $source_rel, %$r };
            }
            closedir $th;
        }
        closedir $ld;
    }

    _cleanup_tmp_layouts($tmp_dir);

    # SM060: release may ship a layout-only update (no themes at all).
    # Only error "no themes found" if we ALSO installed no layouts.
    unless ( @results || @layout_results ) {
        return { ok => 0,
            error => 'No layouts or themes found under layouts/*/ in release' };
    }

    my $themes_installed  = scalar grep { $_->{ok} } @results;
    my $layouts_installed = scalar grep { $_->{ok} } @layout_results;

    # SM068: auto-set layout:/theme: in lazysite.conf on a fresh
    # site so the operator isn't left at an empty config after a
    # successful install. Never overwrite an operator-set value —
    # only populate when the key is currently unset or empty. If
    # the install had zero layout successes, no auto-set happens
    # (same for theme).
    my ( $layout_auto_set, $layout_auto_set_name ) = ( 0, '' );
    my ( $theme_auto_set,  $theme_auto_set_name )  = ( 0, '' );
    if ( $layouts_installed >= 1 ) {
        my ($cur_layout, $cur_theme) = _read_active_layout_and_theme();

        unless ( length $cur_layout ) {
            my ($first_layout) = map  { $_->{source} =~ m{^layouts/([^/]+)$} ? $1 : () }
                                 grep { $_->{ok} } @layout_results;
            if ( defined $first_layout && length $first_layout ) {
                if ( _write_conf_key( 'layout', $first_layout ) ) {
                    $layout_auto_set      = 1;
                    $layout_auto_set_name = $first_layout;
                    $cur_layout           = $first_layout;
                    log_event( 'INFO', 'layouts-install',
                        'layout auto-set', name => $first_layout,
                        user => $auth_user );
                }
            }
        }

        # Theme auto-set only when we now have a layout AND theme is
        # unset AND at least one theme installed under that layout.
        if ( length $cur_layout && !length $cur_theme
             && $themes_installed >= 1 ) {
            my ($first_theme) = map  {
                    $_->{source} =~ m{^layouts/\Q$cur_layout\E/themes/([^/]+)$}
                        ? $1 : ()
                } grep { $_->{ok} } @results;
            if ( defined $first_theme && length $first_theme ) {
                if ( _write_conf_key( 'theme', $first_theme ) ) {
                    $theme_auto_set      = 1;
                    $theme_auto_set_name = $first_theme;
                    log_event( 'INFO', 'layouts-install',
                        'theme auto-set', name => $first_theme,
                        layout => $cur_layout, user => $auth_user );
                }
            }
        }
    }

    log_event( 'INFO', 'layouts-install', 'release installed',
        repo             => $repo, tag => $tag,
        layouts_total    => scalar @layout_results,
        layouts_ok       => $layouts_installed,
        themes_total     => scalar @results,
        themes_ok        => $themes_installed,
        layout_auto_set  => $layout_auto_set,
        theme_auto_set   => $theme_auto_set,
        user             => $auth_user );

    return {
        ok              => 1,
        repo            => $repo,
        tag             => $tag,
        layouts         => \@layout_results,
        themes          => \@results,
        layout_auto_set => $layout_auto_set
                            ? JSON::PP::true() : JSON::PP::false(),
        theme_auto_set  => $theme_auto_set
                            ? JSON::PP::true() : JSON::PP::false(),
        layout_auto_set_name => $layout_auto_set_name,
        theme_auto_set_name  => $theme_auto_set_name,
    };
}

sub _cleanup_tmp_layouts {
    my ($dir) = @_;
    system( "rm", "-rf", $dir ) if $dir =~ m{^/tmp/lazysite-layouts-\d+$};
}

sub action_layouts_release_contents {
    my ($tag) = @_;
    $tag //= '';

    return { ok => 0, error => 'Invalid tag' }
        unless length $tag
            && $tag =~ m{^[A-Za-z0-9._/-]+$}
            && $tag !~ m{\.\.};

    my $repo = _layouts_repo();
    return { ok => 0, error => 'layouts_repo not set or invalid in lazysite.conf' }
        unless defined $repo && length $repo
            && $repo =~ m{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$};

    my $have_azip = eval { require Archive::Zip; Archive::Zip->import(qw(:ERROR_CODES)); 1 };
    return { ok => 0,
        error => 'Archive::Zip not installed (apt-get install libarchive-zip-perl)' }
        unless $have_azip;

    require LWP::UserAgent;
    my $ua  = LWP::UserAgent->new( timeout => 30, agent => 'lazysite/1.0' );
    my $url = "https://api.github.com/repos/$repo/zipball/$tag";
    my $res = $ua->get($url);
    return { ok => 0, error => 'Failed to fetch zipball: ' . $res->status_line }
        unless $res->is_success;

    my $tmp_dir = "/tmp/lazysite-layouts-$$";
    make_path($tmp_dir);

    my $zip_path = "$tmp_dir/release.zip";
    unless ( open my $zfh, '>:raw', $zip_path ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Cannot write zipball' };
    }
    else {
        print $zfh $res->content;
        close $zfh;
    }

    my $extract_dir = "$tmp_dir/extracted";
    make_path($extract_dir);

    my $zip = Archive::Zip->new();
    unless ( $zip->read($zip_path) == Archive::Zip::AZ_OK() ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Cannot read zipball' };
    }

    for my $member ( $zip->members ) {
        my $name = $member->fileName;
        if ( $name =~ m{\A/} || $name =~ m{(?:^|/)\.\.(?:/|$)} ) {
            _cleanup_tmp_layouts($tmp_dir);
            return { ok => 0, error => "Unsafe zip entry: $name" };
        }
    }

    unless ( $zip->extractTree( '', "$extract_dir/" ) == Archive::Zip::AZ_OK() ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Extraction failed' };
    }

    # Strip the GitHub wrapper dir (OWNER-REPO-SHA/).
    my @top;
    opendir my $dh, $extract_dir or do {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => 'Cannot read extracted dir' };
    };
    for my $e ( readdir $dh ) {
        next if $e =~ /^\./;
        push @top, $e if -d "$extract_dir/$e";
    }
    closedir $dh;
    unless ( @top == 1 ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0,
            error => 'Unexpected zipball layout (expected single wrapper dir)' };
    }
    my $wrapper = "$extract_dir/$top[0]";

    my $layouts_dir = "$wrapper/layouts";
    unless ( -d $layouts_dir ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0,
            error => 'Release does not contain a layouts/ directory '
                   . '(repo must follow D013 nested shape)' };
    }

    # Walk layouts/LAYOUT/themes/THEME/theme.json. Any parse errors
    # or missing manifests produce an entry with ok => 0 rather than
    # aborting the whole walk — the operator still gets a partial
    # preview.
    my @themes;
    if ( opendir my $ld, $layouts_dir ) {
        for my $layout_name ( sort readdir $ld ) {
            next if $layout_name =~ /^\./;
            my $themes_path = "$layouts_dir/$layout_name/themes";
            next unless -d $themes_path;

            opendir my $th, $themes_path or next;
            for my $theme_name ( sort readdir $th ) {
                next if $theme_name =~ /^\./;
                my $theme_path = "$themes_path/$theme_name";
                next unless -d $theme_path;

                my $tj = "$theme_path/theme.json";
                my $description = '';
                if ( -f $tj && open my $jf, '<:utf8', $tj ) {
                    my $raw = do { local $/; <$jf> };
                    close $jf;
                    my $meta = eval { decode_json($raw) };
                    if ( ref $meta eq 'HASH' && defined $meta->{description} ) {
                        $description = $meta->{description};
                    }
                }
                push @themes, {
                    layout      => $layout_name,
                    name        => $theme_name,
                    description => $description,
                };
            }
            closedir $th;
        }
        closedir $ld;
    }

    _cleanup_tmp_layouts($tmp_dir);

    return { ok => 1, repo => $repo, tag => $tag, themes => \@themes };
}

sub action_layouts_available {
    my $layouts_dir = "$DOCROOT/lazysite/layouts";
    my @layouts;
    if ( -d $layouts_dir ) {
        opendir my $dh, $layouts_dir
            or return { ok => 1, layouts => [] };
        for my $name ( sort readdir $dh ) {
            next if $name =~ /^\./;
            # Sanitise: reject anything that wouldn't be a valid layout
            # directory under D013's contract.
            next unless $name =~ /^[A-Za-z0-9_-]+$/;
            next unless -f "$layouts_dir/$name/layout.tt";
            push @layouts, $name;
        }
        closedir $dh;
    }
    return { ok => 1, layouts => \@layouts };
}

sub action_themes_for_layout {
    my ($layout) = @_;
    $layout //= '';
    $layout =~ s/[^A-Za-z0-9_-]//g;
    return { ok => 0, error => 'layout parameter required', themes => [] }
        unless length $layout;

    my $themes_dir = "$DOCROOT/lazysite/layouts/$layout/themes";
    my @themes;
    if ( -d $themes_dir ) {
        opendir my $dh, $themes_dir
            or return { ok => 1, themes => [] };
        for my $name ( sort readdir $dh ) {
            next if $name =~ /^\./;
            next unless $name =~ /^[A-Za-z0-9_-]+$/;
            my $tj = "$themes_dir/$name/theme.json";
            next unless -f $tj;

            # Verify theme declares compatibility with this layout.
            # A theme whose layouts[] doesn't include $layout got there
            # via some non-manager install path and shouldn't surface
            # as a valid choice.
            open my $jf, '<:utf8', $tj or next;
            my $raw = do { local $/; <$jf> };
            close $jf;
            my $meta = eval { decode_json($raw) };
            next unless ref $meta eq 'HASH'
                     && ref $meta->{layouts} eq 'ARRAY'
                     && grep { $_ eq $layout } @{ $meta->{layouts} };

            push @themes, $name;
        }
        closedir $dh;
    }
    return { ok => 1, themes => \@themes, layout => $layout };
}

sub action_layouts_repo_get {
    my $value = _layouts_repo() // '';
    return { ok => 1, value => $value };
}

sub action_layouts_repo_set {
    my ($value) = @_;
    $value //= '';

    # Empty string is the explicit "unset" signal; the key is removed
    # from the conf rather than written as an empty value.
    if ( length $value ) {
        # Match GitHub's actual allowed repo-name chars: each segment
        # starts with alnum and contains alnum/./_/-.
        unless ( $value =~
            m{^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$} ) {
            return { ok => 0,
                error => 'Invalid layouts_repo format (expected OWNER/REPO)' };
        }
    }

    my $conf_path = "$DOCROOT/lazysite/lazysite.conf";
    my $content   = '';
    if ( -f $conf_path ) {
        open my $fh, '<:utf8', $conf_path
            or return { ok => 0, error => "Cannot read lazysite.conf" };
        $content = do { local $/; <$fh> };
        close $fh;
    }

    if ( length $value ) {
        if ( $content =~ /^layouts_repo\s*:/m ) {
            $content =~ s/^layouts_repo\s*:.*$/layouts_repo: $value/m;
        }
        else {
            $content =~ s/\n?$/\n/;    # ensure trailing newline
            $content .= "layouts_repo: $value\n";
        }
    }
    else {
        # Unset: drop any layouts_repo line entirely.
        $content =~ s/^layouts_repo\s*:.*\n?//m;
    }

    my ( $wok, $werr ) = write_file_checked( $conf_path, $content );
    return { ok => 0, error => "Cannot write lazysite.conf: $werr" }
        unless $wok;

    log_event( 'INFO', 'layouts-repo-set',
        'layouts_repo updated', value => $value, user => $auth_user );

    return { ok => 1, value => $value };
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

sub _artifact_dir {
    my ($p) = @_;
    my $layout = $p->{layout} // '';
    my $theme  = $p->{theme}  // '';
    return { ok => 0, error => 'invalid or missing layout' }
        unless $layout =~ /^[A-Za-z0-9_-]+$/;
    if ( length $theme ) {
        return { ok => 0, error => 'invalid theme' }
            unless $theme =~ /^[A-Za-z0-9_-]+$/;
        return { ok => 1, layout => $layout, theme => $theme,
                 dir => "$LAZYSITE_DIR/layouts/$layout/themes/$theme" };
    }
    return { ok => 1, layout => $layout, theme => '',
             dir => "$LAZYSITE_DIR/layouts/$layout" };
}

sub _compute_manifest {
    my ($dir) = @_;
    my %m;
    return \%m unless -d $dir;
    File::Find::find( { no_chdir => 1, wanted => sub {
        return unless -f $_;
        ( my $rel = $_ ) =~ s{^\Q$dir\E/}{};
        open my $fh, '<:raw', $_ or return;
        my $sha = Digest::SHA->new(256);
        $sha->addfile($fh);
        close $fh;
        $m{$rel} = { sha256 => $sha->hexdigest, size => ( -s $_ ) + 0 };
    } }, $dir );
    return \%m;
}

sub _artifact_digest {
    my ($dir) = @_;
    return sha256_hex( JSON::PP->new->canonical->encode( _compute_manifest($dir) ) );
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
