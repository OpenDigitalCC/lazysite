#!/usr/bin/perl
# SM735: docs/INDEX.md must list what the tree actually holds.
#
# The repository carries about 4.3MB of markdown across 719 files. The index
# exists so an agent can discover what is written down without reading it - and
# an index that has drifted is worse than none, because a reader trusts it while
# it is wrong. That is the same argument t/lint/58 makes for the generated
# action reference, and this is the same treatment.
#
# THE CHECK IS THE GENERATOR. Rather than re-implement the listing and compare
# two opinions, this runs tools/gen-doc-index.pl and diffs its output against
# the committed file - so the test cannot disagree with the tool about what the
# index SHOULD say, only about whether it says it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $gen  = "$root/tools/gen-doc-index.pl";
my $idx  = "$root/docs/INDEX.md";

ok( -f $gen, 'the generator is present' );
ok( -f $idx, 'docs/INDEX.md is present' ) or done_testing(), exit;

my $committed = do {
    open my $fh, '<', $idx or die $!;
    local $/; <$fh>;
};

open my $ph, '-|', $^X, $gen or die "cannot run the generator: $!";
my $fresh = do { local $/; <$ph> };
close $ph;

ok( length $fresh, 'the generator produced output' );

is( $committed, $fresh,
    'docs/INDEX.md matches the tree (regenerate: perl tools/gen-doc-index.pl --write)' );

# The index earns its place only if it is small enough to read. If it ever
# approaches the size of the corpus it maps, it has stopped being an index.
cmp_ok( length($committed), '<', 200_000,
    'the index is small enough to be read instead of the corpus' );

subtest 'it points at the tools rather than duplicating them' => sub {
    like( $committed, qr/backlog\.pl/,
        'the feature-request lister is named, not re-implemented' );
    unlike( $committed, qr/^\| \[`SM\d+/m,
        'and no feature request is listed here - that would be the second copy' );
};

done_testing();
