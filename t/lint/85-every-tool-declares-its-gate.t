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

done_testing();
