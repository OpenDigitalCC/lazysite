#!/usr/bin/perl
# SEC-2026-07 / SM152: the plugin runner used to interpolate the request `script`
# straight into a filesystem path (only a `-f` check), so plugin-read/action with
# script="content/x.md" or "../../x.pl" executed an arbitrary on-disk file as Perl
# via qx($^X ...) - authenticated RCE by any manager-UI account. The fix routes
# plugin resolution through a canonical REGISTRY (plugins/*.pl + the two core
# descriptor scripts); a request names a plugin by its registry KEY, looked up
# exactly - nothing else resolves or runs. This pins that boundary.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Plugins qw(resolve_plugin_script action_plugin_action action_plugin_read);

# --- install layout: base holds plugins/ + cgi-bin/, docroot is base/public_html
my $base = tempdir( CLEANUP => 1 );
my $doc  = "$base/public_html";
make_path( "$base/plugins", "$doc/content", "$doc/lazysite/logs" );

sub _w { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

# A legitimate plugin that answers --describe.
_w( "$base/plugins/stub.pl",
    "\$_=join(' ',\@ARGV); if(/--describe/){print '{\"id\":\"stub\",\"label\":\"Stub\",\"actions\":[]}'} exit 0;\n" );

# The RCE payload: a .md whose Perl writes a marker, then fakes a descriptor.
my $marker = "$base/RCE_EXECUTED";
_w( "$doc/content/evil.md",
    "system('touch','$marker'); print '{\"id\":\"x\",\"actions\":[{\"id\":\"run\"}]}'; exit 0;\n" );
# And a .pl outside the docroot entirely (traversal target).
_w( "$base/evil.pl",
    "system('touch','$marker'); print '{\"id\":\"x\",\"actions\":[{\"id\":\"run\"}]}'; exit 0;\n" );

local $Lazysite::Manager::Plugins::DOCROOT = $doc;

# --- resolution: only registry keys resolve -------------------------------
{
    my $reg = Lazysite::Manager::Plugins::plugin_registry();
    ok( $reg->{'plugins/stub.pl'}, 'registry contains the real plugin' );
    is( resolve_plugin_script('plugins/stub.pl'), $reg->{'plugins/stub.pl'},
        'a registered plugin resolves to its canonical path' );

    is( resolve_plugin_script('content/evil.md'), undef,
        'a docroot content file does NOT resolve (not a registry key)' );
    is( resolve_plugin_script('../../evil.pl'), undef,
        'a traversal path does NOT resolve' );
    is( resolve_plugin_script("$base/evil.pl"), undef,
        'an absolute path does NOT resolve' );
    is( resolve_plugin_script('../evil.pl'), undef,
        'a parent-dir path does NOT resolve' );
}

# --- execution: the runner refuses to run a non-registry script -----------
{
    unlink $marker;
    my $r = action_plugin_action( undef, 'content/evil.md', 'run', {} );
    ok( !$r->{ok},   'plugin-action on a content file is refused' );
    ok( !-e $marker, 'the RCE payload did NOT execute (no marker)' );

    unlink $marker;
    my $r2 = action_plugin_read( 'x', '../../evil.pl' );
    ok( !$r2->{ok},  'plugin-read on a traversal path is refused' );
    ok( !-e $marker, 'the traversal RCE payload did NOT execute' );
}

done_testing();
