#!/usr/bin/perl
# SM315: a theme that mirrors nothing says so, at activation and standing.
#
# THE DEFECT. Theme assets live at `layouts/<layout>/themes/<theme>/assets/` and
# are mirrored to `/lazysite-assets/<layout>/<theme>/` on activation. Put them
# one level higher - directly in `themes/<theme>/`, beside theme.json, which is
# where an author who has not dissected a working layout will naturally put them
# - and every single signal says it worked:
#
#   the upload succeeds
#   activate_layout returns ok:1
#   the mirror is created empty, or not at all
#   `theme_assets` resolves to nothing, so the stylesheet link is never emitted
#   every page returns 200, valid, fast and completely unstyled
#
# Measured on edge/0.10.9 while authoring a layout for a site build. The
# diagnosis took a SCREENSHOT: at the HTTP level a fully unstyled site is
# indistinguishable from a working one, and an agent building over MCP and
# WebDAV has no screenshot step. It would hand over an unstyled site reporting
# success.
#
# The tool already knew. `_mirror_theme_assets` runs at activation and could
# count what it copied; it counted nothing and said nothing. Zero assets for a
# theme that declares colours and fonts is almost always a mistake, and the one
# place that can say so is the acknowledgement the caller is already reading.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Themes ();

my $docroot = tempdir( CLEANUP => 1 );
my $lz      = "$docroot/lazysite";
make_path("$lz/layouts");

$Lazysite::Manager::Themes::DOCROOT      = $docroot;
$Lazysite::Manager::Themes::LAZYSITE_DIR = $lz;
$Lazysite::Manager::Common::DOCROOT      = $docroot;

sub make_theme {
    my ( $layout, $theme, %opt ) = @_;
    my $tdir = "$lz/layouts/$layout/themes/$theme";
    make_path($tdir);
    open my $fh, '>', "$tdir/theme.json" or die $!;
    print $fh qq({"name":"$theme","layouts":["$layout"]});
    close $fh;

    if ( $opt{assets} ) {
        make_path("$tdir/assets");
        open my $c, '>', "$tdir/assets/main.css" or die $!;
        print $c "body{color:#111}\n";
        close $c;
    }
    if ( $opt{misplaced} ) {
        # The reported mistake: the stylesheet beside theme.json.
        open my $c, '>', "$tdir/main.css" or die $!;
        print $c "body{color:#111}\n";
        close $c;
    }
    return $tdir;
}

subtest 'a correctly built theme reports what it mirrored' => sub {
    make_theme( 'good', 'good', assets => 1 );
    my $r = Lazysite::Manager::Themes::_mirror_theme_assets( 'good', 'good' );

    is( ref $r, 'HASH', 'the mirror reports a result at all' )
        or diag('It used to return nothing, which is why zero was invisible.');
    cmp_ok( $r->{mirrored}, '>=', 1, 'and counts the assets it placed' );
    ok( -f "$docroot/lazysite-assets/good/good/main.css",
        'the stylesheet really is in the mirror' );
};

subtest 'the count is of what is THERE, not what was attempted' => sub {
    # A count of intentions is exactly the class of defect this filing exists to
    # close, so the count is taken by walking the destination afterwards.
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Themes.pm"
            or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/Count what is actually THERE/,
        'the implementation counts the destination' );
    like( $src, qr/File::Find::find\([^)]*\$dest/s,
        'by walking the mirror after the copy' );
};

subtest 'a theme with no assets/ reports zero and names where they belong' => sub {
    make_theme( 'bare', 'bare' );
    my $r = Lazysite::Manager::Themes::_mirror_theme_assets( 'bare', 'bare' );

    is( $r->{mirrored}, 0, 'nothing was mirrored' );
    like( $r->{reason}, qr/assets/, 'and it says why' );
    like( $r->{expected}, qr{/themes/bare/assets\z},
        'naming the directory the engine actually mirrors' );
};

subtest 'a MISPLACED asset is named, because that is the real mistake' => sub {
    # The difference that matters. "No assets" is a theme that has none; a .css
    # sitting beside theme.json is a theme whose author believed they had
    # provided one. Those need different sentences, and only the second is a
    # site about to render unstyled.
    make_theme( 'oops', 'oops', misplaced => 1 );
    my $r = Lazysite::Manager::Themes::_mirror_theme_assets( 'oops', 'oops' );

    is( $r->{mirrored}, 0, 'nothing was mirrored' );
    is_deeply( $r->{misplaced}, ['main.css'],
        'the file that looks like a misplaced asset is named' )
        or diag( 'Without this the operator is told the theme has no assets, '
            . 'while looking at a stylesheet they just uploaded.' );
    like( $r->{reason}, qr/render unstyled/,
        'and the consequence is stated, not just the condition' );
};

subtest 'lazysite check carries the standing version' => sub {
    # The activation warning cannot help a site that reached this state some
    # other way - a partial deploy, a mirror cleared by hand, an asset directory
    # that vanished. Those need a check that runs on a site as it is.
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../tools/lazysite-check.pl"
            or die $!;
        local $/;
        <$fh>;
    };

    like( $src, qr/sub report_theme_assets_mirrored/,
        'the standing check exists' );
    like( $src, qr/report_theme_assets_mirrored\(\);/,
        'and is called - a reporter nobody calls is the same defect one level up' );
    like( $src, qr/has no mirrored assets/,
        'it reports the condition' );
    # Matched on a phrase that survives line-wrapping: the message is built by
    # Perl string concatenation, so anything spanning the join is asserting the
    # source layout rather than the text.
    like( $src, qr/nothing else will report it/,
        'and says that nothing else will report it' );
    like( $src, qr/returns 200/,
        'because every page still returns 200 - which is why only a screenshot '
            . 'found this in the field' );
};

done_testing();
