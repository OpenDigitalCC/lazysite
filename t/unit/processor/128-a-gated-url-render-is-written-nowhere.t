#!/usr/bin/perl
# SM1069: process_url writes no render for a gated page.
#
# t/integration/240 cannot reach a successful fetch without the network, so the
# write half is held here, in process, with fetch_url standing in for the
# remote: a protected render is returned and written nowhere (no render cache,
# no registry update); an unprotected one is cached as before.
use strict;
use warnings;
use Test::More;
use Cwd qw(realpath);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_test_site site_tempdir);

my $docroot = realpath( site_tempdir() );
setup_test_site($docroot);
sub put { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
put( "$docroot/remote.url", "http://example.invalid/page\n" );

load_processor($docroot);
my $fetches = 0;
{
    no warnings qw(redefine once);
    *main::fetch_url = sub { $fetches++; return "---\ntitle: Remote\n---\nREMOTE-BODY-1069\n" };
}

my $html = "$docroot/remote.html";

subtest 'protected: rendered, written nowhere, never answered from the cache' => sub {
    my ($page) = main::process_url( "$docroot/remote.url", $html, time, 1 );
    like( $page, qr/REMOTE-BODY-1069/, 'the render is returned' );
    ok( !-f $html, 'and no render is written' );

    put( $html, "<html>CACHED-1069</html>\n" );
    ($page) = main::process_url( "$docroot/remote.url", $html, time, 1 );
    unlike( $page, qr/CACHED-1069/, 'a fresh cached render is not served to it' );
    unlink $html;
};

subtest 'THE CONTROL: unprotected, the render is cached as before' => sub {
    $fetches = 0;
    my ($page) = main::process_url( "$docroot/remote.url", $html, time );
    like( $page, qr/REMOTE-BODY-1069/, 'rendered' );
    ok( -f $html, 'and written to the render cache' );
    main::process_url( "$docroot/remote.url", $html, time );
    is( $fetches, 1, 'and the next request is answered from it' );
};

done_testing();
