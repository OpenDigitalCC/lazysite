#!/usr/bin/perl
# SM654: the `unlocks` map is hand-kept beside the code it describes.
#
# describe-capabilities publishes an `unlocks` map per capability, by channel.
# It is what the briefing tells an agent to read and what an operator reads
# before granting. The site agent found it wrong three times in one afternoon,
# in three different fields:
#
#   manage_themes    map said 5 MCP tools; tools/list offered 34
#   manage_layouts   map said 4; offered 33 (confirmed symmetric)
#   manage_nav       map lists set_nav only, while read_nav declares
#                    cap => 'manage_nav', is admitted, and returns the nav
#
# Understating in one place and omitting in another is what makes it
# unreliable rather than merely wrong: it is neither an upper nor a lower bound
# on what a capability reaches, so a reader has no useful reading of it at all.
#
# THIS LINT COVERS THE HALF THAT IS MECHANICALLY CHECKABLE. An MCP tool
# declares its gate as `cap` / `cap_also` in %TOOLS - a fact, in data, that can
# be compared with the map. The control-API half cannot be checked the same way
# yet: %need holds PREDICATES (sub { $_[0]->{manage_content} }), so which
# capability a gate tests is not extractable without restructuring a
# security-critical table. That is worth doing and is recorded on SM654; it is
# not done here, because the cheap half of a rule is worth having now and a
# risky refactor of the gate is not a lint's business.
#
# THE THEMES/LAYOUTS ROWS ARE NOT CHECKED HERE EITHER, and deliberately. Those
# tools reach a capability through the `path_aware` rule - callable on SOME
# paths - which the listing has no vocabulary for. SM653 is that gap; until it
# has one, a lint would have to encode a rule the product cannot yet express.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper         qw(repo_root);
use Lazysite::Capabilities ();

my $root = repo_root();
my $mcp  = "$root/lazysite-mcp.pl";
plan skip_all => "no $mcp" unless -f $mcp;

my $src = do { open my $fh, '<', $mcp or die $!; local $/; <$fh> };

# WHAT EACH TOOL'S GATE ACTUALLY IS, from the declaration rather than from
# prose about it.
my ($tools_block) = $src =~ /\nmy %TOOLS = \((.*?)\n\);\n/s;
ok( defined $tools_block, 'the tool table was found' )
    or BAIL_OUT( 'no %TOOLS in lazysite-mcp.pl - this test would pass while '
        . 'comparing nothing, which is the failure mode it exists to catch' );

# ONE PASS. Two while(/g) loops over the same string do not both work: the
# first leaves pos() at the end and the second matches nothing, silently, so
# every path_aware tool would have been treated as checkable and the excluded
# set would have been empty without saying so.
my %gate;          # tool => [ capabilities that admit it ]
my %path_aware;    # tools reaching a capability by the SM653 path rule
while ( $tools_block =~ /^\s{4}(\w+)\s*=>\s*\{(.*?)^\s{4}\},/gms ) {
    my ( $name, $body ) = ( $1, $2 );
    my ($c)  = $body =~ /^\s*cap\s*=>\s*'([^']+)'/m;
    my ($ca) = $body =~ /^\s*cap_also\s*=>\s*'([^']+)'/m;
    $gate{$name}       = [ grep { defined && length } ( $c, $ca ) ];
    # NOT line-anchored: path_aware is declared on the same line as cap
    # (`cap => 'manage_content', path_aware => 1,`), so /^\s*path_aware/ matched
    # none of the 29 and the exclusion set came back empty - which the
    # not-vacuous assertion below is here to catch.
    $path_aware{$name} = 1 if $body =~ /\bpath_aware\s*=>\s*1/;
}
cmp_ok( scalar keys %gate, '>', 40, 'the tool table really parsed (not vacuous)' );
cmp_ok( scalar keys %path_aware, '>', 10,
    'path_aware tools exist and are being excluded knowingly' );

# describe() returns a WRAPPER - capabilities, channels, engine_owned, tasks -
# not a capability map. Indexing it directly made every lookup undef, so the
# loops below skipped every capability and passed while comparing nothing. The
# not-vacuous assertion further down is what caught it.
my $info = Lazysite::Capabilities::describe()->{capabilities};
ok( ref $info eq 'HASH' && keys %$info,
    'the capability map was found inside describe()' )
    or BAIL_OUT('no capabilities in describe() - nothing below would compare anything');

# --- every declared gate appears in that capability's unlocks.mcp -----------
# This is the read_nav case: a tool the gate admits, absent from the map, so an
# operator reading the map concludes the capability does not reach it.
my @missing;
my $compared = 0;
# NOT skipping path_aware here, and the first cut of this lint did - which made
# it pass while read_nav, the very omission SM654 measured, stayed missing.
# _tool_callable admits a tool when the caller holds its DECLARED cap, whatever
# path_aware does: the path rule is an ADDITIONAL way in for themes/layouts
# grants, not a replacement for the declaration. So a path_aware tool belongs in
# its declared capability's list exactly like any other. What path_aware muddies
# is the OTHER direction - whether it should also appear under manage_themes -
# and that is SM653's question, which this lint does not ask.
for my $tool ( sort keys %gate ) {
    for my $cap ( @{ $gate{$tool} } ) {
        my $entry = $info->{$cap} or next;    # channel caps have no unlocks map
        my $mcp_list = $entry->{unlocks}{mcp} or next;
        $compared++;
        next if grep { $_ eq $tool } @{$mcp_list};
        push @missing, "$cap does not list $tool, which declares it";
    }
}
# A count of what was actually compared, so this cannot pass by comparing
# nothing - which is exactly what it did while $info was the wrapper.
cmp_ok( $compared, '>', 20,
    'the comparison really ran (not vacuous)' );

is_deeply( \@missing, [], 'every tool a capability admits is named in its unlocks.mcp' )
    or diag( join "\n  ", '', @missing, '',
    'A tool the gate admits and the map omits is a grant that resolves and '
        . 'then appears not to - the reader concludes the capability does not '
        . 'reach it. Add it to unlocks.mcp in Capabilities.pm.' );

# --- and nothing is named that does not exist ------------------------------
# The other direction: a map naming a tool that was renamed or removed sends a
# reader looking for something that is not there.
my @ghosts;
for my $cap ( sort keys %$info ) {
    my $list = $info->{$cap}{unlocks}{mcp} or next;
    for my $tool ( @{$list} ) {
        push @ghosts, "$cap names $tool, which is not a tool" unless exists $gate{$tool};
    }
}
is_deeply( \@ghosts, [], 'every tool named in an unlocks.mcp really exists' )
    or diag( join "\n  ", '', @ghosts );

done_testing();
