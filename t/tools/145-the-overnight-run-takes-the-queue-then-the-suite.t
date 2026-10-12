#!/usr/bin/perl
# SM1061: THE OVERNIGHT RUN TAKES THE QUEUED HANDOFFS, THEN THE NIGHTLY SUITE.
#
# Handoffs too heavy for the working day are queued (tools/overnight.sh --queue
# WORKTREE TIP [FLAG]) and run at 00:30, one at a time, before the nightly
# whole-suite run on main. A second overnight run while one is going skips with
# a line in the results file rather than queueing.
#
# Driven in a scratch repository with the real overnight.sh and suite.sh, a
# stand-in handoff.sh that records its arguments, and a `prove` on PATH that
# records where it ran. No real handoff or suite runs.
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
    copy( "$root/tools/overnight.sh", "$d/tools/overnight.sh" ) or die $!;
    copy( "$root/tools/suite.sh",     "$d/tools/suite.sh" )     or die $!;
    spit( "$d/tools/handoff.sh", <<'SH' );
echo "HANDOFF $(git -C "$(dirname "$0")" branch --show-current) $*" >> "$STUB_CALLS"
echo "READY FOR REVIEW: $(git -C "$(dirname "$0")" branch --show-current) 1234567 (precheck passed)"
SH
    spit( "$d/bin/prove", qq{#!/bin/sh\necho "SUITE in \$PWD" >> "\$STUB_CALLS"\necho "Files=1, Tests=1"\n} );
    chmod 0755, "$d/bin/prove";
    spit( "$d/.gitignore", "tmp/\nbin/\ninbox/\n" );
    git( $d, 'add',    '-A' );
    git( $d, 'commit', '-q', '-m', 'base' );
    git( $d, 'branch', 'feature' );
    my $wt = "$d/tmp/wt-feature";
    git( $d, 'worktree', 'add', '-q', '--detach', $wt, 'main' );
    return ( $d, $wt );
}

sub overnight {
    my ( $d, @args ) = @_;
    local $ENV{PATH}                   = "$d/bin:$ENV{PATH}";
    local $ENV{STUB_CALLS}             = "$d/calls";
    local $ENV{LAZYSITE_NIGHTLY_INBOX} = "$d/inbox";
    my $out = run_cmd( 'bash', "$d/tools/overnight.sh", @args );
    return ( $? >> 8, $out );
}

subtest 'a handoff is queued, and a bad flag is refused' => sub {
    my ( $d,  $wt )  = repo();
    my ( $rc, $out ) = overnight( $d, '--queue', $wt, 'feature', '--full' );
    is( $rc,                                 0, 'queued' ) or diag($out);
    is( slurp("$d/tmp/overnight/queue.txt"), "$wt feature --full\n", 'one line: WORKTREE TIP FLAG' );
    ( $rc, $out ) = overnight( $d, '--queue', $wt, 'feature', '--everything' );
    is( $rc, 2, 'an unknown flag is refused' );
    ( $rc, $out ) = overnight( $d, '--queue', "$d/no-such", 'feature' );
    is( $rc, 2, 'so is a worktree that is not there' );
};

subtest 'the run takes the queue, then the nightly suite' => sub {
    my ( $d, $wt ) = repo();
    overnight( $d, '--queue', $wt, 'feature' );
    my ( $rc, $out ) = overnight($d);
    is( $rc, 0, 'exit 0' ) or diag($out);
    like( slurp("$d/calls"), qr/\AHANDOFF feature --stack main\nSUITE in \Q$d\E\/tmp\/wt-nightly\n\z/,
        'the handoff ran on its tip with --stack main, then the suite on main in the nightly worktree' );
    my $res = slurp("$d/tmp/overnight/results-$day.txt");
    like( $res, qr/^READY FOR REVIEW: feature 1234567 \(precheck passed\)$/m, 'the verdict is in the results file' );
    like( $res, qr/nightly suite: exit 0/, 'and the nightly suite result' );
    is( slurp("$d/tmp/overnight/queue.txt"), '', 'the queue is taken' );
    like( slurp("$d/tmp/overnight/handoff-$day-feature.log"), qr/READY FOR REVIEW/, 'the whole output kept beside it' );
};

subtest 'a queued flag reaches the handoff' => sub {
    my ( $d, $wt ) = repo();
    overnight( $d, '--queue', $wt, 'feature', '--release' );
    overnight($d);
    like( slurp("$d/calls"), qr/^HANDOFF feature --stack main --release$/m, '--release passed through' );
};

subtest 'a second overnight run skips, never queues' => sub {
    my ( $d, $wt ) = repo();
    overnight( $d, '--queue', $wt, 'feature' );
    open my $lk, '>>', "$d/tmp/overnight/.runner.lock" or die $!;
    flock( $lk, LOCK_EX ) or die $!;
    my ( $rc, $out ) = overnight($d);
    close $lk;
    is( $rc,               0,  'exit 0' ) or diag($out);
    is( slurp("$d/calls"), '', 'nothing ran' );
    like( slurp("$d/tmp/overnight/results-$day.txt"), qr/skipped/, 'the results file says it skipped' );
    is( slurp("$d/tmp/overnight/queue.txt"), "$wt feature\n", 'and the queue waits for the next night' );
};

done_testing();
