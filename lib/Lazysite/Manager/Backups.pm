package Lazysite::Manager::Backups;

# SM084: docroot content backups - tarball snapshots stored under
# lazysite/backups/ (infrastructure, never served), surfaced in the manager so an
# operator can snapshot before a risky change and download/restore the original.
# A pre-install snapshot is taken by the Hestia hook; manual ones come from here.

use strict;
use warnings;
use POSIX          qw(strftime);
use File::Path     qw(make_path);
use File::Find     ();
use Fcntl          qw(O_WRONLY O_CREAT O_EXCL);
use Errno          ();
use Lazysite::Util qw(log_event);
use Exporter       qw(import);
our @EXPORT_OK = qw(action_backup_list action_backup_create action_backup_download
    action_backup_restore action_backup_delete);

our $DOCROOT      = '';
our $LAZYSITE_DIR = '';
our $auth_user    = '';

sub _dir { return "$LAZYSITE_DIR/backups" }

# A backup name is a single tarball basename - strict, no path traversal.
sub _valid_name { return $_[0] =~ /\A[A-Za-z0-9._-]+\.tar\.gz\z/ && $_[0] !~ /[.][.]/ }

sub action_backup_list {
    my $dir = _dir();
    my @out;
    if ( opendir my $dh, $dir ) {
        for my $f ( readdir $dh ) {
            next unless $f =~ /\.tar\.gz\z/ && -f "$dir/$f";
            my @st = stat "$dir/$f";
            # Kind from the (now lazysite-prefixed) name; `site` is a per-domain
            # site package (SM158) that also lives here.
            my ($kind) = $f =~ /\A(?:lazysite-)?(preinstall|prerestore|manual|full|site)-/;
            $kind //= 'manual';
            my $scope = $kind eq 'full' ? 'full' : $kind eq 'site' ? 'site' : 'content';
            push @out, { name => $f, size => $st[7] // 0, mtime => $st[9] // 0,
                kind => $kind, scope => $scope };
        }
        closedir $dh;
    }
    @out = sort { $b->{mtime} <=> $a->{mtime} } @out;
    return { ok => 1, backups => \@out };
}

# Claim an unused artefact name by creating it O_EXCL, and return
# (path, basename) - or () if 50 suffixes were all taken, or the create failed
# for a reason other than "exists" (a full or unwritable backups directory, say,
# which must not be reported as a successful snapshot).
#
# tar then writes THROUGH the placeholder: it opens O_WRONLY|O_CREAT|O_TRUNC, so
# the inode we claimed is the one it fills.
sub _claim_name {
    my ( $dir, $kind ) = @_;
    my $stamp = strftime( '%Y%m%dT%H%M%SZ', gmtime );
    for my $n ( 1 .. 50 ) {
        my $name = "lazysite-$kind-$stamp" . ( $n > 1 ? "-$n" : q{} ) . '.tar.gz';
        my $path = "$dir/$name";
        if ( sysopen my $fh, $path, O_WRONLY | O_CREAT | O_EXCL, oct '640' ) {
            close $fh;
            return ( $path, $name );
        }
        next if $! == Errno::EEXIST();
        log_event( 'ERROR', 'backup-create', 'cannot create backup file',
            path => $path, error => "$!" );
        return ();
    }
    log_event( 'ERROR', 'backup-create', 'no free backup name in this second',
        dir => $dir );
    return ();
}

# SM268 03-F11: keep the artefact directory bounded.
#
# install.pl's apply_retention globs `lazysite-backup-*` - only the installer's
# own. Every manager artefact (manual, prerestore, full, site) was out of its
# reach, and nothing removed a prerestore snapshot EVER. Since SM183 made every
# surface snapshot before an apply, and action_backup_restore snapshots before
# every restore, each of which is a full copy of the docroot content, an agent
# looping site_apply fills the disk - and on a shared instance that takes every
# hosted site down and corrupts in-flight writes.
#
# Per KIND, because the kinds are not interchangeable: ten manual snapshots and
# ten prerestore snapshots are ten of each, and expiring an operator's deliberate
# snapshot because a plugin took twenty automatic ones would be the wrong
# trade. `backup_retention: 0` means unlimited, matching install.pl.
#
# Newest-first, and the newest of a kind is never removed: a retention rule that
# can empty the directory is a rule that deletes the snapshot taken thirty
# seconds ago because the limit was misread.
sub _retention_limit {
    my $conf    = "$LAZYSITE_DIR/lazysite.conf";
    my $default = 10;
    return $default unless -f $conf;
    open my $fh, '<:utf8', $conf or return $default;
    my $val = $default;
    while ( my $l = <$fh> ) {
        next unless $l =~ /^backup_retention\s*:\s*(\d+)\s*$/;
        $val = $1 + 0;
        last;
    }
    close $fh;
    return $val;
}

sub _apply_retention {
    my ($kind) = @_;
    my $keep = _retention_limit();
    return unless $keep > 0;

    my $dir = _dir();
    opendir my $dh, $dir or return;
    my @mine = grep { /\A(?:lazysite-)?\Q$kind\E-/ && /\.tar\.gz\z/ } readdir $dh;
    closedir $dh;
    return if @mine <= $keep;

    my @by_age = sort { ( stat "$dir/$b" )[9] <=> ( stat "$dir/$a" )[9] } @mine;
    for my $old ( @by_age[ $keep .. $#by_age ] ) {
        next unless unlink "$dir/$old";
        log_event( 'INFO', 'backup-retention', 'expired old snapshot',
            file => $old, kind => $kind, keep => $keep );
    }
    return;
}

# SM268 03-F11: and a way to remove one deliberately.
#
# The only delete in the API was site-backup-delete, confined to the
# lazysite-site- namespace, so a manual snapshot an operator no longer wanted -
# or a prerestore snapshot of a restore that went fine - could only be removed
# from the shell. Retention bounds the growth; this is for the operator who
# knows which one they want gone.
#
# The site- namespace is deliberately NOT reachable here: it has its own delete
# with its own scope confinement (a scoped partner must not remove another
# domain's package), and duplicating that check in a second place is how the two
# come to disagree.
sub action_backup_delete {
    my ($name) = @_;
    $name = '' unless defined $name;
    return { ok => 0, kind => 'invalid', error => 'Invalid backup name' }
        unless _valid_name($name);
    return { ok => 0, kind => 'invalid',
        error => 'A site package is removed with site-backup-delete, which '
            . 'applies the per-domain scope checks this action does not.' }
        if $name =~ /\A(?:lazysite-)?site-/;
    return { ok => 0, kind => 'invalid',
        error => 'Not a lazysite snapshot name' }
        unless $name =~ /\A(?:lazysite-)?(?:preinstall|prerestore|manual|full)-/;

    my $full = _dir() . "/$name";
    return { ok => 0, kind => 'not-found', error => 'Backup not found' } unless -f $full;

    unlink $full or return { ok => 0, error => "Could not delete the backup: $!" };
    log_event( 'INFO', 'backup-delete', 'snapshot removed',
        file => $name, user => $auth_user );
    return { ok => 1, name => $name };
}

sub action_backup_create {
    my ($kind) = @_;
    $kind = 'manual' unless defined $kind && $kind =~ /\A(manual|prerestore|full)\z/;
    my $dir = _dir();
    make_path($dir) unless -d $dir;
    # All backup artefacts carry the `lazysite-` namespace prefix so they are
    # unmistakably ours (and sort together): lazysite-<kind>-<UTCstamp>.tar.gz.
    #
    # SM268 03-F9: the name is claimed ATOMICALLY, and the stamp has one-second
    # resolution. Two snapshots in the same second - an apply's safety snapshot
    # and a concurrent backup-create or git-sync snapshot - produced the same
    # name, and both tar processes wrote the same inode. Every caller was told
    # ok => 1 and handed a name; all but one described someone else's tarball.
    # That is the worst failure mode this feature has, because the operator
    # believes they can roll back. A check-then-create (-e, then tar) does not
    # fix it either: the window is between the test and the write. O_EXCL is the
    # test and the claim in one syscall, so exactly one caller wins each name and
    # the losers take the next suffix.
    my ( $out, $name ) = _claim_name( $dir, $kind );
    return { ok => 0, error => 'Backup failed: could not claim a filename' }
        unless defined $out;

    # 'full' = the whole site including the lazysite/ infra (config, auth,
    # forms, nav, themes/layouts) - a portable snapshot for DR and for migrating a
    # site to another domain (restored by a system user via install.pl --restore
    # --domain; NOT self-service, because it carries the auth secrets). Only the
    # backups dir (don't nest) and regenerable caches/mirror are excluded.
    # Otherwise = content only, excluding the whole lazysite/ infra as before.
    my @excludes =
        $kind eq 'full'
        ? ( '--exclude=./lazysite/backups', '--exclude=./lazysite/cache',
        '--exclude=./lazysite-assets' )
        : ( '--exclude=./lazysite', '--exclude=./lazysite-assets' );

    my $rc = system( 'tar', 'czf', $out, '-C', $DOCROOT, @excludes, '.' );
    if ( $rc != 0 || !-f $out || -z $out ) {
        # Drop the placeholder we claimed, or a failed snapshot leaves a
        # zero-byte tarball in the listing that reads as a usable one.
        unlink $out;
        return { ok => 0, error => 'Backup failed' };
    }
    log_event( 'INFO', 'backup-create',
        ( $kind eq 'full' ? 'full system snapshot' : 'docroot snapshot' ),
        file => $name, user => $auth_user );
    # After the snapshot exists, never before: expiring an old one to make room
    # for a new one that then fails would lose both.
    _apply_retention($kind);

    my @st = stat $out;
    return { ok => 1, name => $name, size => $st[7] // 0, mtime => $st[9] // 0,
        scope => ( $kind eq 'full' ? 'full' : 'content' ) };
}

# SM084 (the open half, eight-dimension review D5): restore a snapshot. OVERLAY
# semantics, matching install.pl --restore: the tarball's files are written
# back over the docroot; files created since the snapshot are left in place.
# A prerestore safety snapshot is taken first, so the restore is itself
# reversible. Rendered caches for restored sources are dropped afterwards -
# the extracted files carry their ORIGINAL (older) mtimes, so without the
# clear the mtime cache check would keep serving the pre-restore pages.
sub action_backup_restore {
    my ($name) = @_;
    $name = '' unless defined $name;
    return { ok => 0, error => 'Invalid backup name' } unless _valid_name($name);

    # A full-system backup carries the auth secrets and overwrites config/accounts;
    # restoring it (especially onto a different domain) is a deliberate system-user
    # operation via install.pl --restore, not a self-service manager click.
    return { ok => 0, error => 'A full-system backup is restored by a system user '
            . 'with install.pl --restore (use --domain to migrate to another domain), '
            . 'not from the manager. Download it and restore it from the shell.' }
        if $name =~ /\A(?:lazysite-)?full-/;    # new + legacy (pre-prefix) names

    my $full = _dir() . "/$name";
    return { ok => 0, error => 'Backup not found' } unless -f $full;

    my $safety = action_backup_create('prerestore');
    return { ok => 0, error => 'Refusing to restore: safety snapshot failed' }
        unless $safety->{ok};

    # SEC-2026-07 (M-TAR): --no-same-permissions (with the existing
    # --no-same-owner) so a hostile or ancient tarball cannot restore setuid/
    # setgid bits or world-writable/over-permissive modes onto the docroot;
    # extracted files take the process umask instead of the archived mode.
    #
    # SEC-2026-07 (M-TAR-AUTH): defence-in-depth against a privilege-escalation
    # chain - a crafted content tarball whose members include lazysite/auth/*
    # (accounts, group grants, the HMAC secret) or lazysite.conf would, on plain
    # extraction, overwrite the auth/config namespace and let a manage_config
    # delegate promote itself to operator. A legitimate CONTENT snapshot never
    # contains ./lazysite (action_backup_create excludes it for every non-full
    # kind), and a FULL snapshot is refused above - so excluding ./lazysite here
    # is a no-op for real archives and neutralises the escalation for a hostile
    # one. tar --exclude drops matching members at extraction time.
    # SM268 C3: `--exclude=./lazysite` matched only archives TAR ITSELF made.
    #
    # GNU tar matches --exclude against the member name as stored. A hostile
    # archive naming its member `lazysite/auth/users` (no `./`) or
    # `.//lazysite/auth/users` did not match, so the M-TAR-AUTH guard above -
    # whose comment says it "neutralises the escalation" - was inert for exactly
    # the archives it was written for. Proven end to end by an adversarial
    # review: an uploaded tarball restored through this action replaced the
    # account store and the group grants with the attacker's.
    #
    # Cover every spelling, and add --anchored so the patterns cannot be
    # side-stepped by nesting. Belt and braces with the wildcard form, which
    # matches a `lazysite` segment wherever tar normalises it to.
    my $rc = system(
        'tar',             'xzf', $full, '-C', $DOCROOT,
        '--no-same-owner', '--no-same-permissions',
        '--anchored',
        '--exclude=./lazysite', '--exclude=./lazysite/*',
        '--exclude=lazysite',   '--exclude=lazysite/*',
        '--no-anchored',
        '--exclude=*/lazysite/*',
    );
    return { ok => 0, error => 'Restore extraction failed (safety snapshot kept: '
            . $safety->{name} . ')' }
        if $rc != 0;

    # Drop render caches: only .html with a .md sibling (a bare legacy .html is
    # real migration content since SM133, never a cache - leave it alone).
    my $cleared = 0;
    File::Find::find(
        { no_chdir => 1,
            wanted => sub {
                my $p = $File::Find::name;
                return unless $p =~ /\.html\z/ && -f $p;
                return if index( $p, "$DOCROOT/lazysite" ) == 0;
                ( my $src = $p ) =~ s/\.html\z/.md/;
                return unless -f $src;
                unlink $p and $cleared++;
            },
        },
        $DOCROOT
    );
    # SM110: backups exclude lazysite/cache entirely, so the per-alias-host
    # tree survives a restore and would serve pre-restore renders - drop it
    # wholesale; each host re-renders on its next request.
    Lazysite::Util::clear_host_cache($DOCROOT);

    # SM085: a restore is visible content history, not history erasure - commit
    # the restored state of the whole versioned set (no-op when git is off).
    require Lazysite::Git;
    Lazysite::Git::commit_all( $DOCROOT, $auth_user, "restore from backup $name" );

    log_event( 'INFO', 'backup-restore', 'snapshot restored', file => $name,
        safety => $safety->{name}, cache_cleared => $cleared, user => $auth_user );
    return { ok => 1, restored => $name, safety => $safety->{name},
        cache_cleared => $cleared };
}

# Streams the tarball (Content-Disposition attachment). Returns an error hash
# only on a pre-stream failure; on success it has already written the response.
sub action_backup_download {
    my ($name) = @_;
    $name = '' unless defined $name;
    return { ok => 0, error => 'Invalid backup name' } unless _valid_name($name);
    my $full = _dir() . "/$name";
    return { ok => 0, error => 'Backup not found' } unless -f $full;

    my $size = ( stat $full )[7] // 0;
    ( my $safe = $name ) =~ s/[\r\n"\\]//g;
    log_event( 'INFO', 'backup-download', 'backup downloaded', file => $name, user => $auth_user );

    binmode STDOUT;
    local $| = 1;
    print "Status: 200 OK\r\n";
    print "Content-Type: application/gzip\r\n";
    print "Content-Length: $size\r\n";
    print "Content-Disposition: attachment; filename=\"$safe\"\r\n";
    print "Cache-Control: no-store, private\r\n";
    print "\r\n";
    open my $fh, '<', $full or return { ok => 0, error => 'Cannot read backup' };
    binmode $fh;
    my $buf;
    while ( my $n = sysread $fh, $buf, 65536 ) { syswrite STDOUT, $buf, $n }
    close $fh;
    return { ok => 1, streamed => 1 };
}

1;
