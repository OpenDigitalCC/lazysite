#!/usr/bin/perl
# SM1199 (found by the C2 restack, 2026-10-19): tools/precheck.sh ran
# `prove -l -j8` with the 8 written into the line, so an agent on the shared host
# could not keep the rule "at most -j2" short of editing the tool.
#
# The job count is now LAZYSITE_PROVE_JOBS or `--jobs N` (the flag wins), and 8
# when neither is given, so the release manager's runs are as they were. This
# runs the real script with a stub `prove` first on PATH that records its
# arguments; the suite itself is not run.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_cmd);

my $root = repo_root();
my $d    = site_tempdir();
mkdir "$d/bin" or die "mkdir: $!";
open my $s, '>', "$d/bin/prove" or die "stub: $!";
print {$s} qq{#!/bin/sh\necho "\$*" > "$d/prove.args"\necho "Files=0, Tests=0"\n};
close $s;
chmod 0755, "$d/bin/prove";

# Returns the arguments the stub prove was given, and the script's exit status.
sub run_precheck {
    my ( $env, @args ) = @_;
    unlink "$d/prove.args";
    local $ENV{PATH} = "$d/bin:$ENV{PATH}";
    delete local $ENV{LAZYSITE_PROVE_JOBS};
    local @ENV{ keys %$env } = values %$env;
    # HEAD as the base: nothing changed against it, so no related tests are named.
    my $out = run_cmd( 'bash', "$root/tools/precheck.sh", @args );
    my $rc  = $? >> 8;
    my $got = '';
    if ( open my $f, '<', "$d/prove.args" ) { local $/; $got = <$f>; close $f }
    return ( $got, $rc, $out );
}

my ( $a0, $rc0 ) = run_precheck( {}, 'HEAD' );
like( $a0, qr/(?:^|\s)-j8(?:\s|$)/, 'with no setting it is still -j8' );
is( $rc0, 0, '...and the stubbed run passes' );

my ( $a1 ) = run_precheck( { LAZYSITE_PROVE_JOBS => 2 }, 'HEAD' );
like( $a1, qr/(?:^|\s)-j2(?:\s|$)/, 'LAZYSITE_PROVE_JOBS=2 gives -j2' );
unlike( $a1, qr/-j8/, '...and not -j8' );

my ( $a2 ) = run_precheck( {}, '--jobs', '2', 'HEAD' );
like( $a2, qr/(?:^|\s)-j2(?:\s|$)/, '--jobs 2 gives -j2' );

my ( $a3 ) = run_precheck( { LAZYSITE_PROVE_JOBS => 4 }, '--jobs', '2', 'HEAD' );
like( $a3, qr/(?:^|\s)-j2(?:\s|$)/, 'the flag wins over the variable' );

my ( $a4, $rc4, $out4 ) = run_precheck( { LAZYSITE_PROVE_JOBS => 'many' }, 'HEAD' );
is( $a4, '', 'a job count that is not a number runs nothing' );
is( $rc4, 2, '...and exits 2' );
like( $out4, qr/positive whole number.*'many'/, '...naming the value' );

my ( $a5, $rc5 ) = run_precheck( {}, '--jobs' );
is( $a5, '', '--jobs with no number runs nothing' );
is( $rc5, 2, '...and exits 2' );

done_testing;
