#!/usr/bin/perl
# SM126 D: the host-dependency doc is DERIVED from dist/config/sbom-deps.json,
# so it cannot silently drift. This test regenerates it with tools/gen-host-deps.pl
# and fails if the committed docs/reference/host-dependencies.md differs (the
# golden-file contract). It also smoke-tests lazysite-check.pl --dependencies.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# --- Golden: generator output == committed doc -----------------------------
my $gen = "$root/tools/gen-host-deps.pl";
my $doc = "$root/docs/reference/host-dependencies.md";
ok( -f $gen, 'gen-host-deps.pl present' );
ok( -f $doc, 'host-dependencies.md present' );

my $generated = `$^X \Q$gen\E 2>&1`;
is( $? >> 8, 0, 'gen-host-deps.pl exits 0' );

open my $fh, '<', $doc or die "cannot read $doc: $!";
my $committed = do { local $/; <$fh> };
close $fh;

is( $generated, $committed,
    'committed host-dependencies.md matches gen-host-deps.pl output '
  . '(regenerate with: perl tools/gen-host-deps.pl > docs/reference/host-dependencies.md)' );

# The generated doc must carry the do-not-edit marker and the install line.
like( $committed, qr/Generated file - do not edit by hand/, 'doc marked generated' );
like( $committed, qr/sudo apt-get install/, 'doc carries the install line' );
like( $committed, qr/libtext-multimarkdown-perl/, 'a known non-core package is listed' );

# --- lazysite-check.pl --dependencies smoke ---------------------------------
my $check = "$root/tools/lazysite-check.pl";
my $out = `$^X \Q$check\E --dependencies 2>&1`;
is( $? >> 8, 0, '--dependencies exits 0 (informational)' );
like( $out, qr/Non-core Perl modules:/, 'reports the non-core module section' );
like( $out, qr/\bTemplate\b/, 'lists Template (a non-core dependency)' );
like( $out, qr/\d+ of \d+ non-core modules present/, 'prints a present/total summary' );

done_testing();
