#!/usr/bin/perl
# Content-history guarantee suite: pins the contract that version recording
# can never SILENTLY cease again (the 2026-07-11 field defect: a pre-0.7.7
# doctor chown left 0755 object dirs, every post-init commit failed, saves
# kept succeeding, and nothing said so). The same guarantee tier as
# t/unit/lib/16-audit-guarantee.t established for the audit trail.
#
# Four angles:
#   1. STRUCTURAL write-path coverage: every content-write operation (manager
#      module action_*, manager-api inline action_*, DAV do_* verb) is
#      classified HERE as hooked (and its body really calls the hook) or
#      exempt with a reason - a future write path fails this test until
#      classified. A representative set is then driven through the real
#      modules asserting the history grows by exactly one commit per
#      operation (a batched operation = one commit).
#   2. MIXED-IDENTITY permanence: after init + commits + a gc cycle under
#      umask 0022, every dir under lazysite/git is group-writable and every
#      file group-readable (mutable files group-writable) - the
#      core.sharedRepository=group promise verified empirically.
#   3. THE TRIPLE NEVER DISAGREES: one induced commit failure is reported in
#      the same state by all surfaces - the WARN, the COMMIT_FAILED
#      breadcrumb, the lazysite-check probe, the content-history plugin's
#      status - and after check --fix plus one successful save all of them
#      recover together, with the new commit present.
#   4. EMPTY-STATE honesty: the Files page renders the failure-suspecting
#      message for an existing file with zero history, and no history UI at
#      all when the feature is disabled.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Find ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root);
use Lazysite::Git ();

my $root = repo_root();

sub t_spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh }
sub t_slurp { open my $fh, '<', $_[0] or return undef; local $/; my $t = <$fh>; close $fh; $t }

sub src_of {
    my ($file) = @_;
    open my $fh, '<', $file or die "$file: $!";
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

# Extract top-level sub bodies matching a name pattern; a body runs to the
# next `sub ` at column 0 (the 16-audit-guarantee.t approach).
sub sub_bodies {
    my ( $src, $name_re ) = @_;
    my %body;
    while ( $src =~ /^sub\s+(\w+)\s*\{(.*?)(?=^sub\s|\z)/msg ) {
        my ( $name, $b ) = ( $1, $2 );    # copy first: the filter match resets $1
        $body{$name} = $b if $name =~ $name_re;
    }
    return \%body;
}

my $HOOK_RE = qr/\b_git_commit\s*\(
    | \bLazysite::Git::(?:commit_paths|commit_all|init)\s*\(/x;

# =========================================================================
# 1a. Structural registry: every write path classified hooked-or-exempt
# =========================================================================
#
# THE WRITE-PATH REGISTRY. Adding an action/verb to any scanned surface
# without classifying it here fails the build. "Hooked" means the sub body
# itself calls the content-history hook (verified below). Exempt entries
# carry the reason they are allowed to skip the hook.
my %HOOKED = map { $_ => 1 } qw(
    Files::action_save
    Files::action_delete
    Files::action_move
    Files::action_copy
    Files::action_migrate_to_local
    Files::action_git_init
    Upload::action_file_upload
    Backups::action_backup_restore
    Plugins::action_plugin_save
    API::action_config_set
    API::action_nav_save
    DAV::do_put
    DAV::do_delete
    DAV::do_copy_move
);

my %EXEMPT = (
    # --- Files ---
    'Files::action_list'         => 'read-only',
    'Files::action_read'         => 'read-only',
    'Files::action_aliases_list' => 'read-only',
    'Files::action_acl_get'      => 'read-only',
    'Files::action_git_status'   => 'read-only',
    'Files::action_git_history'  => 'read-only',
    'Files::action_git_show'     => 'read-only',
    'Files::action_mkdir'   => 'creates an empty directory - git cannot track one',
    'Files::action_acl_set' => 'ACL sidecar store (permissions metadata, not page '
        . 'content; swept by the next commit_all capture)',
    'Files::action_acl_remove' => 'ACL sidecar store (as action_acl_set)',
    'Files::action_git_restore' =>
        'commits via its pass through action_save (asserted behaviourally '
        . 'in t/unit/manager/25-git-actions.t)',
    # --- Upload ---
    'Upload::action_file_download'     => 'read-only',
    'Upload::action_file_zip_download' => 'read-only',
    # --- Backups ---
    'Backups::action_backup_list'     => 'read-only',
    'Backups::action_backup_download' => 'read-only',
    'Backups::action_backup_create' =>
        'writes only under lazysite/backups/ - excluded from the versioned set',
    # --- Plugins ---
    'Plugins::action_plugin_list'       => 'read-only',
    'Plugins::action_plugin_read'       => 'read-only',
    'Plugins::action_plugin_action' => 'dispatches a plugin child process; a plugin '
        . 'that mutates content owns its capture (git-sync commits via Lazysite::Git '
        . 'and snapshots before any apply)',
    'Plugins::action_handler_list'      => 'read-only',
    'Plugins::action_form_targets_read' => 'read-only',
    'Plugins::action_plugin_enable' => 'rewrites the plugins: list in lazysite.conf '
        . 'without a commit (pre-existing; folded into the next capture sweep)',
    'Plugins::action_plugin_disable' => 'as action_plugin_enable',
    'Plugins::action_handler_save' =>
        'writes under lazysite/forms/ - excluded from the versioned set',
    'Plugins::action_handler_delete'    => 'as action_handler_save',
    'Plugins::action_form_targets_save' => 'as action_handler_save',
    # --- Layouts / Themes (artifact trees: captured wholesale by the
    #     commit_all sweeps, not per-action hooks - pre-existing design) ---
    'Layouts::action_layouts_releases'         => 'read-only',
    'Layouts::action_layouts_release_contents' => 'read-only',
    'Layouts::action_layouts_available'        => 'read-only',
    'Layouts::action_themes_for_layout'        => 'read-only',
    'Layouts::action_layouts_repo_get'         => 'read-only',
    'Layouts::action_layouts_manifest'         => 'read-only',
    'Layouts::action_layouts_install'          => 'layout/theme artifact write (capture-swept)',
    'Layouts::action_layout_install'           => 'layout/theme artifact write (capture-swept)',
    'Layouts::action_layout_delete'            => 'layout/theme artifact write (capture-swept)',
    'Layouts::action_artifact_backups_delete'  => 'layout/theme artifact write (capture-swept)',
    'Layouts::action_layouts_repo_set' => 'conf write without a commit (pre-existing; '
        . 'folded into the next capture sweep)',
    'Themes::action_theme_list'        => 'read-only',
    'Themes::action_themes_list_all'   => 'read-only',
    'Themes::action_cache_list'        => 'read-only',
    'Themes::action_artifact_manifest' => 'read-only',
    'Themes::action_artifact_validate' => 'read-only',
    'Themes::action_theme_activate'    => 'layout/theme artifact write (capture-swept)',
    'Themes::action_layout_activate'   => 'layout/theme artifact write (capture-swept)',
    'Themes::action_theme_delete'      => 'layout/theme artifact write (capture-swept)',
    'Themes::action_theme_rename'      => 'layout/theme artifact write (capture-swept)',
    'Themes::action_theme_upload'      => 'layout/theme artifact write (capture-swept)',
    'Themes::action_cache_invalidate' =>
        'removes generated *.html - excluded from the versioned set',
    # --- Sessions ---
    'Sessions::action_sessions_list' => 'read-only',
    'Sessions::action_session_revoke' =>
        'auth store write - lazysite/auth/ is excluded from the versioned set',
    'Sessions::action_user_revoke' => 'as action_session_revoke',
    # --- manager-api inline ---
    'API::action_preview_grant' => 'preview grant state, not site content',
    'API::action_preview_clear' => 'preview grant state, not site content',
    'API::action_preview'       => 'read-only',
    'API::action_notices'       => 'read-only',
    'API::action_notices_seen' =>
        'notice-seen marker under lazysite/manager, not page content',
    'API::action_pages'                 => 'read-only',
    'API::action_config_read'           => 'read-only',
    'API::action_describe_capabilities' => 'read-only',
    'API::action_whoami'                => 'read-only',
    'API::action_recent_changes'        => 'read-only',
    'API::action_audit'                 => 'read-only',
    'API::action_analyse_visitors'      => 'read-only',
    'API::action_version'               => 'read-only',
    'API::action_principals'            => 'read-only',
    'API::action_users'                 => 'auth store - excluded from the versioned set',
    'API::action_rotate_auth_secret'    => 'auth store - excluded from the versioned set',
    'API::action_nav_read'              => 'read-only',
    # --- DAV verbs ---
    'DAV::do_options'   => 'read-only',
    'DAV::do_propfind'  => 'read-only',
    'DAV::do_get'       => 'read-only',
    'DAV::do_proppatch' => 'property response only - writes no content',
    'DAV::do_mkcol'     => 'creates an empty directory - git cannot track one',
    'DAV::do_lock'      => 'lock sidecars under lazysite/manager/locks - excluded',
    'DAV::do_unlock'    => 'as do_lock',
);

subtest 'write-path registry: every action/verb classified, hooks verified' => sub {
    my %surface = (
        Files    => [ "$root/lib/Lazysite/Manager/Files.pm",    qr/^action_/ ],
        Upload   => [ "$root/lib/Lazysite/Manager/Upload.pm",   qr/^action_/ ],
        Backups  => [ "$root/lib/Lazysite/Manager/Backups.pm",  qr/^action_/ ],
        Plugins  => [ "$root/lib/Lazysite/Manager/Plugins.pm",  qr/^action_/ ],
        Layouts  => [ "$root/lib/Lazysite/Manager/Layouts.pm",  qr/^action_/ ],
        Themes   => [ "$root/lib/Lazysite/Manager/Themes.pm",   qr/^action_/ ],
        Sessions => [ "$root/lib/Lazysite/Manager/Sessions.pm", qr/^action_/ ],
        API      => [ "$root/lazysite-manager-api.pl",          qr/^action_/ ],
        DAV      => [ "$root/lazysite-dav.pl",                  qr/^do_/ ],
    );

    my ( %seen, @unclassified, @unhooked, @overhooked );
    for my $tag ( sort keys %surface ) {
        my ( $file, $re ) = @{ $surface{$tag} };
        my $bodies = sub_bodies( src_of($file), $re );
        for my $name ( sort keys %{$bodies} ) {
            my $id = "$tag\::$name";
            $seen{$id} = 1;
            if ( $HOOKED{$id} ) {
                push @unhooked, $id unless $bodies->{$name} =~ $HOOK_RE;
            }
            elsif ( exists $EXEMPT{$id} ) {
                # Drift the other way: an exempt sub that now calls the hook
                # must be reclassified (its exemption reason is stale).
                push @overhooked, $id if $bodies->{$name} =~ $HOOK_RE;
            }
            else {
                push @unclassified, $id;
            }
        }
    }
    ok( scalar keys %seen > 60, 'write surfaces enumerated from source' );
    ok( !@unclassified,
        'no unclassified write path (each is hooked or exempt-with-reason)' )
        or diag "UNCLASSIFIED (classify in the registry): @unclassified";
    ok( !@unhooked, 'every registered-hooked sub really calls the hook' )
        or diag "REGISTERED HOOKED BUT NO HOOK CALL: @unhooked";
    ok( !@overhooked, 'no exempt sub silently gained a hook (stale exemption)' )
        or diag "EXEMPT BUT HOOKED (reclassify): @overhooked";

    my @stale = grep { !$seen{$_} } ( sort keys %HOOKED, sort keys %EXEMPT );
    ok( !@stale, 'registry names only real subs (no stale entries)' )
        or diag "STALE: @stale";
    my @both = grep { $HOOKED{$_} } sort keys %EXEMPT;
    ok( !@both, 'no sub is both hooked and exempt' ) or diag "IN BOTH: @both";
};

# =========================================================================
# Everything below drives real git.
# =========================================================================
if ( !Lazysite::Git::git_available() ) {
    diag 'git not installed on this host - behavioural guarantees not exercised';
    done_testing();
    exit 0;
}

sub mksite {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite/manager/locks", "$d/lazysite/cache" );
    t_spit( "$d/lazysite/lazysite.conf", "site_name: T\ngit_history: enabled\n" );
    t_spit( "$d/lazysite/nav.conf",      "Home | /\n" );
    t_spit( "$d/index.md",               "home\n" );
    Lazysite::Git::reset_cache();
    return $d;
}

sub commits { return Lazysite::Git::count_commits( $_[0] ) }

# =========================================================================
# 1b. Behavioural: one commit per operation, batched ops = one commit
# =========================================================================
subtest 'representative write paths: history grows by exactly one per operation' => sub {
    my $d = mksite();
    require Lazysite::Manager::Files;
    require Lazysite::Manager::Backups;
    local $Lazysite::Manager::Files::DOCROOT   = $d;
    local $Lazysite::Manager::Files::LOCK_DIR  = "$d/lazysite/manager/locks";
    local $Lazysite::Manager::Files::auth_user = 'alice';
    local $Lazysite::Manager::Common::DOCROOT  = $d;    # validate_path/deny lists
    local $Lazysite::Auth::Acl::DOCROOT        = $d;    # per-file ACL store
    local $Lazysite::Manager::Backups::DOCROOT      = $d;
    local $Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";
    local $Lazysite::Manager::Backups::auth_user    = 'alice';

    my $r = Lazysite::Git::init( $d, 'alice' );
    ok( $r->{ok}, 'init (adoption commit)' ) or diag $r->{error};
    Lazysite::Git::reset_cache();
    is( commits($d), 1, 'adoption = 1 commit' );

    my $step = sub {
        my ( $label, $expect_delta, $code ) = @_;
        my $before = commits($d);
        my $res    = $code->();
        ok( ref $res ne 'HASH' || $res->{ok}, "$label succeeds" )
            or diag explain $res;
        is( commits($d) - $before, $expect_delta, "$label -> +$expect_delta commit(s)" );
    };

    $step->( 'save (create)', 1, sub {
        Lazysite::Manager::Files::action_save( 'note.md', 'alice', "v1\n", undef ) } );
    $step->( 'save (edit)', 1, sub {
        Lazysite::Manager::Files::action_save( 'note.md', 'alice', "v2\n", undef ) } );
    $step->( 'copy', 1, sub {
        Lazysite::Manager::Files::action_copy( 'note.md', 'note-copy.md', 'alice' ) } );
    $step->( 'move', 1, sub {
        Lazysite::Manager::Files::action_move( 'note-copy.md', 'moved.md', 'alice' ) } );
    $step->( 'delete', 1, sub {
        Lazysite::Manager::Files::action_delete( 'moved.md', 'alice' ) } );

    # backup create is NOT a commit (it writes only under the excluded
    # lazysite/backups/); the restore that changes the worktree IS one.
    my $backup;
    $step->( 'backup create', 0, sub {
        my $b = Lazysite::Manager::Backups::action_backup_create('manual');
        $backup = $b->{name};
        $b } );
    $step->( 'delete before restore', 1, sub {
        Lazysite::Manager::Files::action_delete( 'note.md', 'alice' ) } );
    $step->( 'backup restore', 1, sub {
        Lazysite::Manager::Backups::action_backup_restore($backup) } );
    ok( -f "$d/note.md", 'the restore brought the page back' );

    # A batched operation is ONE commit carrying every path.
    t_spit( "$d/a.md", "a\n" );
    t_spit( "$d/b.md", "b\n" );
    $step->( 'batched commit_paths (2 paths)', 1, sub {
        Lazysite::Git::commit_paths( $d, 'alice', 'upload 2 files', 'a.md', 'b.md' ) } );
    my ( $ok, $names ) =
        Lazysite::Git::run_git( $d, 'show', '--name-only', '--format=', 'HEAD' );
    ok( $ok, 'newest commit readable' );
    like( $names, qr/^a\.md$/m, 'batch commit carries the first path' );
    like( $names, qr/^b\.md$/m, 'batch commit carries the second path' );

    is( commits($d), 9, 'exactly the expected total - no silent extra or missing commits' );
};

# =========================================================================
# 2. Mixed-identity permanence under umask 0022 (incl. a gc cycle)
# =========================================================================
subtest 'shared-repo promise: group access survives commits and gc under umask 0022' => sub {
    my $old = umask 0022;
    my $d   = mksite();
    my $r   = Lazysite::Git::init( $d, 'alice' );
    ok( $r->{ok}, 'init under umask 0022' ) or diag $r->{error};
    Lazysite::Git::reset_cache();
    for my $n ( 1 .. 3 ) {
        t_spit( "$d/p$n.md", "v$n\n" );
        Lazysite::Git::commit_paths( $d, 'alice', "create p$n.md", "p$n.md" );
    }
    my ( $gok ) = Lazysite::Git::run_git( $d, 'gc', '-q' );
    ok( $gok, 'gc/repack cycle ran' );
    umask $old;

    my ( undef, $shared ) =
        Lazysite::Git::run_git( $d, 'config', '--get', 'core.sharedRepository' );
    chomp( $shared //= '' );
    like( $shared, qr/\A(?:group|1|true)\z/i, 'core.sharedRepository is set at init' );

    my $gd = Lazysite::Git::git_dir($d);
    my ( @baddir, @badread, @badwrite );
    File::Find::find(
        { no_chdir => 1,
            wanted => sub {
                my $p = $File::Find::name;
                my @s = lstat $p or return;
                return if -l _;
                my $mode = $s[2] & 07777;
                if ( -d _ ) {
                    push @baddir, $p unless ( $mode & 0020 ) && ( $mode & 0010 );
                    return;
                }
                push @badread, $p unless $mode & 0040;
                # Loose objects and packs are deliberately read-only; every
                # OTHER file (refs, logs, index, HEAD, exclude...) must be
                # group-writable for the second identity.
                push @badwrite, $p
                    unless index( $p, "$gd/objects/" ) == 0 || $mode & 0020;
            },
        },
        $gd );
    ok( !@baddir, 'every dir under lazysite/git is group-writable + traversable' )
        or diag join "\n", @baddir;
    ok( !@badread, 'every file under lazysite/git is group-readable' )
        or diag join "\n", @badread;
    ok( !@badwrite, 'every mutable (non-object) file is group-writable' )
        or diag join "\n", @badwrite;
};

# =========================================================================
# 3. The triple never disagrees: WARN + breadcrumb + probe + plugin status
# =========================================================================
subtest 'one induced failure, every surface agrees; one fix, every surface recovers' => sub {
    my $d = mksite();
    require Lazysite::Manager::Files;
    local $Lazysite::Manager::Files::DOCROOT   = $d;
    local $Lazysite::Manager::Files::LOCK_DIR  = "$d/lazysite/manager/locks";
    local $Lazysite::Manager::Files::auth_user = 'alice';
    local $Lazysite::Manager::Common::DOCROOT  = $d;
    local $Lazysite::Auth::Acl::DOCROOT        = $d;
    my $r = Lazysite::Git::init( $d, 'alice' );
    ok( $r->{ok}, 'init ok' );
    Lazysite::Git::reset_cache();
    my $gd = Lazysite::Git::git_dir($d);
    chmod 0664, "$d/lazysite/lazysite.conf", "$d/lazysite/nav.conf";    # keep the doctor quiet

    my $grp = getgrgid( ( stat $d )[5] ) // ( stat $d )[5];
    my $check  = sub { qx($^X "$root/tools/lazysite-check.pl" --docroot "$d" --group $grp @_ 2>&1) };
    my $status = sub {
        my $out = qx($^X "$root/plugins/content-history.pl" --scan --docroot "$d");
        return eval { decode_json($out) } // {};
    };

    # Induce the field failure: the CGI cannot write the object store.
    chmod 0555, "$gd/objects";

    my $warn  = '';
    my $saved = do {
        local *STDERR;
        open STDERR, '>', \$warn or die $!;
        Lazysite::Manager::Files::action_save( 'page.md', 'alice', "one\n", undef );
    };
    ok( $saved->{ok}, 'the save itself still succeeds (WARN-and-proceed contract)' );
    like( $warn, qr/content-history commit failed/,
        'surface 1: the WARN is emitted, naming the failure' );
    ok( -e "$gd/COMMIT_FAILED", 'surface 2: the COMMIT_FAILED breadcrumb is present' );
    my $out = $check->();
    like( $out, qr/SILENTLY NOT RECORDED/,
        'surface 3: the check probe FAILs naming the symptom' );
    like( $out, qr/COMMIT_FAILED.*missing from the history/s,
        'surface 3: the check reads the breadcrumb too' );
    isnt( $? >> 8, 0, 'check exits non-zero' );
    my $st = $status->();
    ok( $st->{recording_failed}, 'surface 4: plugin status says recording is failing' );
    like( $st->{message}, qr/FAILED/, 'plugin status message says so in plain language' );
    is( scalar @{ Lazysite::Git::file_log( $d, 'page.md' ) },
        0, 'and indeed: no version was recorded' );

    # Repair + one successful save: every surface recovers together.
    my $fix = $check->('--fix');
    like( $fix, qr/restored group access on \d+ path\(s\) under lazysite\/git/,
        '--fix repairs the repo perms' );
    like( $fix, qr/0 failure\(s\)/, 'post-fix report shows no failures' );

    my $warn2 = '';
    my $saved2 = do {
        local *STDERR;
        open STDERR, '>', \$warn2 or die $!;
        Lazysite::Manager::Files::action_save( 'page.md', 'alice', "two\n", undef );
    };
    ok( $saved2->{ok}, 'the next save succeeds' );
    unlike( $warn2, qr/commit failed/, 'no WARN on the healthy path' );
    ok( !-e "$gd/COMMIT_FAILED", 'breadcrumb cleared by the successful commit' );
    my $log = Lazysite::Git::file_log( $d, 'page.md' );
    is( $log->[0]{subject}, 'edit page.md', 'the new commit is in the history' );
    my $st2 = $status->();
    ok( $st2->{ok} && !$st2->{recording_failed}, 'plugin status healthy again' );
    unlike( $st2->{message}, qr/FAILED/, 'no failure language once recovered' );
    my $out2 = $check->();
    like( $out2, qr/the repo is usable by the CGI/, 'check probe ok again' );
    unlike( $out2, qr/COMMIT_FAILED/, 'check no longer reports the breadcrumb' );
};

# =========================================================================
# 4. Empty-state honesty on the Files page (pinned strings)
# =========================================================================
subtest 'Files page: truthful empty state, no history UI when disabled' => sub {
    my $src = src_of("$root/starter/manager/files.md");
    like( $src, qr/No versions recorded for this file\. If it was changed after\s+history was enabled, version recording may be failing/,
        'zero-history empty state suspects a recording failure' );
    like( $src, qr/run <code>lazysite check<\/code>/,
        'and points at the doctor' );
    unlike( $src, qr/No history for this file yet/,
        'the old benign wording is gone' );
    like( $src, qr/GIT\.enabled && isEditable\(f\.name\)\s*\?.*History/,
        'the History control renders only when the feature is enabled' );
};

done_testing();
