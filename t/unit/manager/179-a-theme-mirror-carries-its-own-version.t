#!/usr/bin/perl
# SM830, the engine half: a theme mirror carries its own version, and a layout
# can link it as [% theme_version %].
#
# The tokens link already keys on its own file's hash. main.css and the rest are
# linked by LAYOUT templates, which had only the engine version to key on - so an
# edited theme went on being served from every browser's cache until the next
# release. The mirror writer now records one fingerprint over every file it
# writes, and the render hands it to the layout.
#
# The property is the same one the tokens key holds: it moves when the bytes
# do, and ONLY then - a re-activation rewrites every file, and a key that moved
# on that would expire every visitor's cache for nothing.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir run_processor);

require Lazysite::Manager::Themes;

my $docroot = site_tempdir();
my $lazy    = "$docroot/lazysite";
my $tdir    = "$lazy/layouts/base/themes/brand";

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

spit( "$tdir/theme.json", encode_json( { name => 'brand', version => '1', layouts => ['base'] } ) );
spit( "$tdir/assets/main.css",      "body { color: #111; }\n" );
spit( "$tdir/assets/fonts/x.woff2", "\x00\x01FONTBYTES" );
spit( "$lazy/layouts/base/layout.tt",
    '<html><head><link rel="stylesheet" href="[% theme_assets %]/main.css?v=[% theme_version %]"></head>'
        . '<body>[% content %]</body></html>' );
spit( "$lazy/lazysite.conf", "site_name: T\nlayout: base\ntheme: brand\n" );
spit( "$docroot/index.md",   "---\ntitle: Home\n---\nHome.\n" );

{
    no warnings 'once';
    $Lazysite::Manager::Themes::LAZYSITE_DIR = $lazy;
    $Lazysite::Manager::Themes::DOCROOT      = $docroot;
}

my $mirror = "$docroot/lazysite-assets/base/brand";

sub mirror_and_read {
    Lazysite::Manager::Themes::_mirror_theme_assets( 'base', 'brand' );
    open my $fh, '<', "$mirror/.fingerprint" or return undef;
    my $v = <$fh>;
    close $fh;
    chomp $v;
    return $v;
}

sub rendered_key {
    unlink "$docroot/index.html";
    my ($v) = ( run_processor( $docroot, '/' ) // '' ) =~ m{/main\.css\?v=([^"]+)"};
    return $v;
}

my $k1 = mirror_and_read();
like( $k1 // '', qr/\A[0-9a-f]{12}\z/, 'the mirror carries a 12-hex fingerprint' );
is( rendered_key(), $k1, 'and the layout\'s link carries it as [% theme_version %]' );

is( mirror_and_read(), $k1, 're-mirroring identical bytes leaves it alone - a re-activation expires nothing' );

spit( "$tdir/assets/main.css", "body { color: #222; }\n" );
my $k2 = mirror_and_read();
isnt( $k2, $k1, 'editing a stylesheet moves it' );
is( rendered_key(), $k2, 'and the page links the new key, so browsers refetch' );

spit( "$tdir/assets/fonts/x.woff2", "\x00\x01OTHERFONT" );
isnt( mirror_and_read(), $k2, 'so does a binary asset - every file counts, not only the CSS' );

unlink "$mirror/.fingerprint";
spit( "$lazy/.install-state.json", encode_json( { version => '9.9.9-test' } ) );
is( rendered_key(), '9.9.9-test',
    'a mirror written before this has no fingerprint, and the key is the engine version - what these links carried before' );

done_testing();
