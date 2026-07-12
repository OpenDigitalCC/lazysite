#!/usr/bin/perl
# SM147: the built-in ::: qr content component. It ships under
# lazysite/templates/components and must resolve on ANY layout (even one with
# no components/ dir), rendering a container that draws the QR client-side from
# the shared public /assets/qrcode.js. The data is only ever carried in an
# escaped attribute (computed into a matrix in JS), never inserted as markup.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

# Install the real built-in component into the test site.
my $cdir = "$docroot/lazysite/templates/components";
make_path($cdir);
copy( "$FindBin::Bin/../../../starter/lazysite/templates/components/qr.tt",
    "$cdir/qr.tt" )
    or BAIL_OUT("cannot stage qr.tt: $!");

# A layout dir that ships NO components/ of its own - the built-in must still win.
my $layout = "$docroot/lazysite/layouts/base";
make_path($layout);

ok( main::_component_exists( $layout, 'qr' ),
    'built-in qr resolves even on a layout with no components/ dir' );

my $out = main::convert_fenced_components(
    "::: qr data=\"https://example.org/pay\" size=\"180\"\n:::\n",
    $layout, "$docroot/index.md", {} );

like( $out, qr/class="lz-qr"/, 'renders a QR container' );
like( $out, qr{data-qr="https://example\.org/pay"}, 'carries the data in an escaped attribute' );
like( $out, qr{data-qr-size="180"}, 'honours the size attribute' );
like( $out, qr{/assets/qrcode\.js}, 'loads the shared PUBLIC qrcode.js' );
unlike( $out, qr/^::: qr/m, 'the fence is consumed' );

# No data attribute -> a harmless comment, not a broken QR.
my $out2 = main::convert_fenced_components(
    "::: qr\n:::\n", $layout, "$docroot/index.md", {} );
unlike( $out2, qr/class="lz-qr"/, 'no data attribute renders no QR container' );

# A same-named LAYOUT component overrides the built-in.
make_path("$layout/components");
open my $lc, '>', "$layout/components/qr.tt" or BAIL_OUT($!);
print {$lc} 'LAYOUT-QR-OVERRIDE';
close $lc;
my $out3 = main::convert_fenced_components(
    "::: qr\nx\n:::\n", $layout, "$docroot/index.md", {} );
like( $out3, qr/LAYOUT-QR-OVERRIDE/, 'a layout component of the same name wins over the built-in' );

done_testing();
