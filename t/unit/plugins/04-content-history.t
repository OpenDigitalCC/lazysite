#!/usr/bin/perl
# The Content history plugin (plugins/content-history.pl) - the operator
# surface for SM085's engine, moved off the Backups page (field feedback:
# it is not a backup, it is the enabling of change logging). What matters:
# the descriptor shape (Status + a confirmed Enable action in action mode),
# status speaks plain language in every state (git absent / not enabled /
# enabled with a version count), enable = the git-init semantics (conf key
# written, repo initialised, adoption commit reported, idempotent re-enable
# that keeps every version), the engine gate opens after enable, and the
# plugin is auto-discovered by plugin-list and drivable through the manager
# action seam with the acting user attributed.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(decode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Git ();

my $ROOT   = "$FindBin::Bin/../../..";
my $PLUGIN = "$ROOT/plugins/content-history.pl";
ok( -f $PLUGIN, 'content-history plugin present' );

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

sub mksite {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    t_spit( "$d/lazysite/lazysite.conf", "site_name: T\nmanager: enabled\n" );
    t_spit( "$d/lazysite/nav.conf",      "Home | /\n" );
    t_spit( "$d/index.md",               "home\n" );
    return $d;
}

# --- descriptor -----------------------------------------------------------------
{
    my $desc = run_plugin('--describe');
    is( $desc->{id},      'content-history', '--describe: id' );
    is( $desc->{name},    'Content history', '--describe: name' );
    is( $desc->{version}, '1.0',             '--describe: version' );
    like( $desc->{description}, qr/recorded as a version/i,
        'description says what it IS - change recording, not a backup' );
    like( $desc->{description}, qr/Files page/, 'description points at the Files page surface' );
    like( $desc->{description}, qr/never includes secrets/i,
        'description carries the what-is-not-versioned boundary' );
    like( $desc->{description}, qr/Full-system backups/i,
        'description keeps the DR distinction' );
    my %act = map { $_->{id} => $_ } @{ $desc->{actions} // [] };
    ok( $act{status} && $act{enable}, 'actions: status / enable' );
    ok( !$act{status}{run}, 'status rides the default --scan path' );
    is( $act{enable}{run}, 'action', 'enable runs in action mode' );
    # SM148: enable/disable are the toggle's lifecycle hooks, HIDDEN from the
    # config page (so no "Enable" button shows while already enabled).
    ok( $act{enable}{hidden},  'enable is a hidden lifecycle action (toggle-driven)' );
    ok( $act{disable}{hidden}, 'disable/pause is hidden too' );
    is( $desc->{on_enable},  'enable',  'the toggle on_enable hook points at it' );
    is( $desc->{on_disable}, 'disable', 'the toggle on_disable hook points at it' );
}

# --- git-absent: plain-language degradation, never a failure ---------------------
{
    my $d = mksite();
    local $ENV{PATH} = '/nonexistent-no-git';    # the child scans PATH for git
    my $s = run_plugin( '--scan', '--docroot', $d );
    ok( $s->{ok},             'status still answers with git absent' ) or diag explain $s;
    ok( !$s->{git_available}, 'status: reports git unavailable' );
    ok( !$s->{enabled},       'status: not enabled without git' );
    like( $s->{message}, qr/git is not installed/i, 'plain-language git-absent message' );
    like( $s->{message}, qr/install the git package/i, 'and it says what to do' );

    my $e = run_plugin( '--action', 'enable', '--docroot', $d );
    ok( !$e->{ok}, 'enable refuses with git absent' );
    like( $e->{error}, qr/git is not installed/i, 'enable refusal in plain language' );
}

if ( !Lazysite::Git::git_available() ) {
    diag 'git not installed on this host - the enable round-trip is not exercised';
    done_testing();
    exit 0;
}

# --- status before / enable / status after: the round-trip ------------------------
my $D = mksite();
{
    my $s = run_plugin( '--scan', '--docroot', $D );
    ok( $s->{ok},        'status ok before enable' ) or diag explain $s;
    ok( !$s->{enabled},  'status: not enabled yet' );
    ok( $s->{git_available}, 'status: git present' );
    is( $s->{commits}, 0, 'status: no versions yet' );
    like( $s->{message}, qr/not enabled/i,       'plain-language not-enabled message' );
    like( $s->{message}, qr/initial snapshot/i,  'explains what enabling does' );

    my $r = run_plugin( '--action', 'enable', '--docroot', $D );
    ok( $r->{ok}, 'enable ok' ) or diag explain $r;
    like( $r->{commit}, qr/\A[0-9a-f]{40}\z/, 'the adoption commit is reported' );
    cmp_ok( $r->{commits}, '>=', 1, 'version count reported' );
    like( $r->{message}, qr/enabled/i, 'plain-language success message' );
    like( t_slurp("$D/lazysite/lazysite.conf"), qr/^git_history: enabled$/m,
        'conf key written - the same key the engine hooks gate on' );
    ok( -f "$D/lazysite/git/HEAD", 'repo initialised at lazysite/git' );

    Lazysite::Git::reset_cache();
    ok( Lazysite::Git::enabled($D), 'the engine gate opens - hooks unchanged' );

    my $again = run_plugin( '--action', 'enable', '--docroot', $D );
    ok( $again->{ok} && $again->{already}, 'a second enable is an idempotent no-op' );
    is( $again->{commits}, $r->{commits}, 'and keeps the recorded versions' );
    like( $again->{message}, qr/already/i, 'saying so in plain language' );

    my $s2 = run_plugin( '--scan', '--docroot', $D );
    ok( $s2->{ok} && $s2->{enabled}, 'status: enabled after enable' );
    ok( $s2->{initialised},          'status: initialised' );
    ok( !$s2->{recording_failed},    'status: recording healthy (no breadcrumb)' );
    cmp_ok( $s2->{commits}, '>=', 1, 'status: version count' );
    like( $s2->{message}, qr/Files page/, 'enabled message points at the Files page' );
    unlike( $s2->{message}, qr/FAILED/, 'no failure language on the healthy path' );

    # Last-commit health: the engine's COMMIT_FAILED breadcrumb surfaces here
    # (the full failure->recovery lifecycle is t/unit/lib/18-git-guarantee.t).
    t_spit( "$D/lazysite/git/COMMIT_FAILED", "x\n" );
    my $s3 = run_plugin( '--scan', '--docroot', $D );
    ok( $s3->{recording_failed}, 'status: breadcrumb reported as recording_failed' );
    like( $s3->{message}, qr/FAILED/,        'failing state named in plain language' );
    like( $s3->{message}, qr/lazysite check/, 'and points at the doctor' );
    unlink "$D/lazysite/git/COMMIT_FAILED";
}

# --- refusals ----------------------------------------------------------------------
{
    ok( !run_plugin( '--action', 'nope', '--docroot', $D )->{ok},
        'an unknown action id is refused' );
    ok( !run_plugin( '--scan', '--docroot', '/nonexistent-docroot' )->{ok},
        'status refuses a missing docroot' );
}

# --- plugin-list discovery + the manager action seam --------------------------------
SKIP: {
    require Lazysite::Manager::Plugins;
    my $base = tempdir( CLEANUP => 1 );
    symlink( "$ROOT/plugins", "$base/plugins" )
        or skip 'no symlink support', 1;
    my $site = "$base/site";
    make_path("$site/lazysite");
    t_spit( "$site/lazysite/lazysite.conf", "site_name: T\n" );
    t_spit( "$site/index.md",               "home\n" );
    local $Lazysite::Manager::Plugins::DOCROOT  = $site;
    local $Lazysite::Manager::Common::auth_user = 'bob';

    my $list = Lazysite::Manager::Plugins::action_plugin_list();
    ok( $list->{ok}, 'plugin-list ok' );
    my %by_id = map { $_->{id} => $_ } @{ $list->{plugins} };
    ok( $by_id{'content-history'}, 'content-history is auto-discovered' );
    is( $by_id{'content-history'}{_script}, 'plugins/content-history.pl',
        'with its plugins/ script path' );
    ok( $by_id{'git-sync'}, 'beside its sibling git-sync' );
    like( $by_id{'git-sync'}{description}, qr/Content history plugin/,
        'git-sync now points at the plugin, not the Backups page' );

    my $st = Lazysite::Manager::Plugins::action_plugin_action( 'content-history',
        'plugins/content-history.pl', 'status', undef );
    ok( $st->{ok} && !$st->{enabled}, 'status dispatches through the manager seam' );

    my $en = Lazysite::Manager::Plugins::action_plugin_action( 'content-history',
        'plugins/content-history.pl', 'enable', undef );
    ok( $en->{ok}, 'enable dispatches through the manager seam' ) or diag explain $en;
    like( $en->{commit}, qr/\A[0-9a-f]{40}\z/, 'and reports the adoption commit' );
    ok( -f "$site/lazysite/git/HEAD", 'the site repo is initialised' );

    Lazysite::Git::reset_cache();
    my $log = Lazysite::Git::file_log( $site, 'index.md' );
    is( $log->[0]{author}, 'bob', 'the adoption commit is attributed to the acting user' );
}

# --- ONE switch: the Plugin-Manager toggle runs the lifecycle hooks ----------------
# Field feedback: enabling the plugin must be all it takes - no second Enable
# on the config page. Ticking runs on_enable (init + adoption commit);
# unticking runs on_disable (recording paused, every version kept).
SKIP: {
    require Lazysite::Manager::Plugins;
    my $base = tempdir( CLEANUP => 1 );
    symlink( "$ROOT/plugins", "$base/plugins" )
        or skip 'no symlink support', 1;
    my $site = "$base/site";
    make_path("$site/lazysite");
    t_spit( "$site/lazysite/lazysite.conf", "site_name: T\n" );
    t_spit( "$site/index.md",               "home\n" );
    local $Lazysite::Manager::Plugins::DOCROOT  = $site;
    local $Lazysite::Manager::Common::auth_user = 'bob';

    my $desc = decode_json( scalar qx($^X \Q$PLUGIN\E --describe) );
    is( $desc->{on_enable},  'enable',  'descriptor declares the on_enable hook' );
    is( $desc->{on_disable}, 'disable', 'descriptor declares the on_disable hook' );

    my $en = Lazysite::Manager::Plugins::action_plugin_enable('plugins/content-history.pl');
    ok( $en->{ok}, 'plugin-enable ok' ) or diag explain $en;
    ok( $en->{hook} && $en->{hook}{ok}, 'the toggle ran the on_enable hook' )
        or diag explain $en;
    like( $en->{hook}{commit}, qr/\A[0-9a-f]{40}\z/, 'hook took the adoption commit' );
    like( t_slurp("$site/lazysite/lazysite.conf"), qr/^plugins:/m, 'plugin listed in conf' );
    Lazysite::Git::reset_cache();
    ok( Lazysite::Git::enabled($site), 'recording is ON after the one switch' );
    my $commits = Lazysite::Git::count_commits($site);

    my $dis = Lazysite::Manager::Plugins::action_plugin_disable('plugins/content-history.pl');
    ok( $dis->{ok}, 'plugin-disable ok' ) or diag explain $dis;
    ok( $dis->{hook} && $dis->{hook}{ok}, 'the toggle ran the on_disable hook' )
        or diag explain $dis;
    like( $dis->{hook}{message}, qr/kept/, 'pause message says the versions are kept' );
    Lazysite::Git::reset_cache();
    ok( !Lazysite::Git::enabled($site), 'recording is OFF after unticking' );
    ok( -f "$site/lazysite/git/HEAD", 'the repo (and its versions) stay on disk' );
    like( t_slurp("$site/lazysite/lazysite.conf"), qr/^git_history:/m,
        'conf keys survive removing the last plugin on their own lines (line-glue regression)' );

    my $re = Lazysite::Manager::Plugins::action_plugin_enable('plugins/content-history.pl');
    ok( $re->{ok} && $re->{hook} && $re->{hook}{ok}, 're-enable resumes recording' )
        or diag explain $re;
    Lazysite::Git::reset_cache();
    ok( Lazysite::Git::enabled($site), 'recording is ON again' );
    is( Lazysite::Git::count_commits($site), $commits, 'resume kept every version (no re-adoption)' );

    # A plugin with no lifecycle hooks toggles exactly as before (no hook key).
    my $plain = Lazysite::Manager::Plugins::action_plugin_enable('plugins/git-sync.pl');
    ok( $plain->{ok} && !exists $plain->{hook}, 'a hookless plugin toggles with no hook result' )
        or diag explain $plain;
}

done_testing();
