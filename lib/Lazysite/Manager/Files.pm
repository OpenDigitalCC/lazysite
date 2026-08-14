package Lazysite::Manager::Files;

# SM079: manager file CRUD (list / read / save / delete / mkdir), the edit-lock
# store, and the per-file ACL actions. Context ($DOCROOT, $LOCK_DIR,
# $LOCK_TIMEOUT, $auth_user, $action) is set by the dispatcher.

use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Find;
use File::Path      qw(make_path);
use File::Copy      qw(copy);
use File::Basename  qw(dirname);
use Cwd             qw(realpath);
use Fcntl           qw(:flock);
use POSIX           qw(strftime);
use Lazysite::Util  qw(log_event unlink_host_copies clear_host_cache);
use Lazysite::Paths ();
use Lazysite::Manager::Common
    qw(validate_path is_blocked_path is_blocked_config write_file_checked _write_conf_key raw_html_page_refusal load_upload_limits outside_all_scopes);
use Lazysite::Auth::Acl
    qw(load_acls save_acls _acl_norm _to_list _acl_allows _is_operator _acl_denied);
use Lazysite::Manager::Upload qw(is_editable_text);
use Lazysite::Private         ();                    # SM286: where content actually lives
use Exporter 'import';

our @EXPORT_OK = qw(
    action_list action_read action_save action_save_binary
    action_delete action_mkdir action_move action_copy
    action_migrate_to_local action_aliases_list
    acquire_lock release_lock renew_lock _get_lock_info
    action_acl_get action_acl_set action_acl_remove action_protected_sections
    invalidate_registries registry_roots action_regenerate_registries
    action_git_status action_git_history action_git_history_summary
    action_git_show action_git_restore action_git_init
);

our $DOCROOT;

# SM293: this site's engine tree - beside the docroot once migrated,
# inside it before. Asked, never computed, so both layouts work on one
# code path and a site migrates by moving the directory.
sub _lz { return Lazysite::Paths::lazysite_dir($DOCROOT) }
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

# SM286: the same canonical directory in the OTHER tree, or undef. Used only to
# union a listing's children - never to resolve a path, which stays the job of
# Lazysite::Private so there is one answer to "where does this live".
sub _sibling_dir {
    my ( $real, $lroot, $canon ) = @_;
    my $priv = Lazysite::Private::private_root($DOCROOT);
    return undef unless defined $priv && length $priv;
    my $other = ( $lroot eq $DOCROOT ) ? $priv : $DOCROOT;
    return length $canon ? "$other/$canon" : $other;
}

sub action_list {
    my ($dir_path) = @_;
    $dir_path //= '/';
    $dir_path =~ s{[^a-zA-Z0-9/_.-]}{}g;
    # SM019c: collapse a trailing slash so child paths are assembled
    # as "/dir/name" not "/dir//name". The next line keeps "/" itself
    # intact because s{/+$}{}  on "/" yields "", which we re-inflate.
    $dir_path =~ s{/+$}{};
    $dir_path = '/' if $dir_path eq '';

    # SM286: a listing must show a section that lives in the private store, or
    # the manager reports an empty folder for content that is there.
    #
    # This handler builds its own path rather than going through validate_path,
    # which is why the cross-surface test caught it while read and write were
    # already right - a reminder that "wire the resolver" means finding the
    # places that resolve for themselves, not only the shared helper.
    #
    # The TREE is chosen first and the existing confinement then runs against
    # it unchanged, so SEC-2026-07 H3's boundary test and 04-F5's canonical-key
    # derivation keep their exact shape. A folder is wholly in one tree or the
    # other (the store's invariant), so there is nothing to merge.
    ( my $list_rel = $dir_path ) =~ s{\A/+}{};
    my $lroot = $DOCROOT;
    if ( length $list_rel ) {
        my ( undef, $where )
            = Lazysite::Private::resolve( $DOCROOT, $list_rel );
        $lroot = Lazysite::Private::private_root($DOCROOT)
            if $where eq 'private';
    }

    my $fs_path = "$lroot$dir_path";
    my $real    = realpath($fs_path);
    return { ok => 0, error => "Invalid path" }
        unless $real
        && ( $real eq $lroot || index( $real, "$lroot/" ) == 0 )    # SEC-2026-07 (H3)
        && -d $real;

    # SM268 04-F5: this was the one file handler with no blocklist, and the
    # character strip above PRESERVES `..`. Two consequences, both disclosure.
    #
    # A confined partner spelled `..` through its own scope prefix - the scope
    # gates test the raw request string, so `/content/clientA/../clientB` passed
    # and then resolved elsewhere. And `lazysite/auth` was listable by any
    # manage_content grant, which is reconnaissance on the auth tree. Worse than
    # a plain listing: every entry carries the ACL owner, the read and write
    # user lists, and any live lock holder, so it is a username roster keyed to
    # files.
    #
    # Confine on the CANONICAL path, never the request spelling: $real has the
    # `..` resolved, so deriving the docroot-relative key from it is what closes
    # the traversal rather than another string test.
    my $canon = $real eq $lroot ? q{} : substr( $real, length($lroot) + 1 );
    if ( length $canon ) {
        return { ok => 0, error => 'Path is blocked', kind => 'blocked' }
            if is_blocked_path($canon);
        return { ok => 0, error => 'Path is blocked by config', kind => 'blocked-config' }
            if is_blocked_config($canon);
    }
    # The listing reports the canonical location, so a `..` spelling cannot be
    # used to make the response describe a directory by a name it does not have.
    $dir_path = length $canon ? "/$canon" : '/';

    my @entries;
    my $acls = load_acls();    # SM074: owner display, read once per listing

    # SM286: a directory's CHILDREN may be split across the two trees even
    # though no single path is in both. The root is the ordinary case: a gated
    # top-level section lives in the private store while its siblings do not,
    # and listing one tree would make that section vanish from the file browser
    # entirely - which is how an operator loses track of content they protected.
    #
    # So the names are unioned. They cannot collide under the store's invariant;
    # where they do, that is the stray-public fault and the private copy wins,
    # for the same fail-safe reason resolution does.
    my %child;    # name => absolute path in whichever tree holds it
    for my $pair ( [ $real, 0 ], [ _sibling_dir( $real, $lroot, $canon ), 1 ] ) {
        my ( $dir, $is_other ) = @$pair;
        next unless defined $dir && -d $dir;
        opendir my $dh, $dir or next;
        for my $name ( readdir $dh ) {
            next if $name =~ /^\./;
            # First writer wins unless the private tree is the second read, in
            # which case it overrides - private is the governed copy.
            $child{$name} = "$dir/$name"
                if !exists $child{$name} || ( $is_other && $lroot eq $DOCROOT );
        }
        closedir $dh;
    }
    return { ok => 0, error => "Cannot read directory" }
        unless %child || -d $real;

    for my $name ( sort keys %child ) {
        my $full = $child{$name};
        my $rel  = $dir_path eq '/' ? "/$name" : "$dir_path/$name";
        # SM268 04-F5: and per entry, so a listable directory cannot advertise a
        # blocklisted file inside it.
        ( my $entry_key = $rel ) =~ s{^/}{};
        next
            if ( is_blocked_path($entry_key) || is_blocked_config($entry_key) )
            && !Lazysite::Manager::Common::path_leads_to_carveout($entry_key);
        my @st     = stat($full);
        my $is_dir = -d $full ? 1 : 0;
        my $entry  = {
            name  => $name,
            path  => $rel,
            type  => $is_dir ? 'dir' : 'file',
            size  => $is_dir ? 0     : ( $st[7] // 0 ),
            mtime => $st[9] // 0,
        };

        # SM286: which tree this entry lives in.
        #
        # Protected content is no longer in the document root, and an operator
        # looking at a listing has no other way to tell - the row looks
        # identical either way. Without this, "is this page actually protected?"
        # can only be answered by reading the ACL and trusting that the move
        # happened, which is the assumption every defect in this programme has
        # been made of.
        #
        # A LABEL, never a path. The standing rule is that filesystem paths are
        # never exposed through any surface, and the store's location is a
        # filesystem fact; 'private' tells the operator what they need to act on
        # and discloses nothing about the layout of the host.
        my $priv_root = Lazysite::Private::private_root($DOCROOT);
        $entry->{store} =
            ( defined $priv_root
                && ( $full eq $priv_root || index( $full, "$priv_root/" ) == 0 ) )
            ? 'private'
            : 'public';
        # SM019b: surface emptiness so the client knows whether a
        # dir row should get a delete-selection checkbox. The check
        # matches action_delete's rmdir semantics: any non-dot
        # entry (including hidden files) counts as content. We
        # only count, never stat, so the cost scales with the
        # directory size, not tree depth.
        if ($is_dir) {
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
                    $entry->{owner} = $a->{owner} if defined $a->{owner};
                    $entry->{read}  = $a->{read}  if ref $a->{read} eq 'ARRAY';
                    $entry->{write} = $a->{write} if ref $a->{write} eq 'ARRAY';
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

    my $lock_info = _get_lock_info($rel_path);

    return {
        ok      => 1,
        path    => $rel_path,
        content => $content,
        mtime   => ( stat $full )[9],
        lock    => $lock_info,
    };
}

# SM240: write BYTES. action_save opens '>:utf8' and is text-only, so an MCP-only
# agent could not place a single non-text byte on a site it otherwise had full
# manage_content over - no webfont, no photograph, no favicon.ico. That gap is
# why MCP-built sites import fonts from a CDN, hotlink photography, and never
# have a favicon: each is a rule the agent was given and could not follow.
#
# Same gates as action_save, in the same order, deliberately: validate_path, the
# blocked-path check (which also enforces the DANGEROUS_RE extension blocklist),
# the configurable blocked-extension list, the live-lock check and the per-file
# ACL. Nothing here is a new privilege - it is the same privilege on a file type
# the channel could not express. The two text-only steps are skipped because they
# cannot apply: raw_html_page_refusal parses front matter, and alias indexing
# reads Markdown.
sub action_save_binary {
    my ( $rel_path, $username, $bytes ) = @_;

    my $result = validate_path($rel_path);
    return $result unless $result->{ok};

    return { ok => 0, error => "Path is blocked", kind => 'blocked' }
        if is_blocked_path( $result->{rel} );
    # check_extensions => 1: the operator's configurable blocked list applies to
    # an upload, exactly as it does to the multipart upload path.
    return { ok => 0, error => "Path is blocked by config", kind => 'blocked-config' }
        if is_blocked_config( $result->{rel}, 1 );

    my $limits = load_upload_limits();
    my $max    = $limits->{max_bytes} // ( 10 * 1024 * 1024 );
    if ( length($bytes) > $max ) {
        return { ok => 0, kind => 'too-large',
            error => sprintf(
                'File is %d bytes; this site accepts at most %d (%.1f MB). '
                    . 'Raise manager_upload_max_mb to change it.',
                length($bytes), $max, $max / ( 1024 * 1024 ) ) };
    }

    my $full    = $result->{full};
    my $existed = -f $full;

    my $lock_key = $rel_path;
    $lock_key =~ s{/}{:}g;
    my $lrec = _read_lock_record("$LOCK_DIR/$lock_key.lock");
    if ( _lock_fresh($lrec)
        && ( $lrec->{origin} eq 'dav' || ( $lrec->{user} // '' ) ne $username ) )
    {
        return { ok => 0, locked => 1,
            error => "File is locked by " . ( $lrec->{user} // 'another client' ) };
    }

    if ( my $d = _acl_denied( $result->{rel}, 'write', $username ) ) { return $d }

    my $dir = dirname($full);
    make_path($dir) unless -d $dir;

    my $tmp = "$full.$$.tmp";
    open my $fh, '>', $tmp or return { ok => 0, error => "Cannot write file: $!" };
    binmode $fh;
    unless ( print {$fh} $bytes ) {
        my $e = "$!";
        close $fh;
        unlink $tmp;
        return { ok => 0, error => "Write failed: $e" };
    }
    unless ( close $fh ) {
        my $e = "$!";
        unlink $tmp;
        return { ok => 0, error => "Close failed: $e" };
    }
    if     ( my @st = stat $full ) { chmod $st[2] & 07777, $tmp }
    unless ( rename $tmp, $full ) {
        my $e = "$!";
        unlink $tmp;
        return { ok => 0, error => "Rename failed: $e" };
    }

    unlink "$LOCK_DIR/$lock_key.lock" if -f "$LOCK_DIR/$lock_key.lock";
    log_event( 'INFO', $action, 'binary file saved',
        path => $rel_path, bytes => length($bytes), user => $auth_user );

    _git_commit( $username,
        ( $existed ? 'edit ' : 'create ' ) . $result->{rel}, $result->{rel} );

    my @st = stat $full;
    return {
        ok      => 1,
        path    => $result->{rel},
        bytes   => length($bytes),
        created => ( $existed ? JSON::PP::false : JSON::PP::true ),
        mtime   => ( $st[9] // 0 ),
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
    my $lrec      = _read_lock_record($lock_file);
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

    log_event( 'INFO', $action, 'file saved', path => $rel_path, user => $auth_user );

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
#
# SM251: and it must clear them for EVERY content root, not just the docroot.
# update_registries (SM110/SM151) writes a domain's registries INTO that domain's
# content root - that is the whole point of per-domain registries - while this
# only ever unlinked "$DOCROOT/$out". So on a multi-domain instance the
# invalidation missed the file it was aiming at: deleting a page under a domain's
# content root left THAT domain's sitemap and llms.txt untouched, and the entry
# survived until the TTL expired. The reported symptom ("a deleted page stays in
# the sitemap") was read as slow convergence; it was the refresh aiming at the
# wrong file.
#
# Over-invalidating is the safe direction here: a registry that is regenerated
# unnecessarily costs one rebuild on the next request, whereas one that is missed
# serves a page that no longer exists.
sub _registry_roots {
    my %seen  = ( $DOCROOT => 1 );
    my @roots = ($DOCROOT);

    # Reuse the domain parser rather than re-reading the conf here - SM255's
    # lesson about one file with several readers applies to parsing too.
    require Lazysite::Manager::Domains;
    no warnings 'once';
    local $Lazysite::Manager::Domains::DOCROOT = $DOCROOT;
    my $r = eval { Lazysite::Manager::Domains::domains_list() };
    return @roots unless ref $r eq 'HASH' && $r->{ok};

    for my $d ( @{ $r->{domains} || [] } ) {
        my $cr = $d->{content_root} // '';
        next unless length $cr;
        $cr =~ s{^/+|/+$}{}g;
        next if !length $cr || $cr =~ m{(?:^|/)\.\.(?:/|$)};
        my $full = "$DOCROOT/$cr";
        next if $seen{$full}++;
        push @roots, $full if -d $full;
    }
    return @roots;
}

# SM264: the public entry points. The invalidator and its root list are called
# from outside this module now (the regenerate_registries MCP tool), and reaching
# into a private sub from another file is exactly the coupling the leading
# underscore is there to discourage.
sub invalidate_registries { return _invalidate_registries() }

# SM301: the control-API twin of MCP's regenerate_registries (SM264). One
# implementation for both channels, so the two cannot answer differently - the
# thing t/lint/23 exists to prevent.
#
# Clears every content root, not just the docroot's (SM251), so a multi-domain
# instance is handled in one call.
sub action_regenerate_registries {
    my $docroot = $DOCROOT;
    my @roots   = _registry_roots();
    _invalidate_registries();
    my @rel = map {
        my $r = $_;
        $r =~ s{^\Q$docroot\E/*}{};
        length $r ? "/$r" : '/';
    } @roots;
    return {
        ok            => 1,
        cleared_roots => \@rel,
        note          => 'The registries are cleared and rebuild on the next '
            . 'request for one. Fetch /sitemap.xml (or the registry you care '
            . 'about) to force it, then verify.',
    };
}
sub registry_roots { return _registry_roots() }

sub _invalidate_registries {
    my $rdir = _lz() . "/templates/registries";
    return unless -d $rdir;
    opendir my $dh, $rdir or return;
    my @tt = grep { /\.tt$/ } readdir $dh;
    closedir $dh;
    for my $root ( _registry_roots() ) {
        for my $t (@tt) {
            ( my $out = $t ) =~ s/\.tt$//;
            unlink "$root/$out" if -f "$root/$out";
        }
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
        if (@entries) {
            return { ok => 0, error => "Directory is not empty" };
        }
        rmdir $full
            or return { ok => 0, error => "Cannot remove directory: $!" };
        log_event( 'INFO', $action, 'directory deleted',
            path => $rel_path, user => $auth_user );
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

    log_event( 'INFO', $action, 'file deleted', path => $rel_path, user => $auth_user );
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

    log_event( 'INFO', $action, 'directory created',
        path => $rel_path, user => $auth_user );

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
    return { ok => 0, error => "Source not found" } unless -e $src_full;
    return { ok => 0, error => "Target already exists" } if -e $dst_full;

    # Refuse a live foreign lock on the source (mirror action_save).
    my $lock_key = $src_rel;
    $lock_key =~ s{/}{:}g;
    my $lock_file = "$LOCK_DIR/$lock_key.lock";
    my $lrec      = _read_lock_record($lock_file);
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
    my @store_warnings;
    if ( exists $acls->{$sk} ) {
        $acls->{$dk} = delete $acls->{$sk};
        save_acls($acls);

        # SM286: the ACL follows the path, so the CONTENT has to follow the ACL.
        #
        # The rename above puts the bytes wherever the destination resolved,
        # which for a new path under a public folder is the docroot - so moving
        # a protected page would carry its rule to the new key while leaving the
        # content public. The rule would still be enforced by the engine and
        # ignored by any front end serving the file directly: SM283 exactly,
        # reintroduced by a rename.
        #
        # Re-syncing against the NEW key settles it in one place, whichever
        # direction the move went, and covers un-protecting by moving out of a
        # gated folder just as well.
        push @store_warnings, _sync_private_store( $dk, $acls->{$dk} );
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
    return { ok => 1, from => $s->{rel}, to => $d->{rel},
        ( @store_warnings ? ( warnings => \@store_warnings ) : () ) };
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
            user    => $username,     at    => time(), origin => 'manager',
            timeout => $LOCK_TIMEOUT, token => undef,  owner  => '',
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
    my $rec       = _read_lock_record($lock_file);
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

# SM287: which spellings mean "the whole site", and which are refused.
#
# The root was the one scope that could not be expressed: a root entry was inert
# under every spelling, so a wholly-private site had to enumerate its top-level
# folders - a workaround that fails OPEN as content grows, because a file added
# at the root next month is public with nothing to say so.
#
# '/', '' and '.' all plainly mean the site, so they NORMALISE to the canonical
# '/'. Glob spellings are REFUSED with a message naming the canonical form: the
# store has no glob syntax anywhere else, so accepting '*' would imply a
# matching language that does not exist, and quietly storing it is how this
# started - the old behaviour accepted every one of these and gated nothing.
my %ROOT_SPELLING = map { $_ => 1 } ( '/', '',   '.',  './' );
my %ROOT_GLOB     = map { $_ => 1 } ( '*', '/*', '**', '/**', './*' );

sub _acl_root_key {
    my ($raw) = @_;
    my $t = defined $raw ? $raw : '';
    $t =~ s/\A\s+|\s+\z//g;
    return 'root' if $ROOT_SPELLING{$t};
    return 'glob' if $ROOT_GLOB{$t};
    return '';
}

# SM286: does this ACL record keep the PUBLIC out?
#
# Read semantics come straight from Acl::_acl_allows, and they are the reason the
# question is about `read` alone: an absent or EMPTY read list allows everyone
# ("return 1 unless ref $list eq 'ARRAY' && @$list"). So an entry that names only
# a write list restricts editing and publishes exactly as before - moving that
# content out of the docroot would take a public page offline to express a rule
# about who may edit it.
#
# `draft` counts. A draft section 404s to the public, which is a stronger
# statement than gating, not a weaker one.
sub _acl_gates_public {
    my ($rec) = @_;
    return 0 unless ref $rec eq 'HASH';
    return 1 if $rec->{draft};
    my $read = $rec->{read};
    return ( ref $read eq 'ARRAY' && @$read ) ? 1 : 0;
}

# SM286: put the bytes where the rule says they belong.
#
# This is the point of the whole work item. Until now a gate was a rule the
# ENGINE honoured and every front end had to be told about separately; three
# releases running, a front end was not told, or was told and answered first
# (SM248, SM268 H17, SM283). Moving the content out of the document root makes
# the rule structural: there is nothing for a front end to serve and nothing for
# it to get wrong.
#
# Returns a list of warnings. Deliberately warnings and NOT a failure:
#
#   - A gate whose move failed is still a gate. The ACL is stored, the engine
#     honours it, and the exposure is exactly what it was before this existed.
#     Refusing the ACL because the filesystem misbehaved would leave the content
#     ungoverned, which is worse than governed-but-not-moved.
#
#   - Ungating whose move-out failed leaves content in the store, where the
#     engine still resolves and serves it. Slower, but not wrong, and not a
#     disclosure in either direction.
#
# What must never happen is silence, because either state is invisible from the
# outside: the operator sees the permission they asked for either way.
sub _sync_private_store {
    my ( $rel, $rec ) = @_;
    my @warnings;

    # The site-wide rule cannot be expressed as a move. The docroot cannot be
    # moved into its own sibling - it would have to BECOME the store - so a '/'
    # entry stays enforced by the engine alone, exactly as SM287 built it.
    #
    # Said out loud rather than skipped quietly: this is the one scope where the
    # SM283 class of exposure is still reachable if a front end serves files
    # from the docroot without asking the engine, and an operator choosing to
    # make a whole site private deserves to know that.
    if ( $rel eq '/' ) {
        push @warnings,
            'a site-wide rule is enforced by the engine and does not move any '
            . 'files. Every other path moves out of the document root when it '
            . 'is protected; the site root cannot, because it IS the document '
            . 'root. If a front end serves this site directly, protect '
            . 'individual folders as well.';
        return @warnings;
    }

    # Sections are stored with a trailing slash; the mover takes a path.
    ( my $path = $rel ) =~ s{/+\z}{};
    return @warnings unless length $path;

    require Lazysite::Private;
    my $gates = _acl_gates_public($rec);

    my ( $ok, $err ) =
        $gates
        ? Lazysite::Private::move_in( $DOCROOT, $path )
        : Lazysite::Private::move_out( $DOCROOT, $path );

    # SM286: the companions a page drags along. A move that takes the .md and
    # leaves these behind protects the page and publishes its substance.
    #
    #   .brief  - the authored "why" sidecar. Content, and about the very page
    #             being protected, so it follows it in both directions.
    #
    #   .html   - the render cache from BEFORE the gate existed. It is a
    #             complete public copy of the page, sitting in the docroot,
    #             which is precisely what SM283 was: a front end serving a file
    #             beside a gated page without asking the engine. Deleted rather
    #             than moved, because it is derived - the next render writes it
    #             into the store (the processor's _private_twin) - and deleting a
    #             regenerable file cannot lose anything.
    if ($ok) {
        my $brief = "$path.brief";
        my ( $bok, $berr ) =
            $gates
            ? Lazysite::Private::move_in( $DOCROOT, $brief )
            : Lazysite::Private::move_out( $DOCROOT, $brief );
        if ( !$bok ) {
            push @warnings,
                "the notes beside this page could not be moved with it"
                . ( defined $berr && length $berr ? ": $berr" : '' ) . '.';
        }

        if ( $gates && $path =~ /\.md\z/ ) {
            ( my $cache = $path ) =~ s/\.md\z/.html/;
            if ( -f "$DOCROOT/$cache" ) {
                unlink "$DOCROOT/$cache"
                    or push @warnings,
                    'a previously rendered copy of this page is still in the '
                    . 'document root and could not be removed - it is a public '
                    . 'copy of the content just protected.';
            }
        }
    }

    if ( !$ok ) {
        my $what = $gates ? 'out of' : 'back into';
        push @warnings,
            "the permission was saved, but the content could not be moved "
            . "$what the document root"
            . ( defined $err && length $err ? ": $err" : '' )
            . '. The rule is in force - the engine honours it - but the files '
            . 'are still where they were, so a front end that serves them '
            . 'without asking the engine would not be covered.';
        log_event( 'ERROR', 'acl-set', 'private store move failed',
            path  => $rel, direction => ( $gates ? 'in' : 'out' ),
            error => ( $err // '' ) );
    }
    return @warnings;
}

sub action_acl_set {
    my ( $rel_path, $user, $read, $write, $owner_req, $draft ) = @_;

    my $rootish = _acl_root_key($rel_path);
    if ( $rootish eq 'glob' ) {
        return { ok => 0,
            error => "Wildcards are not a path here. To govern the whole site, "
                . "including every folder beneath it, use \"/\" as the path." };
    }

    my ( $r, $rel );
    if ( $rootish eq 'root' ) {
        $rel = '/';    # canonical, and the only key the writer ever produces
    }
    else {
        $r = validate_path($rel_path);
        return $r unless $r->{ok};
        $rel = _acl_norm( $r->{rel} );
        return { ok => 0, error => "Path is blocked", kind => 'blocked' }
            if is_blocked_path($rel) || is_blocked_config($rel);
    }

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
        :                                                                 $user;
    my %rec = ( owner => $owner );
    my $rl  = _to_list($read);  $rec{read}  = $rl if defined $rl;
    my $wl  = _to_list($write); $rec{write} = $wl if defined $wl;

    # SM278: `draft` is a FIRST-CLASS field here, not a passenger. SM181 shipped
    # the engine half (a draft prefix 404s to the public and is absent from
    # every listing) but this writer built its record from owner/read/write
    # alone, so a caller setting draft got ok:1 and a stored ACL without it -
    # a security setting that reported success and did nothing. Absent means
    # "leave as it is" on an existing entry, so a caller updating only the read
    # list does not silently publish a draft section; a false value clears it.
    if ( defined $draft ) {
        # SM291: an unrecognised value is REFUSED, not read as false.
        #
        # This coercion used to end in `: 0` - anything it did not recognise
        # cleared the flag and published the section, while reporting ok:1. A
        # site agent measured it: draft => "yes-please" turned a folder that was
        # 404ing to the public into one that bounces to login. Omitting draft is
        # safe and documented as safe, so the malformed spelling was the
        # destructive one, which is the wrong way round for a typo.
        #
        # Refused HERE rather than only in the MCP validator because every
        # surface funnels through this one writer (SM267), and the control API
        # hands it form-encoded strings that no JSON schema ever sees.
        my $on;
        if    ( ref $draft eq 'JSON::PP::Boolean' ) { $on = $draft ? 1 : 0 }
        elsif ( !ref $draft && $draft =~ /\A(?:1|true|yes|on)\z/i )   { $on = 1 }
        elsif ( !ref $draft && $draft =~ /\A(?:0|false|no|off|)\z/i ) { $on = 0 }
        else {
            return { ok => 0,
                error => "The 'draft' setting must be true or false. It was "
                    . "neither, so nothing was changed - an unrecognised value "
                    . "used to clear the flag and publish the section." };
        }
        $rec{draft} = JSON::PP::true() if $on;
    }
    elsif ( $existing && $existing->{draft} ) {
        $rec{draft} = JSON::PP::true();
    }
    $acls->{$rel} = \%rec;
    save_acls($acls) or return { ok => 0, error => "Cannot write the ACL store" };
    log_event( 'INFO', 'acl-set', 'acl set', path => $rel, user => $auth_user );

    # SM243/SM224: an @group entry can NEVER match a token, MCP or WebDAV
    # partner. Those channels deliberately carry no groups (mcp.pl sets
    # user_groups = () and calls it "the safe default", which it is), so a rule
    # granting @editors applies to cookie users and silently to nobody on a
    # remote channel. An agent setting this has no way to discover that its rule
    # is inert, so say it here rather than let it be found the hard way.
    my @warnings;

    # SM286: and now move the bytes to match the rule. AFTER the store is
    # written, deliberately - if the process dies between the two, the surviving
    # state is "rule recorded, content not yet moved", which the engine already
    # enforces correctly. The other order would leave content out of the docroot
    # with nothing recording why.
    push @warnings, _sync_private_store( $rel, \%rec );

    my @grp = grep { defined && /\A\@/ } ( @{ $rec{read} || [] }, @{ $rec{write} || [] } );
    if (@grp) {
        push @warnings,
            'this ACL names ' . join( ', ', @grp ) . '. A @group entry matches '
            . 'only a signed-in manager user: token, MCP and WebDAV partners carry '
            . 'no groups, so the rule does NOT apply to them. Name those accounts '
            . 'individually if they need access.';
    }

    # $rel, not $r->{rel}: on the root branch $r is never assigned, so this
    # reported path => undef for the one rule that covers the whole site.
    return { ok => 1, path => $rel, acl => \%rec,
        ( @warnings ? ( warnings => \@warnings ) : () ) };
}

# SM267 (carved out of SM181): what is held back right now.
#
# SM181 shipped both policies - a folder ACL entry gates a section, `draft`
# hides it outright - and both are reached by hand-editing acls.json. So the
# product could hold a section back and had no screen that said which sections
# were held back, which is the failure mode of a good hiding mechanism: a
# section left in draft after launch stays invisible and nothing says so.
#
# Read-only, and deliberately SECTIONS only (a key ending in /). Per-file ACLs
# are the Files page's business and answer a different question; mixing them
# here would bury the four entries that matter among hundreds that do not.
sub action_protected_sections {
    my ( $user, $scopes ) = @_;
    my $acls = load_acls();
    my @out;

    for my $key ( sort keys %$acls ) {
        my $a = $acls->{$key} or next;
        next unless ref $a eq 'HASH';

        # SM292: a section is a key that names a FOLDER - which is not the same
        # as a key ending in a slash.
        #
        # This filtered on the trailing slash alone, and validate_path derives
        # `rel` from realpath, which has no trailing slash. So every rule an
        # operator created through the manager or MCP was stored as `members`
        # and this panel skipped all of them. It listed only hand-edited keys.
        #
        # That is precisely the failure SM267 built this screen to prevent: "the
        # product could hold a section back and had no screen that said which
        # sections were held back". It had the screen, and the screen was empty
        # for everyone who used the supported route. Its tests wrote acls.json
        # by hand with trailing slashes, so they agreed with each other and
        # never with the writer.
        my $is_section = ( $key =~ m{/\z} ) ? 1 : 0;
        ( my $bare = $key ) =~ s{/+\z}{};
        if ( !$is_section && length $bare ) {
            my ( $abs, $where ) = Lazysite::Private::resolve( $DOCROOT, $bare );
            $is_section = 1 if $where && -d $abs;
        }
        next unless $is_section;

        # A scoped manager sees only sections inside their own scope. Listing a
        # section they cannot reach would disclose the existence of content the
        # scope exists to keep from them - the same reasoning that makes a draft
        # section 404 rather than 403.
        next
            if ref $scopes eq 'ARRAY'
            && @$scopes
            && outside_all_scopes( $scopes, $key );

        my ( $pages, $assets ) = ( 0, 0 );

        # SM286: count where the content actually IS. A protected section now
        # lives outside the docroot, so counting only the docroot would report
        # every gated section as 0 pages / 0 assets / exists:false - "held back
        # and empty" - at the exact moment protecting it succeeded.
        my ( $dir, $where ) = Lazysite::Private::resolve( $DOCROOT, $bare );
        $dir = "$DOCROOT/$key" unless $where;
        if ( -d $dir ) {
            File::Find::find(
                { no_chdir => 1,
                    wanted => sub {
                        return unless -f $File::Find::name;
                        $File::Find::name =~ /\.md\z/ ? $pages++ : $assets++;
                    },
                },
                $dir
            );
        }

        push @out, {
            prefix => $key,
            # SM287: the site-wide rule is listed here because it IS a protected
            # section - the widest one - but flagged so the panel can say so.
            # Rendered as one folder row among the others it would read as a
            # folder called "/", which understates a rule covering everything.
            site_wide => ( $key eq '/' ? 1 : 0 ),
            # Two DIFFERENT acts, named differently, because publishing a draft
            # section and un-gating a private one are not the same decision.
            policy => ( $a->{draft} ? 'draft' : 'gated' ),
            owner  => $a->{owner} // '',
            read   => $a->{read}  || [],
            write  => $a->{write} || [],
            pages  => $pages,
            assets => $assets,
            exists => ( -d $dir ) ? 1 : 0,
        };
    }
    return { ok => 1, sections => \@out };
}

sub action_acl_remove {
    my ( $rel_path, $user ) = @_;

    # SM287: remove has to understand the same spellings as set, or a site-wide
    # rule can be created and not taken off - which is a worse trap than not
    # being able to create one. Found by the writer test, not by review.
    #
    # A hand-edited store may hold '' or '.'; the writer only produces '/', but
    # removing the root must clear whichever of them is actually there, or the
    # operator is left with a rule the UI says is gone.
    my $rootish = _acl_root_key($rel_path);
    if ( $rootish eq 'glob' ) {
        return { ok => 0,
            error => "Wildcards are not a path here. To remove the rule that "
                . "governs the whole site, use \"/\" as the path." };
    }
    if ( $rootish eq 'root' ) {
        my $acls = load_acls();
        my ($present) = grep { exists $acls->{$_} } ( '/', '', '.', './' );
        return { ok => 1, path => '/', removed => 0 } unless defined $present;
        my $existing = $acls->{$present};
        unless ( _is_operator()
            || ( $existing->{owner} // '' ) eq ( $user // '' ) )
        {
            return { ok => 0, error => "Only the owner may remove permissions" };
        }
        delete $acls->{$_} for ( '/', '', '.', './' );
        save_acls($acls)
            or return { ok => 0, error => "Cannot write the ACL store" };
        log_event( 'INFO', 'acl-remove', 'site-wide acl removed',
            path => '/', user => $auth_user );
        return { ok => 1, path => '/', removed => 1 };
    }

    my $r = validate_path($rel_path);
    return $r unless $r->{ok};
    my $rel = _acl_norm( $r->{rel} );
    return { ok => 0, error => "Path is blocked", kind => 'blocked' }
        if is_blocked_path($rel) || is_blocked_config($rel);
    my $acls     = load_acls();
    my $existing = $acls->{$rel};
    return { ok => 1, path => $r->{rel}, removed => 0 } unless $existing;
    unless ( _is_operator() || ( $existing->{owner} // '' ) eq ( $user // '' ) ) {
        return { ok => 0, error => "Only the owner may remove permissions" };
    }
    delete $acls->{$rel};
    save_acls($acls) or return { ok => 0, error => "Cannot write the ACL store" };
    log_event( 'INFO', 'acl-remove', 'acl removed', path => $rel, user => $auth_user );

    # SM286: the rule is gone, so the content comes back into the document root.
    # Passing undef is the whole statement - no record means nothing gates it.
    #
    # Content left in the store would still be SERVED (the resolver looks there
    # first), so this is not a disclosure risk in either direction; it would just
    # be content sitting somewhere its permissions no longer explain, which is
    # how a store drifts out of step with the tree it shadows.
    my @warnings = _sync_private_store( $rel, undef );

    return { ok => 1, path => $r->{rel}, removed => 1,
        ( @warnings ? ( warnings => \@warnings ) : () ) };
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
    # A real health probe, not just the conf flag: verdict catches the state where
    # the config says enabled but the repo is missing/unusable (an interrupted
    # enable), so a caller can tell "actually in good shape" from "looks enabled".
    my $h = Lazysite::Git::health($DOCROOT);
    return {
        ok          => 1,
        verdict     => $h->{verdict},
        healthy     => _git_bool( $h->{healthy} ),
        enabled     => _git_bool( $h->{verdict} eq 'ok' || $h->{verdict} eq 'degraded' ),
        initialised => _git_bool( $h->{initialised} ),
        git_available    => _git_bool( $h->{git_available} ),
        recording_failed => _git_bool( $h->{recording_failed} ),
        lock_present     => _git_bool( $h->{lock_present} ),
        commits          => $h->{commits},
    };
}

# Per-file timeline. Disabled / no repo = an empty list, never an error.
sub action_git_history {
    my ( $rel_path, $username, $limit ) = @_;
    my $r = _git_target( $rel_path, $username );
    return $r unless $r->{ok};
    require Lazysite::Git;
    my $enabled = Lazysite::Git::enabled($DOCROOT);

    # SM286: content in the private store is NOT under version control, and this
    # has to be said rather than shown as an empty list.
    #
    # The history work tree is the docroot; the store is its sibling, so a
    # protected file's history stops at the commit that removed it from the
    # public tree. That is deliberate, not an oversight - Git.pm's own header
    # makes the exclude list a security boundary on the grounds that a history
    # which may be pushed to a remote must never carry personal data, and
    # members-only content is precisely that.
    #
    # What would be wrong is the REPORT. `enabled: 1` with `versions: []` reads
    # as "this file has no history", when the truth is "history does not cover
    # this file". SM261 was this same failure on this same response: an empty
    # result and a wrong answer are indistinguishable to the caller, so the
    # failure mode is a confident wrong conclusion rather than an error.
    my $in_store = ( ( $r->{store} // '' ) eq 'private' ) ? 1 : 0;

    return {
        ok      => 1,
        path    => $r->{rel},
        enabled => _git_bool($enabled),

        # SM261: `versions`, not `entries`. A list response names its CONTENTS,
        # so a caller can predict the key from the tool. A reporting agent read
        # this as returning zero versions and began writing it up as a defect -
        # it was returning two `entries` perfectly well. A wrong key and an
        # empty result are indistinguishable, so the failure mode is not an
        # error but a confident wrong conclusion.
        versions => ( $enabled && !$in_store
            ? Lazysite::Git::file_log( $DOCROOT, $r->{rel}, $limit )
            : [] ),

        versioned => _git_bool( $enabled && !$in_store ),
        ( $in_store
            ? ( notice => 'This content is protected, and protected content is'
                    . ' kept out of the version history - a history can be'
                    . ' pushed to a remote, and this content is not meant to'
                    . ' travel. Its history runs up to the point it was'
                    . ' protected.' )
            : ()
        ),
    };
}

# SM199: the file-list / table-of-contents over the history - every path under
# version control with per-file revision stats (count, first/latest date, last
# author) plus a site-level summary (total files, total revisions). A read-only,
# site-level view (the complement of the per-file action_git_history); gated on
# manage_content at the dispatch layer exactly like git-history. Disabled / no
# repo = enabled:false with empty rows, never an error. Reuses the lineage-aware
# engine (SM175), so counts follow renames and never leak across a recreate.
sub action_git_history_summary {
    require Lazysite::Git;
    my $enabled = Lazysite::Git::enabled($DOCROOT);
    my $s =
        $enabled
        ? Lazysite::Git::files_summary($DOCROOT)
        : { files => [], summary => { files => 0, revisions => 0 } };
    return {
        ok      => 1,
        enabled => _git_bool($enabled),
        files   => $s->{files},
        summary => $s->{summary},
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
