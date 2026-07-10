#!/usr/bin/perl
# SM085 phase 1: Lazysite::Git - the content-history core. What matters:
# init writes the never-versioned exclude list (the SECURITY-critical entries
# asserted literally), commits carry the acting user and a terse message,
# the read functions have stable shapes and refuse bad shas/paths, disabled
# means no-op, and a host without git degrades cleanly (mocked PATH).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Git ();

sub spit  { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh }
sub slurp { open my $fh, '<', $_[0] or return undef; local $/; my $t = <$fh>; close $fh; $t }

sub site {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/content", "$d/lazysite/auth", "$d/lazysite/forms",
        "$d/lazysite/cache", "$d/lazysite/logs", "$d/lazysite/manager/locks" );
    spit( "$d/lazysite/lazysite.conf",   "site_name: T\ngit_history: enabled\n" );
    spit( "$d/lazysite/nav.conf",        "Home | /\n" );
    spit( "$d/lazysite/auth/users",      "alice:hash\n" );
    spit( "$d/lazysite/auth/.secret",    "sekret\n" );
    spit( "$d/lazysite/forms/smtp.conf", "password: pw\n" );
    spit( "$d/lazysite/notify-xmpp.conf", "password: pw\n" );
    spit( "$d/lazysite/logs/access.log", "1.2.3.4\n" );
    spit( "$d/content/about.md",         "hello v1\n" );
    spit( "$d/content/about.html",       "<html>generated</html>" );
    spit( "$d/index.md",                 "home\n" );
    return $d;
}

# --- clean degradation with git absent (mocked PATH) -------------------------
{
    my $d = site();
    my $emptybin = tempdir( CLEANUP => 1 );
    local $ENV{PATH} = $emptybin;
    Lazysite::Git::reset_cache();
    ok( !Lazysite::Git::git_available(), 'git_available false on a PATH without git' );
    my $r = Lazysite::Git::init( $d, 'installer' );
    ok( !$r->{ok}, 'init refuses without a git binary' );
    like( $r->{error}, qr/git/i, 'init names git in the error' );
    ok( !-d "$d/lazysite/git", 'no repo dir created' );
    is( Lazysite::Git::enabled($d), 0, 'not enabled without an initialised repo' );
    my $c = eval { Lazysite::Git::commit_paths( $d, 'alice', 'edit x', 'index.md' ) };
    is( $@, '', 'commit_paths does not die without git' );
    ok( !$c, 'commit_paths is a no-op without git' );
    is_deeply( Lazysite::Git::file_log( $d, 'index.md' ), [], 'file_log empty without a repo' );
    is( Lazysite::Git::file_at( $d, 'a' x 40, 'index.md' ), undef, 'file_at undef without a repo' );
}

Lazysite::Git::reset_cache();
plan skip_all => 'git not installed on this host' unless Lazysite::Git::git_available();

# --- init: repo placement, exclude list, adoption commit ---------------------
my $d = site();
{
    my $r = Lazysite::Git::init( $d, 'installer' );
    ok( $r->{ok}, 'init succeeds' ) or diag explain $r;
    like( $r->{commit}, qr/\A[0-9a-f]{40}\z/, 'init reports the adoption commit sha' );
    ok( -f "$d/lazysite/git/HEAD", 'GIT_DIR lives at lazysite/git (never under a served path)' );
    ok( !-e "$d/.git", 'no .git under the docroot' );

    my $mode = ( stat "$d/lazysite/git" )[2] & 07777;
    is( $mode & 0007, 0, 'lazysite/git is not world-accessible' );

    my $excl = slurp("$d/lazysite/git/info/exclude") // '';
    # SECURITY-critical exclusions, asserted literally (a pushable history must
    # never carry a secret or personal data).
    like( $excl, qr{^/lazysite/auth/$}m,             'exclude: lazysite/auth/ (credentials, secrets)' );
    like( $excl, qr{^/lazysite/forms/$}m,            'exclude: lazysite/forms/ (submission PII, SMTP secret)' );
    like( $excl, qr{^/lazysite/notify-xmpp\.conf$}m, 'exclude: notify-xmpp.conf (XMPP password)' );
    like( $excl, qr{^/lazysite/cache/$}m,            'exclude: lazysite/cache/' );
    like( $excl, qr{^/lazysite/logs/$}m,             'exclude: lazysite/logs/ (visitor data)' );
    like( $excl, qr{^/lazysite/backups/$}m,          'exclude: lazysite/backups/' );
    like( $excl, qr{^/lazysite/manager/locks/$}m,    'exclude: lazysite/manager/locks/' );
    like( $excl, qr{^/lazysite/manager/\.csrf-secret$}m, 'exclude: the CSRF secret' );
    like( $excl, qr{^/lazysite/git/$}m,              'exclude: the repo itself' );
    like( $excl, qr{^/lazysite-assets/$}m,           'exclude: lazysite-assets/ mirrors' );
    like( $excl, qr{^\*\.html$}m,                    'exclude: generated *.html' );
    like( $excl, qr{^\.install-state}m,              'exclude: .install-state artefacts' );
    like( $excl, qr{^/lazysite/aliases\.json$}m,     'exclude: aliases.json (regenerable)' );

    is( Lazysite::Git::enabled($d), 1, 'enabled: conf key + initialised repo' );

    # The adoption commit captured the versioned set and nothing excluded.
    my ( $ok, $files ) = Lazysite::Git::run_git( $d, 'ls-files' );
    ok( $ok, 'run_git ls-files works (the sync-plugin plumbing)' );
    like( $files,   qr{^content/about\.md$}m,      'versioned: content page' );
    like( $files,   qr{^lazysite/lazysite\.conf$}m, 'versioned: lazysite.conf' );
    like( $files,   qr{^lazysite/nav\.conf$}m,      'versioned: nav.conf' );
    unlike( $files, qr{^lazysite/auth/},            'NOT versioned: auth store' );
    unlike( $files, qr{^lazysite/forms/},           'NOT versioned: forms' );
    unlike( $files, qr{^lazysite/logs/},            'NOT versioned: logs' );
    unlike( $files, qr{\.html$},                    'NOT versioned: generated html' );
    unlike( $files, qr{^lazysite/git/},             'NOT versioned: the repo itself' );

    my $l = Lazysite::Git::file_log( $d, 'content/about.md' );
    is( scalar @{$l}, 1, 'one history entry after adoption' );
    is( $l->[0]{subject}, 'adopt existing site', 'adoption commit message' );
    is( $l->[0]{author},  'installer',           'adoption commit author' );

    my $again = Lazysite::Git::init( $d, 'installer' );
    ok( !$again->{ok}, 'a second init is refused' );
}

# --- commit_paths: attribution, message, shapes -------------------------------
my ( $sha_v1, $sha_v2 );
{
    $sha_v1 = Lazysite::Git::file_log( $d, 'content/about.md' )->[0]{sha};
    spit( "$d/content/about.md", "hello v2\n" );
    ok( Lazysite::Git::commit_paths( $d, 'alice', 'edit content/about.md', 'content/about.md' ),
        'commit_paths commits a changed path' );
    my $l = Lazysite::Git::file_log( $d, 'content/about.md' );
    is( scalar @{$l}, 2, 'two entries after an edit' );
    is( $l->[0]{subject}, 'edit content/about.md', 'terse action message' );
    is( $l->[0]{author},  'alice',                 'acting user is the author' );
    like( $l->[0]{sha}, qr/\A[0-9a-f]{40}\z/, 'sha shape' );
    cmp_ok( abs( time() - $l->[0]{epoch} ), '<', 300, 'epoch is a sane unix time' );
    $sha_v2 = $l->[0]{sha};

    # author line is "user <user@lazysite>"
    my ( undef, $an ) = Lazysite::Git::run_git( $d, 'log', '-n1', '--format=%an <%ae>' );
    chomp( $an //= '' );
    is( $an, 'alice <alice@lazysite>', 'author identity is user <user@lazysite>' );

    ok( !Lazysite::Git::commit_paths( $d, 'alice', 'noop', 'content/about.md' ),
        'nothing changed = no commit' );
    ok( !Lazysite::Git::commit_paths( $d, 'alice', 'gone', 'content/never-existed.md' ),
        'a pathspec that matches nothing is tolerated (no die, no commit)' );

    # a delete is a commit too (stage -A picks up the removal)
    unlink "$d/index.md";
    ok( Lazysite::Git::commit_paths( $d, 'alice', 'delete index.md', 'index.md' ),
        'a deletion commits' );
}

# --- file_at / file_diff -------------------------------------------------------
{
    is( Lazysite::Git::file_at( $d, $sha_v1, 'content/about.md' ), "hello v1\n",
        'file_at returns the historic content' );
    is( Lazysite::Git::file_at( $d, substr( $sha_v1, 0, 7 ), 'content/about.md' ),
        "hello v1\n", 'a 7-char abbreviated sha works' );

    spit( "$d/content/about.md", "hello v3\n" );    # worktree change, uncommitted
    my $diff = Lazysite::Git::file_diff( $d, $sha_v1, 'content/about.md' );
    like( $diff, qr/^-hello v1$/m, 'diff shows the historic line removed' );
    like( $diff, qr/^\+hello v3$/m, 'diff is against the current worktree' );
    my $same = Lazysite::Git::file_diff( $d, $sha_v2, 'content/never-existed.md' );
    is( $same // '', '', 'diff of an unknown path is empty, not an error' );
}

# --- validation refusals --------------------------------------------------------
{
    is( Lazysite::Git::file_at( $d, 'HEAD',  'content/about.md' ), undef, 'symbolic rev refused (sha regex)' );
    is( Lazysite::Git::file_at( $d, 'zz123', 'content/about.md' ), undef, 'non-hex sha refused' );
    is( Lazysite::Git::file_at( $d, $sha_v1, '../etc/passwd' ),    undef, 'traversal path refused' );
    is( Lazysite::Git::file_at( $d, $sha_v1, '-oops' ),            undef, 'option-shaped path refused' );
    is_deeply( Lazysite::Git::file_log( $d, '../outside.md' ), [], 'file_log refuses traversal' );
    is_deeply( Lazysite::Git::file_log( $d, '' ),               [], 'file_log refuses an empty path' );
    my $before = Lazysite::Git::count_commits($d);
    ok( !Lazysite::Git::commit_paths( $d, 'alice', 'x', '../outside.md' ),
        'commit_paths refuses traversal' );
    is( Lazysite::Git::count_commits($d), $before, 'no commit was made for a refused path' );
}

# --- disabled = no-ops -----------------------------------------------------------
{
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );    # key removed
    Lazysite::Git::reset_cache();
    is( Lazysite::Git::enabled($d), 0, 'conf key off = disabled (repo still on disk)' );
    my $before = Lazysite::Git::count_commits($d);
    spit( "$d/content/about.md", "hello v4\n" );
    ok( !Lazysite::Git::commit_paths( $d, 'alice', 'edit', 'content/about.md' ),
        'commit_paths no-ops when disabled' );
    is_deeply( Lazysite::Git::file_log( $d, 'content/about.md' ), [],
        'file_log empty when disabled' );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\ngit_history: enabled\n" );
    Lazysite::Git::reset_cache();
    is( Lazysite::Git::count_commits($d), $before, 'nothing was committed while disabled' );
}

# --- commit_all (the backup-restore hook) -----------------------------------------
{
    spit( "$d/content/extra.md", "restored\n" );
    ok( Lazysite::Git::commit_all( $d, 'admin', 'restore from backup manual-x.tar.gz' ),
        'commit_all commits the whole versioned set' );
    my $l = Lazysite::Git::file_log( $d, 'content/extra.md' );
    is( $l->[0]{subject}, 'restore from backup manual-x.tar.gz', 'restore message recorded' );
    is( $l->[0]{author},  'admin', 'restore attributed to the acting user' );
}

done_testing();
