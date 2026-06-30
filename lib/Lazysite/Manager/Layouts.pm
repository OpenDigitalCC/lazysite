package Lazysite::Manager::Layouts;

# SM079: the layouts-repo subsystem - fetch / list / install layout releases
# from a remote repo, the repo-url config, and the available-layouts /
# themes-for-layout queries. Depends one-way on the theming core (Themes) for
# _install_theme_from_dir + _read_active_layout_and_theme. Context: $DOCROOT,
# $LAZYSITE_DIR, $auth_user, $action. Archive::Zip + LWP::UserAgent are inline.

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Path qw(make_path remove_tree);
use File::Copy qw(copy);
use File::Basename qw(basename dirname);
use Cwd qw(realpath);
use POSIX qw(strftime);
use Lazysite::Util qw(log_event);
use Lazysite::Manager::Common qw(write_file_checked _write_conf_key);
use Lazysite::Manager::Themes qw(_install_theme_from_dir _read_active_layout_and_theme
    _snapshot_artifact _prune_backups _mirror_theme_assets action_layout_activate);
use Exporter 'import';

our @EXPORT_OK = qw(
    action_layouts_releases action_layouts_install action_layouts_release_contents
    action_layouts_available action_themes_for_layout action_layout_delete
    action_layouts_manifest action_layout_install
    action_layouts_repo_get action_layouts_repo_set);

our $DOCROOT;
our $LAZYSITE_DIR;
our $auth_user = '';
our $action    = '';

# === moved from Manager::Themes (SM079 polish) ===

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
            # Backup snapshots (LAYOUT-backup-<ts>, made on activate/delete)
            # also carry a layout.tt; they are not installable layouts.
            next if $name =~ /-backup-\d/;
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
            next if $name =~ /-backup-\d/;    # theme snapshot, not a real theme
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

sub action_layout_delete {
    my ($layout_name) = @_;
    $layout_name //= '';
    $layout_name =~ s/[^a-zA-Z0-9_-]//g;
    return { ok => 0, error => 'Layout name required' } unless length $layout_name;

    # Deleting a layout removes its themes/ too, so guard hard: never the
    # active layout (the UI also gates this and confirms before calling).
    my ( $active_layout, undef ) = _read_active_layout_and_theme();
    return { ok => 0, error => 'Cannot delete the active layout' }
        if length $active_layout && $layout_name eq $active_layout;

    my $layouts_dir = "$DOCROOT/lazysite/layouts";
    my $layout_dir  = "$layouts_dir/$layout_name";
    return { ok => 0, error => 'Layout not found' } unless -d $layout_dir;

    # Resolve symlinks and confirm the target sits inside layouts/.
    my $real_parent = realpath($layouts_dir);
    my $real        = realpath($layout_dir);
    return { ok => 0, error => 'Invalid layout path' }
        unless $real && $real_parent && index( $real, $real_parent ) == 0;

    # Enumerate the themes that will be removed with the layout (for the
    # response + audit; the UI shows the count in its confirmation).
    my @themes;
    if ( opendir my $th, "$layout_dir/themes" ) {
        @themes = sort grep { !/^\./ && !/-backup-\d/
            && -f "$layout_dir/themes/$_/theme.json" } readdir $th;
        closedir $th;
    }

    # Snapshot before removal, same retention as activate-time backups, so a
    # delete is recoverable from layouts/<LAYOUT>-backup-<ts>. But do NOT snapshot
    # when deleting a backup itself - otherwise cleaning up a backup just spawns a
    # replacement and the list never shrinks.
    unless ( $layout_name =~ /-backup-\d/ ) {
        _snapshot_artifact( $layouts_dir, $layout_name );
        _prune_backups( $layouts_dir, $layout_name );
    }

    my $rc = system( 'rm', '-rf', $layout_dir );
    if ( $rc != 0 ) {
        log_event( 'ERROR', 'layout-delete', 'rm failed',
            path => $layout_dir, rc => ( $rc >> 8 ) );
        return { ok => 0, error => 'Delete failed' };
    }

    # Remove the whole web-served mirror for this layout (every theme under it).
    my $assets_dir = "$DOCROOT/lazysite-assets/$layout_name";
    if ( -d $assets_dir ) {
        my $arc = system( 'rm', '-rf', $assets_dir );
        log_event( 'WARN', 'layout-delete', 'rm assets failed',
            path => $assets_dir, rc => ( $arc >> 8 ) ) if $arc != 0;
    }

    log_event( 'INFO', 'layout-delete', 'layout deleted',
        name => $layout_name, themes => join( ',', @themes ),
        theme_count => scalar @themes, user => $auth_user );

    return {
        ok             => 1,
        deleted        => $layout_name,
        themes_removed => \@themes,
    };
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

# === SM (manifest-based per-layout install) ===
#
# The whole-repo zipball flow (action_layouts_install) installs every layout +
# theme at a tag. This complements it: read manifest.json and install ONE layout
# plus its theme(s) on demand, from the per-package zips. manifest.json + the
# package zips are fetched as raw files on a ref (layouts_ref, default 'main')
# from the configured layouts_repo - the manifest's package paths are repo
# relative, which suits raw files.

sub _layouts_ref {
    my $conf = "$DOCROOT/lazysite/lazysite.conf";
    my $ref;
    if ( open my $fh, '<', $conf ) {
        while (<$fh>) { if (/^layouts_ref\s*:\s*(\S+)/) { $ref = $1; last } }
        close $fh;
    }
    return ( defined $ref && length $ref ) ? $ref : 'main';
}

sub _raw_base {
    my $repo = _layouts_repo();
    my $ref  = _layouts_ref();
    return "https://raw.githubusercontent.com/$repo/$ref";
}

sub _http_get {
    my ($url) = @_;
    require LWP::UserAgent;
    my $ua  = LWP::UserAgent->new( timeout => 30, agent => 'lazysite/1.0' );
    my $res = $ua->get($url);
    return ( 0, 'HTTP ' . $res->status_line ) unless $res->is_success;
    return ( 1, $res->content );
}

# Download a zip to a fresh dir and extract it (with zip-slip guards).
# Returns (1, $extract_dir) or (0, $error).
sub _download_extract {
    my ( $url, $extract_dir ) = @_;
    my ( $ok, $content ) = _http_get($url);
    return ( 0, "fetch failed ($content)" ) unless $ok;

    make_path($extract_dir);
    my $zip_path = "$extract_dir/pkg.zip";
    open my $zfh, '>:raw', $zip_path or return ( 0, 'cannot write package' );
    print {$zfh} $content;
    close $zfh;

    my $zip = Archive::Zip->new();
    return ( 0, 'cannot read package' )
        unless $zip->read($zip_path) == Archive::Zip::AZ_OK();
    for my $m ( $zip->members ) {
        my $n = $m->fileName;
        return ( 0, "unsafe zip entry: $n" )
            if $n =~ m{\A/} || $n =~ m{(?:^|/)\.\.(?:/|$)};
    }
    return ( 0, 'extraction failed' )
        unless $zip->extractTree( '', "$extract_dir/" ) == Archive::Zip::AZ_OK();
    unlink $zip_path;
    return ( 1, $extract_dir );
}

# Pure resolver: from a decoded manifest pick the layout package + the theme
# package(s) to install. $theme is an explicit choice; $all installs every
# theme; otherwise the layout's default_theme (falling back to its first).
# Returns { ok => 1, layout => {name,package}, themes => [{name,package}...] }
# or { ok => 0, error }.
sub _resolve_manifest_install {
    my ( $manifest, $layout, $theme, $all ) = @_;
    return { ok => 0, error => 'manifest.json has no layouts[]' }
        unless ref $manifest eq 'HASH' && ref $manifest->{layouts} eq 'ARRAY';

    my ($entry) = grep { ( $_->{name} // '' ) eq $layout }
        @{ $manifest->{layouts} };
    return { ok => 0, error => "Layout not in manifest: $layout" }
        unless $entry;
    return { ok => 0, error => "Layout '$layout' has no package in manifest" }
        unless defined $entry->{package} && length $entry->{package};

    my @themes = ref $entry->{themes} eq 'ARRAY' ? @{ $entry->{themes} } : ();
    my @want;
    if ($all) {
        @want = @themes;
    }
    elsif ( defined $theme && length $theme ) {
        my ($t) = grep { ( $_->{name} // '' ) eq $theme } @themes;
        return { ok => 0, error => "Theme '$theme' not listed for layout '$layout'" }
            unless $t;
        @want = ($t);
    }
    else {
        my $def = $entry->{default_theme} // '';
        my ($t) = grep { ( $_->{name} // '' ) eq $def } @themes;
        @want = $t ? ($t) : ( @themes ? ( $themes[0] ) : () );
    }

    return {
        ok     => 1,
        layout => { name => $entry->{name}, package => $entry->{package} },
        themes => [ map { { name => $_->{name}, package => $_->{package} } } @want ],
    };
}

# Fetch + return the catalogue for the browse UI, annotated with what is
# already installed locally.
sub action_layouts_manifest {
    my $repo = _layouts_repo();
    return { ok => 0, error => 'layouts_repo not set or invalid in lazysite.conf' }
        unless defined $repo && length $repo
            && $repo =~ m{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$};

    my ( $ok, $body ) = _http_get( _raw_base() . '/manifest.json' );
    return { ok => 0,
        error => "Could not fetch manifest.json ($body). The repo must ship a "
               . "manifest.json on the '" . _layouts_ref() . "' branch." }
        unless $ok;

    my $data = eval { decode_json($body) };
    return { ok => 0, error => 'manifest.json is not valid JSON' }
        unless ref $data eq 'HASH' && ref $data->{layouts} eq 'ARRAY';

    my %inst_layout =
        map { $_ => 1 } @{ ( action_layouts_available() || {} )->{layouts} || [] };

    my @out;
    for my $l ( @{ $data->{layouts} } ) {
        my $name = $l->{name};
        next unless defined $name && length $name;
        my %inst_theme;
        if ( $inst_layout{$name} ) {
            %inst_theme = map { $_ => 1 }
                @{ ( action_themes_for_layout($name) || {} )->{themes} || [] };
        }
        push @out, {
            name          => $name,
            version       => $l->{version}       // '',
            default_theme => $l->{default_theme} // '',
            installed     => $inst_layout{$name}
                ? JSON::PP::true() : JSON::PP::false(),
            themes => [
                map {
                    {
                        name      => $_->{name},
                        version   => $_->{version} // '',
                        installed => $inst_theme{ $_->{name} // '' }
                            ? JSON::PP::true() : JSON::PP::false(),
                    }
                } ( ref $l->{themes} eq 'ARRAY' ? @{ $l->{themes} } : () )
            ],
        };
    }

    return { ok => 1, repo => $repo, ref => _layouts_ref(), layouts => \@out };
}

# Install one layout + its theme(s) from the manifest, then (by default)
# activate it. Body: { layout, theme?, all?, activate? }.
sub action_layout_install {
    my ($request_body) = @_;
    my $req = eval { decode_json( $request_body // '{}' ) } // {};

    my $layout = $req->{layout} // '';
    $layout =~ s/[^A-Za-z0-9_-]//g;
    my $theme = $req->{theme};
    $theme =~ s/[^A-Za-z0-9_-]//g if defined $theme;
    my $all      = $req->{all}      ? 1 : 0;
    my $update   = $req->{update}   ? 1 : 0;
    my $activate = exists $req->{activate} ? ( $req->{activate} ? 1 : 0 ) : 1;
    return { ok => 0, error => 'layout required' } unless length $layout;

    my $repo = _layouts_repo();
    return { ok => 0, error => 'layouts_repo not set or invalid in lazysite.conf' }
        unless defined $repo && length $repo
            && $repo =~ m{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$};

    my $have_azip =
        eval { require Archive::Zip; Archive::Zip->import(qw(:ERROR_CODES)); 1 };
    return { ok => 0,
        error => 'Archive::Zip not installed (apt-get install libarchive-zip-perl)' }
        unless $have_azip;

    my ( $mok, $mbody ) = _http_get( _raw_base() . '/manifest.json' );
    return { ok => 0, error => "Could not fetch manifest.json ($mbody)" }
        unless $mok;
    my $manifest = eval { decode_json($mbody) };
    my $plan = _resolve_manifest_install( $manifest, $layout,
        ( $all ? undef : $theme ), $all );
    return $plan unless $plan->{ok};

    my $base    = _raw_base();
    my $tmp_dir = "/tmp/lazysite-layout-install-$$";
    make_path($tmp_dir);

    # 1. Layout package.
    my ( $lok, $ldir ) =
        _download_extract( "$base/$plan->{layout}{package}", "$tmp_dir/layout" );
    unless ($lok) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => "Layout download/extract failed: $ldir" };
    }
    my $lr = _install_layout_from_dir( $ldir, $layout, 'layout-install',
        $auth_user, $update );
    unless ( $lr->{ok} ) {
        _cleanup_tmp_layouts($tmp_dir);
        return { ok => 0, error => "Layout install failed: $lr->{error}" };
    }

    # 2. Theme package(s).
    my @themes_installed;
    my @theme_errors;
    for my $t ( @{ $plan->{themes} } ) {
        my $tname = $t->{name};
        my ( $tok, $tdir ) =
            _download_extract( "$base/$t->{package}", "$tmp_dir/theme-$tname" );
        unless ($tok) {
            push @theme_errors, "$tname: download/extract ($tdir)";
            next;
        }
        my $tr = _install_theme_from_dir( $tdir, 'layout-install', $auth_user );
        if ( $tr->{ok} ) {
            _mirror_theme_assets( $layout, $tname );
            push @themes_installed, $tname;
        }
        else {
            push @theme_errors, "$tname: $tr->{error}";
        }
    }

    _cleanup_tmp_layouts($tmp_dir);

    # 3. Activate (atomic; rebuilds the mirror + busts the cache).
    my $primary = ( defined $theme && length $theme ) ? $theme
                : ( $plan->{layout}{name} && grep { $_ eq $layout } @themes_installed )
                    ? $layout
                : ( @themes_installed ? $themes_installed[0] : '' );
    my $activated = JSON::PP::false();
    if ( $activate && @themes_installed ) {
        my $ar = action_layout_activate( $layout, { theme => $primary } );
        $activated = $ar->{ok} ? JSON::PP::true() : JSON::PP::false();
    }

    log_event( 'INFO', 'layout-install', 'manifest install',
        repo => $repo, ref => _layouts_ref(), layout => $layout,
        themes => join( ',', @themes_installed ),
        errors => join( '; ', @theme_errors ),
        activated => ( $activate ? 1 : 0 ), user => $auth_user );

    return {
        ok               => 1,
        layout           => $layout,
        themes_installed => \@themes_installed,
        theme_errors     => \@theme_errors,
        active_theme     => $primary,
        activated        => $activated,
    };
}

sub _install_layout_from_dir {
    my ( $layout_source, $layout_name, $action_label, $user, $force ) = @_;

    return { ok => 0, error => 'missing layout.tt in release' }
        unless -f "$layout_source/layout.tt";

    my $target_dir = "$DOCROOT/lazysite/layouts/$layout_name";

    # Collect the release's layout files: the root files (layout.tt, optional
    # layout.json) and the optional components/ subtree (D035 content
    # components). themes/ is handled separately by the theme walker. Component
    # files are carried as relative paths (components/<...>) so the compare and
    # copy logic below treats them like any other file.
    my @rel_files;
    opendir my $sh, $layout_source
        or return { ok => 0, error => 'Cannot read layout source dir' };
    for my $f ( sort readdir $sh ) {
        next if $f =~ /^\./;
        next if $f eq 'themes';
        my $src = "$layout_source/$f";
        if ( -f $src ) {
            push @rel_files, $f;
        }
        elsif ( -d $src && $f eq 'components' ) {
            push @rel_files, map { "components/$_" } _list_files_rel($src);
        }
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
            unless ($force) {
                return { ok => 0,
                    error => 'already installed and differs; refusing to overwrite ('
                           . join( ', ', @differs ) . '). Re-install with update to '
                           . 'overwrite.' };
            }
            # update: snapshot the existing layout (recoverable), then overwrite
            # the layout files. themes/ is left untouched.
            _snapshot_artifact( "$DOCROOT/lazysite/layouts", $layout_name );
            _prune_backups( "$DOCROOT/lazysite/layouts", $layout_name );
            for my $f (@rel_files) {
                make_path( dirname("$target_dir/$f") );
                my $rc = system( 'cp', "$layout_source/$f", "$target_dir/$f" );
                if ( $rc != 0 ) {
                    log_event( 'ERROR', $action_label, 'cp layout (update) failed',
                        file => $f, layout => $layout_name, rc => ( $rc >> 8 ) );
                    return { ok => 0,
                        error => "Update failed (cp $f to layout $layout_name)" };
                }
            }
            log_event( 'INFO', $action_label, 'layout updated',
                name => $layout_name, files => join( ',', @differs ), user => $user );
            return { ok => 1, action => 'updated' };
        }
        return { ok => 1, action => 'already_installed' };
    }

    # New install.
    make_path($target_dir);
    for my $f (@rel_files) {
        make_path( dirname("$target_dir/$f") );
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

# Recursively list regular files under $base as paths relative to $base.
sub _list_files_rel {
    my ( $base, $prefix ) = @_;
    $prefix //= '';
    my @out;
    opendir my $dh, $base or return @out;
    for my $e ( sort readdir $dh ) {
        next if $e =~ /^\./;
        my $full = "$base/$e";
        my $rel = length $prefix ? "$prefix/$e" : $e;
        if    ( -f $full ) { push @out, $rel }
        elsif ( -d $full ) { push @out, _list_files_rel( $full, $rel ) }
    }
    closedir $dh;
    return @out;
}

sub _slurp_bytes {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    my $data = do { local $/; <$fh> };
    close $fh;
    return $data;
}

1;
