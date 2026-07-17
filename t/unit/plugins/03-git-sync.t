#!/usr/bin/perl
# SM085 phase 1 (sync half): plugins/git-sync.pl - push/pull the content
# history to an operator-configured remote. What matters: the descriptor
# (password-typed token field = the 0660 config rule; the pull action declares
# its keep_mine/take_theirs choices), remote-address validation refusals
# (https / git@host:path / ssh:// only - never javascript:/file:/arbitrary
# schemes), push lands commits on a local bare remote with the stored remote
# URL carrying NO token, a fast-forward pull applies + invalidates caches +
# reindexes aliases behind a safety snapshot, a diverged pull reports the
# plain-language conflict list WITHOUT touching the worktree until the
# operator chooses, keep_mine/take_theirs resolve as specified, the token
# config file is never versioned (so it can never be pushed), and no
# operator-facing string uses git vocabulary. All remotes are LOCAL bare
# repos (test seam LAZYSITE_GIT_SYNC_ALLOW_LOCAL) - no network anywhere.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Git ();

my $ROOT   = "$FindBin::Bin/../../..";
my $PLUGIN = "$ROOT/plugins/git-sync.pl";
ok( -f $PLUGIN, 'git-sync plugin present' );

sub t_spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh }
sub t_slurp { open my $fh, '<', $_[0] or return undef; local $/; my $t = <$fh>; close $fh; $t }

# Run the plugin exactly as action_plugin_action does (child process, JSON on
# stdout), list-form - no shell.
sub run_plugin {
    my (@args) = @_;
    open my $fh, '-|', $^X, $PLUGIN, @args or die "cannot run plugin: $!";
    my $out = do { local $/; <$fh> };
    close $fh;
    my $r = eval { decode_json($out) };
    return $r // { ok => 0, error => "no JSON output: " . ( $out // '' ) };
}

# The operator-facing vocabulary contract: no git terms, ever.
sub vocab_ok {
    my ( $msg, $label ) = @_;
    unlike( $msg // '', qr/\b(?:git|merge|rebase|branch|repository|commit|fetch[- ]first|fast[- ]forward)\b/i,
        "$label: no git vocabulary" );
}

# --- descriptor ---------------------------------------------------------------
{
    my $desc = run_plugin('--describe');
    is( $desc->{id},          'git-sync',               '--describe: id' );
    is( $desc->{config_file}, 'lazysite/git-sync.conf', '--describe: config file' );
    my %field = map { $_->{key} => $_ } @{ $desc->{config_schema} // [] };
    ok( $field{remote_url}, 'schema: remote_url field' );
    is( $field{branch}{default}, 'main', 'schema: branch defaults to main' );
    is( $field{auth_token}{type}, 'password',
        'schema: auth_token is password-typed (triggers the 0660 config-file rule)' );
    my %act = map { $_->{id} => $_ } @{ $desc->{actions} // [] };
    ok( $act{test} && $act{push} && $act{pull}, 'actions: test / push / pull' );
    is( $act{push}{run}, 'action', 'push runs in action mode' );
    is( $act{pull}{run}, 'action', 'pull runs in action mode' );
    my @choices = map { $_->{id} } @{ $act{pull}{choices} // [] };
    is_deeply( [ sort @choices ], [ 'keep_mine', 'take_theirs' ],
        'pull declares the keep_mine / take_theirs choices' );
    vocab_ok( join( ' ', map { $_->{label} } values %act ), 'action labels' );
}

# --- remote-address validation (direct unit calls, modulino) -------------------
require $PLUGIN;
{
    ok( main::valid_remote_url('https://forge.example.com/site/content.git'), 'https accepted' );
    ok( main::valid_remote_url('https://forge.example.com:3000/site/content'), 'https with port accepted' );
    ok( main::valid_remote_url('git@forge.example.com:site/content.git'), 'scp-style accepted' );
    ok( main::valid_remote_url('ssh://git@forge.example.com/site/content.git'), 'ssh:// accepted' );
    ok( !main::valid_remote_url('javascript:alert(1)'), 'javascript: refused' );
    ok( !main::valid_remote_url('file:///etc/passwd'),  'file: refused' );
    ok( !main::valid_remote_url('http://host/x'),       'plain http refused' );
    ok( !main::valid_remote_url('https://u:tok@host/x'), 'https with embedded credentials refused' );
    ok( !main::valid_remote_url('gopher://host/x'),       'arbitrary scheme refused' );
    ok( !main::valid_remote_url('-oProxyCommand=evil'),   'option-shaped value refused' );
    ok( !main::valid_remote_url('https://host/x;rm -rf'), 'shell metacharacters refused' );
    ok( !main::valid_remote_url('/srv/somewhere'), 'local path refused without the test seam' );
    ok( !main::valid_remote_url(''),               'empty refused' );
    local $ENV{LAZYSITE_GIT_SYNC_ALLOW_LOCAL} = 1;
    ok( main::valid_remote_url('/srv/somewhere'), 'local path accepted under the test seam' );
}

# --- the askpass helper: no secret in the file, tight mode, env-fed ------------
{
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/git");
    my $helper = main::_write_askpass($d);
    ok( $helper && -f $helper, 'askpass helper written' );
    is( ( ( stat $helper )[2] & 07777 ), 0700, 'helper is 0700' );
    my $body = t_slurp($helper);
    like( $body, qr/LAZYSITE_GIT_SYNC_TOKEN/, 'helper reads the token from the environment' );
    unlike( $body, qr/sekrit/, 'helper file itself carries no secret' );
    unlink $helper;
}

plan skip_all => 'git not installed on this host' unless Lazysite::Git::git_available();

$ENV{LAZYSITE_GIT_SYNC_ALLOW_LOCAL} = 1;
$ENV{LAZYSITE_ACTING_USER}          = 'alice';

my $TOKEN = 'sekrit-token-123';

sub mksite {
    my ($d) = @_;
    $d //= tempdir( CLEANUP => 1 );
    make_path( "$d/content", "$d/lazysite/auth", "$d/lazysite/cache" );
    t_spit( "$d/lazysite/lazysite.conf", "site_name: T\ngit_history: enabled\n" );
    t_spit( "$d/lazysite/nav.conf",      "Home | /\n" );
    t_spit( "$d/content/about.md",       "hello v1\n" );
    t_spit( "$d/index.md",               "home\n" );
    Lazysite::Git::reset_cache();
    my $r = Lazysite::Git::init( $d, 'installer' );
    die "init failed: $r->{error}" unless $r->{ok};
    Lazysite::Git::reset_cache();
    return $d;
}

sub mkremote {
    my $r = tempdir( CLEANUP => 1 ) . '/remote.git';
    system( 'git', 'init', '--bare', '-q', '-b', 'main', $r ) == 0 or die 'bare init failed';
    return $r;
}

sub conf_sync {
    my ( $d, $remote ) = @_;
    t_spit( "$d/lazysite/git-sync.conf",
        "remote_url: $remote\nbranch: main\nauth_token: $TOKEN\n" );
}

# A throwaway working clone standing in for "someone else's copy".
sub clone_remote {
    my ($remote) = @_;
    my $w = tempdir( CLEANUP => 1 ) . '/work';
    system( 'git', 'clone', '-q', $remote, $w ) == 0 or die 'clone failed';
    return $w;
}

sub wgit {
    my ( $w, @args ) = @_;
    system( 'git', '-C', $w, '-c', 'user.name=other', '-c', 'user.email=other@example',
        @args ) == 0 or die "git @args failed in $w";
}

sub remote_count {
    my ($remote) = @_;
    open my $fh, '-|', 'git', "--git-dir=$remote", 'rev-list', '--count', 'refs/heads/main'
        or return -1;
    chomp( my $n = do { local $/; <$fh> } // '' );
    close $fh;
    return $n =~ /(\d+)/ ? $1 + 0 : -1;
}

sub head_of {
    my ($d) = @_;
    my ( undef, $sha ) = Lazysite::Git::run_git( $d, 'rev-parse', 'HEAD' );
    chomp( $sha //= '' );
    return $sha;
}

sub prerestore_count {
    my ($d) = @_;
    my @s = glob "$d/lazysite/backups/lazysite-prerestore-*.tar.gz";
    return scalar @s;
}

# --- refusals ------------------------------------------------------------------
{
    # No content history at all
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    t_spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    Lazysite::Git::reset_cache();
    my $r = run_plugin( '--action', 'push', '--docroot', $d );
    ok( !$r->{ok}, 'push refuses when content history is off' );
    like( $r->{error}, qr/Content history/i, 'refusal names the missing feature' );
    vocab_ok( $r->{error}, 'history-off refusal' );
}
{
    my $d = mksite();
    my $r = run_plugin( '--action', 'push', '--docroot', $d );
    ok( !$r->{ok}, 'push refuses without a configured remote' );
    like( $r->{error}, qr/remote copy|remote address/i, 'refusal says the remote is unconfigured' );
    vocab_ok( $r->{error}, 'no-remote refusal' );

    t_spit( "$d/lazysite/git-sync.conf", "remote_url: javascript:alert(1)\n" );
    $r = run_plugin( '--action', 'push', '--docroot', $d );
    ok( !$r->{ok}, 'push refuses a bad remote address' );
    like( $r->{error}, qr/https:\/\/|address/i, 'refusal explains the accepted forms' );

    $r = run_plugin( '--action', 'pull', '--docroot', $d, '--choice', 'nonsense' );
    ok( !$r->{ok}, 'an unknown choice value is refused' );
}

# --- push: commits arrive, no token anywhere, helper cleaned up -----------------
my $D      = mksite();
my $REMOTE = mkremote();
conf_sync( $D, $REMOTE );
{
    # Simulate the exclude list of a repo initialised before the sync plugin
    # existed: strip the git-sync.conf line and let the action self-heal it.
    my $x = t_slurp("$D/lazysite/git/info/exclude");
    $x =~ s{^/lazysite/git-sync\.conf\n}{}m;
    t_spit( "$D/lazysite/git/info/exclude", $x );

    t_spit( "$D/content/about.md", "hello v2\n" );
    Lazysite::Git::commit_paths( $D, 'alice', 'edit content/about.md', 'content/about.md' );

    my $r = run_plugin( '--action', 'push', '--docroot', $D );
    ok( $r->{ok}, 'push succeeds' ) or diag explain $r;
    like( $r->{message}, qr/Pushed \d+ new change/, 'push reports "Pushed N new changes"' );
    vocab_ok( $r->{message}, 'push success message' );
    is( remote_count($REMOTE), Lazysite::Git::count_commits($D),
        'the commits arrived on the remote' );

    # The stored remote URL and the repo config carry no token, ever.
    my ( undef, $url ) = Lazysite::Git::run_git( $D, 'config', '--get', 'remote.origin.url' );
    chomp( $url //= '' );
    is( $url, $REMOTE, 'remote.origin.url is the clean address (no token)' );
    my $gitconf = t_slurp("$D/lazysite/git/config") // '';
    unlike( $gitconf, qr/\Q$TOKEN\E/, 'the token never reaches the git config' );

    # The transient credential helper is gone after the action.
    my @left = glob "$D/lazysite/git/sync-askpass*";
    is( scalar @left, 0, 'the askpass helper is removed after the action' );

    # The token config file is never versioned - so it can never be pushed.
    my ( undef, $files ) = Lazysite::Git::run_git( $D, 'ls-files' );
    unlike( $files, qr{^lazysite/git-sync\.conf$}m, 'git-sync.conf is not versioned' );
    like( t_slurp("$D/lazysite/git/info/exclude"), qr{^/lazysite/git-sync\.conf$}m,
        'the exclude line was self-healed' );

    my $r2 = run_plugin( '--action', 'push', '--docroot', $D );
    ok( $r2->{ok}, 'a second push succeeds' );
    like( $r2->{message}, qr/up to date/i, 'nothing to push reads as up to date' );
    vocab_ok( $r2->{message}, 'push up-to-date message' );
}

# --- test connection -------------------------------------------------------------
{
    my $r = run_plugin( '--scan', '--docroot', $D );
    ok( $r->{ok}, 'test connection succeeds against the local remote' ) or diag explain $r;
    ok( $r->{reachable},     'reports reachable' );
    ok( $r->{branch_exists}, 'reports the content is present' );
    vocab_ok( $r->{message}, 'test-connection message' );

    my $d2 = mksite();
    conf_sync( $d2, mkremote() );    # empty remote
    my $r2 = run_plugin( '--scan', '--docroot', $d2 );
    ok( $r2->{ok},             'test connection ok against an empty remote' );
    ok( !$r2->{branch_exists}, 'empty remote reported as having nothing yet' );
}

# --- pull: fast-forward applies, caches drop, aliases reindex, snapshot taken ----
{
    my $w = clone_remote($REMOTE);
    t_spit( "$w/content/about.md", "hello v3 (remote)\n" );
    t_spit( "$w/content/new.md", "---\ntitle: New\naliases:\n  - /old-url\n---\nfresh\n" );
    wgit( $w, 'add',    '-A', '.' );
    wgit( $w, 'commit', '-q', '-m',     'remote edit' );
    wgit( $w, 'push',   '-q', 'origin', 'main' );

    # Stale render caches that the pull must drop.
    t_spit( "$D/content/about.html", "<html>stale</html>" );
    make_path("$D/lazysite/cache/hosts/alias.example/content");
    t_spit( "$D/lazysite/cache/hosts/alias.example/content/about.html", "<html>stale</html>" );

    my $snaps = prerestore_count($D);
    my $r     = run_plugin( '--action', 'pull', '--docroot', $D );
    ok( $r->{ok}, 'fast-forward pull succeeds' ) or diag explain $r;
    cmp_ok( $r->{applied}, '>=', 1, 'reports changes applied' );
    like( $r->{message}, qr/\d+ change/i, 'plain-language applied message' );
    vocab_ok( $r->{message}, 'pull applied message' );
    ok( ( grep { $_ eq 'content/about.md' } @{ $r->{pages} } ), 'reports which pages changed' );
    is( t_slurp("$D/content/about.md"), "hello v3 (remote)\n", 'the change is applied' );
    ok( !-e "$D/content/about.html", 'sibling render cache dropped' );
    ok( !-e "$D/lazysite/cache/hosts/alias.example/content/about.html",
        'host-copy cache dropped' );
    cmp_ok( prerestore_count($D), '>', $snaps, 'a safety snapshot was taken first' );
    my $aliases = t_slurp("$D/lazysite/aliases.json") // '';
    like( $aliases, qr{/old-url}, 'aliases reindexed for the pulled page' );

    my $r2 = run_plugin( '--action', 'pull', '--docroot', $D );
    ok( $r2->{ok}, 'pull again succeeds' );
    like( $r2->{message}, qr/up to date/i, 'nothing to pull reads as up to date' );
    vocab_ok( $r2->{message}, 'pull up-to-date message' );
}

# --- pull: diverged - report, do not touch; then keep_mine ------------------------
{
    # Someone else's copy changes about.md AND a file only they touch...
    my $w = clone_remote($REMOTE);
    t_spit( "$w/content/about.md",  "theirs v4\n" );
    t_spit( "$w/content/theirs.md", "their new page\n" );
    wgit( $w, 'add',    '-A', '.' );
    wgit( $w, 'commit', '-q', '-m',     'their edit' );
    wgit( $w, 'push',   '-q', 'origin', 'main' );

    # ...while our copy changes about.md differently.
    t_spit( "$D/content/about.md", "mine v4\n" );
    Lazysite::Git::commit_paths( $D, 'alice', 'edit content/about.md', 'content/about.md' );
    my $head  = head_of($D);
    my $snaps = prerestore_count($D);

    my $r = run_plugin( '--action', 'pull', '--docroot', $D );
    ok( $r->{ok}, 'diverged pull returns a report, not a failure' ) or diag explain $r;
    ok( $r->{needs_choice}, 'diverged pull asks for a choice' );
    is_deeply( $r->{conflicts}, ['content/about.md'],
        'the changed-in-both-places list names the page' );
    like( $r->{message}, qr/both/i, 'plain-language conflict message' );
    vocab_ok( $r->{message}, 'conflict message' );
    is( t_slurp("$D/content/about.md"), "mine v4\n", 'worktree untouched' );
    is( head_of($D),          $head,  'history untouched - nothing was combined yet' );
    is( prerestore_count($D), $snaps, 'no snapshot for a report-only run' );

    my $r2 = run_plugin( '--action', 'pull', '--docroot', $D, '--choice', 'keep_mine' );
    ok( $r2->{ok}, 'keep_mine pull succeeds' ) or diag explain $r2;
    is( t_slurp("$D/content/about.md"), "mine v4\n", 'keep_mine keeps my version' );
    is( t_slurp("$D/content/theirs.md"), "their new page\n",
        'their non-conflicting change still arrives' );
    isnt( head_of($D), $head, 'the combination is recorded' );
    # (name-based, not count-based: snapshot names are second-granular and an
    # earlier snapshot in the same second would mask the new one)
    ok( $r2->{snapshot} && -f "$D/lazysite/backups/$r2->{snapshot}",
        'safety snapshot before combining' );
    ok( ( grep { $_ eq 'content/theirs.md' } @{ $r2->{pages} // [] } ),
        'reports the pages that changed on our side' );

    # After keeping ours we are ahead of the remote: push must be clean, never forced.
    my $r3 = run_plugin( '--action', 'push', '--docroot', $D );
    ok( $r3->{ok}, 'push after keep_mine succeeds' ) or diag explain $r3;
    is( remote_count($REMOTE), Lazysite::Git::count_commits($D), 'remote in step again' );
}

# --- pull: take_theirs -------------------------------------------------------------
{
    my $w = clone_remote($REMOTE);
    t_spit( "$w/content/about.md", "theirs v5\n" );
    wgit( $w, 'add',    '-A', '.' );
    wgit( $w, 'commit', '-q', '-m',     'their edit 2' );
    wgit( $w, 'push',   '-q', 'origin', 'main' );

    t_spit( "$D/content/about.md", "mine v5\n" );
    Lazysite::Git::commit_paths( $D, 'alice', 'edit content/about.md', 'content/about.md' );

    my $r = run_plugin( '--action', 'pull', '--docroot', $D, '--choice', 'take_theirs' );
    ok( $r->{ok}, 'take_theirs pull succeeds' ) or diag explain $r;
    is( t_slurp("$D/content/about.md"), "theirs v5\n", 'take_theirs takes the remote version' );
    ok( ( grep { $_ eq 'content/about.md' } @{ $r->{pages} // [] } ),
        'the replaced page is reported as changed' );
}

# --- push refuses when the remote is ahead (no force, ever) -------------------------
{
    my $w = clone_remote($REMOTE);
    t_spit( "$w/content/ahead.md", "remote-only\n" );
    wgit( $w, 'add',    '-A', '.' );
    wgit( $w, 'commit', '-q', '-m',     'remote ahead' );
    wgit( $w, 'push',   '-q', 'origin', 'main' );

    t_spit( "$D/content/local.md", "local-only\n" );
    Lazysite::Git::commit_paths( $D, 'alice', 'create content/local.md', 'content/local.md' );

    my $r = run_plugin( '--action', 'push', '--docroot', $D );
    ok( !$r->{ok}, 'push refuses when the remote has changes we lack' );
    like( $r->{error}, qr/Pull/i, 'the refusal points at Pull' );
    vocab_ok( $r->{error}, 'remote-ahead refusal' );
    ok( -f "$w/content/ahead.md", 'remote content was not overwritten' );
}

# --- the manager seam: action_plugin_action's run:'action' + choice gating --------
{
    require Lazysite::Manager::Plugins;
    my $base = tempdir( CLEANUP => 1 );
    symlink( "$ROOT/plugins", "$base/plugins" )
        or plan skip_all => 'no symlink support';
    my $site = "$base/site";
    make_path($site);
    mksite($site);
    conf_sync( $site, mkremote() );
    local $Lazysite::Manager::Plugins::DOCROOT  = $site;
    local $Lazysite::Manager::Common::auth_user = 'bob';

    # A request-supplied choice must match a descriptor-declared id - nothing
    # request-controlled reaches the command line.
    my $r = Lazysite::Manager::Plugins::action_plugin_action( 'git-sync',
        'plugins/git-sync.pl', 'pull', { choice => 'bogus; rm -rf /' } );
    ok( !$r->{ok}, 'manager refuses an undeclared choice value' );
    like( $r->{error}, qr/Unknown choice/, 'with the Unknown choice error' );

    $r = Lazysite::Manager::Plugins::action_plugin_action( 'git-sync',
        'plugins/git-sync.pl', 'push', undef );
    ok( $r->{ok}, 'push dispatches through the manager action seam' ) or diag explain $r;
    like( $r->{message}, qr/Pushed \d+ new change/, 'and reports as a push' );

    $r = Lazysite::Manager::Plugins::action_plugin_action( 'git-sync',
        'plugins/git-sync.pl', 'test', undef );
    ok( $r->{ok} && $r->{reachable}, 'test connection rides the legacy --scan path' );

    $r = Lazysite::Manager::Plugins::action_plugin_action( 'git-sync',
        'plugins/git-sync.pl', 'nope', undef );
    ok( !$r->{ok}, 'an undeclared action id is refused' );
}

done_testing();
