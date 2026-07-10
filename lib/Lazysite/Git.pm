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
    commit_paths commit_all file_log file_at file_diff count_commits run_git);

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
# GIT_DIR/info/exclude at init. The auth/forms/notify-xmpp/logs entries are the
# SECURITY boundary; cache/backups/locks/git/assets/html/install-state keep the
# history clean of runtime and generated artefacts. The CSRF secret and the
# upload-rate DB are manager runtime state at lazysite/manager/ top level -
# excluded for the same reason as auth/.
my @EXCLUDE = qw(
    /lazysite/auth/
    /lazysite/forms/
    /lazysite/notify-xmpp.conf
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
    my ($iok) = run_git( $docroot, '-c', 'init.defaultBranch=main', 'init', '-q' );
    return { ok => 0, error => 'git init failed' } unless $iok && -d $gd;
    run_git( $docroot, 'config', 'core.worktree', $docroot );
    chmod 02770, $gd;    # CGI-writable, never world-accessible (check-tool probe)

    open my $ex, '>', "$gd/info/exclude"
        or return { ok => 0, error => "Cannot write info/exclude: $!" };
    print {$ex} "# lazysite content history (SM085) - never-versioned paths.\n";
    print {$ex} "# A pushable history must never carry a secret or personal data.\n";
    print {$ex} "$_\n" for @EXCLUDE;
    close $ex;

    my ($aok) = run_git( $docroot, 'add', '-A', '--', '.' );
    return { ok => 0, error => 'git add failed for the adoption commit' } unless $aok;
    my ($cok) = run_git( $docroot, 'commit', '-q', '--allow-empty',
        '-m', 'adopt existing site', '--author', _author($user) );
    return { ok => 0, error => 'the adoption commit failed' } unless $cok;

    reset_cache();
    my ( undef, $sha ) = run_git( $docroot, 'rev-parse', 'HEAD' );
    chomp $sha if defined $sha;
    log_event( 'INFO', 'git-init', 'content history initialised',
        commit => ( $sha // '' ), user => ( $user // '' ) );
    return { ok => 1, commit => $sha };
}

# --- auto-commit ------------------------------------------------------------------

# Stage exactly the named pathspecs and commit. Internal: callers validated (or
# own) the pathspecs. Per-path add so one unmatched pathspec (a never-tracked
# sidecar, an ignored file) cannot abort the batch. Returns 1 if a commit was
# made, 0 otherwise; NEVER dies past the eval - a git failure must not break
# the save that triggered it.
sub _stage_and_commit {
    my ( $docroot, $user, $message, @specs ) = @_;
    my $made = eval {
        my $staged = 0;
        for my $spec (@specs) {
            my ($ok) = run_git( $docroot, 'add', '-A', '--', $spec );
            $staged++ if $ok;
        }
        return 0 unless $staged;
        my ($clean) = run_git( $docroot, 'diff', '--cached', '--quiet' );
        return 0 if $clean;    # exit 0 = nothing staged, nothing to commit
        my ($cok) = run_git( $docroot, 'commit', '-q', '-m', _clean_message($message),
            '--author', _author($user) );
        die "git commit failed\n" unless $cok;
        1;
    };
    unless ( defined $made ) {
        log_event( 'WARN', 'git', 'content-history commit failed (the write itself succeeded)',
            error => ( $@ // 'unknown' ), user => ( $user // '' ) );
        return 0;
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
    return _stage_and_commit( $docroot, $user, $message, @specs );
}

# commit_all: stage the whole versioned set (the backup-restore hook - a
# restore is visible history, not history erasure).
sub commit_all {
    my ( $docroot, $user, $message ) = @_;
    return 0 unless enabled($docroot);
    return _stage_and_commit( $docroot, $user, $message, '.' );
}

# --- reads (repo-absent / disabled = empty or undef, never an error) --------------

# Per-file timeline: [ { sha, epoch, author, subject }, ... ] newest first.
sub file_log {
    my ( $docroot, $path, $limit ) = @_;
    return [] unless enabled($docroot);
    my $rel = _norm_rel($path);
    return [] unless defined $rel;
    $limit = ( defined $limit && $limit =~ /\A\d+\z/ && $limit > 0 ) ? $limit : 50;
    $limit = 200 if $limit > 200;
    my ( $ok, $out ) = run_git( $docroot, 'log', "-n$limit",
        '--format=%H%x09%at%x09%an%x09%s', '--', $rel );
    return [] unless $ok && defined $out;
    my @entries;
    for my $line ( split /\n/, $out ) {
        my ( $sha, $at, $an, $subject ) = split /\t/, $line, 4;
        next unless defined $sha && $sha =~ /\A[0-9a-f]{40}\z/;
        push @entries,
            { sha => $sha, epoch => ( $at // 0 ) + 0, author => ( $an // '' ),
            subject => ( $subject // '' ) };
    }
    return \@entries;
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

sub count_commits {
    my ($docroot) = @_;
    return 0 unless initialised($docroot);
    my ( $ok, $out ) = run_git( $docroot, 'rev-list', '--count', 'HEAD' );
    return 0 unless $ok && defined $out && $out =~ /(\d+)/;
    return $1 + 0;
}

1;
