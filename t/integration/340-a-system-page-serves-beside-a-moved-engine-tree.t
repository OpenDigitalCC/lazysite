#!/usr/bin/perl
# SM1283: the engine's protected system pages (SM201) serve when the engine tree
# sits BESIDE the docroot (SM293's <docroot>-lazysite), not only inside it.
#
# The fallback chose lazysite/templates/system/claim.md and the content-root
# confinement then refused it, because that file's real path is outside the
# docroot once the tree has moved. So a site on the recommended layout with no
# docroot copy answered /claim and /login with a 404.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_processor site_tempdir);

my $root    = repo_root();
my $docroot = site_tempdir();
system( 'cp', '-r', "$root/starter/.", $docroot ) == 0 or die "cp starter failed\n";
make_path("$docroot/lazysite/cache");
system( 'cp', "$docroot/lazysite.conf.example", "$docroot/lazysite/lazysite.conf" ) == 0
    or die "cp conf failed\n";

sub status_of { my ($r) = @_; my ($s) = $r =~ /Status:\s*(\d+)/; return $s // 0 }

ok( !-f "$docroot/claim.md", 'the docroot has no claim.md of its own' );
is( status_of( run_processor( $docroot, '/claim', LAZYSITE_NOCACHE => 1 ) ),
    200, 'inside the docroot: /claim serves the engine default' );

rename "$docroot/lazysite", "$docroot-lazysite" or die "move the engine tree: $!\n";
ok( -f "$docroot-lazysite/templates/system/claim.md", 'the engine tree is beside the docroot' );

for my $page (qw(/claim /login)) {
    my $out = run_processor( $docroot, $page, LAZYSITE_NOCACHE => 1 );
    is( status_of($out), 200, "beside the docroot: $page serves the engine default, not a 404" );
}

# The exemption is for the engine's page trees only: a page that is not a
# system page still answers 404.
is( status_of( run_processor( $docroot, '/not-a-system-page', LAZYSITE_NOCACHE => 1 ) ),
    404, 'a page that is not a system page still 404s' );

done_testing();
