#!/usr/bin/perl
# SM1336 (ruling 81, T-39): EVERY SERVED COPY OF A THEME CARRIES ITS TOKENS AND
# ITS VERSION, HOWEVER IT WAS WRITTEN.
#
# Two writers built a theme's copy by hand instead of through
# _mirror_theme_assets: an installed theme (the manager's Upload Theme and MCP
# install_theme) copied assets/ alone into the docroot, and a copied theme
# copied the docroot's copy of the theme it came from. Neither copy had
# theme-tokens.css or the fingerprint (SM830) of its own - so its pages inlined
# their tokens and keyed main.css on the engine version - and neither reached a
# secondary domain at all. Both now write the copy the one way every other copy
# is written.
#
# With the fix reverted, the installed theme's copies lack the tokens and the
# fingerprint and the secondary domain has none; the copied theme has no
# secondary copy.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
use TestHelper qw(site_tempdir);
use Lazysite::Manager::Themes ();

my $d = site_tempdir();

sub put {
    my ( $p, $c ) = @_;
    ( my $dir = $p ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $c;
    close $fh;
    return;
}

put( "$d/lazysite/lazysite.conf", <<'CONF' );
site_name: T
layout: gallery
theme: base
alias_hosts: two.example
alias.two.example.content_root: sites/two
CONF
put( "$d/lazysite/layouts/gallery/layout.tt", "[% content %]\n" );
put( "$d/lazysite/layouts/gallery/themes/base/theme.json", '{"name":"base"}' );
put( "$d/lazysite/layouts/gallery/themes/base/assets/main.css", "/* base */\n" );

$Lazysite::Manager::Common::DOCROOT      = $d;
$Lazysite::Manager::Files::DOCROOT       = $d;
$Lazysite::Manager::Themes::DOCROOT      = $d;
$Lazysite::Manager::Themes::LAZYSITE_DIR = "$d/lazysite";
$Lazysite::Manager::Domains::DOCROOT     = $d;

sub carries {
    my ( $theme, $label ) = @_;
    for my $root ( $d, "$d/sites/two" ) {
        my $copy = "$root/lazysite-assets/gallery/$theme";
        my $who  = $root eq $d ? 'the docroot\'s copy' : 'the secondary domain\'s copy';
        ok( -f "$copy/main.css", "$label: $who exists" );
        ok( -f "$copy/theme-tokens.css", "$label: $who carries theme-tokens.css" );
        ok( -s "$copy/.fingerprint", "$label: $who carries its fingerprint" );
    }
}

subtest 'an installed theme' => sub {
    my $x = "$d/extracted";
    put( "$x/theme.json", JSON::PP::encode_json( { name => 'fresh', layouts => ['gallery'],
                config => { colours => { primary => '#abcdef' } } } ) );
    put( "$x/assets/main.css", "/* fresh */\n" );
    my $r = Lazysite::Manager::Themes::_install_theme_from_dir( $x, 'theme-upload', 'op' );
    ok( $r->{ok}, 'installed' ) or diag explain $r;
    carries( 'fresh', 'installed' );
    my $tok = do { local $/; open my $fh, '<', "$d/lazysite-assets/gallery/fresh/theme-tokens.css"; <$fh> } // '';
    like( $tok, qr/--theme-colours-primary: #abcdef/, 'the tokens are its own' );
};

subtest 'a copied theme' => sub {
    put( "$d/lazysite/layouts/gallery/themes/base/theme.json",
        JSON::PP::encode_json( { name => 'base', config => { colours => { primary => '#111111' } } } ) );
    my $r = Lazysite::Manager::Themes::action_theme_copy( 'base', 'copy', {} );
    ok( $r->{ok}, 'copied' ) or diag explain $r;
    carries( 'copy', 'copied' );
};

done_testing;
