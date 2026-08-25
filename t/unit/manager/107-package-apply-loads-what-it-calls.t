#!/usr/bin/perl
# SM546: whether an apply works must not depend on what some other code
# happened to load earlier in the process. package_apply called
# Backups::verify_sha256 without SitePackage ever loading Backups; only
# package_create and the snapshot branch of apply_and_configure did. The first
# caller taking the snapshot-free path in a clean process got a crash in
# place of a result. Found by the backups structural review (N3), proven by
# probe tmp/bp-probe-apply-no-backups.t.
#
# This test deliberately loads SitePackage and nothing else from the manager.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::SitePackage qw(package_apply apply_and_configure);

sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/backups", "$d/stage/content" );
spit( "$d/lazysite/lazysite.conf", "site_name: probe\n" );
spit( "$d/stage/site.json",
    '{"site_package":1,"keys":{"content_root":"x"},"nav":"base-inherited"}' );
spit( "$d/stage/content/index.md", "# hi\n" );
my $pkg = "$d/lazysite/backups/lazysite-site-x-20260101T000000Z.tar.gz";
system( 'tar', 'czf', $pkg, '-C', "$d/stage", '.' ) == 0 or die 'tar failed';
$Lazysite::Manager::SitePackage::DOCROOT = $d;

ok( $INC{'Lazysite/Manager/Backups.pm'},
    'using SitePackage brings Backups with it - the module it calls into' );

my $r = eval { package_apply( $pkg, content_root => 'sites/x' ) };
is( ref $r, 'HASH', 'package_apply from a process that loaded only SitePackage returns a hash' )
    or diag $@;
is( $r->{ok}, 1, 'and the apply succeeded' ) or diag explain $r;
ok( -f "$d/sites/x/index.md", 'the content arrived' );

my $r2 = eval { apply_and_configure( $pkg, content_root => 'sites/y', snapshot => 0 ) };
is( ref $r2, 'HASH', 'apply_and_configure(snapshot => 0) returns a hash too' ) or diag $@;

done_testing;
