#!/usr/bin/perl
# SM1061: THE NIGHTLY SUITE RUNS ON MAIN, QUIETLY, AND SPEAKS ONLY ON A FAILURE.
#
# Revised ruling, release manager 2026-10-12: a targeted precheck on each
# commit and handoff, the whole suite on demand and for a release, and as a
# safety net a whole-suite run every night "after midnight". `tools/suite.sh
# --nightly`:
#   - runs on main's tip in a detached worktree it manages (tmp/wt-nightly),
#     moved to main each run, under nice/ionice;
#   - never queues: finding the suite lock held, it logs a line and exits 0, so
#     one night's run cannot overlap another or run into the day;
#   - logs to tmp/nightly/DATE.log and keeps the newest 14;
#   - on a failure files DATE-nightly-suite-failed-on-SHA.md in the inbox with
#     the failing files and their first failure lines; on a pass, nothing.
#
# Driven in a scratch repository with the real suite.sh and a `prove` on PATH
# that records where it ran. No real suite runs.
use strict;
use warnings;
use Test::More;
use Fcntl      qw(:flock);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use POSIX      qw(strftime);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();
my $day  = strftime( '%Y-%m-%d', localtime );

sub spit {
    my ( $p, $t ) = @_;
    ( my $d = $p ) =~ s{/[^/]+$}{};
    make_path($d);
    open my $f, '>', $p or die "$p: $!";
    print {$f} $t;
    close $f;
}
sub slurp { open my $f, '<', $_[0] or return ''; local $/; my $t = <$f>; close $f; $t }

sub git {
    my ( $d, @a ) = @_;
    open my $ph, '-|', 'git', '-C', $d, @a or die "git @a: $!";
    my $o = do { local $/; <$ph> } // '';
    close $ph;
    die "git @a: exit $?" if $?;
    chomp $o;
    return $o;
}

sub repo {
    my $d = tempdir( CLEANUP => 1 );
    git( $d, 'init',   '-q',         '-b', 'main' );
    git( $d, 'config', 'user.email', 't@example.invalid' );
    git( $d, 'config', 'user.name',  't' );
    make_path("$d/tools");
    copy( "$root/tools/suite.sh", "$d/tools/suite.sh" ) or die $!;
    spit( "$d/.gitignore", "tmp/\ncalls\nbin/\ninbox/\n" );
    spit( "$d/bin/prove",  <<'SH' );
#!/bin/sh
echo "PROVE $* in $PWD at $(git rev-parse HEAD) nice $(nice)" >> "$STUB_CALLS"
if [ -n "${STUB_FAIL:-}" ]; then
  echo "t/unit/x/01-a.t .. "
  echo "#   Failed test 'the widget renders'"
  echo "#   at t/unit/x/01-a.t line 12."
  echo "#   Failed test 'a later one'"
  echo "#   at t/unit/x/01-a.t line 40."
  echo "Test Summary Report"
  echo "-------------------"
  echo "t/unit/x/01-a.t (Wstat: 256 (exited 1) Tests: 3 Failed: 2)"
  echo "Files=2, Tests=5,  0 wallclock secs"
  exit 1
fi
echo "Files=2, Tests=5,  0 wallclock secs"
SH
    chmod 0755, "$d/bin/prove";
    git( $d, 'add', '-A' );
    git( $d, 'commit', '-q', '-m', 'base' );
    return $d;
}

sub nightly {
    my ( $d, %env ) = @_;
    local $ENV{PATH}                   = "$d/bin:$ENV{PATH}";
    local $ENV{STUB_CALLS}             = "$d/calls";
    local $ENV{LAZYSITE_NIGHTLY_INBOX} = "$d/inbox";
    local $ENV{STUB_FAIL}              = $env{fail} // '';
    my $out = run_cmd( 'bash', "$d/tools/suite.sh", '--nightly' );
    return ( $? >> 8, $out );
}

subtest 'a pass runs on main in tmp/wt-nightly, quietly, and files nothing' => sub {
    my $d = repo();
    my ( $rc, $out ) = nightly($d);
    is( $rc, 0, 'exit 0' ) or diag($out);
    my $main = git( $d, 'rev-parse', 'main' );
    like( slurp("$d/calls"), qr/^PROVE -lr -j\d+ t\/ in \Q$d\E\/tmp\/wt-nightly at $main nice 19$/m,
        'prove -lr ran once, in the nightly worktree, at main, at nice 19' );
    like( slurp("$d/tmp/nightly/$day.log"), qr/nightly: prove exit 0/, 'the log is tmp/nightly/DATE.log' );
    ok( !glob("$d/inbox/*"), 'and nothing is filed in the inbox' );

    # Main moves; the next night runs on the new tip, and a file a test left in
    # the worktree does not stop it.
    spit( "$d/next", "n\n" );
    git( $d, 'add', 'next' );
    git( $d, 'commit', '-q', '-m', 'next' );
    spit( "$d/tmp/wt-nightly/tools/suite.sh", "edited by a test\n" );
    unlink "$d/calls";
    ( $rc, $out ) = nightly($d);
    is( $rc, 0, 'the next run passes too' ) or diag($out);
    my $next = git( $d, 'rev-parse', 'main' );
    like( slurp("$d/calls"), qr/ at $next /, 'on the new main' );
    is( git( "$d/tmp/wt-nightly", 'status', '--porcelain' ), '', 'with the worktree reset to it' );
    is( git( "$d/tmp/wt-nightly", 'branch', '--show-current' ), '', 'and detached, holding no branch' );
};

subtest 'a failure files a short report naming the failing file' => sub {
    my $d = repo();
    my ( $rc, $out ) = nightly( $d, fail => 1 );
    is( $rc, 1, 'exit 1' );
    my $sha    = git( $d, 'rev-parse', '--short=12', 'main' );
    my $report = "$d/inbox/$day-nightly-suite-failed-on-$sha.md";
    ok( -f $report, 'the report is DATE-nightly-suite-failed-on-SHA.md in the inbox' )
        or diag( join ' ', glob("$d/inbox/*") );
    my $r = slurp($report);
    like( $r, qr/^- t\/unit\/x\/01-a\.t$/m, 'naming the failing file' );
    like( $r, qr/Failed test 'the widget renders'\n\s+#\s+at t\/unit\/x\/01-a\.t line 12\./, 'with its first failure' );
    unlike( $r, qr/a later one/, 'and only the first' );
    like( slurp("$d/tmp/nightly/$day.log"), qr/FAILED - filed/, 'the log says it filed one' );
};

subtest 'a held lock is a skip with a log line, never a queue' => sub {
    my $d = repo();
    make_path("$d/tmp");
    open my $lk, '>>', "$d/.git/lazysite-suite.lock" or die $!;
    flock( $lk, LOCK_EX ) or die $!;
    spit( "$d/.git/lazysite-suite.lock.holder", "pid=4242\ncwd=/elsewhere\n" );
    my ( $rc, $out ) = nightly($d);
    close $lk;
    is( $rc,               0,  'exit 0 at once' ) or diag($out);
    is( slurp("$d/calls"), '', 'no suite ran' );
    like( slurp("$d/tmp/nightly/$day.log"), qr/nightly: skipped - another whole-suite run holds/, 'the log says it skipped' );
    like( slurp("$d/tmp/nightly/$day.log"), qr/pid=4242/, '...and who held the lock' );
    ok( !glob("$d/inbox/*"), 'and a skip files nothing' );
};

subtest 'the newest 14 logs are kept' => sub {
    my $d = repo();
    spit( sprintf( "$d/tmp/nightly/2020-01-%02d.log", $_ ), "old\n" ) for 1 .. 20;
    my ( $rc, $out ) = nightly($d);
    is( $rc, 0, 'exit 0' ) or diag($out);
    my @logs = sort map { s{.*/}{}r } glob("$d/tmp/nightly/*.log");
    is( scalar @logs, 14,               'fourteen logs remain' );
    is( $logs[-1],    "$day.log",       "tonight's among them" );
    is( $logs[0],     '2020-01-08.log', 'and the oldest seven went' );
};

done_testing();
