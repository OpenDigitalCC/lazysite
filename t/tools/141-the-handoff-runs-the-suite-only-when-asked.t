#!/usr/bin/perl
# SM1061: THE HANDOFF IS THE PRECHECK; THE WHOLE SUITE ONLY WHEN ASKED.
#
# Ruled by the release manager, 2026-10-12: four agents each ran the whole
# plain suite in their handoff at once on an 8-core host, the load reached
# 26-30, and every suite nearly doubled. So a default handoff runs no whole
# suite at all. `--full` runs it, and `--release` (a branch bound for a cut)
# implies it - both through tools/suite.sh, so the run takes the host-wide lock
# instead of joining a pile-up.
#
# Driven in a scratch repository with the real handoff.sh and suite.sh, and a
# `prove` on PATH that records how it was called. No real suite runs.
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
    copy( "$root/tools/handoff.sh", "$d/tools/handoff.sh" ) or die $!;
    copy( "$root/tools/suite.sh",   "$d/tools/suite.sh" )   or die $!;
    spit( "$d/tools/precheck.sh",           qq{echo "PRECHECK \$1" >> calls\n} );
    spit( "$d/tools/regen-generated.sh",    "exit 0\n" );
    spit( "$d/tools/tracked-tree-check.pl", "exit 0;\n" );
    spit( "$d/tools/bench.pl", qq{open my \$f, '>>', 'calls' or die; print {\$f} "BENCH\\n";\n} );
    spit( "$d/bin/prove", <<'SH' );
#!/bin/sh
echo "PROVE $*" >> calls
echo "Files=1, Tests=1,  0 wallclock secs"
[ -z "${STUB_PROVE_FAIL:-}" ]
SH
    chmod 0755, "$d/bin/prove";
    spit( "$d/.gitignore", "tmp/\ncalls\nbin/\n" );
    git( $d, 'add',      '-A' );
    git( $d, 'commit',   '-q', '-m', 'base' );
    git( $d, 'checkout', '-q', '-b', 'feature' );
    spit( "$d/f", "f\n" );
    git( $d, 'add', 'f' );
    git( $d, 'commit', '-q', '-m', 'feature' );
    return $d;
}

sub handoff {
    my ( $d, @args ) = @_;
    local $ENV{PATH} = "$d/bin:$ENV{PATH}";
    my $out = run_cmd( 'bash', "$d/tools/handoff.sh", @args );
    return ( $? >> 8, $out );
}

subtest 'a default handoff never runs prove -lr' => sub {
    my $d = repo();
    my ( $rc, $out ) = handoff($d);
    is( $rc,               0,                 'READY' ) or diag($out);
    is( slurp("$d/calls"), "PRECHECK main\n", 'the precheck ran, and nothing called prove' );
    like( $out, qr/^READY FOR REVIEW: feature [0-9a-f]+ \(precheck passed\)$/m, 'the READY line says precheck passed' );
    unlike( $out, qr/suite/, 'and says nothing of a suite' );
    ok( !-e "$d/.git/lazysite-suite.lock", 'the suite lock was never taken' );
};

subtest '--full runs the whole suite, through tools/suite.sh' => sub {
    my $d = repo();
    my ( $rc, $out ) = handoff( $d, '--full' );
    is( $rc, 0, 'READY' ) or diag($out);
    like( slurp("$d/calls"), qr/\APRECHECK main\nPROVE -lr -j\d+ t\/\n\z/, 'precheck, then prove -lr -j<nproc> t/ once' );
    like( $out, qr/^==> suite: prove -lr/m, '...started by suite.sh' );
    ok( -e "$d/.git/lazysite-suite.lock", '...which took the lock in the common git dir' );
    like( $out, qr/^READY FOR REVIEW: feature [0-9a-f]+ \(precheck passed; suite passed\)$/m, 'READY says both' );
};

subtest '--release implies --full, and adds the bench' => sub {
    my $d = repo();
    my ( $rc, $out ) = handoff( $d, '--release' );
    is( $rc, 0, 'READY' ) or diag($out);
    like( slurp("$d/calls"), qr/\APRECHECK main\nPROVE -lr -j\d+ t\/\nBENCH\n\z/, 'precheck, the suite, the bench' );
    like( $out, qr/^==> suite: prove -lr/m, 'the suite through suite.sh' );
    like( $out, qr/^READY FOR REVIEW: feature [0-9a-f]+ \(precheck passed; suite passed, bench passed\)$/m,
        'READY says all three' );
};

subtest 'a failing --full suite is NOT READY, and names the log' => sub {
    my $d = repo();
    local $ENV{STUB_PROVE_FAIL} = 1;
    my ( $rc, $out ) = handoff( $d, '--full' );
    is( $rc, 1, 'not ready' );
    like( $out, qr/the suite did not pass - tmp\/suite\.log/, 'naming the log' );
    unlike( $out, qr/READY FOR REVIEW/, 'and nothing is called ready' );
    is( git( $d, 'branch', '--show-current' ), 'feature', 'the branch stays checked out' );
};

done_testing();
