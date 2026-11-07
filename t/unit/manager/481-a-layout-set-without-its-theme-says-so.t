#!/usr/bin/perl
# SM1409: A LAYOUT SET WITHOUT A THEME OF ITS OWN SAYS SO IN WORDS.
#
# domain-set of the layout alone, with the domain's theme still the other
# layout's, ran the SM241 asset mirror on the mixed pair and warned "Assets
# belong in lazysite/layouts/<new layout>/themes/<old theme>/assets" - a path
# that mixes the two and names a directory nobody made (0.16.7 edge, T-106).
#
# The set stays accepted: the documented binding is two calls, layout first,
# and activate_layout / layout-activate with a host send the layout and then
# the theme the same way. What changes is the answer: the mixed pair is not
# mirrored, and the warning names the theme that is not the layout's, the
# layout's own themes and what to send (layout and theme together), and never
# a mixed path. A theme set alone that is not the layout's says the same.
#
# With the change reverted: the warning names the mixed path and not the
# theme's layout.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Manager::Domains ();

my $d = site_tempdir();
for my $pair ( [ 'base', 'house' ], [ 'kestrel', 'plume' ], [ 'kestrel', 'quill' ] ) {
    my ( $l, $t ) = @$pair;
    make_path("$d/lazysite/layouts/$l/themes/$t/assets");
    open my $c, '>', "$d/lazysite/layouts/$l/themes/$t/assets/main.css" or die $!;
    print {$c} "/* $l-$t */\n";
    close $c;
}

sub conf {
    open my $w, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$w} "site_name: T\nlayout: base\ntheme: house\nalias_hosts: b.example\n";
    close $w;
}
sub mirror_exists { -f "$d/lazysite-assets/$_[0]/$_[1]/main.css" }

$Lazysite::Manager::Domains::DOCROOT = $d;

sub says_in_words {
    my ( $r, $theme, $layout ) = @_;
    my $w = join "\n", @{ $r->{warnings} || [] };
    like( $w, qr/its theme '\Q$theme\E' is not a theme of layout '\Q$layout\E'/,
        'the warning names the theme that is not the layout\'s' ) or diag explain $r;
    like( $w, qr/its themes: plume, quill/, '...the layout\'s own themes' );
    like( $w, qr/layout and one of its themes together/, '...and what to send' );
    unlike( $w, qr{layouts/\Q$layout\E/themes/\Q$theme\E}, 'and never the mixed path' );
    unlike( $w, qr/Assets belong in/, '...nor the assets/ advice, which is about a theme of the layout' );
    is( $r->{assets_mirrored}, 0, 'nothing is mirrored' );
    ok( !-e "$d/lazysite-assets/$layout/$theme", 'and no mixed mirror directory is made' );
}

subtest 'a layout set alone, the theme still the other layout\'s' => sub {
    conf();
    my $r = Lazysite::Manager::Domains::domain_set( 'b.example', 'layout', 'kestrel' );
    ok( $r->{ok}, 'the set is accepted: the two-call binding sends the layout first' );
    says_in_words( $r, 'house', 'kestrel' );

    my $t = Lazysite::Manager::Domains::domain_set( 'b.example', 'theme', 'plume' );
    ok( $t->{ok}, 'then the theme' );
    ok( !$t->{warnings}, 'a theme of the layout: no warning' ) or diag explain $t;
    cmp_ok( $t->{assets_mirrored}, '>=', 1, '...and its assets are mirrored' );
    ok( mirror_exists( 'kestrel', 'plume' ), '...under the layout' );
};

subtest 'a theme set alone that is not the layout\'s' => sub {
    conf();
    Lazysite::Manager::Domains::domain_set( 'b.example', 'layout', 'kestrel' );
    Lazysite::Manager::Domains::domain_set( 'b.example', 'theme',  'quill' );
    my $r = Lazysite::Manager::Domains::domain_set( 'b.example', 'theme', 'house' );
    ok( $r->{ok}, 'accepted' );
    says_in_words( $r, 'house', 'kestrel' );
};

subtest 'a layout that is not installed is named as that' => sub {
    conf();
    my $r = Lazysite::Manager::Domains::domain_set( 'b.example', 'layout', 'nosuch' );
    my $w = join "\n", @{ $r->{warnings} || [] };
    like( $w, qr/layout 'nosuch' is not installed on this site/, 'said in words' ) or diag explain $r;
    unlike( $w, qr{layouts/nosuch/themes}, 'with no path built from the two names' );
};

subtest 'a layout whose theme it carries mirrors as before' => sub {
    conf();
    my $r = Lazysite::Manager::Domains::domain_set( 'b.example', 'layout', 'base' );
    ok( $r->{ok} && !$r->{warnings}, 'no warning' ) or diag explain $r;
    ok( mirror_exists( 'base', 'house' ), 'mirrored' );
};

done_testing;
