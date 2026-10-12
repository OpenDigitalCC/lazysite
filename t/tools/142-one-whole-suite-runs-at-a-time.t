#!/usr/bin/perl
# SM1061: ONE WHOLE-SUITE RUN AT A TIME ON THE HOST.
#
# tools/suite.sh is the one way to run the whole plain suite. It takes a flock
# under the repository's COMMON git dir, so every worktree shares it; a second
# run WAITS for the first (saying who holds it, from the note beside the lock)
# rather than failing, and the two never overlap.
#
# Driven in a scratch repository with the real suite.sh and a `prove` on PATH
# that records when it starts and ends, and holds until the test lets it go -
# so the overlap, if there were one, is certain rather than a timing accident.
# No real suite runs; no sleep is longer than a 50 ms poll.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

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
    system( 'git', '-C', $d, @a ) == 0 or die "git @a: exit $?";
}

# Poll for a condition; give up after ten seconds.
sub wait_for {
    my ($cond) = @_;
    for ( 1 .. 200 ) {
        return 1 if $cond->();
        select( undef, undef, undef, 0.05 );
    }
    return 0;
}

my $d = tempdir( CLEANUP => 1 );
git( $d, 'init',   '-q',         '-b', 'main' );
git( $d, 'config', 'user.email', 't@example.invalid' );
git( $d, 'config', 'user.name',  't' );
make_path("$d/tools");
copy( "$root/tools/suite.sh", "$d/tools/suite.sh" ) or die $!;
spit( "$d/bin/prove", <<'SH' );
#!/bin/sh
echo "start $STUB_ID" >> "$STUB_CALLS"
n=0
while [ ! -e "$STUB_GATE" ] && [ "$n" -lt 400 ]; do sleep 0.05; n=$((n + 1)); done
echo "end $STUB_ID" >> "$STUB_CALLS"
echo "Files=1, Tests=1,  0 wallclock secs"
SH
chmod 0755, "$d/bin/prove";
my $calls = "$d/calls";

# A second worktree: the lock is in the COMMON git dir, so a run there must wait
# for a run in the main checkout.
git( $d, 'commit', '-q', '--allow-empty', '-m', 'base' );
my $wt = tempdir( CLEANUP => 1 ) . '/wt';
git( $d, 'worktree', 'add', '-q', '--detach', $wt );
make_path("$wt/tools");
copy( "$root/tools/suite.sh", "$wt/tools/suite.sh" ) or die $!;

sub start {
    my ( $dir, $id ) = @_;
    my $pid = fork() // die "fork: $!";
    if ( !$pid ) {
        $ENV{PATH}       = "$d/bin:$ENV{PATH}";
        $ENV{STUB_ID}    = $id;
        $ENV{STUB_CALLS} = $calls;
        $ENV{STUB_GATE}  = "$d/gate-$id";
        open STDOUT, '>',  "$d/out-$id" or die;
        open STDERR, '>&', \*STDOUT     or die;
        exec 'bash', "$dir/tools/suite.sh" or exit 127;
    }
    return $pid;
}

my $first = start( $d, 'A' );
ok( wait_for( sub { slurp($calls) =~ /start A/ } ), 'the first run started its suite' );

my $second = start( $wt, 'B' );
ok( wait_for( sub { slurp("$d/out-B") =~ /waiting for it/ } ), 'the second run says it is waiting' );
like( slurp("$d/out-B"), qr/^suite:\s+pid=$first$/m, '...naming the holder from its note' );
like( slurp("$d/out-B"), qr/^suite:\s+cwd=\Q$d\E$/m, '...and where it runs' );
unlike( slurp($calls), qr/start B/, 'and its suite has not started while the first holds the lock' );

spit( "$d/gate-A", '' );
spit( "$d/gate-B", '' );
waitpid( $first, 0 );
is( $? >> 8, 0, 'the first run passed' );
waitpid( $second, 0 );
is( $? >> 8, 0, 'the second run passed, after waiting rather than failing' );

is( slurp($calls), "start A\nend A\nstart B\nend B\n", 'the two suites ran one after the other, never together' );
like( slurp("$d/out-A"),         qr/^Files=1, Tests=1/m, 'a run prints the Files= line' );
like( slurp("$d/tmp/suite.log"), qr/^Files=1/m, 'and keeps its log in its own worktree' );
like( slurp("$wt/tmp/suite.log"), qr/^Files=1/m, '...each worktree its own' );

done_testing();
