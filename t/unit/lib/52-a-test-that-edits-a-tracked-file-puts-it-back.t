#!/usr/bin/perl
# SM894: a test that edits a tracked file puts it back - on a die, on a signal,
# and when it cannot, something notices and names it.
#
# Three tests write tracked files for real (the tool under test reads them;
# mocking the switch would test the mock). Each carried its own restore, two in
# END blocks and one inline, and a run that was killed mid-test left VERSION at
# 99.0.0 - which failed t/lint/63 on every later run, on a tree nobody had
# edited, so the next person debugged the lint. preserve_tracked is the one
# owner of that lifecycle now, and tools/tracked-tree-check.pl is the gate that
# notices the case no handler can cover.
#
# THE CHILD IS A REAL SCRIPT, killed from outside: an END block and a signal
# handler cannot be exercised from inside the process that owns them.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root run_cmd);

my $root  = repo_root();
my $check = "$root/tools/tracked-tree-check.pl";
plan skip_all => "no $check" unless -f $check;

# A scratch git repository with one tracked file, so the check script has a
# real `git status` to read and nothing in the project's own tree is touched.
my $dir = tempdir( CLEANUP => 1 );
my $out = run_cmd( 'git', '-C', $dir, 'init', '-q' );
plan skip_all => "git init failed: $out" if $? != 0;
run_cmd( 'git', '-C', $dir, 'config', 'user.email', 't@example.invalid' );
run_cmd( 'git', '-C', $dir, 'config', 'user.name',  'suite' );
my $file = "$dir/RECORD";
_write( $file, "ORIGINAL\n" );
run_cmd( 'git', '-C', $dir, 'add', 'RECORD' );
run_cmd( 'git', '-C', $dir, 'commit', '-q', '-m', 'one tracked file' );
my $preserve = "$dir/preserve";

# The child: preserve the file, edit it, then die / wait to be signalled.
my $child = "$dir/child.pl";
_write( $child, <<"PERL" );
use strict; use warnings;
use lib "$root/t/lib";
use TestHelper qw(preserve_tracked);
my \$how = shift;
sub mutate {
    open my \$fh, '>', "$file" or die \$!; print {\$fh} "MUTATED\\n"; close \$fh;
    # The sentinel is how the parent knows the edit happened: in the die case
    # the file is restored again before any poll could see it mutated.
    open my \$s, '>', "$dir/edited" or die \$!; close \$s;
}
sub slurp { open my \$fh, '<', "$file" or die \$!; local \$/; <\$fh> }
if (\$how eq 'scope') {
    { my \$g = preserve_tracked("$file"); mutate(); }
    # What the file holds the moment the guard is gone - BEFORE exit and END.
    open my \$a, '>', "$dir/after-scope" or die \$!; print {\$a} slurp(); close \$a;
    exit 0;
}
my \$g = preserve_tracked("$file");
mutate();
die "on purpose\\n" if \$how eq 'die';
sleep 1 for 1 .. 60;
PERL

sub _write { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }
sub _read { my ($p) = @_; open my $fh, '<', $p or return undef; local $/; my $t = <$fh>; close $fh; $t }

# Run the child, wait until it has edited the file, then do $act to it.
sub run_child {
    my ( $how, $act ) = @_;
    unlink "$dir/edited";
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ( !$pid ) {
        $ENV{LAZYSITE_PRESERVE_DIR} = $preserve;
        open STDERR, '>', '/dev/null';
        exec $^X, $child, $how;
        exit 127;
    }
    my $edited = 0;
    for ( 1 .. 5000 ) {
        if ( -f "$dir/edited" ) { $edited = 1; last }
        select undef, undef, undef, 0.002;
    }
    $act->($pid) if $act;
    waitpid $pid, 0;
    return ( $edited, $? );
}

subtest 'the guard puts the file back when it goes out of scope, before the test ends' => sub {
    # Not the same as "at exit": a test that preserves inside one subtest and
    # reads the file in the next needs the restore at the brace, and END would
    # be too late. This is the case that tells DESTROY from END.
    unlink "$dir/after-scope";
    my ( $edited, $st ) = run_child('scope');
    ok( $edited, 'the child edited the file first' );
    is( $st, 0, 'and exited normally' );
    is( _read("$dir/after-scope"), "ORIGINAL\n",
        'the file was already back when the guard went out of scope' );
    is( scalar( () = glob("$preserve/*") ), 0, 'and no backup survived' );
};

subtest 'a die inside the test puts the file back' => sub {
    my ( $edited, $st ) = run_child('die');
    ok( $edited, 'the child edited the file first' );
    isnt( $st, 0, 'and died' );
    is( _read($file),                       "ORIGINAL\n", 'the file is back' );
    is( scalar( () = glob("$preserve/*") ), 0,            'and no backup survived' );
};

subtest 'SIGTERM - an interrupted prove, a gate timeout - puts the file back' => sub {
    my ( $edited, $st ) = run_child( 'wait', sub { kill 'TERM', $_[0] } );
    ok( $edited,   'the child edited the file first' );
    ok( $st & 127, 'and was killed by a signal (the handler re-raised it)' )
        or diag("wait status $st");
    is( _read($file), "ORIGINAL\n", 'the file is back' )
        or diag( 'An END block does not run on a signal. This is the case '
            . 'that left VERSION at 99.0.0.' );
    is( scalar( () = glob("$preserve/*") ), 0, 'and no backup survived' );
};

subtest 'SIGKILL cannot be caught - so the check names the file and the test' => sub {
    my ( $edited, undef ) = run_child( 'wait', sub { kill 'KILL', $_[0] } );
    ok( $edited, 'the child edited the file first' );
    is( _read($file), "MUTATED\n", 'the file is NOT back - nothing could run' );
    my @left = glob("$preserve/*.owner");
    is( scalar @left, 1, 'the backup and its marker outlived the test' );

    my $rep = run_cmd( $^X, $check, $dir, '--preserve-dir', $preserve );
    isnt( $?, 0, 'tracked-tree-check exits non-zero' ) or diag($rep);
    like( $rep, qr/modified tracked file: RECORD/, 'it names the modified tracked file' );
    like( $rep, qr/backup never restored: \Q$file\E/, 'and the backup that was never restored' );
    like( $rep, qr/taken by \Q$child\E/, 'and the TEST that took it - the thing a reader wants' )
        or diag($rep);

    # The recovery the message describes, then the check is quiet.
    run_cmd( 'git', '-C', $dir, 'checkout', '--', 'RECORD' );
    unlink glob("$preserve/*");
    run_cmd( $^X, $check, $dir, '--preserve-dir', $preserve );
    is( $?, 0, 'clean tree, no backups: the check is quiet' );
};

subtest 'an untracked file does not count' => sub {
    _write( "$dir/scratch.log", "noise\n" );
    my $rep = run_cmd( $^X, $check, $dir, '--preserve-dir', $preserve );
    is( $?, 0, 'untracked files are the suite\'s business' ) or diag($rep);
};

done_testing();
