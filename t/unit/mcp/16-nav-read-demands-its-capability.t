#!/usr/bin/perl
# SM421 (parity map F1): MCP's nav READ demanded manage_content where every
# other surface demands manage_nav.
#
# read_nav was declared path_aware, but its run passes only `host` - no path -
# so the dispatcher's carve-out pass had nothing to inspect and never reached
# the capability that owns nav.conf. WebDAV GET of nav.conf requires manage_nav;
# the API's token nav-read requires manage_nav; MCP's set_nav (the write)
# already required it. Only the MCP read undershot, on one surface out of three.
#
# Nav is public, so this is a consistency defect rather than a disclosure -
# which is exactly why it survived: nothing it leaked was secret, so nothing
# complained. The engine's rule about who owns nav.conf is the thing being
# restored.
#
# Asserted against the TOOL TABLE rather than by driving a grant, because the
# declaration IS the gate here - the dispatcher reads `cap` before any run.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $mcp = repo_root() . '/lazysite-mcp.pl';
plan skip_all => "no $mcp" unless -f $mcp;
my $src = do { open my $fh, '<', $mcp or die $!; local $/; <$fh> };

sub tool_block {
    my ($name) = @_;
    my ($b)    = $src =~ /\n    \Q$name\E => \{(.*?)\n    \},\n/s;
    return $b // '';
}

for my $t (qw(read_nav set_nav)) {
    my $b = tool_block($t);
    ok( length $b, "$t is declared" ) or next;
    ( my $code = $b ) =~ s/^\s*#.*$//mg;
    like( $code, qr/cap\s*=>\s*'manage_nav'/,
        "$t is gated on manage_nav - the capability that owns nav.conf" )
        or diag( "A nav operation gated on manage_content lets a grant without "
            . "manage_nav reach nav.conf on this surface while WebDAV and the "
            . "control API both refuse it." );
}

# The control: this must not have quietly re-gated every tool.
my $rf = tool_block('read_file');
like( $rf, qr/cap\s*=>\s*'manage_content'/,
    'read_file still asks for manage_content - the change is scoped to nav' );

done_testing();
