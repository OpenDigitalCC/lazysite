#!/usr/bin/perl
# SM515: two tools in the MCP table were written with `schema` instead of
# `inputSchema` and with no `cap`. The dispatcher treats a cap-less tool as
# channel-only, so any authenticated partner could call delete_brief, and
# no argument validation ran. Nothing caught it: the parity lints read the
# keys that WERE there. This one asserts the keys that must be: every
# entry in the tool table declares both `cap` and `inputSchema`. There is
# no legitimate cap-less tool - introspection (tools/list, whoami) lives
# outside the table.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
open my $fh, '<', "$root/lazysite-mcp.pl" or die $!;
my $src = do { local $/; <$fh> };
close $fh;

my @entries = $src =~ /^    ([a-z_]+) => \{\n(?:.*?)\n    \},\n/msg;
my %body;
while ( $src =~ /^    ([a-z_]+) => \{\n(.*?)\n    \},\n/msg ) { $body{$1} = $2 }
cmp_ok( scalar keys %body, '>=', 60, 'the tool table was parsed' );

my ( @no_cap, @no_schema, @wrong_key );
for my $t ( sort keys %body ) {
    push @no_cap,    $t unless $body{$t} =~ /^\s+cap\s*=>/m;
    push @no_schema, $t unless $body{$t} =~ /^\s+inputSchema\s*=>/m;
    push @wrong_key, $t if $body{$t} =~ /^\s+schema\s*=>/m;
}
is_deeply( \@no_cap, [], 'every tool declares a cap' )
    or diag("cap-less (any partner can call these): @no_cap");
is_deeply( \@no_schema, [], 'every tool declares an inputSchema' )
    or diag("schema-less (arguments unvalidated, null published): @no_schema");
is_deeply( \@wrong_key, [], 'no tool uses the key `schema` - it is silently ignored' )
    or diag("wrong key: @wrong_key");

# SM537: every tool carries its OWN annotation. %ANNOTATE named 47 of 69
# tools and the rest fell to the default [0,0,1] - reads advertised as
# open-world writes, drops and deletes as non-destructive - and clients drive
# per-call approval from those hints. The default stays as a safety net for
# the dispatcher, but no table entry may rely on it.
#
# SM943 stage 2: a twin's row comes from its action's declaration
# (Lazysite::ControlApi::Actions::mcp_annotations), and %OWN_ANNOTATE holds the
# rest - so "annotated" is the union of the two.
{
    my ($ann) = $src =~ /^my \%OWN_ANNOTATE = \((.*?)^\);/ms;
    ok( $ann, 'the %OWN_ANNOTATE map was found' );
    like( $src, qr/^my \%ANNOTATE\s*=\s*Lazysite::ControlApi::Actions::mcp_annotations\(\);/m,
        'and %ANNOTATE starts from the twins\' derived rows' );
    my @own = ( $ann // '' ) =~ /^\s*([a-z_]+)\s*=>\s*\[/mg;
    # Four tools were written twice in the hand-kept table, and a Perl hash keeps
    # the LAST row in silence - so two rows that disagreed would publish whichever
    # was typed second.
    my %count;
    $count{$_}++ for @own;
    my @twice = grep { $count{$_} > 1 } sort keys %count;
    is_deeply( \@twice, [], 'no tool has two rows' )
        or diag("written more than once: @twice");
    require Lazysite::ControlApi::Actions;
    my %twin      = Lazysite::ControlApi::Actions::mcp_annotations();
    my %annotated = ( map { $_ => 1 } @own, keys %twin );
    cmp_ok( scalar keys %annotated, '>=', 60, 'the annotation map was parsed' );
    my @default = grep { !$annotated{$_} } sort keys %body;
    is_deeply( \@default, [], 'every tool has an explicit annotation (none falls to the default)' )
        or diag("on the default [0,0,1]: @default");
    my @stale = grep { !$body{$_} } sort keys %annotated;
    is_deeply( \@stale, [], 'every annotation names a tool that exists' )
        or diag("annotated but not in the table: @stale");
}

done_testing();
