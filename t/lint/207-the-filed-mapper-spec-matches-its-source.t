#!/usr/bin/perl
# SM747: the mapper specification filed into SM747 still matches the document it
# was filed from.
#
# The specification lives in ANOTHER PROJECT - /srv/projects/odoo/oom - and is marked
# "DRAFT, growing with use". The release manager's direction is that SM747 is the one
# place for Odoo notes, so on 2026-10-01 the spec was copied into the filing. That
# makes two copies of a document only one of which is being edited, which is how two
# descriptions of one thing come to disagree.
#
# THIS FILING HAS ALREADY GONE STALE TWICE, which is why the gate is here rather than
# a note asking somebody to remember:
#   - its Sequencing table called the egress prerequisite "the piece being built
#     first" for three days after it shipped in 0.15.1;
#   - its status-note said the mapper spec was "not in the tree at all" while the
#     spec existed and had been written days earlier.
#
# TWO CHECKS, BECAUSE THE SOURCE IS NOT ALWAYS THERE - the shape t/lint/89 uses for
# the field-practice briefing, for the same reason. The OOM tree exists on one
# machine; in a release tarball, in CI or in a fresh clone it does not, and a gate
# that could only run there would be a gate that never runs. So:
#   1. the filing always records a sha256 and names the source path - checked here
#      with no access to the source at all;
#   2. where the source IS readable, its hash is compared, and a difference says the
#      spec moved on and the filing has not.
#
# A DIFFERENCE IS NOT A FAILURE OF THE OTHER PROJECT. It means the filed copy is
# behind: re-read the source, update the section and the recorded hash in the same
# change. The lint says so rather than leaving somebody to guess which way to fix it.
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
like( $source // '', qr{MAPPER-SPEC\.md\z},
    'and it is the mapper specification' );

my ($sha) = $text =~ m{^\| sha256 at filing \| `([0-9a-f]{64})` \|}m;
ok( $sha, 'the filed spec records the sha256 it was filed at' )
    or diag( 'The hash is the whole mechanism: without it, drift is invisible '
        . 'until somebody reads both documents side by side.' );

# The claims the section must carry, because each is a decision a reader relies on.
like( $text, qr/status DRAFT/,
    'the filing says the source is a DRAFT rather than a settled specification' );
like( $text, qr/t\/lint\/207/,
    'and it points at this gate, so a reader knows the comparison exists' );

# --- 2. and when the source is readable, the copy is compared ---------------
SKIP: {
    skip "the OOM tree is not on this machine ($source)", 2
        unless defined $source && -r $source;

    my $live = do {
        open my $fh, '<:raw', $source or die "$source: $!";
        local $/;
        <$fh>;
    };
    my $now = sha256_hex($live);

    is( $now, $sha, 'the source has not moved since the spec was filed' )
        or diag( "  filed:   $sha\n"
            . "  source:  $now\n"
            . "  The specification has been edited since it was filed into SM747.\n"
            . "  THE FILED COPY IS THE ONE THAT IS BEHIND - re-read $source,\n"
            . "  update the 'The mapper specification, FILED' section, and change\n"
            . "  the recorded sha256 in the SAME commit. Do not edit the hash\n"
            . "  alone: that silences the gate without fixing the disagreement.\n" );

    # The three open items the spec carries are the ones SM747 now owes. If the
    # source stops listing them, the filing's copy of them is a claim about a
    # document that no longer says it.
    my ($open) = $live =~ m{^\#\# Open\s*\n(.*)\z}ms;
    ok( defined $open && $open =~ /\S/,
        'the source still carries its own Open list, which SM747 reproduces' );
}

done_testing();
