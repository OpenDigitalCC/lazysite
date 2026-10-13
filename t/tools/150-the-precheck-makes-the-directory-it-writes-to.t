#!/usr/bin/perl
# THE PRECHECK MAKES THE DIRECTORY IT WRITES TO.
#
# tools/precheck.sh writes its prove output to tmp/precheck.log. tmp/ is
# ignored, so a fresh `git worktree add` has none, and the redirect failed
# before prove ran: the precheck - and the handoff that runs it - reported a
# FAIL on a branch with nothing wrong. Three agents hit it on 2026-10-12.
# t/tools/144's scratch tree made tmp/ itself, which is why no test saw it.
#
# Here the real precheck.sh runs in a scratch repository with NO tmp/, and a
# `prove` on PATH that records it ran. handoff.sh's own write under tmp/ (the
# bench log, --release) is held by its source: the directory is made first.
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
    return;
}
sub slurp { open my $f, '<', $_[0] or return ''; local $/; my $t = <$f>; close $f; return $t }

sub git {
    my ( $d, @a ) = @_;
    open my $ph, '-|', 'git', '-C', $d, @a or die "git @a: $!";
    my $o = do { local $/; <$ph> } // '';
    close $ph;
    return $o;
}

subtest 'precheck.sh in a worktree with no tmp/' => sub {
    my $d = tempdir( CLEANUP => 1 );
    git( $d, 'init',   '-q',         '-b', 'main' );
    git( $d, 'config', 'user.email', 't@example.invalid' );
    git( $d, 'config', 'user.name',  't' );
    make_path("$d/tools");
    copy( "$root/tools/precheck.sh",       "$d/tools/precheck.sh" )       or die $!;
    copy( "$root/tools/precheck-areas.pl", "$d/tools/precheck-areas.pl" ) or die $!;
    spit( "$d/lib/Foo.pm",        "package Foo; 1;\n" );
    spit( "$d/t/lint/01-a-lint.t", "1;\n" );
    spit( "$d/bin/prove", qq{#!/bin/sh\necho "\$*" > "\$STUB_CALLS"\necho "Files=1, Tests=1"\n} );
    chmod 0755, "$d/bin/prove";
    spit( "$d/.gitignore", "tmp/\nbin/\ncalls\n" );
    git( $d, 'add',      '-A' );
    git( $d, 'commit',   '-q', '-m', 'base' );
    git( $d, 'checkout', '-q', '-b', 'change' );
    spit( "$d/lib/Foo.pm", "package Foo; 2;\n" );
    git( $d, 'commit', '-q', '-am', 'change a module' );

    ok( !-e "$d/tmp", 'the scratch worktree has no tmp/, as a fresh worktree has none' );

    local $ENV{PATH}       = "$d/bin:$ENV{PATH}";
    local $ENV{STUB_CALLS} = "$d/calls";
    my $out = run_cmd( 'bash', "$d/tools/precheck.sh", 'main' );
    is( $? >> 8, 0, 'the precheck passed' ) or diag($out);
    like( slurp("$d/calls"), qr{t/lint/01-a-lint\.t}, 'prove ran, with the lints' );
    ok( -d "$d/tmp", 'tmp/ was made' );
    like( slurp("$d/tmp/precheck.log"), qr/^Files=1, Tests=1$/m, 'and the log is in it' );
    unlike( $out, qr/No such file or directory/, 'no redirect failed' );
};

subtest 'handoff.sh makes tmp/ before it writes the bench log' => sub {
    my $h     = slurp("$root/tools/handoff.sh");
    my $mkdir = index( $h, "\nmkdir -p tmp\n" );
    my $write = index( $h, '> tmp/handoff-bench.log' );
    ok( $write > 0, 'the handoff writes tmp/handoff-bench.log' );
    ok( $mkdir > 0 && $mkdir < $write, 'and makes tmp/ first, at the top level' );
};

subtest 'suite.sh makes tmp/ before it writes the suite log' => sub {
    my $s     = slurp("$root/tools/suite.sh");
    my $mkdir = index( $s, "\nmkdir -p tmp\n" );
    my $write = index( $s, '>"$LOG"' );
    ok( $write > 0, 'the suite writes its log' );
    ok( $mkdir > 0 && $mkdir < $write, 'and makes tmp/ first' );
};

done_testing();
