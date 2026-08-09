#!/usr/bin/perl
# SM259: the Domains page describes a domain ONCE.
#
# It used to carry two forms for the same object: #cfg-sheet (grouped sections,
# opens over the page - the pattern 0.9.15 moved the EDIT path onto) and
# #add-panel (an inline display:none block with its own three-column flex layout
# and its own copies of every field id). The operator's complaint was that the
# edit modal works well and the add form is clumsy; the deeper cost is that every
# future change to what a domain HAS lands twice, and one that lands once leaves
# two forms disagreeing.
#
# That is the same one-object-two-mechanisms shape SM255 spent a release removing
# from the conf writers, so it is worth a guard rather than trusting that nobody
# re-adds a second form.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
open my $fh, '<:utf8', "$root/starter/manager/domains.md" or die $!;
my $src = do { local $/; <$fh> };
close $fh;

# --- the retired form is gone, including its helpers ------------------------
for my $dead (qw(add-panel toggleAdd addDomain)) {
    unlike( $src, qr/\Q$dead\E/, "the retired add form leaves no '$dead' behind" );
}

# Its field ids are the tell: f-host, f-croot and friends were the second copy.
for my $id (qw(f-host f-croot f-siteurl f-sitename f-appearance f-seed f-clone-from)) {
    unlike( $src, qr/\Q$id\E/, "no orphaned '$id' from the retired form" );
}

# --- one renderer, two modes ------------------------------------------------
like( $src, qr/function domainSettingsHtml\(\s*row,\s*isCreate\s*\)/,
    'domainSettingsHtml takes the mode - one renderer, not two' );
like( $src, qr/function openCreateSheet\(/, 'the sheet opens in create mode' );
like( $src, qr/function createDomain\(/,    'and has its own submit' );
like( $src, qr/onclick="openCreateSheet\(\)"/,
    'the Add domain button opens the sheet' );

# --- the create-only behaviour survived the move ----------------------------
# These are the three things the add form had that Configure has no reason to,
# and losing any of them would make this a downgrade rather than a
# consolidation.
like( $src, qr/function cloneFrom\(/,      'copy-settings-from survived' );
like( $src, qr/NEW_HOST \+ '-seed'/,       'seed-a-home-page survived' );
like( $src, qr/function onNewHostInput\(/, 'the live site-URL derivation survived' );

# cloneFrom must write to the SHEET's fields; pointing at the retired form's ids
# is exactly the breakage this consolidation could have introduced silently.
my ($clone) = $src =~ /(function cloneFrom\b.*?\n\})/s;
ok( defined $clone, 'cloneFrom body located' );
like( $clone, qr/NEW_HOST/, 'cloneFrom fills the create sheet, not the old form' );

# --- one set of field ids ---------------------------------------------------
# The create sheet reuses editField's id scheme, so a new domain key is added in
# ONE place and appears in both modes.
like( $src, qr/var NEW_HOST = /, 'the create mode has a pseudo-host for its ids' );
like( $src, qr/editField\(host, k, row, isCreate\)/,
    'editField is shared by both modes' );

done_testing();
