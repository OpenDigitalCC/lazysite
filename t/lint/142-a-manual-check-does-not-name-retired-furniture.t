#!/usr/bin/perl
# N141-03: docs/MANUAL-CHECKS.md does not send a walker looking for something
# the product deliberately removed.
#
# Tier B5 spoke of the "Protected sections panel". SM635 retired it -
# loadProtectedSections() says so in its own first line, "this no longer paints
# a card - it loads the map the LISTING reads" - and protection now shows as a
# padlock on the folder's own row. The check was right about the behaviour and
# wrong about where to look, which cost the site agent time on 0.13.16 and was
# reported from a walk that PASSED.
#
# WHY A TEST AND NOT JUST AN EDIT. A manual check is a document about a product,
# and this whole register exists because such documents go stale invisibly.
# Fixing the sentence without pinning it is how it comes back the next time
# somebody writes from memory.
#
# THE PIN IS TWO-WAY, and that is the point. It asserts the doc's claim AND the
# code that makes the claim true, so whichever side moves, this fails and says
# which - rather than the doc quietly becoming wrong again while a test about
# it goes on passing.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return undef;
    local $/;
    return <$fh>;
}

my $checks = slurp("$root/docs/MANUAL-CHECKS.md");
my $files  = slurp("$root/starter/manager/files.md");
ok( $checks, 'MANUAL-CHECKS.md is readable' ) or do { done_testing(); exit };
ok( $files,  'files.md is readable' )         or do { done_testing(); exit };

# --- the product really has retired the card --------------------------------
#
# Read from the code, never asserted from memory: if the card ever comes back,
# the doc's correction becomes the wrong one and this says so first.
like( $files, qr/no longer paints a card/,
    'the listing still says it paints no card (SM635)' )
    or diag( 'If the Protected sections card returned, MANUAL-CHECKS B5 needs '
        . 'its note removing - the correction below would then be the stale '
        . 'thing.' );

# --- and the check no longer sends anyone to look for it ---------------------
my ($tier_b) = $checks =~ /### Tier B(.*?)### Tier C/s;
ok( $tier_b, 'the Tier B block was located' ) or do { done_testing(); exit };

ok( $tier_b !~ /Protected sections (?:panel|card)\b(?![^.]*retired)/,
    'Tier B does not name a Protected sections panel as somewhere to go' )
    or diag( 'SM635 removed it. Protection shows as a padlock on the folder row '
        . 'in Files. A check that names retired furniture costs its walker the '
        . 'time it takes to conclude the feature is missing.' );

like( $tier_b, qr/retired\s+by SM635/,
    'and it says where protection actually shows, with the reason' );

# --- B4 carries what the walk actually found ---------------------------------
#
# A gated section is absent from the sitemap too. Reading an absence as proof of
# draft is the mistake the note prevents.
like( $tier_b, qr/GATED section is also absent from the sitemap/i,
    'B4 notes that a gated section is absent from the sitemap as well' )
    or diag( 'Otherwise an absence from /sitemap.xml reads as "this is draft" '
        . 'when it only shows the section is protected somehow.' );

done_testing();
