#!/usr/bin/perl
# SM943 ruling 2 (2026-10-09): the STRUCTURED nav read needs no capability
# beyond the surface's base access, identically on both surfaces; the write
# stays manage_nav.
#
# History: SM421 gated read_nav on manage_nav, because the API's nav-read and a
# WebDAV GET of nav.conf demanded it and the MCP read undershot. The release
# manager ruled the other way for the structured read: "As nav is public, do we
# need a cap to be able to read it? ... Surfaces should be consistent." So
# read_nav and nav-read take none, set_nav and nav-save keep manage_nav, and the
# raw file (WebDAV GET, read_file) keeps manage_nav. What the read reaches is
# the caller's own domains (SM976); t/integration/113 drives that.
#
# Asserted against the declarations, because the declaration IS the gate here -
# the MCP dispatcher reads `cap`, the control API reads %GATE, before any run.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use lib repo_root() . '/lib';
use Lazysite::ControlApi::Actions ();

my $mcp = repo_root() . '/lazysite-mcp.pl';
plan skip_all => "no $mcp" unless -f $mcp;
my $src = do { open my $fh, '<', $mcp or die $!; local $/; <$fh> };

sub tool_block {
    my ($name) = @_;
    my ($b)    = $src =~ /\n    \Q$name\E => \{(.*?)\n    \},\n/s;
    ( my $code = $b // '' ) =~ s/^\s*#.*$//mg;
    return $code;
}

like( tool_block('read_nav'), qr/cap\s*=>\s*undef\b/,
    'read_nav needs no capability beyond MCP access' )
    or diag('SM943 ruling 2: the nav is public; its structured read is not gated.');
like( tool_block('set_nav'), qr/cap\s*=>\s*'manage_nav'/, 'set_nav is gated on manage_nav' );

my %gate = %Lazysite::ControlApi::Actions::GATE;
is( $gate{'nav-read'}, 'ALWAYS', 'nav-read needs no capability beyond control-API access' );
is_deeply( $gate{'nav-save'}, ['manage_nav'], 'nav-save is gated on manage_nav alone' );

# The control: this must not have quietly re-gated every tool.
like( tool_block('read_file'), qr/cap\s*=>\s*'manage_content'/,
    'read_file still asks for manage_content - the change is scoped to the nav read' );

done_testing();
