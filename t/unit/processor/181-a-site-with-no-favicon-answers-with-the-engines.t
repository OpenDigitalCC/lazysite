#!/usr/bin/perl
# SM1397: A SITE WITH NO FAVICON OF ITS OWN ANSWERS /favicon.ico AND /favicon.svg
# WITH THE ENGINE'S, so a hand-made layout that links one (a layout with no
# default_theme and no resolving theme emits /favicon.svg) does not 404 on a
# fresh site. Through the real processor:
#
#   * with no file, /favicon.svg is an SVG and /favicon.ico a real ICO (the
#     header, one 16x16 entry, a 32-bit image), both 200, cacheable, and HEAD
#     gets the headers alone;
#   * a file the site has wins, from the docroot and from a domain's content
#     root;
#   * any other missing path is still not found.
#
# Sabotage: drop the fallback's call before not_found and the first case 404s.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_processor site_tempdir);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub status_of { my ($r) = @_; my ($s) = $r =~ /Status:\s*(\d+)/; return $s // 200 }
sub body_of  { my ($r) = @_; my ($b) = $r =~ /\r?\n\r?\n(.*)\z/s; return $b // '' }

my $d = site_tempdir();
make_path("$d/lazysite");
spit( "$d/lazysite/lazysite.conf", "site_name: T\nalias_hosts: two.test\nalias.two.test.content_root: two\n" );
make_path("$d/two");
spit( "$d/index.md",     "---\ntitle: Home\n---\n\nHome.\n" );
spit( "$d/two/index.md", "---\ntitle: Two\n---\n\nTwo.\n" );

subtest 'no file: the engine answers both' => sub {
    my $svg = run_processor( $d, '/favicon.svg' );
    is( status_of($svg), 200, '/favicon.svg answers 200' );
    like( $svg, qr{^Content-Type: image/svg\+xml}mi, '...as SVG' );
    like( body_of($svg), qr{\A<svg xmlns="http://www\.w3\.org/2000/svg"}, '...an SVG document' );
    like( $svg, qr{^Cache-Control: public, max-age=3600}m, '...cacheable for an hour' );

    my $ico = run_processor( $d, '/favicon.ico' );
    is( status_of($ico), 200, '/favicon.ico answers 200' );
    like( $ico, qr{^Content-Type: image/x-icon}mi, '...as an icon' );
    my $b = body_of($ico);
    my ( $res, $type, $count ) = unpack( 'vvv', $b );
    is( "$res/$type/$count", '0/1/1', 'a real ICO: reserved 0, type 1, one entry' );
    my ( $w, $h, undef, undef, $planes, $bpp, $size, $off ) = unpack( 'CCCCvvVV', substr( $b, 6, 16 ) );
    is( "${w}x$h", '16x16', '...16 by 16' );
    is( $bpp, 32, '...32 bits a pixel' );
    is( length($b), $off + $size, '...and the image is exactly what the entry declares' );
    my ( $hdr, $bw, $bh ) = unpack( 'VVV', substr( $b, $off, 12 ) );
    is( "$hdr/$bw/$bh", '40/16/32', 'a BITMAPINFOHEADER with the height doubled for the mask' );
    like( $ico, qr{^Content-Length: \d+}m, 'with its length' );

    my $head = run_processor( $d, '/favicon.ico', REQUEST_METHOD => 'HEAD' );
    is( status_of($head), 200, 'HEAD answers 200' );
    is( body_of($head), '', '...with no body' );
};

subtest 'a file the site has wins' => sub {
    spit( "$d/favicon.svg", '<svg xmlns="http://www.w3.org/2000/svg"><!-- MINE --></svg>' );
    like( body_of( run_processor( $d, '/favicon.svg' ) ), qr/MINE/, 'the docroot\'s own file' );
    spit( "$d/two/favicon.svg", '<svg xmlns="http://www.w3.org/2000/svg"><!-- TWO --></svg>' );
    like( body_of( run_processor( $d, '/favicon.svg', HTTP_HOST => 'two.test' ) ), qr/TWO/, 'a domain\'s own file from its content root' );
    unlink "$d/two/favicon.svg";
    like( body_of( run_processor( $d, '/favicon.svg', HTTP_HOST => 'two.test' ) ), qr/MINE/,
        'a domain with none falls back to the docroot\'s before the engine\'s' );
    unlink "$d/favicon.svg";
    unlike( body_of( run_processor( $d, '/favicon.svg' ) ), qr/MINE/, 'the file gone, the engine\'s again' );
};

subtest 'nothing else is invented' => sub {
    is( status_of( run_processor( $d, '/favicon.png' ) ),    404, '/favicon.png is not found' );
    is( status_of( run_processor( $d, '/icons/favicon.ico' ) ), 404, 'and only at the root' );
};

done_testing;
