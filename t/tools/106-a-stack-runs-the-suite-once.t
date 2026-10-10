#!/usr/bin/perl
# SM971: A STACK OF BRANCHES IS HANDED OFF WITH ONE FULL SUITE, NOT ONE EACH.
#
# Every stacked branch's handoff ran the six-minute suite on a tree the next
# branch contains. `tools/handoff.sh --stack BASE` runs the one-minute precheck
# on each branch from BASE to the checked-out tip - each against the branch
# below it - and the full suite once, on the tip; each branch is READY only if
# all of it passed, and the first precheck that fails stops the run naming its
# branch. Without --stack it is the same path with a stack of one.
#
# Driven in a scratch repository with the real handoff.sh and stand-ins that
# record their calls: a precheck, the generators, the tracked-tree check, and a
# one-test suite that says which branch it ran on.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

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
# STDOUT ONLY (Q14d): under the coverage gate a perl child prints Devel::Cover
# notices on stderr, and run_cmd merges stderr in - so the branch name compared
# below read 'Devel::Cover: Deleting old coverage ...\nmain' and failed the gate.
sub git {
    my ( $d, @a ) = @_;
    open my $ph, '-|', 'git', '-C', $d, @a or die "git @a: $!";
    my $o = do { local $/; <$ph> } // '';
    close $ph;
    die "git @a: exit $?" if $?;
    chomp $o;
    return $o;
}

sub stack {
    my $d = tempdir( CLEANUP => 1 );
    git( $d, 'init',   '-q',         '-b', 'main' );
    git( $d, 'config', 'user.email', 't@example.invalid' );
    git( $d, 'config', 'user.name',  't' );
    make_path( "$d/tools", "$d/tmp" );
    copy( "$root/tools/handoff.sh", "$d/tools/handoff.sh" ) or die $!;
    spit( "$d/tools/precheck.sh", <<'SH' );
b=$(git branch --show-current)
echo "PRECHECK $b $1" >> calls
[ "$b" != "${STUB_PRECHECK_FAIL:-}" ]
SH
    spit( "$d/tools/regen-generated.sh",    "exit 0\n" );
    spit( "$d/tools/tracked-tree-check.pl", "exit 0;\n" );
    spit( "$d/t/00-suite.t",                <<'T' );
use Test::More;
my $b = `git branch --show-current`; chomp $b;
open my $f, '>>', 'calls' or die; print {$f} "SUITE $b\n"; close $f;
system( 'git', 'branch', '-q', '-D', $ENV{STUB_LAND} ) if $ENV{STUB_LAND};
pass('the suite'); done_testing;
T
    spit( "$d/.gitignore", "tmp/\ncalls\n" );
    git( $d, 'add',      '-A' );
    git( $d, 'commit',   '-q', '-m', 'base' );
    git( $d, 'checkout', '-q', '-b', 'unrelated' );
    spit( "$d/u", "u\n" );
    git( $d, 'add',      'u' );
    git( $d, 'commit',   '-q', '-m', 'not in the stack' );
    git( $d, 'checkout', '-q', 'main' );
    for my $b (qw(s1 s2 s3)) {
        git( $d, 'checkout', '-q', '-b', $b );
        spit( "$d/$b", "$b\n" );
        git( $d, 'add', $b );
        git( $d, 'commit', '-q', '-m', $b );
    }
    return $d;
}

sub handoff {
    my ( $d, @args ) = @_;
    my $out = run_cmd( 'bash', "$d/tools/handoff.sh", @args );
    return ( $? >> 8, $out );
}

subtest 'every branch is prechecked against the one below it; the suite runs once' => sub {
    my $d = stack();
    my ( $rc, $out ) = handoff( $d, '--stack', 'main' );
    is( $rc, 0, 'READY' ) or diag($out);
    is( slurp("$d/calls"), "PRECHECK s1 main\nPRECHECK s2 s1\nPRECHECK s3 s2\nSUITE s3\n",
        'precheck per branch, in order, and the suite once, on the tip' );
    like( $out, qr/^READY FOR REVIEW: $_ [0-9a-f]+ \(precheck passed; tier-review passed on s3\)$/m, "$_ is READY" )
        for qw(s1 s2 s3);
    unlike( $out, qr/unrelated/, 'a branch off the stack is not part of it' );
    is( git( $d, 'branch', '--show-current' ), 'main', 'and the worktree is back on the base' );
};

subtest 'a branch whose precheck fails stops the stack, by name' => sub {
    my $d = stack();
    local $ENV{STUB_PRECHECK_FAIL} = 's2';
    my ( $rc, $out ) = handoff( $d, '--stack', 'main' );
    is( $rc, 1, 'not ready' );
    like( $out, qr/^NOT READY: s2 [0-9a-f]+ - the stack stops there$/m, 'naming the branch' );
    is( slurp("$d/calls"), "PRECHECK s1 main\nPRECHECK s2 s1\n", 'nothing above it ran, and no suite' );
    unlike( $out, qr/READY FOR REVIEW/, 'no branch is called ready' );
    is( git( $d, 'branch', '--show-current' ), 's3', 'and the worktree is where it started' );
};

subtest 'without --stack the stack is the checked-out branch' => sub {
    my $d = stack();
    git( $d, 'checkout', '-q', 's1' );
    my ( $rc, $out ) = handoff($d);
    is( $rc,               0,                              'READY' ) or diag($out);
    is( slurp("$d/calls"), "PRECHECK s1 main\nSUITE s1\n", 'one precheck against main, one suite' );
    like( $out, qr/^READY FOR REVIEW: s1 [0-9a-f]+ \(tier-review passed\)$/m, 'the one line review reads' );
};

# Q16a: run in a linked worktree while the base is checked out in the main one,
# the return to the base failed - git checks a branch out in one worktree only -
# and a run whose every gate passed said NOT READY (n308, n332). It detaches at
# the base there, which frees the branch as well.
subtest 'in a linked worktree the run ends detached at the base, and is READY' => sub {
    my $d = stack();
    git( $d, 'checkout', '-q', 'main' );
    my $wt = tempdir( CLEANUP => 1 ) . '/wt';
    git( $d, 'worktree', 'add', '-q', $wt, 's3' );
    make_path("$wt/tmp");
    my ( $rc, $out ) = handoff( $wt, '--stack', 'main' );
    is( $rc, 0, 'READY' ) or diag($out);
    like( $out, qr/^READY FOR REVIEW: $_ [0-9a-f]+ \(precheck passed; tier-review passed on s3\)$/m, "$_ is READY" )
        for qw(s1 s2 s3);
    like( $out, qr/the worktree is detached at main, so s1 s2 s3 is free to review/, '...saying where it left the worktree' );
    unlike( $out, qr/NOT READY|still held/, 'and nothing says it is held' );
    is( git( $wt, 'branch', '--show-current' ), '', 'the linked worktree holds no branch' );
    is( git( $wt, 'rev-parse', 'HEAD' ), git( $d, 'rev-parse', 'main' ), '...and sits at the base' );
    is( git( $d, 'branch', '--show-current' ), 'main', 'the main checkout is left on the base' );
    git( $d, 'checkout', '-q', 's3' );    # dies if s3 were still held
    is( git( $d, 'branch', '--show-current' ), 's3', 'and s3 is free: the main checkout can take it' );
};

# Q16a: a stack branch landed - and so deleted - by review while the suite ran
# printed "READY FOR REVIEW: <branch>  (...)" with no SHA, after git's "fatal:
# Needed a single revision".
subtest 'a stack branch landed during the run is named, not called ready' => sub {
    my $d = stack();
    local $ENV{STUB_LAND} = 's1';
    my ( $rc, $out ) = handoff( $d, '--stack', 'main' );
    is( $rc, 0, 'READY' ) or diag($out);
    like( $out, qr/^s1 \(landed or deleted during the run\)$/m, 'the landed branch is named as such' );
    unlike( $out, qr/READY FOR REVIEW: s1\b/,         '...and not called ready' );
    unlike( $out, qr/fatal|Needed a single revision/, '...with no error from git' );
    like( $out, qr/^READY FOR REVIEW: $_ [0-9a-f]+ \(/m, "$_ is READY" ) for qw(s2 s3);
    like( $out, qr/so s2 s3 is free to review/, 'and only the branches still there are offered' );
};

done_testing();
