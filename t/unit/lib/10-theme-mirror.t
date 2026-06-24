#!/usr/bin/perl
# SM080: the theme-asset mirror (/lazysite-assets/LAYOUT/THEME/) must be built
# on ACTIVATION, so theme_assets resolves for a copied-then-activated layout.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";

BEGIN {
    eval { require Template; 1 }
        or plan skip_all => 'Template Toolkit not available (layout validation needs it)';
}
use Lazysite::Manager::Themes qw(action_layout_activate);
use Lazysite::Manager::Files ();
use Lazysite::Manager::Common ();

sub w {
    my ( $p, $c ) = @_;
    make_path( ( $p =~ m{(.*)/} )[0] );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $c;
    close $fh;
}
sub slurp { open my $f, '<', $_[0] or return ''; local $/; <$f> }

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/manager/locks");
w( "$d/lazysite/layouts/base/layout.tt", '<html>[% content %]</html>' );
w( "$d/lazysite/layouts/base/themes/sky/theme.json", '{"name":"sky","layouts":["base"]}' );
w( "$d/lazysite/layouts/base/themes/sky/assets/main.css", 'body{color:teal}' );
w( "$d/lazysite/lazysite.conf", "site_name: T\n" );

$Lazysite::Manager::Themes::DOCROOT      = $d;
$Lazysite::Manager::Themes::LAZYSITE_DIR = "$d/lazysite";
$Lazysite::Manager::Themes::auth_user    = 'alice';
$Lazysite::Manager::Themes::action       = 'test';
$Lazysite::Manager::Files::DOCROOT       = $d;
$Lazysite::Manager::Files::LOCK_DIR      = "$d/lazysite/manager/locks";
$Lazysite::Manager::Files::auth_user     = 'alice';
$Lazysite::Manager::Common::DOCROOT      = $d;

my $mirror = "$d/lazysite-assets/base/sky/main.css";
ok( !-f $mirror, 'no asset mirror before activation' );

my $r = action_layout_activate( 'base', { theme => 'sky' } );
ok( $r->{ok}, 'layout + theme activated' ) or diag( $r->{error} );
ok( -f $mirror, 'SM080: asset mirror built at /lazysite-assets/base/sky/ on activation' );
is( slurp($mirror), 'body{color:teal}', 'mirrored CSS content is correct' );

done_testing();
