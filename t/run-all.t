#!/usr/bin/perl
# Aggregate runner — executes every t/**/*.t and reports one pass/fail per file.
# Skipped when run under `prove` (which already discovers the children itself),
# to avoid duplicate execution and TAP-parser conflicts from nested output.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;

if ( $ENV{HARNESS_ACTIVE} ) {
    plan skip_all =>
        'run-all.t is standalone — prove already runs the children. '
      . 'Use `perl t/run-all.t` directly for an aggregate summary.';
}

my @files;
find(
    sub {
        return unless /\.t\z/ && !/run-all\.t\z/;
        push @files, $File::Find::name;
    },
    $FindBin::Bin
);

plan tests => scalar @files;

for my $file ( sort @files ) {
    # Capture child TAP so it doesn't leak into our stream.
    my $qfile = quotemeta $file;
    qx($^X $qfile >/dev/null 2>&1);
    my $rc = $?;
    is( $rc, 0, "pass: $file" );
}
