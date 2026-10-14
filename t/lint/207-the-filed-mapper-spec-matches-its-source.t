#!/usr/bin/perl
# SM747: the mapper specification filed into SM747 still matches the copy of it that
# lazysite vendors.
#
# The specification lives in ANOTHER PROJECT - OOM - and is marked "DRAFT, growing
# with use". The release manager's direction is that SM747 is the one place for Odoo
# notes, so on 2026-10-01 the spec was copied into the filing. That makes two copies
# of a document only one of which is being edited, which is how two descriptions of
# one thing come to disagree.
#
# THIS FILING HAS ALREADY GONE STALE TWICE, which is why the gate is here rather than
# a note asking somebody to remember:
#   - its Sequencing table called the egress prerequisite "the piece being built
#     first" for three days after it shipped in 0.15.1;
#   - its status-note said the mapper spec was "not in the tree at all" while the
#     spec existed and had been written days earlier.
#
# WHAT IT COMPARES WITH, AND WHY (SM1081, 2026-10-14). This lint used to compare the
# filing with OOM's working tree, which OOM's developers edit all day, and it failed
# the release gate THREE TIMES on 2026-10-13 and 14 although nothing was wrong in
# lazysite. The release manager: "it isn't intended that oom changes will prevent a
# lazysite build ... we can't be testing against odoo to run a lazysite, it's just an
# extension, not core." So the filing is compared with the copy of the spec that sits
# INSIDE THIS REPOSITORY, t/vendor/oom/docs/MAPPER-SPEC.md - always present,
# deterministic, and held to its own hash by t/lint/261. There is therefore no "source
# not readable" skip: the source is always there. Adopting a newer OOM is a reviewable
# commit that runs tools/vendor-oom.sh and updates the filing with it; this lint fails
# until both agree, and says which way to fix it.
#
# A DIFFERENCE IS NOT A FAILURE OF THE OTHER PROJECT. It means the filing and the
# vendored snapshot disagree: update the filed section and the recorded hash to the
# snapshot, in the same change. Do not edit the hash alone: that silences the gate
# without fixing the disagreement.
use strict;
use warnings;
use Test::More;
use Digest::SHA qw(sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $filing = "$root/docs/feature-requests/SM747-a-site-app-reads-live-facts-from-odoo.md";

plan skip_all => "no $filing" unless -f $filing;

my $text = do {
    open my $fh, '<:utf8', $filing or die "$filing: $!";
    local $/;
    <$fh>;
};

# --- 1. the filing says where it came from and what it hashed to -------------
my ($source) = $text =~ m{^\| Source \| `([^`]+)` \|}m;
ok( $source, 'the filed spec names its source path' )
    or diag( 'Without the path nobody can check the copy, and this becomes a '
        . 'document of unknown provenance inside a filing of record.' );
is( $source // '', 't/vendor/oom/docs/MAPPER-SPEC.md',
    'and it is the copy lazysite vendors, inside this repository (not OOM\'s tree, not the host)' );

my ($sha) = $text =~ m{^\| sha256 at filing \| `([0-9a-f]{64})` \|}m;
ok( $sha, 'the filed spec records the sha256 it was filed at' )
    or diag( 'The hash is the whole mechanism: without it, drift is invisible '
        . 'until somebody reads both documents side by side.' );

# The claims the section must carry, because each is a decision a reader relies on.
like( $text, qr/status DRAFT/,
    'the filing says the source is a DRAFT rather than a settled specification' );
like( $text, qr/t\/lint\/207/,
    'and it points at this gate, so a reader knows the comparison exists' );

# --- 2. the copy is compared with the vendored spec - always there -------------
my $path = "$root/t/vendor/oom/docs/MAPPER-SPEC.md";
ok( -r $path, 'the vendored spec is in the repository' )
    or BAIL_OUT("$path is missing - run tools/vendor-oom.sh (t/lint/261 says what else)");

my $live = do {
    open my $fh, '<:raw', $path or die "$path: $!";
    local $/;
    <$fh>;
};
my $now = sha256_hex($live);

is( $now, $sha, 'the vendored spec is the one that was filed into SM747' )
    or diag( "  filed:     $sha\n"
        . "  vendored:  $now\n"
        . "  The filing and t/vendor/oom disagree. A newer OOM was vendored without re-filing the\n"
        . "  spec into SM747, or the filing was edited alone. RE-FILE: update the 'The mapper\n"
        . "  specification, FILED' section from t/vendor/oom/docs/MAPPER-SPEC.md, and the\n"
        . "  recorded sha256, in the SAME commit as tools/vendor-oom.sh.\n" );

# The open items the spec carries are the ones SM747 now owes. If the source stops
# listing them, the filing's copy of them is a claim about a document that no longer
# says it.
my ($open) = $live =~ m{^\#\# Open\s*\n(.*)\z}ms;
ok( defined $open && $open =~ /\S/, 'the spec still carries its own Open list, which SM747 reproduces' );

done_testing();
