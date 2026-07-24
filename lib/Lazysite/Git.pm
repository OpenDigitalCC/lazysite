package Lazysite::Git;

# SM085 phase 1: the content-history core. The docroot is versioned with git -
# GIT_DIR at <docroot>/lazysite/git (inside the protected, never-served
# lazysite/ tree; no .git under the docroot, nothing for the web server to
# leak), the docroot as the work tree. Ignore rules live in GIT_DIR/info/exclude
# so the operator's site gains no visible file, and the exclude list is the
# security boundary: a history that can be pushed to a remote must NEVER carry
# a secret or personal data (auth store, forms, notify-xmpp.conf, logs).
#
# Write hooks (Files/Upload/Backups/dav) call commit_paths / commit_all; both
# are eval-guarded and no-op instantly when the feature is off - a git failure
# must never break a save. All git invocations are LIST-FORM (no shell): paths
# and commit messages are attacker-influenced. Shas and paths are validated
# before any git call. run_git is the plumbing the git-sync remote plugin
# (follow-up) builds on.

use strict;
use warnings;
use Lazysite::Util qw(log_event);
use Exporter 'import';

our @EXPORT_OK = qw(enabled initialised git_available git_dir init
    commit_paths commit_all commit_move file_log file_at file_diff file_diff_across
    path_at count_commits run_git breadcrumb_path health files_summary);

sub git_dir { return "$_[0]/lazysite/git" }

# Feature gate: conf key `git_history: enabled` AND an initialised repo.
# Cached per docroot per process (CGI is one-shot; hooks may check repeatedly).
our %ENABLED_CACHE;
sub reset_cache { %ENABLED_CACHE = (); return }

sub _conf_enabled {
    my ($docroot) = @_;
    open my $fh, '<', "$docroot/lazysite/lazysite.conf" or return 0;
    my $on = 0;
    while ( my $line = <$fh> ) {
        if ( $line =~ /^git_history\s*:\s*enabled\b/ ) { $on = 1; last }
    }
    close $fh;
    return $on;
}

sub initialised {
    my ($docroot) = @_;
    return ( defined $docroot && -f git_dir($docroot) . '/HEAD' ) ? 1 : 0;
}

sub enabled {
    my ($docroot) = @_;
    return 0 unless defined $docroot && length $docroot;
    $ENABLED_CACHE{$docroot} //=
        ( _conf_enabled($docroot) && initialised($docroot) ) ? 1 : 0;
    return $ENABLED_CACHE{$docroot};
}

# Is a git binary on PATH? A cheap stat scan - no fork - so the hooks' guard
# and the check tool's probe stay quiet and fast when git is absent.
sub git_available {
    for my $dir ( split /:/, ( $ENV{PATH} // '' ) ) {
        next unless length $dir;
        return 1 if -f "$dir/git" && -x _;
    }
    return 0;
}

# --- validation (before ANY git call) ----------------------------------------

sub _valid_sha { return ( defined $_[0] && $_[0] =~ /\A[0-9a-f]{7,40}\z/ ) ? 1 : 0 }

# A docroot-relative path: no NULs, not absolute, not option-shaped, and no
# empty / . / .. segments (traversal). Callers strip a leading slash first.
sub _valid_rel {
    my ($rel) = @_;
    return 0 unless defined $rel && length $rel;
    return 0 if $rel =~ /\0/ || $rel =~ m{\A/} || $rel =~ /\A-/;
    for my $seg ( split m{/}, $rel ) {
        return 0 if $seg eq '' || $seg eq '.' || $seg eq '..';
    }
    return 1;
}

sub _norm_rel {
    my ($path) = @_;
    return undef unless defined $path;
    ( my $rel = $path ) =~ s{^/+}{};
    return _valid_rel($rel) ? $rel : undef;
}

# Sanitised commit author "user <user@lazysite>" - the identity contract the
# audit trail shares. The user string is stripped to a safe alphabet.
sub _author {
    my ($user) = @_;
    ( my $u = $user // '' ) =~ s/[^A-Za-z0-9_.@-]//g;
    $u = 'unknown' unless length $u;
    return "$u <$u\@lazysite>";
}

sub _clean_message {
    my ($msg) = @_;
    ( my $m = $msg // '' ) =~ s/[\x00-\x1f]+/ /g;
    $m = substr( $m, 0, 200 ) if length $m > 200;
    $m = '(no message)' unless length $m;
    return $m;
}

# --- plumbing ------------------------------------------------------------------

# run_git($docroot, @args): run git against the site repo, list-form exec (no
# shell anywhere - arguments are attacker-influenced), stdout captured. Returns
# ( $ok, $output ); ( 0, undef ) when git is unavailable or cannot be run.
# stderr passes through to the server error log. This is the seam the git-sync
# remote plugin calls.
sub run_git {
    my ( $docroot, @args ) = @_;
    return ( 0, undef ) unless defined $docroot && length $docroot;
    return ( 0, undef ) unless git_available();
    my $gd  = git_dir($docroot);
    my @cmd = (
        'git',
        '-c',            'user.name=lazysite', '-c', 'user.email=lazysite@localhost',
        '-c',            'advice.addIgnoredFile=false',
        "--git-dir=$gd", "--work-tree=$docroot", @args
    );
    open my $fh, '-|', @cmd or return ( 0, undef );
    binmode $fh, ':utf8';
    my $out = do { local $/; <$fh> };
    close $fh;
    return ( ( $? == 0 ? 1 : 0 ), $out );
}

# --- init: adopt the existing site ----------------------------------------------

# The never-versioned list (SM085 design decisions, binding). Written to
# GIT_DIR/info/exclude at init. The auth/forms/notify-xmpp/git-sync/logs
# entries are the SECURITY boundary (git-sync.conf holds the remote access
# token; the sync plugin also self-heals this entry on repos initialised
# before it existed); cache/backups/locks/git/assets/html/install-state keep the
# history clean of runtime and generated artefacts. The CSRF secret and the
# upload-rate DB are manager runtime state at lazysite/manager/ top level -
# excluded for the same reason as auth/.
my @EXCLUDE = qw(
    /lazysite/auth/
    /lazysite/forms/
    /lazysite/notify-xmpp.conf
    /lazysite/git-sync.conf
    /lazysite/cache/
    /lazysite/logs/
    /lazysite/backups/
    /lazysite/manager/locks/
    /lazysite/manager/.csrf-secret
    /lazysite/manager/.upload-rate.db
    /lazysite/git/
    /lazysite/aliases.json
    /lazysite-assets/
    *.html
    .install-state*
);

# Initialise the repo and take the adoption commit ("adopt existing site") of
# the whole versioned set. Does NOT touch lazysite.conf - the git-init manager
# action owns the conf key. Returns { ok, commit } or { ok => 0, error }.
sub init {
    my ( $docroot, $user ) = @_;
    return { ok => 0, error => 'No docroot' } unless defined $docroot && -d $docroot;
    return { ok => 0, error => 'git is not installed on this host' }
        unless git_available();
    return { ok => 0, error => 'Content history is already initialised' }
        if initialised($docroot);

    my $gd = git_dir($docroot);
    # --shared=group: git forces group-writable modes on everything it creates
    # (object dirs, refs, locks), umask-independent - the canonical shared-repo
    # setting. Without it a 0022 umask leaves 0755 object dirs that break the
    # CGI's commits after any ownership handover (field defect 2026-07-11:
    # silent version loss on a doctored site).
    my ($iok) = run_git( $docroot, '-c', 'init.defaultBranch=main', 'init', '-q',
        '--shared=group' );
    return { ok => 0, error => 'git init failed' } unless $iok && -d $gd;
    run_git( $docroot, 'config', 'core.worktree', $docroot );
    # --shared=group records core.sharedRepository=1; normalise to the named
    # form so the doctor's probe reads one canonical value.
    run_git( $docroot, 'config', 'core.sharedRepository', 'group' );
    chmod 02770, $gd;    # CGI-writable, never world-accessible (check-tool probe)

    open my $ex, '>', "$gd/info/exclude"
        or return { ok => 0, error => "Cannot write info/exclude: $!" };
    print {$ex} "# lazysite content history (SM085) - never-versioned paths.\n";
    print {$ex} "# A pushable history must never carry a secret or personal data.\n";
    print {$ex} "$_\n" for @EXCLUDE;
    close $ex;
    # Group-writable: git-sync's exclude self-heal may append as the other
    # identity (CLI-enabled repo, CGI-run sync) - umask-independent, like the
    # rest of the repo under core.sharedRepository=group.
    chmod 0664, "$gd/info/exclude";

    my ($aok) = run_git( $docroot, 'add', '-A', '--', '.' );
    return { ok => 0, error => 'git add failed for the adoption commit' } unless $aok;
    my ($cok) = run_git( $docroot, 'commit', '-q', '--allow-empty',
        '-m', 'adopt existing site', '--author', _author($user) );
    return { ok => 0, error => 'the adoption commit failed' } unless $cok;
    # See _stage_and_commit: git rewrites this scratch file in place; keep it
    # group-writable for the other identity's commits.
    chmod 0664, "$gd/COMMIT_EDITMSG";

    reset_cache();
    my ( undef, $sha ) = run_git( $docroot, 'rev-parse', 'HEAD' );
    chomp $sha if defined $sha;
    log_event( 'INFO', 'git-init', 'content history initialised',
        commit => ( $sha // '' ), user => ( $user // '' ) );
    return { ok => 1, commit => $sha };
}

# --- auto-commit ------------------------------------------------------------------

# The recording-health breadcrumb. A failed commit never breaks the save that
# triggered it (by design, below), which also makes the failure invisible
# without log-diving - the field defect 2026-07-11 was a doctored repo whose
# 0755 object dirs silently lost every post-init version. The breadcrumb
# GIT_DIR/COMMIT_FAILED is touched on any commit failure and removed by the
# next successful commit; the content-history plugin's status action and the
# lazysite-check doctor both read it, so "versioning is currently failing" is
# visible without the server log.
sub breadcrumb_path { return git_dir( $_[0] ) . '/COMMIT_FAILED' }

sub _mark_commit_failed {
    my ($docroot) = @_;
    if ( open my $fh, '>', breadcrumb_path($docroot) ) {
        print {$fh} "content-history commit failed - see the server error log;\n"
            . "cleared automatically by the next successful commit\n";
        close $fh;
        # Group-writable: the clearing commit may run as the other identity.
        chmod 0664, breadcrumb_path($docroot);
    }
    return;
}

# Stage exactly the named pathspecs and commit. Internal: callers validated (or
# own) the pathspecs. Per-path add so one unmatched pathspec (a never-tracked
# sidecar, an ignored file) cannot abort the batch - but an add that fails for
# a path that EXISTS is repo trouble (e.g. unwritable object dirs), not the
# tolerated unmatched case, and fails loudly. Returns 1 if a commit was made,
# 0 otherwise; NEVER dies past the eval - a git failure must not break the
# save that triggered it (it leaves the breadcrumb above instead).
sub _stage_and_commit {
    my ( $docroot, $user, $message, $trailers, @specs ) = @_;
    my $made = eval {
        my $staged = 0;
        for my $spec (@specs) {
            my ($ok) = run_git( $docroot, 'add', '-A', '--', $spec );
            if    ($ok) { $staged++ }
            elsif ( $spec eq '.' || -e "$docroot/$spec" ) {
                die "git add failed for an existing path ($spec)\n";
            }
        }
        return 0 unless $staged;
        my ($clean) = run_git( $docroot, 'diff', '--cached', '--quiet' );
        return 0 if $clean;    # exit 0 = nothing staged, nothing to commit
            # Optional structured trailers (SM175: Lazysite-Renamed-From) - git's
            # own --trailer keeps them well-formed at the end of the message, which
            # _clean_message (control chars -> space) could not preserve inline.
        my @tr = $trailers ? map { ( '--trailer', $_ ) } @{$trailers} : ();
        my ($cok) = run_git( $docroot, 'commit', '-q', '-m', _clean_message($message),
            @tr, '--author', _author($user) );
        die "git commit failed\n" unless $cok;
        1;
    };
    unless ( defined $made ) {
        log_event( 'WARN', 'git', 'content-history commit failed (the write itself succeeded)',
            error => ( $@ // 'unknown' ), user => ( $user // '' ) );
        _mark_commit_failed($docroot);
        return 0;
    }
    if ($made) {
        unlink breadcrumb_path($docroot);
        # COMMIT_EDITMSG is a scratch file git rewrites IN PLACE on every
        # commit, with the process umask - core.sharedRepository does not
        # cover it, and an unwritable one is FATAL to the next commit
        # (verified). Keep it group-writable so the other identity can
        # commit after us.
        chmod 0664, git_dir($docroot) . '/COMMIT_EDITMSG';
    }
    return $made;
}

# commit_paths($docroot, $user, $message, @paths): one commit staging exactly
# those paths (a batched operation is one commit). Instant no-op when the
# feature is off; invalid paths are dropped before any git call.
sub commit_paths {
    my ( $docroot, $user, $message, @paths ) = @_;
    return 0 unless enabled($docroot);
    my @specs = grep { defined } map { _norm_rel($_) } @paths;
    return 0 unless @specs;
    return _stage_and_commit( $docroot, $user, $message, undef, @specs );
}

# commit_all: stage the whole versioned set (the backup-restore hook - a
# restore is visible history, not history erasure).
sub commit_all {
    my ( $docroot, $user, $message ) = @_;
    return 0 unless enabled($docroot);
    return _stage_and_commit( $docroot, $user, $message, undef, '.' );
}

# commit_move($docroot, $user, $message, $from, @paths): a rename recorded as a
# first-class move (SM175). Stages @paths - the source deletion, the destination
# add and any sidecars - as ONE commit, and records the rename source $from in a
# Lazysite-Renamed-From trailer. file_log follows history across the rename via
# that trailer (not git's rename heuristic), and because the link is explicit a
# later unrelated file at the old or new path never inherits this thread. The
# caller performs the on-disk rename first (as it does today); this only records
# it. Instant no-op when the feature is off; invalid paths are dropped.
sub commit_move {
    my ( $docroot, $user, $message, $from, @paths ) = @_;
    return 0 unless enabled($docroot);
    my $from_rel = _norm_rel($from);
    my @specs    = grep { defined } map { _norm_rel($_) } @paths;
    return 0 unless @specs && defined $from_rel;
    return _stage_and_commit( $docroot, $user, $message,
        ["Lazysite-Renamed-From:$from_rel"], @specs );
}

# --- reads (repo-absent / disabled = empty or undef, never an error) --------------

# Per-file timeline: [ { sha, epoch, author, subject }, ... ] newest first.
# SM175: the history follows the file's IDENTITY, not merely its path. It walks
# the current incarnation - back to the most recent commit that added this path
# (--diff-filter=A) - and then, ONLY if that commit is a recorded move (carries a
# Lazysite-Renamed-From trailer), continues into the source path's lineage,
# recursively. So a rename keeps its history, while a delete ends the thread: a
# later file created at the same path starts clean and never inherits the deleted
# file's past. Plain `git log -- path` (and even `git log --follow`) leak that
# past because they list every commit that ever touched the pathname.
sub file_log {
    my ( $docroot, $path, $limit ) = @_;
    return [] unless enabled($docroot);
    my $rel = _norm_rel($path);
    return [] unless defined $rel;
    $limit = ( defined $limit && $limit =~ /\A\d+\z/ && $limit > 0 ) ? $limit : 50;
    $limit = 200 if $limit > 200;

    my @entries;
    my $cur   = $rel;
    my $start = 'HEAD';
    my %seen;    # "$path\@$start" - guard against a pathological trailer cycle
    while ( @entries < $limit && defined $cur && !$seen{"$cur\@$start"}++ ) {
        # This incarnation begins at the most recent commit that ADDED $cur
        # at-or-before $start - the boundary we must not read past (reading past
        # it would leak an earlier, deleted file that reused the path).
        my ( undef, $aout ) = run_git( $docroot, 'log', '--diff-filter=A',
            '-n1', '--format=%H', $start, '--', $cur );
        my ($add) = ( $aout // '' ) =~ /\A([0-9a-f]{40})/;

        my ( $lok, $lout ) = run_git( $docroot, 'log',
            '--format=%H%x09%at%x09%an%x09%s', $start, '--', $cur );
        last unless $lok && defined $lout;

        my $reached_add = 0;
        for my $line ( split /\n/, $lout ) {
            my ( $sha, $at, $an, $subject ) = split /\t/, $line, 4;
            next unless defined $sha && $sha =~ /\A[0-9a-f]{40}\z/;
            push @entries,
                { sha => $sha, epoch => ( $at // 0 ) + 0, author => ( $an // '' ),
                subject => ( $subject // '' ), path => $cur };
            if ( defined $add && $sha eq $add ) { $reached_add = 1; last }
            last if @entries >= $limit;
        }
        # A limit cut-off mid-incarnation must not jump lineage; stop unless we
        # cleanly reached this incarnation's add commit.
        last unless $reached_add && defined $add;

        # Follow ONLY a recorded rename. No trailer => the thread ends here.
        my ( undef, $tout ) = run_git( $docroot, 'log', '-n1',
            '--format=%(trailers:key=Lazysite-Renamed-From,valueonly)', $add );
        my $from = defined $tout ? $tout : '';
        $from =~ s/\A\s+//;
        $from =~ s/\s+\z//;
        $from = _norm_rel($from);
        last unless defined $from;

        $cur   = $from;
        $start = "$add~1";
    }
    return \@entries;
}

# SM199: the file-list / table-of-contents over the history. Enumerates the
# content paths currently under version control (git ls-files at HEAD - the
# tracked set is exactly the versioned content, since info/exclude keeps
# secrets, caches and generated *.html out), then aggregates each path's
# lineage-aware timeline (file_log, SM175 semantics) into per-file statistics.
# Because it reuses file_log, a rename's pre-rename revisions are counted under
# the CURRENT path and a delete-then-recreate at a reused path starts clean -
# no leak across the boundary, the same guarantee the per-file view gives.
#
# Returns { files => [ { path, revisions, first, latest, last_author }, ... ]
# (sorted by path), summary => { files, revisions } }. Dates are commit epochs
# (first = oldest in the lineage, latest = newest); last_author is the author of
# the most recent revision. Disabled / no repo = empty, never an error. Each
# path's history is bounded by the file_log limit (200), so a pathological
# thousand-revision file counts up to that bound - the same cap the per-file
# view honours.
sub files_summary {
    my ($docroot) = @_;
    return { files => [], summary => { files => 0, revisions => 0 } }
        unless enabled($docroot);

    # The tracked content set AT HEAD (what the history covers) - ls-tree of the
    # committed tree, recursive, NUL-delimited so unusual bytes stay intact.
    # (git ls-files lists the index/worktree; the committed tree is the right set
    # for a history overview, and it is exactly what info/exclude has kept clean.)
    my ( $ok, $out ) = run_git( $docroot, 'ls-tree', '-r', '--name-only', '-z', 'HEAD' );
    return { files => [], summary => { files => 0, revisions => 0 } }
        unless $ok && defined $out;

    my @files;
    my $total_rev = 0;
    for my $rel ( split /\0/, $out ) {
        next unless length $rel;
        my $norm = _norm_rel($rel);
        next unless defined $norm;
        my $log = file_log( $docroot, $norm, 200 );
        next unless @{$log};    # a path with no readable lineage is skipped
        my $revisions = scalar @{$log};

        # file_log is newest-first: [0] is the latest revision, [-1] the oldest
        # in this incarnation's lineage.
        my $latest = $log->[0];
        my $first  = $log->[-1];
        push @files, {
            path        => $norm,
            revisions   => $revisions,
            first       => $first->{epoch},
            latest      => $latest->{epoch},
            last_author => $latest->{author},
        };
        $total_rev += $revisions;
    }
    @files = sort { $a->{path} cmp $b->{path} } @files;
    return {
        files   => \@files,
        summary => { files => scalar @files, revisions => $total_rev },
    };
}

# The file's content at a version. undef on any refusal or miss.
sub file_at {
    my ( $docroot, $sha, $path ) = @_;
    return undef unless enabled($docroot) && _valid_sha($sha);
    my $rel = _norm_rel($path);
    return undef unless defined $rel;
    my ( $ok, $out ) = run_git( $docroot, 'show', "$sha:$rel" );
    return $ok ? $out : undef;
}

# Unified diff of a version against the current worktree.
sub file_diff {
    my ( $docroot, $sha, $path ) = @_;
    return undef unless enabled($docroot) && _valid_sha($sha);
    my $rel = _norm_rel($path);
    return undef unless defined $rel;
    my ( $ok, $out ) = run_git( $docroot, 'diff', $sha, '--', $rel );
    return $ok ? $out : undef;
}

# SM175: the path a file had at $sha, resolved through its RECORDED rename
# lineage (the same walk file_log uses). Returns undef if $sha is not in this
# file's lineage - so a caller (git-show / git-restore) can only reach content
# that genuinely belongs to THIS file's history, never an arbitrary $sha:$path.
# $sha may be a 7-40 char prefix.
sub path_at {
    my ( $docroot, $path, $sha ) = @_;
    return undef unless enabled($docroot);
    return undef unless defined $sha && $sha =~ /\A[0-9a-f]{7,40}\z/;
    my $want = lc $sha;
    for my $e ( @{ file_log( $docroot, $path, 200 ) } ) {
        return $e->{path} if index( $e->{sha}, $want ) == 0;
    }
    return undef;
}

# SM175: a unified diff of a historic version (at $sha, where the file then
# lived at $from) against the current committed file at $to - used by git-show
# when the history crossed a rename, so "version vs current" still works.
sub file_diff_across {
    my ( $docroot, $sha, $from, $to ) = @_;
    return undef unless enabled($docroot) && _valid_sha($sha);
    my $f = _norm_rel($from);
    my $t = _norm_rel($to);
    return undef unless defined $f && defined $t;
    my ( $ok, $out ) = run_git( $docroot, 'diff', "$sha:$f", "HEAD:$t" );
    return $ok ? $out : undef;
}

sub count_commits {
    my ($docroot) = @_;
    return 0 unless initialised($docroot);
    my ( $ok, $out ) = run_git( $docroot, 'rev-list', '--count', 'HEAD' );
    return 0 unless $ok && defined $out && $out =~ /(\d+)/;
    return $1 + 0;
}

# A genuine health probe for the content-history repo - not just "is the conf key
# set" (enabled()) but "is the repository ACTUALLY there and usable". This exists
# to catch the masked failure mode where enabling wrote git_history: enabled to
# lazysite.conf but the git init did not complete (an interrupted / failed
# request), leaving the config saying ON with no usable repo behind it. Returns a
# structured hash with a single-word `verdict` the status surfaces consume:
#   no-git       - the git binary is not installed
#   disabled     - not enabled and no repo (the normal off state)
#   paused       - recording is off but an initialised repo (earlier versions) is kept
#   inconsistent - conf says ENABLED but the repo is missing or unusable  <-- the bug
#   degraded     - usable repo, but the last record FAILED or a stale lock is present
#   ok           - enabled, initialised, HEAD is a real commit, and the repo reads
sub health {
    my ($docroot) = @_;
    my %h = (
        git_available    => git_available()         ? 1 : 0,
        conf_enabled     => _conf_enabled($docroot) ? 1 : 0,
        initialised      => initialised($docroot)   ? 1 : 0,
        head_ok          => 0,
        readable         => 0,
        lock_present     => ( -e git_dir($docroot) . '/index.lock' ) ? 1 : 0,
        recording_failed => ( -e breadcrumb_path($docroot) )         ? 1 : 0,
        commits          => 0,
    );
    if ( $h{git_available} && $h{initialised} ) {
        my ( $ok_head, $sha ) = run_git( $docroot, 'rev-parse', '--verify', 'HEAD' );
        $h{head_ok} = ( $ok_head && defined $sha && $sha =~ /[0-9a-f]{7,40}/ ) ? 1 : 0;
        my ($ok_st) = run_git( $docroot, 'status', '--porcelain' );
        $h{readable} = $ok_st ? 1 : 0;
        $h{commits}  = count_commits($docroot) if $h{head_ok};
    }
    my $usable = $h{git_available} && $h{initialised} && $h{head_ok} && $h{readable};
    $h{verdict} =
        !$h{git_available} ? 'no-git'
        : $h{conf_enabled} ? (
        !$usable                                       ? 'inconsistent'
        : ( $h{recording_failed} || $h{lock_present} ) ? 'degraded'
        : 'ok'
        )
        : ( $h{initialised} ? 'paused' : 'disabled' );
    $h{healthy} = ( $h{verdict} eq 'ok' ) ? 1 : 0;
    return \%h;
}

1;
