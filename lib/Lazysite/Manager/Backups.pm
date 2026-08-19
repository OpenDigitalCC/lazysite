package Lazysite::Manager::Backups;

# SM084: docroot content backups - tarball snapshots stored under
# lazysite/backups/ (infrastructure, never served), surfaced in the manager so an
# operator can snapshot before a risky change and download/restore the original.
# A pre-install snapshot is taken by the Hestia hook; manual ones come from here.

use strict;
use warnings;
use POSIX             qw(strftime);
use File::Path        qw(make_path);
use File::Find        ();
use File::Basename    qw(dirname basename);
use Lazysite::Private ();
use Fcntl             qw(O_WRONLY O_CREAT O_EXCL);
use Errno             ();
use Lazysite::Util    qw(log_event);
use Exporter          qw(import);
our @EXPORT_OK = qw(action_backup_list action_backup_create action_backup_download
    action_backup_restore action_backup_delete
    write_sha256 read_sha256 verify_sha256);

our $DOCROOT      = '';
our $LAZYSITE_DIR = '';
our $auth_user    = '';

sub _dir { return "$LAZYSITE_DIR/backups" }

# A backup name is a single tarball basename - strict, no path traversal.
sub _valid_name { return $_[0] =~ /\A[A-Za-z0-9._-]+\.tar\.gz\z/ && $_[0] !~ /[.][.]/ }

# SM183: write the integrity digest beside an artefact, and return it.
#
# A site package is made to TRAVEL - an agency builds a demo and hands it to the
# client's own instance, often across organisations and by whatever channel is to
# hand. The receiving operator has no way to tell an altered package from an
# intact one, and "apply" overwrites a site. The release tarballs have carried a
# .sha256 sidecar for exactly this reason since long before site packages
# existed; this gives packages and backups the same.
#
# A sidecar file rather than a manifest field, deliberately: it is verifiable
# with sha256sum -c and no lazysite tooling at all, which is the situation the
# receiving operator is actually in.
#
# Failure to write it is NOT fatal. The artefact is valid without it; a digest
# that cannot be stored should not lose an operator their backup - but it must
# be REPORTED as absent, which is the SM268 03-F10 half below.
#
# SM268 03-F10: write it atomically, and never report a digest that was not
# stored.
#
# This wrote with a plain `open '>'` - which follows a symlink, has no O_EXCL and
# is not atomic - silently ignored an open failure while STILL returning the
# digest to its caller, and chmod 0664'd the sidecar into the same
# group-writable directory as the artefact it describes. A caller that was told
# a digest and got no file is the worst of the three: package_create recorded a
# sha256 in its response for an artefact that carries none.
sub write_sha256 {
    my ($path) = @_;
    return '' unless -f $path;
    require Digest::SHA;
    my $sha = eval { Digest::SHA->new('sha256')->addfile( $path, 'b' )->hexdigest };
    return '' unless defined $sha && length $sha;
    my $base = $path;
    $base =~ s{.*/}{};

    my $side = "$path.sha256";
    if ( -l $side ) {
        log_event( 'ERROR', 'sha256', 'sidecar path is a symlink - refusing',
            path => $side );
        return '';
    }
    my $tmp = "$side.tmp.$$";
    unless ( sysopen my $fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, oct '640' ) {
        log_event( 'ERROR', 'sha256', 'cannot write digest sidecar',
            path => $tmp, error => "$!" );
        return '';
    }
    else {
        print {$fh} "$sha  $base\n";    # sha256sum -c format
        close $fh;
    }
    unless ( rename $tmp, $side ) {
        log_event( 'ERROR', 'sha256', 'cannot install digest sidecar',
            path => $side, error => "$!" );
        unlink $tmp;
        return '';
    }
    return $sha;
}

# Read the digest beside an artefact, if one was written.
#
# SM268 03-F10: the BASENAME field is checked. This took the first 64 hex
# characters and ignored the rest of the line, so a sidecar describing a
# different artefact was accepted as this one's - which is the whole point of
# sha256sum's second field.
sub read_sha256 {
    my ($path) = @_;
    open my $fh, '<', "$path.sha256" or return '';
    my $line = <$fh> // '';
    close $fh;
    my ( $sha, $named ) = $line =~ /\A([0-9a-f]{64})\s+\*?(\S+)/;
    return '' unless defined $sha;
    my $base = $path;
    $base =~ s{.*/}{};
    return '' unless defined $named && $named eq $base;
    return $sha;
}

# SM268 03-F10: the digest was DISPLAYED and never verified.
#
# action_backup_list surfaced read_sha256 for every artefact and nothing
# anywhere recomputed it. An operator sees a digest in the UI beside a package
# and reads it as "verified"; it meant "a digest was written at some point".
# Misleading assurance is worse than none: someone who tampers with a tarball in
# place and leaves the sidecar alone gets a green-looking listing.
#
# Returns 'verified', 'mismatch', or 'absent'. Not a boolean, because the three
# cases need different responses: absent is an artefact from before the sidecar
# existed and is merely unverified, while mismatch is a fact about this file
# now.
sub verify_sha256 {
    my ($path) = @_;
    my $want = read_sha256($path);
    return 'absent' unless length $want;
    require Digest::SHA;
    my $got = eval { Digest::SHA->new('sha256')->addfile( $path, 'b' )->hexdigest };
    return 'mismatch' unless defined $got && length $got;
    return $got eq $want ? 'verified' : 'mismatch';
}

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
                kind => $kind, scope => $scope,
                # SM183: present only when a digest was written beside it, so an
                # artefact from before this is simply unverified rather than
                # looking like one whose digest failed.
                #
                # SM268 03-F10: and RECOMPUTED, not merely echoed. A digest
                # displayed beside a package reads as "verified" whether or not
                # anything checked it, so the listing now says which of the
                # three it is: verified, mismatch, or absent.
                sha256        => read_sha256("$dir/$f"),
                sha256_status => verify_sha256("$dir/$f") };
        }
        closedir $dh;
    }
    @out = sort { $b->{mtime} <=> $a->{mtime} } @out;
    return { ok => 1, backups => \@out };
}

# SM183: the stamp is second-granular and was the ONLY thing making a name
# unique, so two snapshots in the same second produced the same name and the
# second silently overwrote the first.
#
# That is not theoretical and it is not cosmetic. action_backup_restore takes its
# own safety snapshot before restoring; roll back an apply promptly and the
# restore's snapshot lands on the apply's, destroying the artefact being restored
# FROM - and then "restores" the state you were trying to undo. It reported
# success throughout. Found by testing the rollback round trip.
#
# SM268 03-F9: the first fix for that was `if (-e $out) { pick a -N }`, which is
# a check followed by a create and therefore fixed it only for SEQUENTIAL
# callers. An adversarial review ran twelve concurrent snapshots and got two
# files: every caller was told ok => 1 and handed a name, and ten of them named
# someone else's tarball. Two tar processes writing one inode is also not
# guaranteed to produce a valid archive.
#
# O_EXCL is the test and the claim in one syscall, so exactly one caller wins
# each name and the losers take the next suffix. Still disambiguate rather than
# refuse: a backup is a safety net and the caller is usually mid-operation, so
# failing to take one is worse than taking one under a slightly longer name.
#
# Returns (path, basename), or () if 50 suffixes were all taken or the create
# failed for a reason other than "exists" - a full or unwritable backups
# directory, say, which must not be reported as a successful snapshot.
#
# tar then writes THROUGH the placeholder - it opens O_WRONLY|O_CREAT|O_TRUNC,
# so the inode we claimed is the one it fills.
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

# Filesystem paths are never exposed (standing rule), and tar's stderr is full
# of them. Absolute paths under the docroot or the private store become the
# site-relative form a caller can act on; anything else absolute is replaced
# wholesale rather than trimmed, because a path outside the site tells a remote
# caller about the host and nothing about their problem.
sub _scrub_paths {
    my ($text) = @_;
    return '' unless defined $text;

    # SM386: KEEP THE SITE-RELATIVE PATH. It is the whole diagnostic value and
    # it discloses nothing a caller cannot already list.
    #
    # The first version replaced the docroot with <site> and then ran a generic
    # absolute-path rule that ate what was left, so every message came out as
    # "<site><path>" or "<path>". A partner agent chasing a Permission denied
    # from tar could not tell whether it was failing on the private store, the
    # cache, a lock file, or something under lazysite/ it should not be reading
    # at all - which is the one thing needed to act.
    #
    # The generic rule's lookbehind excluded "<" and not ">", so it matched the
    # relative remainder immediately after the placeholder it had just written.
    # A guard that does not cover its own output.
    #
    # RELATIVE ALWAYS, ABSOLUTE NEVER. A path inside the site keeps its shape
    # under a placeholder root; a path outside keeps only its last two segments,
    # which names the artefact without describing the host's layout.
    my $priv = Lazysite::Private::private_root($DOCROOT);
    my @roots;
    push @roots, [ $priv,    '<private>' ] if defined $priv    && length $priv;
    push @roots, [ $DOCROOT, '<site>' ]    if defined $DOCROOT && length $DOCROOT;

    # Longest first: the private store is a SIBLING of the docroot on some
    # layouts and a child on none, but ordering by length keeps this correct if
    # that ever changes.
    for my $r ( sort { length( $b->[0] ) <=> length( $a->[0] ) } @roots ) {
        my ( $root, $label ) = @$r;
        $text =~ s{\Q$root\E(?=/|\s|\z|:)}{$label}g;
    }

    # Anything still absolute is outside the site. Keep the tail so the reader
    # can tell a lock file from a library, and drop the rest.
    $text =~ s{(?<![\w<>])(/(?:[\w.\-]+/)*)([\w.\-]+/[\w.\-]+)}{<outside>/$2}g;
    $text =~ s{(?<![\w<>/])/[\w.\-]+(?=\s|:|\z)}{<outside>}g;

    $text =~ s/\s+\z//;
    my @lines = split /\n/, $text;
    @lines = @lines[ 0 .. 2 ] if @lines > 3;    # the first fault, not the flood
    return join '; ', @lines;
}

# Is the archive a readable gzip stream? A tar warning is only acceptable if
# what it produced can actually be restored, and "the file exists and is not
# empty" does not establish that.
sub _gzip_ok {
    my ($path) = @_;
    my $pid = fork();
    return 0 unless defined $pid;
    if ( !$pid ) {
        # Checked, because an unchecked open here would leave gzip's chatter on
        # the caller's STDOUT - and in a CGI worker that means diagnostic text
        # in the middle of a response body.
        open STDOUT, '>', '/dev/null' or exit 127;
        open STDERR, '>', '/dev/null' or exit 127;
        exec( 'gzip', '-t', $path ) or exit 127;
    }
    waitpid $pid, 0;
    return ( $? == 0 ) ? 1 : 0;
}

sub action_backup_create {
    my ($kind) = @_;
    $kind = 'manual' unless defined $kind && $kind =~ /\A(manual|prerestore|full)\z/;
    my $dir = _dir();

    # SM381: CHECKED. An unchecked make_path meant a permissions failure here
    # surfaced two frames later as "could not claim a filename", which names the
    # wrong thing entirely - the directory could not be made, and the operator
    # was sent to look at filenames.
    unless ( -d $dir ) {
        make_path($dir);
        unless ( -d $dir ) {
            return { ok => 0,
                error  => 'Backup failed: cannot create the backup directory',
                reason => 'cannot create the backup directory',
                detail => _scrub_paths("$dir: $!") };
        }
    }
    # All backup artefacts carry the `lazysite-` namespace prefix so they are
    # unmistakably ours (and sort together): lazysite-<kind>-<UTCstamp>.tar.gz.
    # The name is claimed atomically - see _claim_name for why a check-then-create
    # was not enough.
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

    # SM381: THE RENDER CACHE'S TEMPFILES, which exist for milliseconds and are
    # renamed away. The processor writes "<page>.html.tmp.<pid>" into the
    # DOCROOT and renames it into place, so a visitor arriving mid-backup lets
    # tar enumerate a temp file that is gone before tar opens it. tar then exits
    # non-zero for a file nobody wanted archived.
    #
    # Excluded rather than only tolerated, because the file is genuinely not
    # wanted in a backup: restoring one would put a half-written page into a site.
    push @excludes, '--exclude=*.tmp.[0-9]*';

    # SM286: the private content store is CONTENT, and it lives outside the
    # docroot - so a tar of the docroot alone silently stops backing up every
    # gated section. That is worse than the exposure the store removes, and it
    # would be discovered at restore time, which is the worst moment to discover
    # anything.
    #
    # A mid-command -C switches tar's directory for the members that follow, so
    # one pass produces `./...` for the docroot and `lazysite-private/...` for
    # the store. The docroot members keep their exact existing spelling, so an
    # archive written before this still restores unchanged - the format is
    # extended, not replaced. (Back-compat is not required here as of
    # 2026-08-13, but breaking it for no gain would still be a choice with a
    # cost and none of the benefit.)
    my @store;
    my $priv = Lazysite::Private::private_root($DOCROOT);
    if ( defined $priv && -d $priv ) {
        my $parent = dirname($priv);
        my $leaf   = basename($priv);
        @store = ( '-C', $parent, $leaf );
    }

    # SM378: SAY WHY. 'Backup failed' discarded tar's exit status, its stderr
    # and which of three distinct conditions actually fired - so a caller met a
    # wall rather than a diagnosable fault. A partner agent hit exactly that:
    # site_apply refused with 'safety snapshot failed', while site_backup on the
    # same host succeeded in both directions minutes later, and there was
    # nothing in the refusal to tell the two apart.
    #
    # The three conditions are NOT the same fault and must not share a message:
    # tar exiting non-zero is a tar problem; a missing archive after a zero exit
    # is a filesystem or permissions problem; a zero-byte archive means tar
    # believed it wrote something and did not.
    # LIST FORM, NO SHELL, AND THE REDIRECT IN THE CHILD ONLY.
    #
    # An earlier draft reached for `sh -c` to get the redirect and used a
    # bashism (${@:3}) that dash - Debian's /bin/sh - does not understand, which
    # would have broken every backup on the platform this ships to.
    #
    # The draft after THAT redirected this process's STDERR around the system()
    # call, which is a hazard in a persistent worker (SM381): for the duration
    # of a multi-second tar every unrelated warning in the process goes to a
    # temp file that is then deleted, and if the call dies between the two
    # opens, STDERR stays redirected for the life of the worker.
    #
    # fork/exec redirects in the CHILD, so the parent's STDERR is never touched.
    my $err_file = "$out.err";
    my $rc       = 0;
    my $pid      = fork();
    if ( !defined $pid ) {
        $rc = -1;
    }
    elsif ( !$pid ) {
        open STDERR, '>', $err_file or exit 127;
        exec( 'tar', 'czf', $out, '-C', $DOCROOT, @excludes, '.', @store )
            or exit 127;
    }
    else {
        waitpid $pid, 0;
        $rc = $?;
    }
    my $tar_err = '';
    if ( open my $eh, '<', $err_file ) {
        local $/;
        $tar_err = <$eh> // '';
        close $eh;
    }
    unlink $err_file;

    # SM381: TAR EXIT 1 IS "SOME FILES DIFFER", NOT A FAILURE.
    #
    # tar uses 1 for a warning - a file changed or vanished while being read -
    # and 2 for a fatal error. Treating both as fatal is why a busy site could
    # not be snapshotted: one visitor triggering a render during the tar
    # produced exit 1 and the whole apply refused. It explains every symptom the
    # field reported - intermittent, traffic-correlated, and invisible to a
    # manual backup taken at a quiet moment.
    #
    # The archive still has to be USABLE before a warning is accepted: present,
    # non-empty, and readable as a gzip stream. A warning plus a valid archive
    # is a backup; a warning plus a broken one is a failure.
    my $status = $rc >> 8;
    my $usable = ( -f $out && !-z $out && _gzip_ok($out) ) ? 1 : 0;
    my $warned = ( $status == 1 && $usable ) ? 1 : 0;

    if ($warned) {
        log_event( 'INFO', 'backup-create',
            'tar reported changed files during the snapshot; archive verified',
            file => $name, user => $auth_user );
    }

    if ( ( $rc != 0 && !$warned ) || !-f $out || -z $out ) {
        # Drop the placeholder we claimed, or a failed snapshot sits in the
        # listing as a zero-byte tarball that reads as a usable one.
        unlink $out;
        my $why
            = $rc != 0 ? sprintf( 'tar exited %d', $rc >> 8 )
            : !-f $out ? 'tar reported success but wrote no archive'
            :            'tar wrote an empty archive';
        return { ok => 0,
            error  => "Backup failed: $why",
            reason => $why,
            ( length $tar_err ? ( detail => _scrub_paths($tar_err) ) : () ) };
    }
    log_event( 'INFO', 'backup-create',
        ( $kind eq 'full' ? 'full system snapshot' : 'docroot snapshot' ),
        file => $name, user => $auth_user );
    my $sha = write_sha256($out);

    # After the snapshot exists and carries its digest, never before: expiring an
    # old one to make room for a new one that then fails would lose both.
    _apply_retention($kind);

    my @st = stat $out;
    return { ok => 1, name => $name, size => $st[7] // 0, mtime => $st[9] // 0,
        sha256 => $sha,
        scope  => ( $kind eq q{full} ? q{full} : q{content} ) };
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
    unless ( $safety->{ok} ) {
        # SM378: the same discard as the apply path, in the operation where
        # being unable to roll back matters most.
        my $why = $safety->{reason} || $safety->{error} || 'no reason given';
        return { ok => 0,
            error => "Refusing to restore: safety snapshot failed - $why",
            ( $safety->{detail} ? ( detail => $safety->{detail} ) : () ) };
    }

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

        # SM286: and the private store, which this pass must NOT touch. Its
        # members are extracted separately, into the docroot's parent, below.
        #
        # Without these the first pass extracts `lazysite-private/...` INTO the
        # docroot - putting every gated file back exactly where the front end
        # serves it, which is the whole exposure, restored from a backup, by the
        # operation meant to recover from one. The existing `lazysite` excludes
        # do not cover it: the names differ, and these members carry no `./`.
        # Caught by the test, not by review.
        #
        # Matched by SUFFIX rather than by this site's own store name. The store
        # is named for its docroot, so an archive made on a site whose docroot
        # had a different basename carries a differently-named member - and an
        # exclude that missed it would extract that store into this docroot,
        # which is the exposure this pass exists to avoid. A wildcard cannot
        # under-match here; the separate pass below is what decides whether the
        # store is restored at all, and it uses the exact name.
        '--no-anchored',
        '--exclude=*lazysite-private',
        '--exclude=*lazysite-private/*',
        '--exclude=*/lazysite/*',
    );
    return { ok => 0, error => 'Restore extraction failed (safety snapshot kept: '
            . $safety->{name} . ')' }
        if $rc != 0;

    # SM286: the private store, extracted in its OWN pass, into the docroot's
    # parent - because that is where it lives.
    #
    # This is the most dangerous line in the file and it is worth saying why.
    # The pass above extracts an operator-supplied archive INTO the docroot; the
    # SEC-2026-07 review showed an uploaded tarball replacing the account store
    # through exactly this action, and the `lazysite` excludes are the fix. This
    # pass extracts OUTSIDE the docroot, so a careless version would let an
    # uploaded archive write anywhere its member names pointed.
    #
    # Confined three ways, none of them sufficient alone:
    #   * only members named `lazysite-private` are extracted at all - an
    #     explicit member list, not a filter, so anything else in the archive is
    #     never a candidate;
    #   * --anchored, so the name cannot be reached by nesting;
    #   * the leading `/` strip and `..` refusal that GNU tar applies by default,
    #     which stop an absolute or climbing member.
    # And the pass runs only when the archive actually contains such a member,
    # so an archive without one does no extraction outside the docroot at all.
    {
        my $priv = Lazysite::Private::private_root($DOCROOT);
        my $leaf = defined $priv ? basename($priv) : undef;
        if ( defined $leaf && length $leaf ) {
            my $listing = `tar tzf \Q$full\E 2>/dev/null`;
            if ( defined $listing && $listing =~ m{^\Q$leaf\E/}m ) {
                my $prc = system(
                    'tar',             'xzf', $full, '-C', dirname($priv),
                    '--no-same-owner', '--no-same-permissions',
                    '--anchored',      $leaf,
                );
                return {
                    ok    => 0,
                    error => 'Restore of the private content store failed '
                        . '(safety snapshot kept: ' . $safety->{name} . ')'
                } if $prc != 0;
            }
        }
    }

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
