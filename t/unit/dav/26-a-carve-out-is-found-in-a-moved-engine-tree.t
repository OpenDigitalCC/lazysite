#!/usr/bin/perl
# SM850: WebDAV reaches the nav carve-out in the engine tree wherever it is.
#
# lazysite/nav.conf is writable over WebDAV with manage_nav (t/unit/dav/10).
# resolve_under_docroot rooted every path at the docroot, so on a site whose
# engine tree moved beside it (SM293) the file was looked for in a directory
# that is not there. A `lazysite/...` rel - one authorise() has already ruled
# on - now roots at the engine tree, and is confined to it.
#
# Found reading for SM850; reproduced before the fix.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper      qw(run_dav setup_dav_site grant_caps);
use Lazysite::Paths ();

my $s    = setup_dav_site( conf => "webdav_enabled: true\n", caps => ['webdav'] );
my $doc  = $s->{docroot};
my $auth = $s->{auth};
grant_caps( $doc, 'deploy', 'manage_nav' );

my $lz = Lazysite::Paths::external_lazysite_dir($doc);
rename "$doc/lazysite", $lz or die "migrate: $!";
is( Lazysite::Paths::lazysite_dir($doc), $lz, 'the canary: the site is migrated' );

my $r = run_dav( $doc, 'PUT', '/lazysite/nav.conf', HTTP_AUTHORIZATION => $auth, body => "Home | /\nDocs | /docs\n" );
ok( $r->{code} == 201 || $r->{code} == 204, 'the nav write is allowed with manage_nav' ) or diag "code $r->{code}";
my $got = do { open my $fh, '<', "$lz/nav.conf" or die "$lz/nav.conf: $!"; local $/; <$fh> };
like( $got, qr/Docs \| \/docs/, 'and lands in the engine tree the site renders from' );

my $p = run_dav( $doc, 'PROPFIND', '/lazysite/nav.conf', HTTP_AUTHORIZATION => $auth, HTTP_DEPTH => '0' );
is( $p->{code}, 207, 'and is found there' );

ok( !-e "$doc/lazysite", 'no stray engine tree was made inside the served tree' );

my $c = run_dav( $doc, 'PUT', '/lazysite/lazysite.conf', HTTP_AUTHORIZATION => $auth, body => "plugins: evil\n" );
is( $c->{code}, 403, 'lazysite.conf stays refused - authorise() still rules by rel' );

done_testing();
