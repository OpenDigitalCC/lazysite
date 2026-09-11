#!/usr/bin/perl
# SM852 S2: a site package applied over a protected section keeps it protected.
#
# package_apply copied the package's content to "$DOCROOT/<content_root>/<rel>"
# for every file. A package carrying files under a folder that is protected on
# this site - built elsewhere, or here before the folder was protected - put
# public copies beside the private ones, and made a public folder at the gated
# path, so every later write under it left the store too.
#
# Found by the SM836 review; reproduced before the fix.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper                     qw(site_tempdir);
use Lazysite::Manager::SitePackage qw(package_create package_apply);

my $d    = site_tempdir();
my $priv = "$d-lazysite-private";
make_path( "$d/lazysite", "$d/sites/src/members", "$d/sites/dest", "$priv/sites/dest/members" );

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t }

spit( "$d/lazysite/lazysite.conf",
    "site_name: Agency\nalias_hosts: src.test, dest.test\n"
        . "alias.src.test.content_root: sites/src\nalias.dest.test.content_root: sites/dest\n" );
spit( "$d/sites/src/index.md",                "# Source\n" );
spit( "$d/sites/src/members/handbook.md",     "# Handbook\nFROM-THE-PACKAGE\n" );
spit( "$d/sites/dest/index.md",               "# Dest\n" );
spit( "$priv/sites/dest/members/handbook.md", "# Handbook\nTHE-PROTECTED-COPY\n" );

{
    no warnings 'once';
    $Lazysite::Manager::SitePackage::DOCROOT   = $d;
    $Lazysite::Manager::SitePackage::auth_user = 'tester';
}

my $made = package_create('src.test');
ok( $made->{ok}, 'the canary: the source domain packages' ) or BAIL_OUT( $made->{error} // 'no package' );

my $r = package_apply( "$d/lazysite/backups/$made->{name}", content_root => 'sites/dest' );
ok( $r->{ok}, 'applied' ) or diag explain $r;

like( slurp("$d/sites/dest/index.md"), qr/Source/, 'a public page is written in the public tree, as before' );
like( slurp("$priv/sites/dest/members/handbook.md"), qr/FROM-THE-PACKAGE/,
    'a page in the protected section is written in the private store' );
ok( !-e "$d/sites/dest/members", 'and no public folder was made at the gated path' );

done_testing();
