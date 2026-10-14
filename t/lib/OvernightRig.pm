package OvernightRig;
# SM1062: a scratch repository for driving tools/overnight.sh and
# tools/integration.pl without running a real suite or precheck.
#
# The repository has the real overnight.sh, integration.pl and suite.sh, a
# stand-in tools/precheck.sh that records where it ran and fails when the tree
# holds PRECHECK-FAILS or OLD-BUG (a fault an older main had and a later one fixed), and a `prove` on PATH that runs each named test file (or
# every t/*.t, for -r t/) as a shell script, records the call, and prints
# prove's Wstat line for a file that exits non-zero. A test file is therefore a
# one-line shell condition on the files a stack adds.
use strict;
use warnings;
use Exporter   qw(import);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use POSIX      qw(strftime);
use TestHelper qw(repo_root run_cmd);

our @EXPORT_OK = qw(scratch stack overnight queue git spit slurp today);

my $ROOT = repo_root();

sub today { return strftime( '%Y-%m-%d', localtime ) }

sub spit {
    my ( $p, $t ) = @_;
    ( my $d = $p ) =~ s{/[^/]+$}{};
    make_path($d);
    open my $f, '>', $p or die "$p: $!";
    print {$f} $t;
    close $f;
    return;
}

sub slurp {
    open my $f, '<', $_[0] or return '';
    local $/;
    my $t = <$f>;
    close $f;
    return $t;
}

sub git {
    my ( $d, @a ) = @_;
    open my $ph, '-|', 'git', '-C', $d, @a or die "git @a: $!";
    my $o = do { local $/; <$ph> } // '';
    close $ph;
    die "git @a: exit $?" if $?;
    chomp $o;
    return $o;
}

# A repository on main with the tools, the stubs and the given test files
# ({ 't/a.t' => 'shell condition' }).
sub scratch {
    my (%tests) = @_;
    my $d = tempdir( CLEANUP => 1 );
    git( $d, 'init',   '-q',         '-b', 'main' );
    git( $d, 'config', 'user.email', 't@example.invalid' );
    git( $d, 'config', 'user.name',  't' );
    make_path("$d/tools");
    copy( "$ROOT/tools/$_", "$d/tools/$_" ) or die "$_: $!" for qw(overnight.sh integration.pl suite.sh);
    spit( "$d/tools/precheck.sh", <<'SH' );
cd "$(dirname "$0")/.." || exit 2
echo "PRECHECK $(git log -1 --format=%s) against $(git log -1 --format=%s "$1")" >> "$STUB_CALLS"
[ -e PRECHECK-FAILS ] && { echo "precheck: FAIL"; exit 1; }
[ -e OLD-BUG ] && { echo "precheck: FAIL - OLD-BUG"; exit 1; }
echo "Files=1, Tests=1"
SH
    spit( "$d/bin/prove", <<'SH' );
#!/bin/sh
echo "PROVE $* in $PWD" >> "$STUB_CALLS"
files=
for a in "$@"; do
  case "$a" in
    -*) ;;
    t/) files="$files $(ls t/*.t 2>/dev/null)" ;;
    *) files="$files $a" ;;
  esac
done
rc=0
for f in $files; do
  if ! sh "$f"; then
    echo "$f (Wstat: 256 (exited 1) Tests: 1 Failed: 1)"
    rc=1
  fi
done
[ "$rc" = 0 ] && echo "Files=1, Tests=1, Result: PASS"
exit $rc
SH
    chmod 0755, "$d/bin/prove";
    spit( "$d/$_",         "$tests{$_}\n" ) for keys %tests;
    spit( "$d/.gitignore", "tmp/\nbin/\ninbox/\ncalls\n" );
    git( $d, 'add', '-A' );
    git( $d, 'commit', '-q', '-m', 'base' );
    return $d;
}

# A branch NAME on FROM with one commit adding FILES ({ path => text }); kept
# checked out in its own worktree, tmp/wt-NAME, as an author would leave it.
# Returns the worktree.
sub stack {
    my ( $d, $name, $from, %files ) = @_;
    my $wt = "$d/tmp/wt-$name";
    git( $d, 'worktree', 'add', '-q', '-b', $name, $wt, $from );
    spit( "$wt/$_", $files{$_} ) for keys %files;
    git( $wt, 'add', '-A' );
    git( $wt, 'commit', '-q', '-m', $name );
    return $wt;
}

sub queue {
    my ( $d, @lines ) = @_;
    make_path("$d/tmp/overnight");
    open my $q, '>>', "$d/tmp/overnight/queue.txt" or die $!;
    print {$q} map { "$_\n" } @lines;
    close $q;
    return;
}

# Run the real overnight.sh in the scratch repository; returns (exit, output,
# results file text).
sub overnight {
    my ( $d, @args ) = @_;
    local $ENV{PATH}                   = "$d/bin:$ENV{PATH}";
    local $ENV{STUB_CALLS}             = "$d/calls";
    local $ENV{LAZYSITE_NIGHTLY_INBOX} = "$d/inbox";
    my $out = run_cmd( 'bash', "$d/tools/overnight.sh", @args );
    my $rc  = $? >> 8;
    return ( $rc, $out, slurp( "$d/tmp/overnight/results-" . today() . '.txt' ) );
}

1;
