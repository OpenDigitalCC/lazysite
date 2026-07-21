package Lazysite::Manager::Files;

# SM079: manager file CRUD (list / read / save / delete / mkdir), the edit-lock
# store, and the per-file ACL actions. Context ($DOCROOT, $LOCK_DIR,
# $LOCK_TIMEOUT, $auth_user, $action) is set by the dispatcher.

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Find;
use File::Path qw(make_path);
use File::Copy     qw(copy);
use File::Basename qw(dirname);
use Cwd qw(realpath);
use Fcntl qw(:flock);
use POSIX qw(strftime);
use Lazysite::Util qw(log_event unlink_host_copies clear_host_cache);
use Lazysite::Manager::Common
    qw(validate_path is_blocked_path is_blocked_config write_file_checked _write_conf_key raw_html_page_refusal);
use Lazysite::Auth::Acl
    qw(load_acls save_acls _acl_norm _to_list _acl_allows _is_operator _acl_denied);
use Lazysite::Manager::Upload qw(is_editable_text);
use Exporter 'import';

our @EXPORT_OK = qw(
    action_list action_read action_save action_delete action_mkdir action_move action_copy
    action_migrate_to_local action_aliases_list
    acquire_lock release_lock renew_lock _get_lock_info
    action_acl_get action_acl_set action_acl_remove
    action_git_status action_git_history action_git_show action_git_restore action_git_init
);

our $DOCROOT;
our $LOCK_DIR;
our $LOCK_TIMEOUT = 300;
our $auth_user    = '';
our $action       = '';

# SM085: content-history commit hook. One cheap enabled() check inside
# commit_paths makes every call an instant no-op when the feature is off, and
# Lazysite::Git eval-guards the git work - a git failure never breaks a save.
# $GIT_COMMIT_MESSAGE is a one-shot override localised by action_git_restore so
# the restore's pass through action_save commits as "restore <path> to <sha7>".
our $GIT_COMMIT_MESSAGE;

sub _git_commit {
    my ( $user, $message, @paths ) = @_;
    require Lazysite::Git;
    Lazysite::Git::commit_paths( $DOCROOT, ( $user // $auth_user ), $message, @paths );
    return;
}

# SM175: a rename/move recorded as a first-class move - one commit staging the
# source deletion + the destination (+ sidecars), with a Lazysite-Renamed-From
# trailer naming $from, so content history follows the file across the rename and
# a later file at either path never inherits this one's past.
sub _git_commit_move {
    my ( $user, $message, $from, @paths ) = @_;
    require Lazysite::Git;
    Lazysite::Git::commit_move( $DOCROOT, ( $user // $auth_user ), $message, $from, @paths );
    return;
}

# === moved from lazysite-manager-api.pl (SM079a) ===

sub action_list {
    my ($dir_path) = @_;
    $dir_path //= '/';
    $dir_path =~ s{[^a-zA-Z0-9/_.-]}{}g;
    # SM019c: collapse a trailing slash so child paths are assembled
    # as "/dir/name" not "/dir//name". The next line keeps "/" itself
    # intact because s{/+$}{}  on "/" yields "", which we re-inflate.
    $dir_path =~ s{/+$}{};
    $dir_path = '/' if $dir_path eq '';

    my $fs_path = "$DOCROOT$dir_path";
    my $real    = realpath($fs_path);
    return { ok => 0, error => "Invalid path" }
        unless $real
        && ( $real eq $DOCROOT || index( $real, "$DOCROOT/" ) == 0 )    # SEC-2026-07 (H3)
        && -d $real;

    my @entries;
    my $acls = load_acls();   # SM074: owner display, read once per listing
    opendir my $dh, $real or return { ok => 0, error => "Cannot read directory" };
    for my $name ( sort readdir $dh ) {
        next if $name =~ /^\./;
        my $full = "$real/$name";
        my $rel  = $dir_path eq '/' ? "/$name" : "$dir_path/$name";
        my @st   = stat($full);
        my $is_dir = -d $full ? 1 : 0;
        my $entry  = {
            name  => $name,
            path  => $rel,
            type  => $is_dir ? 'dir' : 'file',
            size  => $is_dir ? 0 : ( $st[7] // 0 ),
            mtime => $st[9] // 0,
        };
        # SM019b: surface emptiness so the client knows whether a
        # dir row should get a delete-selection checkbox. The check
        # matches action_delete's rmdir semantics: any non-dot
        # entry (including hidden files) counts as content. We
        # only count, never stat, so the cost scales with the
        # directory size, not tree depth.
        if ( $is_dir ) {
            if ( opendir my $dh2, $full ) {
                my @kids = grep { $_ ne '.' && $_ ne '..' } readdir $dh2;
                closedir $dh2;
                $entry->{empty} = @kids ? JSON::PP::false : JSON::PP::true;
            }
        }
        else {
            # File metadata for the Files-page list-by-type and brief view.
            my ($ext) = $name =~ /\.([^.]+)$/;
            $entry->{ext} = defined $ext ? lc $ext : '';

            # A generated cache file is an .html with a .md/.url source
            # beside it - distinguishable from author .html (partials).
            if ( $name =~ /\.html$/ ) {
                ( my $stem = $full ) =~ s/\.html$//;
                $entry->{generated} =
                    ( -f "$stem.md" || -f "$stem.url" )
                    ? JSON::PP::true : JSON::PP::false;
            }

            # SM073: brief presence. A .brief is itself a sidecar; any other
            # file may carry one at "<file>.brief".
            if ( $name =~ /\.brief$/ ) {
                $entry->{is_brief} = JSON::PP::true;
            }
            else {
                $entry->{has_brief} =
                    ( -f "$full.brief" ) ? JSON::PP::true : JSON::PP::false;
                # SM074: surface ownership from the central ACL store.
                # SM077: also surface the read/write lists (for the inline
                # permissions editor) and any live lock (for the lock glyph).
                my $a = $acls->{ _acl_norm($rel) };
                if ($a) {
                    $entry->{owner} = $a->{owner}  if defined $a->{owner};
                    $entry->{read}  = $a->{read}   if ref $a->{read}  eq 'ARRAY';
                    $entry->{write} = $a->{write}  if ref $a->{write} eq 'ARRAY';
                }
                ( my $lk = $rel ) =~ s{/}{:}g;
                my $lrec = _read_lock_record("$LOCK_DIR/$lk.lock");
                if ( _lock_fresh($lrec) ) {
                    $entry->{lock} =
                        { locked_by => $lrec->{user}, origin => $lrec->{origin} };
                }
            }
        }
        push @entries, $entry;
    }
    closedir $dh;

    return { ok => 1, path => $dir_path, entries => \@entries };
}

sub action_read {
    my ( $rel_path, $username ) = @_;

    my $result = validate_path($rel_path);
    return $result unless $result->{ok};

    return { ok => 0, error => "Path is blocked", kind => 'blocked' }
        if is_blocked_path( $result->{rel} );
    return { ok => 0, error => "Path is blocked by config", kind => 'blocked-config' }
        if is_blocked_config( $result->{rel} );

    if ( my $d = _acl_denied( $result->{rel}, 'read', $username ) ) { return $d }

    my $full = $result->{full};
    return { ok => 0, error => "File not found", kind => 'not-found' } unless -f $full;

    # SM019: refuse to load binary files as text. The editor handles
    # the binary=1 response by showing a download panel; decoding a
    # PNG as :utf8 here would otherwise emit replacement characters
    # and write the corrupted bytes back on save.
    unless ( is_editable_text( $result->{rel} ) ) {
        return {
            ok     => 0,
            binary => 1,
            kind   => 'binary',
            path   => $rel_path,
            error  => "Binary file - download instead of edit",
        };
    }

    open my $fh, '<:utf8', $full or return { ok => 0, error => "Cannot read file" };
    my $content = do { local $/; <$fh> };
    close $fh;

    my $lock_info = _get_lock_info( $rel_path );

    return {
        ok      => 1,
        path    => $rel_path,
        content => $content,
        mtime   => ( stat $full )[9],
        lock    => $lock_info,
    };
}

sub action_save {
    my ( $rel_path, $username, $content, $mtime_check ) = @_;

    my $result = validate_path($rel_path);
    return $result unless $result->{ok};

    return { ok => 0, error => "Path is blocked", kind => 'blocked' }
        if is_blocked_path( $result->{rel} );
    return { ok => 0, error => "Path is blocked by config", kind => 'blocked-config' }
        if is_blocked_config( $result->{rel} );

    # SM189: refuse a content page that ships raw HTML/SVG (api:/raw: front matter
    # + a script-capable content_type). It bypasses the layout/theme, is served as
    # plain text (ADR 0006), and evades the no-CDN guard. Because MCP write_file /
    # create_page route through action_save, this covers the manager save AND MCP;
    # the WebDAV PUT path enforces the same guard in lazysite-dav.pl.
    if ( my $err = raw_html_page_refusal($content) ) {
        return { ok => 0, error => $err, kind => 'raw-content-refused' };
    }

    my $full = $result->{full};

    # Whether this is a create (new file) or an edit (overwrite) - surfaced in
    # the result so callers can record a meaningful audit action.
    my $existed = -f $full;

    # Conflict check
    if ( -f $full && $mtime_check ) {
        my $current_mtime = ( stat $full )[9];
        if ( $current_mtime != $mtime_check ) {
            return {
                ok       => 0,
                conflict => 1,
                error    => "File was modified since you opened it",
                mtime    => $current_mtime,
            };
        }
    }

    # Lock check. Refuse to overwrite a file held by a live lock that the
    # saver does not own - whether that lock came from WebDAV (origin=dav,
    # opaque to the manager) or another manager user. Mirrors acquire_lock.
    # (The previous inline parser only understood the legacy "user epoch"
    # line format and silently ignored JSON/DAV locks - a lock-propagation
    # hole where a manager save could clobber a WebDAV-locked file.)
    my $lock_key = $rel_path;
    $lock_key =~ s{/}{:}g;
    my $lock_file = "$LOCK_DIR/$lock_key.lock";
    my $lrec = _read_lock_record($lock_file);
    if ( _lock_fresh($lrec)
         && ( $lrec->{origin} eq 'dav' || ( $lrec->{user} // '' ) ne $username ) ) {
        return {
            ok     => 0,
            locked => 1,
            error  => $lrec->{origin} eq 'dav'
                ? "File is locked via WebDAV by " . ( $lrec->{user} // 'another client' )
                : "File is locked by " . ( $lrec->{user} // 'another user' ),
        };
    }

    # SM074: per-file ACL write gate (operators bypass).
    if ( my $d = _acl_denied( $result->{rel}, 'write', $username ) ) { return $d }

    # Create parent directories
    my $dir = dirname($full);
    make_path($dir) unless -d $dir;

    my ( $wok, $werr ) = write_file_checked( $full, $content );
    return { ok => 0, error => $werr } unless $wok;

    # Invalidate cache (only for .md files that have .html cache)
    if ( $full =~ /\.md$/ ) {
        ( my $cache = $full ) =~ s/\.md$/.html/;
        unlink $cache if -f $cache;
        # SM110: drop the per-alias-host copies of this page's render too.
        unlink_host_copies( $DOCROOT, $cache );
        # SM134: keep the alias-redirect map current for this content page.
        require Lazysite::Aliases;
        ( my $arel = $full ) =~ s{^\Q$DOCROOT\E/?}{};
        Lazysite::Aliases::index_page( $DOCROOT, $arel, $content );
    }

    # Release lock
    unlink $lock_file if -f $lock_file;

    log_event('INFO', $action, 'file saved', path => $rel_path, user => $auth_user);

    # SM085: every save is a content-history commit (create vs edit named).
    _git_commit( $username,
        $GIT_COMMIT_MESSAGE
            // ( ( $existed ? 'edit ' : 'create ' ) . $result->{rel} ),
        $result->{rel} );

    _invalidate_registries();
    # A nav change shows on every page - clear all caches, and tell the caller.
    my $nav_change = $rel_path =~ m{(?:^|/)nav\.conf$} ? 1 : 0;
    _invalidate_all_html() if $nav_change;

    my @st = stat($full);
    return { ok => 1, path => $rel_path, mtime => $st[9] // 0,
        created => $existed ? 0 : 1,
        ( $nav_change ? ( cache_rebuilt => 'all-pages' ) : () ) };
}

# SM087: a content create/delete/move changes the page set (or a page's lastmod),
# so the generated registries (sitemap.xml, llms.txt, feed.*) are now stale.
# Removing the generated outputs makes the processor regenerate them fresh on the
# next request (update_registries rebuilds a missing output) - the cross-process
# refresh that fixes "deleted page still in sitemap/llms".
sub _invalidate_registries {
    my $rdir = "$DOCROOT/lazysite/templates/registries";
    return unless -d $rdir;
    opendir my $dh, $rdir or return;
    my @tt = grep { /\.tt$/ } readdir $dh;
    closedir $dh;
    for my $t (@tt) {
        ( my $out = $t ) =~ s/\.tt$//;
        unlink "$DOCROOT/$out" if -f "$DOCROOT/$out";
    }
    return;
}

# SM087: a site-wide config change (nav.conf) appears on every rendered page, so
# the per-page cache clear isn't enough - drop every generated .html so all pages
# re-render with the new nav on the next request.
sub _invalidate_all_html {
    my @stack = ($DOCROOT);
    while (@stack) {
        my $dir = pop @stack;
        opendir my $dh, $dir or next;
        for my $e ( readdir $dh ) {
            next if $e =~ /^\./;
            my $full = "$dir/$e";
            if ( -d $full ) { push @stack, $full unless $e =~ /^(?:lazysite|lazysite-assets)$/; next }
            unlink $full if $e =~ /\.html$/;
        }
        closedir $dh;
    }
    # SM110: the sweep above skips lazysite/ - drop the per-alias-host cache
    # tree wholesale too (a nav change shows on every page of every host).
    clear_host_cache($DOCROOT);
    return;
}

sub action_delete {
    my ( $rel_path, $username ) = @_;

    my $result = validate_path($rel_path);
    return $result unless $result->{ok};

    return { ok => 0, error => "Path is blocked", kind => 'blocked' }
        if is_blocked_path( $result->{rel} );
    return { ok => 0, error => "Path is blocked by config", kind => 'blocked-config' }
        if is_blocked_config( $result->{rel} );

    # SM074: per-file ACL write gate (operators bypass).
    if ( my $d = _acl_denied( $result->{rel}, 'write', $username ) ) { return $d }

    my $full = $result->{full};

    # SM019b: empty directories are deletable from the manager.
    # Non-empty ones are rejected - no recursive delete.
    if ( -d $full ) {
        opendir my $dh, $full
            or return { ok => 0, error => "Cannot read directory: $!" };
        my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        if ( @entries ) {
            return { ok => 0, error => "Directory is not empty" };
        }
        rmdir $full
            or return { ok => 0, error => "Cannot remove directory: $!" };
        log_event('INFO', $action, 'directory deleted',
            path => $rel_path, user => $auth_user);
        return { ok => 1, path => $rel_path };
    }

    return { ok => 0, error => "File not found", kind => 'not-found' } unless -f $full;

    unlink $full or return { ok => 0, error => "Cannot delete: $!" };

    ( my $cache = $full ) =~ s/\.md$/.html/;
    unlink $cache if -f $cache;
    # SM110: drop the per-alias-host copies of this page's render too.
    unlink_host_copies( $DOCROOT, $cache ) if $full =~ /\.md$/;

    # SM134: drop this page's alias-redirect entries.
    if ( $full =~ /\.md$/ ) {
        require Lazysite::Aliases;
        ( my $arel = $full ) =~ s{^\Q$DOCROOT\E/?}{};
        Lazysite::Aliases::deindex_page( $DOCROOT, $arel );
    }

    log_event('INFO', $action, 'file deleted', path => $rel_path, user => $auth_user);
    # SM085: record the deletion in the content history.
    _git_commit( $username, "delete $result->{rel}", $result->{rel} );
    _invalidate_registries();

    return { ok => 1, path => $rel_path };
}

sub action_mkdir {
    my ($rel_path) = @_;

    my $result = validate_path($rel_path);
    return $result unless $result->{ok};

    return { ok => 0, error => "Path is blocked", kind => 'blocked' }
        if is_blocked_path( $result->{rel} );
    return { ok => 0, error => "Path is blocked by config", kind => 'blocked-config' }
        if is_blocked_config( $result->{rel} );

    my $full = $result->{full};
    return { ok => 0, error => "Path already exists" } if -e $full;

    make_path($full)
        or return { ok => 0, error => "Cannot create directory: $!" };

    log_event('INFO', $action, 'directory created',
        path => $rel_path, user => $auth_user);

    return { ok => 1, path => $rel_path };
}

# SM077: rename / move a file or directory. Validates + deny-checks both ends,
# refuses an existing target or a live foreign lock on the source, enforces the
# per-file ACL (write on the source), then moves the file, its .brief sidecar
# and any generated .html cache, and re-keys the source's ACL entry to the new
# path. (A moved directory's own ACL entry is re-keyed; descendant entries are
# not - rare, noted.)
sub action_move {
    my ( $src_rel, $dst_rel, $username ) = @_;
    my $s = validate_path($src_rel);
    return $s unless $s->{ok};
    my $d = validate_path($dst_rel);
    return $d unless $d->{ok};

    for my $r ( $s->{rel}, $d->{rel} ) {
        return { ok => 0, error => "Path is blocked", kind => 'blocked' }
            if is_blocked_path($r) || is_blocked_config($r);
    }

    my ( $src_full, $dst_full ) = ( $s->{full}, $d->{full} );
    return { ok => 0, error => "Source not found" }     unless -e $src_full;
    return { ok => 0, error => "Target already exists" } if -e $dst_full;

    # Refuse a live foreign lock on the source (mirror action_save).
    my $lock_key = $src_rel;
    $lock_key =~ s{/}{:}g;
    my $lock_file = "$LOCK_DIR/$lock_key.lock";
    my $lrec = _read_lock_record($lock_file);
    if ( _lock_fresh($lrec)
         && ( $lrec->{origin} eq 'dav' || ( $lrec->{user} // '' ) ne $username ) ) {
        return { ok => 0, locked => 1,
            error => "Source is locked by " . ( $lrec->{user} // 'another user' ) };
    }

    # Per-file ACL: write access on the source (operators bypass).
    if ( my $deny = _acl_denied( $s->{rel}, 'write', $username ) ) { return $deny }

    my $dst_dir = dirname($dst_full);
    make_path($dst_dir) unless -d $dst_dir;
    rename( $src_full, $dst_full )
        or return { ok => 0, error => "Move failed: $!" };

    # Move the .brief sidecar and any generated .html cache alongside.
    rename( "$src_full.brief", "$dst_full.brief" ) if -e "$src_full.brief";
    if ( $src_full =~ /\.md$/ ) {
        ( my $src_cache = $src_full ) =~ s/\.md$/.html/;
        ( my $dst_cache = $dst_full ) =~ s/\.md$/.html/;
        rename( $src_cache, $dst_cache ) if -f $src_cache;
        # SM110: per-alias-host copies are not moved - drop both the source
        # copies (the page's URL changed) and any lingering ones at the
        # destination path; each host re-renders on its next request.
        unlink_host_copies( $DOCROOT, $src_cache );
        unlink_host_copies( $DOCROOT, $dst_cache );
    }

    # Re-key the ACL entry to the new path.
    my $acls = load_acls();
    my ( $sk, $dk ) = ( _acl_norm( $s->{rel} ), _acl_norm( $d->{rel} ) );
    if ( exists $acls->{$sk} ) {
        $acls->{$dk} = delete $acls->{$sk};
        save_acls($acls);
    }

    # SM134 follow-ups: the page's canonical URL changed - re-key its
    # alias-redirect entries too (per page under a moved directory).
    require Lazysite::Aliases;
    Lazysite::Aliases::reindex_move( $DOCROOT, $s->{rel}, $d->{rel} );

    unlink $lock_file if -f $lock_file;
    log_event( 'INFO', $action, 'file moved',
        from => $src_rel, to => $dst_rel, user => $auth_user );
    # SM085: a move (and its sidecar) is ONE commit; the source deletion and
    # the destination are staged together. SM175: recorded as a first-class move
    # (Lazysite-Renamed-From: $s->{rel}) so content history follows the rename.
    _git_commit_move( $username, "move $s->{rel} -> $d->{rel}", $s->{rel},
        $s->{rel}, $d->{rel},
        ( -e "$dst_full.brief" ? ( "$s->{rel}.brief", "$d->{rel}.brief" ) : () ) );
    _invalidate_registries();
    return { ok => 1, from => $s->{rel}, to => $d->{rel} };
}

# SM: duplicate a file. Like action_move but copies rather than renames, needs
# only READ on the source, and the duplicate is a fresh file owned by whoever
# made it. The generated .html cache is NOT copied - the copy re-renders on
# first request; the .brief sidecar IS copied.
sub action_copy {
    my ( $src_rel, $dst_rel, $username ) = @_;
    my $s = validate_path($src_rel);
    return $s unless $s->{ok};
    my $d = validate_path($dst_rel);
    return $d unless $d->{ok};

    for my $r ( $s->{rel}, $d->{rel} ) {
        return { ok => 0, error => "Path is blocked", kind => 'blocked' }
            if is_blocked_path($r) || is_blocked_config($r);
    }

    my ( $src_full, $dst_full ) = ( $s->{full}, $d->{full} );
    return { ok => 0, error => "Source not found" } unless -e $src_full;
    return { ok => 0, error => "Source is a directory" } if -d $src_full;
    return { ok => 0, error => "Target already exists" } if -e $dst_full;

    # Per-file ACL: READ access on the source (operators bypass).
    if ( my $deny = _acl_denied( $s->{rel}, 'read', $username ) ) { return $deny }

    my $dst_dir = dirname($dst_full);
    make_path($dst_dir) unless -d $dst_dir;
    copy( $src_full, $dst_full )
        or return { ok => 0, error => "Copy failed: $!" };
    copy( "$src_full.brief", "$dst_full.brief" ) if -e "$src_full.brief";

    # The duplicate is a fresh file owned by its creator (fresh ACL, no inherited
    # read/write lists from the source).
    if ( defined $username && length $username ) {
        my $acls = load_acls();
        $acls->{ _acl_norm( $d->{rel} ) } = { owner => $username };
        save_acls($acls);
    }

    # SM134 follow-ups: index the duplicate's aliases now, not on its next save
    # (same last-writer-wins collision rule as a save, since the copy still
    # carries the source's alias list).
    require Lazysite::Aliases;
    Lazysite::Aliases::reindex_copy( $DOCROOT, $d->{rel} );

    log_event( 'INFO', $action, 'file copied',
        from => $src_rel, to => $dst_rel, user => $auth_user );
    # SM085: the duplicate (and its copied sidecar) is one commit.
    _git_commit( $username, "copy $s->{rel} -> $d->{rel}",
        $d->{rel}, ( -e "$dst_full.brief" ? ("$d->{rel}.brief") : () ) );
    _invalidate_registries();
    return { ok => 1, from => $s->{rel}, to => $d->{rel} };
}

# SM096: migrate a remote .url page to local ownership. Fetch the remote body
# through the shared GUARDED fetch (Lazysite::Fetch - same SSRF guard the
# processor uses), write it as a sibling .md, then drop the .url. The page becomes
# local content (the .md wins over the .url in the processor anyway); the .brief
# sidecar and the ACL entry are carried across and any cached render is cleared.
sub action_migrate_to_local {
    my ( $rel, $username ) = @_;
    my $s = validate_path($rel);
    return $s unless $s->{ok};
    return { ok => 0, error => 'Not a .url page' } unless $s->{rel} =~ /\.url$/;
    return { ok => 0, error => 'Path is blocked', kind => 'blocked' }
        if is_blocked_path( $s->{rel} ) || is_blocked_config( $s->{rel} );

    my $url_full = $s->{full};
    return { ok => 0, error => 'Source not found' } unless -f $url_full;

    ( my $md_rel  = $s->{rel} ) =~ s/\.url$/.md/;
    ( my $md_full = $url_full ) =~ s/\.url$/.md/;
    return { ok => 0, error => 'A .md already exists at this path' } if -e $md_full;

    # Per-file ACL: write access on the target page (operators bypass).
    if ( my $deny = _acl_denied( $s->{rel}, 'write', $username ) ) { return $deny }

    open my $uf, '<', $url_full or return { ok => 0, error => 'Cannot read the .url file' };
    my $url = do { local $/; <$uf> };
    close $uf;
    $url =~ s/^\s+|\s+$//g;
    return { ok => 0, error => 'The .url file is empty' } unless length $url;

    require Lazysite::Fetch;
    my $body = Lazysite::Fetch::fetch_url($url);
    return { ok => 0, error => "Could not fetch $url (unreachable, blocked by the "
            . "SSRF guard, or a non-success response)" }
        unless defined $body;

    my ( $wok, $werr ) = write_file_checked( $md_full, $body );
    return { ok => 0, error => "Could not write the local page: $werr" } unless $wok;

    unlink $url_full;    # the page is now local; the .md serves it
    rename( "$url_full.brief", "$md_full.brief" ) if -e "$url_full.brief";

    # Re-key the ACL entry from the .url to the .md (ownership carries over).
    my $acls = load_acls();
    my ( $uk, $mk ) = ( _acl_norm( $s->{rel} ), _acl_norm($md_rel) );
    if ( exists $acls->{$uk} ) {
        $acls->{$mk} = delete $acls->{$uk};
        save_acls($acls);
    }

    ( my $cache = $md_full ) =~ s/\.md$/.html/;
    unlink $cache if -f $cache;
    # SM110: drop the per-alias-host copies of this page's render too.
    unlink_host_copies( $DOCROOT, $cache );

    # SM134 follow-ups: the fetched body may declare aliases - index the new
    # local page now rather than on its next save (same gap as move/copy).
    require Lazysite::Aliases;
    Lazysite::Aliases::index_page( $DOCROOT, $md_rel, $body );

    log_event( 'INFO', $action, 'migrated .url to local .md',
        from => $s->{rel}, to => $md_rel, url => $url, user => $auth_user );
    # SM085: the .url removal and the new local .md are one commit.
    _git_commit( $username, "migrate $s->{rel} -> $md_rel",
        $s->{rel}, $md_rel,
        ( -e "$md_full.brief" ? ( "$s->{rel}.brief", "$md_rel.brief" ) : () ) );
    _invalidate_registries();
    return { ok => 1, from => $s->{rel}, to => $md_rel, url => $url };
}

# SM134 follow-ups: the current alias-redirect map for the manager's read-only
# Aliases card - rows of { alias, target, code }, sorted by alias. Aliases are
# authored in page front matter (`aliases:` / `aliases_temp:`); there is nothing
# to edit here, so this is a plain read (no path, no ACL - the map holds only
# site-local URL pairs).
sub action_aliases_list {
    require Lazysite::Aliases;
    return { ok => 1, aliases => Lazysite::Aliases::list_aliases($DOCROOT) };
}

sub _read_lock_record {
    my ($lock_file) = @_;
    return undef unless -f $lock_file;
    open my $fh, '<', $lock_file or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return undef unless defined $raw;
    $raw =~ s/^\s+//;
    if ( $raw =~ /^\{/ ) {
        my $rec = eval { decode_json($raw) };
        return undef unless ref $rec eq 'HASH';
        $rec->{origin}  ||= 'manager';
        $rec->{timeout} ||= $LOCK_TIMEOUT;
        return $rec;
    }
    my ( $user, $at ) = split /\s+/, $raw, 2;
    return undef unless defined $user;
    $at //= 0;
    $at =~ s/\D.*$//;
    return { user => $user, at => ( $at || 0 ), origin => 'manager',
             timeout => $LOCK_TIMEOUT, token => undef, owner => '' };
}

sub _write_lock_record {
    my ( $lock_file, $rec ) = @_;
    my $tmp = "$lock_file.tmp.$$";
    open my $fh, '>', $tmp or return 0;
    print $fh JSON::PP->new->canonical->encode($rec);
    close $fh;
    chmod 0640, $tmp;
    return rename $tmp, $lock_file;
}

sub _lock_fresh {
    my ($rec) = @_;
    return 0 unless $rec;
    my $age = time() - ( $rec->{at} // 0 );
    return $age < ( $rec->{timeout} // $LOCK_TIMEOUT ) ? 1 : 0;
}

sub acquire_lock {
    my ( $rel_path, $username ) = @_;
    make_path($LOCK_DIR) unless -d $LOCK_DIR;

    my $lock_key = $rel_path;
    $lock_key =~ s{/}{:}g;
    my $lock_file = "$LOCK_DIR/$lock_key.lock";

    my $rec = _read_lock_record($lock_file);
    # A fresh lock blocks if it is held via WebDAV (opaque to the
    # manager) or by a different manager user. The user may refresh
    # their own manager lock.
    if ( _lock_fresh($rec)
         && ( $rec->{origin} eq 'dav' || ( $rec->{user} // '' ) ne $username ) ) {
        return {
            ok        => 0,
            locked    => 1,
            locked_by => $rec->{user},
            locked_at => $rec->{at},
            origin    => $rec->{origin},
            expires   => ( $rec->{at} // 0 ) + ( $rec->{timeout} // $LOCK_TIMEOUT ),
        };
    }

    _write_lock_record( $lock_file, {
        user => $username, at => time(), origin => 'manager',
        timeout => $LOCK_TIMEOUT, token => undef, owner => '',
    } ) or return { ok => 0, error => "Cannot write lock" };
    return { ok => 1, locked_by => $username };
}

sub release_lock {
    my ( $rel_path, $username ) = @_;
    my $lock_key = $rel_path;
    $lock_key =~ s{/}{:}g;
    my $lock_file = "$LOCK_DIR/$lock_key.lock";

    # Never let the manager UI release a live WebDAV lock.
    my $rec = _read_lock_record($lock_file);
    if ( _lock_fresh($rec) && $rec->{origin} eq 'dav' ) {
        return { ok => 0, error => "Locked via WebDAV" };
    }
    unlink $lock_file if -f $lock_file;
    return { ok => 1 };
}

sub renew_lock {
    my ( $rel_path, $username ) = @_;
    return acquire_lock( $rel_path, $username );
}

sub _get_lock_info {
    my ($rel_path) = @_;
    my $lock_key = $rel_path;
    $lock_key =~ s{/}{:}g;
    my $lock_file = "$LOCK_DIR/$lock_key.lock";
    my $rec = _read_lock_record($lock_file);
    return {} unless $rec;
    return {
        locked_by => $rec->{user},
        locked_at => $rec->{at},
        origin    => $rec->{origin},
        active    => _lock_fresh($rec) ? 1 : 0,
    };
}

sub action_acl_get {
    my ( $rel_path, $user ) = @_;
    my $r = validate_path($rel_path);
    return $r unless $r->{ok};
    return { ok => 0, error => "Path is blocked", kind => 'blocked' }
        if is_blocked_path( $r->{rel} ) || is_blocked_config( $r->{rel} );
    my $a = load_acls()->{ _acl_norm( $r->{rel} ) };
    unless ( _is_operator() ) {
        return { ok => 0, error => "Not the owner of this file" }
            if $a && ( $a->{owner} // '' ) ne ( $user // '' );
    }
    return { ok => 1, path => $r->{rel}, acl => $a };
}

sub action_acl_set {
    my ( $rel_path, $user, $read, $write, $owner_req ) = @_;
    my $r = validate_path($rel_path);
    return $r unless $r->{ok};
    my $rel = _acl_norm( $r->{rel} );
    return { ok => 0, error => "Path is blocked", kind => 'blocked' }
        if is_blocked_path($rel) || is_blocked_config($rel);

    my $acls     = load_acls();
    my $existing = $acls->{$rel};

    unless ( _is_operator() ) {
        if ($existing) {
            return { ok => 0, error => "Only the owner may change permissions" }
                unless ( $existing->{owner} // '' ) eq ( $user // '' );
        }
        else {
            # Creating the first ACL needs write access to the file.
            return { ok => 0, error => "You cannot set permissions on this file" }
                unless _acl_allows( $rel, 'write', $user );
        }
    }

    # Keep an existing owner; otherwise an operator may name one, and a
    # normal user always becomes the owner of what they claim.
    my $owner =
        $existing ? $existing->{owner}
      : ( _is_operator() && defined $owner_req && length $owner_req ) ? $owner_req
      : $user;
    my %rec = ( owner => $owner );
    my $rl = _to_list($read);  $rec{read}  = $rl if defined $rl;
    my $wl = _to_list($write); $rec{write} = $wl if defined $wl;
    $acls->{$rel} = \%rec;
    save_acls($acls) or return { ok => 0, error => "Cannot write the ACL store" };
    log_event( 'INFO', 'acl-set', 'acl set', path => $rel, user => $auth_user );
    return { ok => 1, path => $r->{rel}, acl => \%rec };
}

sub action_acl_remove {
    my ( $rel_path, $user ) = @_;
    my $r = validate_path($rel_path);
    return $r unless $r->{ok};
    my $rel  = _acl_norm( $r->{rel} );
    return { ok => 0, error => "Path is blocked", kind => 'blocked' }
        if is_blocked_path($rel) || is_blocked_config($rel);
    my $acls = load_acls();
    my $existing = $acls->{$rel};
    return { ok => 1, path => $r->{rel}, removed => 0 } unless $existing;
    unless ( _is_operator() || ( $existing->{owner} // '' ) eq ( $user // '' ) ) {
        return { ok => 0, error => "Only the owner may remove permissions" };
    }
    delete $acls->{$rel};
    save_acls($acls) or return { ok => 0, error => "Cannot write the ACL store" };
    log_event( 'INFO', 'acl-remove', 'acl removed', path => $rel, user => $auth_user );
    return { ok => 1, path => $r->{rel}, removed => 1 };
}

# --- SM085: content-history manager actions -------------------------------------
# Reads (status/history/show) mirror action_read's gates: path validation, the
# deny lists, and the per-file ACL read gate. Restore never writes divergently -
# it routes the historic content back through action_save, so it inherits the
# lock/ACL checks, cache invalidation (host copies included), alias reindexing,
# the audit entry, and its own history commit.

sub _git_bool { return $_[0] ? JSON::PP::true : JSON::PP::false }

# Shared validation for the per-file history reads. Returns the validate_path
# result or the refusal hash.
sub _git_target {
    my ( $rel_path, $username ) = @_;
    my $r = validate_path($rel_path);
    return $r unless $r->{ok};
    return { ok => 0, error => "Path is blocked", kind => 'blocked' }
        if is_blocked_path( $r->{rel} );
    return { ok => 0, error => "Path is blocked by config", kind => 'blocked-config' }
        if is_blocked_config( $r->{rel} );
    if ( my $deny = _acl_denied( $r->{rel}, 'read', $username ) ) { return $deny }
    return $r;
}

# Feature status for the Files page's History control (the operator-facing
# enable/status surface is the content-history plugin, which drives the same
# Lazysite::Git machinery).
sub action_git_status {
    require Lazysite::Git;
    my $enabled = Lazysite::Git::enabled($DOCROOT);
    return {
        ok            => 1,
        enabled       => _git_bool($enabled),
        initialised   => _git_bool( Lazysite::Git::initialised($DOCROOT) ),
        git_available => _git_bool( Lazysite::Git::git_available() ),
        commits       => ( $enabled ? Lazysite::Git::count_commits($DOCROOT) : 0 ),
    };
}

# Per-file timeline. Disabled / no repo = an empty list, never an error.
sub action_git_history {
    my ( $rel_path, $username, $limit ) = @_;
    my $r = _git_target( $rel_path, $username );
    return $r unless $r->{ok};
    require Lazysite::Git;
    my $enabled = Lazysite::Git::enabled($DOCROOT);
    return {
        ok      => 1,
        path    => $r->{rel},
        enabled => _git_bool($enabled),
        entries => ( $enabled ? Lazysite::Git::file_log( $DOCROOT, $r->{rel}, $limit ) : [] ),
    };
}

# One version: its raw content plus the unified diff against the worktree.
sub action_git_show {
    my ( $rel_path, $username, $sha ) = @_;
    my $r = _git_target( $rel_path, $username );
    return $r unless $r->{ok};
    return { ok => 0, error => 'Invalid version id' }
        unless defined $sha && $sha =~ /\A[0-9a-f]{7,40}\z/;
    # Binary parity with action_read: history content travels as JSON text and
    # a restore would round-trip through the :utf8 save path.
    return { ok => 0, binary => 1, kind => 'binary',
        error => 'Binary file - history view is text-only' }
        unless is_editable_text( $r->{rel} );
    require Lazysite::Git;
    return { ok => 0, error => 'Content history is not enabled' }
        unless Lazysite::Git::enabled($DOCROOT);
    # SM175: history may have crossed a rename - read from the path this file
    # HAD at $sha (resolved server-side through its own lineage, never a
    # client-supplied path), and diff that historic blob against the current one.
    my $read    = Lazysite::Git::path_at( $DOCROOT, $r->{rel}, $sha ) // $r->{rel};
    my $content = Lazysite::Git::file_at( $DOCROOT, $sha, $read );
    return { ok => 0, error => 'No such version of this file' }
        unless defined $content;
    my $diff = ( $read eq $r->{rel} )
        ? Lazysite::Git::file_diff( $DOCROOT, $sha, $r->{rel} )
        : Lazysite::Git::file_diff_across( $DOCROOT, $sha, $read, $r->{rel} );
    return {
        ok   => 1,
        path => $r->{rel},
        ( $read ne $r->{rel} ? ( from_path => $read ) : () ),
        sha     => $sha,
        content => $content,
        diff    => ( $diff // '' ),
    };
}

# Restore = the historic content written back THROUGH action_save (never a
# divergent write path); the save commits it as "restore <path> to <sha7>".
sub action_git_restore {
    my ( $rel_path, $username, $sha ) = @_;
    my $r = _git_target( $rel_path, $username );
    return $r unless $r->{ok};
    return { ok => 0, error => 'Invalid version id' }
        unless defined $sha && $sha =~ /\A[0-9a-f]{7,40}\z/;
    return { ok => 0, binary => 1, kind => 'binary',
        error => 'Binary file - restore from history is text-only' }
        unless is_editable_text( $r->{rel} );
    require Lazysite::Git;
    return { ok => 0, error => 'Content history is not enabled' }
        unless Lazysite::Git::enabled($DOCROOT);
    # SM175: read from the path this file HAD at $sha (lineage-resolved), so a
    # pre-rename version restores into the CURRENT path rather than 404ing.
    my $read    = Lazysite::Git::path_at( $DOCROOT, $r->{rel}, $sha ) // $r->{rel};
    my $content = Lazysite::Git::file_at( $DOCROOT, $sha, $read );
    return { ok => 0, error => 'No such version of this file' }
        unless defined $content;
    my $sha7 = substr $sha, 0, 7;
    local $GIT_COMMIT_MESSAGE = "restore $r->{rel} to $sha7";
    my $saved = action_save( $rel_path, $username, $content, undef );
    return $saved unless ref $saved eq 'HASH' && $saved->{ok};
    $saved->{restored_from} = $sha;
    return $saved;
}

# Enable + initialise: sets the conf key, runs the adoption commit, reports it.
sub action_git_init {
    my ($username) = @_;
    require Lazysite::Git;
    return { ok => 0,
        error => 'git is not installed on this host - install the git package '
            . 'and try again' }
        unless Lazysite::Git::git_available();
    _write_conf_key( 'git_history', 'enabled' )
        or return { ok => 0, error => 'Could not write lazysite.conf' };
    Lazysite::Git::reset_cache();
    if ( Lazysite::Git::initialised($DOCROOT) ) {
        return { ok => 1, already => 1,
            commits => Lazysite::Git::count_commits($DOCROOT) };
    }
    my $r = Lazysite::Git::init( $DOCROOT, $username );
    return $r unless $r->{ok};
    log_event( 'INFO', $action, 'content history enabled',
        commit => ( $r->{commit} // '' ), user => $auth_user );
    return { ok => 1, commit => $r->{commit},
        commits => Lazysite::Git::count_commits($DOCROOT) };
}

1;
