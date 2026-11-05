#!/usr/bin/perl
# SEC-2026-07 / SM152: the extension runner used to interpolate the request `script`
# straight into a filesystem path (only a `-f` check), so extension-read/action with
# script="content/x.md" or "../../x.pl" executed an arbitrary on-disk file as Perl
# via qx($^X ...) - authenticated RCE by any manager-UI account. The fix routes
# extension resolution through a canonical REGISTRY (extensions/*.pl + the two core
# descriptor scripts); a request names an extension by its registry KEY, looked up
# exactly - nothing else resolves or runs. This pins that boundary.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Extensions qw(resolve_extension_script action_extension_action action_extension_read);

# --- install layout: base holds extensions/ + cgi-bin/, docroot is base/public_html
my $base = tempdir( CLEANUP => 1 );
my $doc  = "$base/public_html";
make_path( "$base/extensions", "$doc/content", "$doc/lazysite/logs" );

sub _w { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

# A legitimate extension that answers --describe.
_w( "$base/extensions/stub.pl",
    "\$_=join(' ',\@ARGV); if(/--describe/){print '{\"id\":\"stub\",\"label\":\"Stub\",\"actions\":[]}'} exit 0;\n" );

# The RCE payload: a .md whose Perl writes a marker, then fakes a descriptor.
my $marker = "$base/RCE_EXECUTED";
_w( "$doc/content/evil.md",
    "system('touch','$marker'); print '{\"id\":\"x\",\"actions\":[{\"id\":\"run\"}]}'; exit 0;\n" );
# And a .pl outside the docroot entirely (traversal target).
_w( "$base/evil.pl",
    "system('touch','$marker'); print '{\"id\":\"x\",\"actions\":[{\"id\":\"run\"}]}'; exit 0;\n" );

local $Lazysite::Manager::Extensions::DOCROOT = $doc;

# --- resolution: only registry keys resolve -------------------------------
{
    my $reg = Lazysite::Manager::Extensions::extension_registry();
    ok( $reg->{'extensions/stub.pl'}, 'registry contains the real extension' );
    is( resolve_extension_script('extensions/stub.pl'), $reg->{'extensions/stub.pl'},
        'a registered extension resolves to its canonical path' );

    is( resolve_extension_script('content/evil.md'), undef,
        'a docroot content file does NOT resolve (not a registry key)' );
    is( resolve_extension_script('../../evil.pl'), undef,
        'a traversal path does NOT resolve' );
    is( resolve_extension_script("$base/evil.pl"), undef,
        'an absolute path does NOT resolve' );
    is( resolve_extension_script('../evil.pl'), undef,
        'a parent-dir path does NOT resolve' );
}

# --- execution: the runner refuses to run a non-registry script -----------
{
    unlink $marker;
    my $r = action_extension_action( undef, 'content/evil.md', 'run', {} );
    ok( !$r->{ok},   'extension-action on a content file is refused' );
    ok( !-e $marker, 'the RCE payload did NOT execute (no marker)' );

    unlink $marker;
    my $r2 = action_extension_read( 'x', '../../evil.pl' );
    ok( !$r2->{ok},  'extension-read on a traversal path is refused' );
    ok( !-e $marker, 'the traversal RCE payload did NOT execute' );
}

done_testing();
