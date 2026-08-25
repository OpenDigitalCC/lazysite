#!/usr/bin/perl
# SM533: a layout install cleans up after itself.
#
# Manager/Layouts.pm has one temporary-directory cleaner, guarded so it only
# removes a path this module minted. The guard named one prefix,
# /tmp/lazysite-layouts-<pid>, which the catalogue actions use. The manifest
# install works in /tmp/lazysite-layout-install-<pid> and handed THAT to the
# cleaner on every exit - a no-op, so every install_layout call over the API
# or MCP left its downloaded packages in /tmp and reported success as though
# it had tidied (tmp/tl-probe-tmp-leak.pl).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use Lazysite::Manager::Layouts ();

my $root = tempdir( CLEANUP => 1 );
my $doc  = "$root/site";
make_path("$doc/lazysite");
open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
print {$cf} "layout: base\ntheme: base\nlayouts_repo: example/layouts\n";
close $cf;
$Lazysite::Manager::Layouts::DOCROOT      = $doc;
$Lazysite::Manager::Layouts::LAZYSITE_DIR = "$doc/lazysite";

my $catalogue_dir = "/tmp/lazysite-layouts-$$";
my $install_dir   = "/tmp/lazysite-layout-install-$$";
END { remove_tree($_) for grep { -d } $catalogue_dir, $install_dir }

subtest 'the cleaner removes both directories this module mints' => sub {
    for my $d ( $catalogue_dir, $install_dir ) {
        make_path($d);
        Lazysite::Manager::Layouts::_cleanup_tmp_layouts($d);
        ok( !-d $d, "$d is removed" )
            or diag('The cleaner was handed a path it did not recognise and left it.');
    }
};

subtest 'the cleaner still refuses a path it did not mint' => sub {
    my $stranger = "$root/lazysite-layout-install-$$";
    make_path($stranger);
    Lazysite::Manager::Layouts::_cleanup_tmp_layouts($stranger);
    ok( -d $stranger, 'a same-named directory outside /tmp is left alone' );
    my $sibling = "/tmp/lazysite-layout-install-$$-not-ours";
    make_path($sibling);
    Lazysite::Manager::Layouts::_cleanup_tmp_layouts($sibling);
    ok( -d $sibling, 'a suffixed name is not a mint of ours either' );
    remove_tree($sibling);
};

subtest 'a manifest install leaves nothing in /tmp' => sub {
    plan skip_all => 'Archive::Zip not installed'
        unless eval { require Archive::Zip; 1 };
    my $saw_install_dir = 0;
    {
        no warnings 'redefine';
        *Lazysite::Manager::Layouts::_http_get = sub { return ( 1, '{}' ) };
        *Lazysite::Manager::Layouts::_resolve_manifest_install = sub {
            return {
                ok     => 1,
                layout => { name => 'demo', package => 'demo.zip' },
                themes => [ { name => 'demo', package => 'demo-theme.zip' } ],
            };
        };
        *Lazysite::Manager::Layouts::_download_extract = sub {
            my ( $url, $dir ) = @_;
            $saw_install_dir++ if index( $dir, "$install_dir/" ) == 0;
            make_path($dir);
            open my $f, '>', "$dir/pkg.zip" or die $!;
            print {$f} 'zip-bytes';
            close $f;
            return ( 1, $dir );
        };
        *Lazysite::Manager::Layouts::_install_layout_from_dir = sub { { ok => 1 } };
        *Lazysite::Manager::Layouts::_install_theme_from_dir  = sub { { ok => 1 } };
        *Lazysite::Manager::Layouts::_mirror_theme_assets     = sub { 0 };
    }
    my $r = Lazysite::Manager::Layouts::action_layout_install(
        '{"layout":"demo","theme":"demo"}');
    ok( $r->{ok}, 'the install succeeds' ) or diag explain $r;
    ok( $saw_install_dir, 'the packages were downloaded under the install dir' );
    ok( !-d $install_dir, 'and the install dir is gone when the call returns' )
        or diag("$install_dir is still there: the downloaded packages leak on every install");
};

done_testing();
