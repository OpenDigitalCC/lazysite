#!/usr/bin/perl
# SM1176: EVERYTHING A COVERAGE RUN WRITES INTO THE TREE IS CLASSIFIED, by name.
#
# The 2026-10-18 coverage run stopped in its second group, manager: the first
# group, processor, had left cover_db-processor-cover-stderr.txt at the tree
# root (tools/coverage.sh keeps cover's stderr beside the suite log), and
# t/integration/259 builds the release manifest, which REFUSED it:
# "1 unclassified file(s)". SM1116 classified the suite log and not this file;
# t/tools/169 pinned only the names it had thought of. This test builds the
# names the way the tools do - from the log path, for the whole suite and every
# group - writes them (and the DB folders) into a scratch tree, and runs the
# real manifest builder over it. Nothing is written to the repo root.
#
# The control file proves the builder still refuses what nobody classified.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();

sub slurp { my ($p) = @_; open my $fh, '<', $p or die "$p: $!"; local $/; my $t = <$fh>; close $fh; return $t }
sub spit  { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my @groups = grep { /\A[a-z][\w-]*\z/ } split /\s+/, `\Q$^X\E \Q$root/tools/coverage-groups.pl\E --list 2>/dev/null`;
@groups = qw(processor manager) unless @groups;

# coverage.sh: COVER_ERR="${SUITE_LOG%-suite.*}-cover-stderr.txt"
# coverage-parts.sh: SUITE_LOG=cover_db-<group>-suite.log ; whole run: cover_db-suite.log
my @logs = ( 'cover_db-suite.log', map {"cover_db-$_-suite.log"} @groups );
my @files = map { my $e = $_; $e =~ s/-suite\..*\z//s; ( $_, "$e-cover-stderr.txt" ) } @logs;
my @dirs = ( 'cover_db', map {"cover_db-$_"} @groups );

like( slurp("$root/tools/coverage.sh"), qr/COVER_ERR="\$\{SUITE_LOG%-suite\.\*\}-cover-stderr\.txt"/,
    'coverage.sh still derives the stderr file from the suite log (the names built here are the tool\'s)' );

my $scratch = site_tempdir( leaf => 'tree' );
my $out = "$scratch/../manifest-out.json";

sub run_builder {
    my $dir = shift;
    my $err = "$scratch/../builder.err";
    my $rc  = system("$^X \Q$root/tools/build-manifest.pl\E --staged \Q$dir\E --out \Q$out\E >/dev/null 2>\Q$err\E");
    return ( $rc >> 8, slurp($err) );
}

make_path("$scratch/$_/structure") for @dirs;
spit( "$scratch/$_/structure/x", "x\n" ) for @dirs;
spit( "$scratch/$_", "x\n" ) for @files;

my ( $rc, $err ) = run_builder($scratch);
is( $rc, 0, 'the manifest builder accepts every file a coverage run writes (' . scalar(@files) . ' files, ' . scalar(@dirs) . ' DB folders)' )
    or diag $err;

spit( "$scratch/notes-from-nobody.txt", "x\n" );
( $rc, $err ) = run_builder($scratch);
isnt( $rc, 0, 'control: an unrelated unclassified file is still refused' );
like( $err, qr/notes-from-nobody\.txt/, 'and the refusal names it' );

# What the scripts may write at the tree root: only cover_db-named files and
# folders (the class the exclude rule covers), the lock (a root dotfile), and
# the tracked record under dist/config. A new path outside those fails here.
for my $s (qw(coverage.sh coverage-parts.sh)) {
    my $src = slurp("$root/tools/$s");
    $src =~ s/^\s*#.*$//mg;
    my @bad = grep { !m{\Acover_db(?:-.*)?\z|\A(?:tools|dist|\.coverage\.lock|\.git)\z} }
        map { m!\$ROOT/([^"\s/}]+)! ? $1 : () } split /\n/, $src;
    is_deeply( \@bad, [], "$s: every path built under \$ROOT is cover_db-named, tools/, dist/ or the lock" );
}

done_testing;
