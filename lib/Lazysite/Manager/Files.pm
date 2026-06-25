package Lazysite::Manager::Files;

# SM079: manager file CRUD (list / read / save / delete / mkdir), the edit-lock
# store, and the per-file ACL actions. Context ($DOCROOT, $LOCK_DIR,
# $LOCK_TIMEOUT, $auth_user, $action) is set by the dispatcher.

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Find;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Cwd qw(realpath);
use Fcntl qw(:flock);
use POSIX qw(strftime);
use Lazysite::Util qw(log_event);
use Lazysite::Manager::Common
    qw(validate_path is_blocked_path is_blocked_config write_file_checked);
use Lazysite::Auth::Acl
    qw(load_acls save_acls _acl_norm _to_list _acl_allows _is_operator _acl_denied);
use Lazysite::Manager::Upload qw(is_editable_text);
use Exporter 'import';

our @EXPORT_OK = qw(
    action_list action_read action_save action_delete action_mkdir action_move
    acquire_lock release_lock renew_lock _get_lock_info
    action_acl_get action_acl_set action_acl_remove
);

our $DOCROOT;
our $LOCK_DIR;
our $LOCK_TIMEOUT = 300;
our $auth_user    = '';
our $action       = '';

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
        unless $real && index( $real, $DOCROOT ) == 0 && -d $real;

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

    return { ok => 0, error => "Path is blocked" }
        if is_blocked_path( $result->{rel} );
    return { ok => 0, error => "Path is blocked by config" }
        if is_blocked_config( $result->{rel} );

    if ( my $d = _acl_denied( $result->{rel}, 'read', $username ) ) { return $d }

    my $full = $result->{full};
    return { ok => 0, error => "File not found" } unless -f $full;

    # SM019: refuse to load binary files as text. The editor handles
    # the binary=1 response by showing a download panel; decoding a
    # PNG as :utf8 here would otherwise emit replacement characters
    # and write the corrupted bytes back on save.
    unless ( is_editable_text( $result->{rel} ) ) {
        return {
            ok     => 0,
            binary => 1,
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

    return { ok => 0, error => "Path is blocked" }
        if is_blocked_path( $result->{rel} );
    return { ok => 0, error => "Path is blocked by config" }
        if is_blocked_config( $result->{rel} );

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
    }

    # Release lock
    unlink $lock_file if -f $lock_file;

    log_event('INFO', $action, 'file saved', path => $rel_path, user => $auth_user);

    my @st = stat($full);
    return { ok => 1, path => $rel_path, mtime => $st[9] // 0, created => $existed ? 0 : 1 };
}

sub action_delete {
    my ( $rel_path, $username ) = @_;

    my $result = validate_path($rel_path);
    return $result unless $result->{ok};

    return { ok => 0, error => "Path is blocked" }
        if is_blocked_path( $result->{rel} );
    return { ok => 0, error => "Path is blocked by config" }
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

    return { ok => 0, error => "File not found" } unless -f $full;

    unlink $full or return { ok => 0, error => "Cannot delete: $!" };

    ( my $cache = $full ) =~ s/\.md$/.html/;
    unlink $cache if -f $cache;

    log_event('INFO', $action, 'file deleted', path => $rel_path, user => $auth_user);

    return { ok => 1, path => $rel_path };
}

sub action_mkdir {
    my ($rel_path) = @_;

    my $result = validate_path($rel_path);
    return $result unless $result->{ok};

    return { ok => 0, error => "Path is blocked" }
        if is_blocked_path( $result->{rel} );
    return { ok => 0, error => "Path is blocked by config" }
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
        return { ok => 0, error => "Path is blocked" }
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
    }

    # Re-key the ACL entry to the new path.
    my $acls = load_acls();
    my ( $sk, $dk ) = ( _acl_norm( $s->{rel} ), _acl_norm( $d->{rel} ) );
    if ( exists $acls->{$sk} ) {
        $acls->{$dk} = delete $acls->{$sk};
        save_acls($acls);
    }

    unlink $lock_file if -f $lock_file;
    log_event( 'INFO', $action, 'file moved',
        from => $src_rel, to => $dst_rel, user => $auth_user );
    return { ok => 1, from => $s->{rel}, to => $d->{rel} };
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
    return { ok => 0, error => "Path is blocked" }
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
    return { ok => 0, error => "Path is blocked" }
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
    return { ok => 0, error => "Path is blocked" }
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

1;
