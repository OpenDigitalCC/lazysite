#!/usr/bin/perl
# SM126 B: the capability-map and quickstart docs are DERIVED from
# Lazysite::Capabilities (the same builder behind describe_capabilities), so they
# cannot drift from the live map. Regenerate and fail on any difference.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $gen  = "$root/tools/gen-capability-docs.pl";
ok( -f $gen, 'gen-capability-docs.pl present' );

# SM350 adds the control-API action reference to the same treatment: MCP has
# tools/list, this channel had no published reference at all, and a reference
# that can drift from the dispatcher is worse than none because a caller trusts
# it. t/lint/58 pins the module to the chain; this pins the page to the module.
for my $pair ( [ 'map', 'docs/reference/capability-map.md' ],
               [ 'quickstarts', 'docs/reference/quickstarts.md' ],
               [ 'actions', 'docs/reference/control-api-actions.md' ] ) {
    my ( $what, $rel ) = @{$pair};
    my $doc = "$root/$rel";
    ok( -f $doc, "$rel present" );

    my $generated = `$^X \Q$gen\E $what 2>&1`;
    is( $? >> 8, 0, "gen-capability-docs.pl $what exits 0" );

    open my $fh, '<', $doc or die "cannot read $doc: $!";
    my $committed = do { local $/; <$fh> };
    close $fh;

    is( $generated, $committed,
        "$rel matches the generator (regenerate: perl tools/gen-capability-docs.pl $what > $rel)" );
    like( $committed, qr/Generated file - do not edit by hand/, "$rel marked generated" );
}

# The map lists the engine-owned boundary and points at describe_capabilities.
open my $mf, '<', "$root/docs/reference/capability-map.md" or die $!;
my $mapdoc = do { local $/; <$mf> }; close $mf;
like( $mapdoc, qr/Engine-owned paths/, 'map documents the engine-owned boundary' );
like( $mapdoc, qr/describe_capabilities/, 'map points at the live endpoint' );

# The quickstarts name a real task and its capability.
open my $qf, '<', "$root/docs/reference/quickstarts.md" or die $!;
my $qs = do { local $/; <$qf> }; close $qf;
like( $qs, qr/Install and activate a theme/, 'quickstarts include the theme recipe' );
like( $qs, qr/`manage_themes`/, 'quickstart names the required capability' );

done_testing();
