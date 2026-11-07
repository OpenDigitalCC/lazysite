#!/usr/bin/perl
# SM1385: theme-delete (control API, the manager's Themes page) and delete_theme
# (MCP) take a theme by its path, lazysite/layouts/<layout>/themes/<name>, as
# theme-copy has since SM1339. By name they found a theme only under the active
# layout (D013), so one under any other layout was removable only file by file.
#
# Pinned here: the path form deletes under the layout it names and leaves the
# same-named theme under the active layout alone; the bare name still means the
# active layout's theme; the active theme by path, and a theme a domain serves
# under that layout, are refused as by name; a path into a served copy
# (/lazysite-assets/...) is refused naming the source, and a path that is no
# theme's is refused; over the creator-restricted channel (MCP, a token) the
# side record is read for the layout the path names.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use JSON::PP       qw(encode_json);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my @ALL = qw(api ui manage_users manage_themes manage_layouts);
my $s = new_site( root => $root,
    conf => "control_api_enabled: true\nlayout: base\ntheme: one\n" );
my $d = $s->docroot;

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

sub theme {
    my ( $layout, $t ) = @_;
    make_path("$d/lazysite/layouts/$layout/themes/$t/assets");
    spit( "$d/lazysite/layouts/$layout/layout.tt", "<html>[% content %]</html>\n" );
    spit( "$d/lazysite/layouts/$layout/themes/$t/theme.json",
        encode_json( { name => $t, version => '1.0.0', layouts => [$layout], config => {} } ) );
    spit( "$d/lazysite/layouts/$layout/themes/$t/assets/main.css", "x{}\n" );
    make_path("$d/lazysite-assets/$layout/$t");
    spit( "$d/lazysite-assets/$layout/$t/main.css", "x{}\n" );
    return;
}

theme( 'base',  'one' );
theme( 'base',  'spare' );
theme( 'other', 'one' );
theme( 'other', 'spare' );
theme( 'other', 'pinned' );
theme( 'other', 'gone' );

$s->add_user('human');
$s->grant( 'human', 'g-human', [qw(ui manage_themes)], \@ALL );

sub del {
    my ($path) = @_;
    return $s->call( 'human', 'theme-delete',
        query => 'action=theme-delete&path=' . $path, body => {} );
}
my $L = "$d/lazysite/layouts";

subtest 'by path: the theme under the layout the path names' => sub {
    my $r = del('lazysite/layouts/other/themes/spare');
    ok( $r->{ok}, 'deleted' ) or diag explain $r;
    is( $r->{layout}, 'other', 'the layout is the one the path names' );
    ok( !-d "$L/other/themes/spare", 'the theme under the named layout is gone' );
    ok( -d "$L/base/themes/spare",   'the same name under the active layout is untouched' );
    ok( !-e "$d/lazysite-assets/other/spare", 'and its served copy went with it' );
};

subtest 'by name: still the active layout (D013)' => sub {
    my $r = del('spare');
    ok( $r->{ok}, 'deleted' ) or diag explain $r;
    is( $r->{layout}, 'base', 'under the active layout' );
    ok( !-d "$L/base/themes/spare", 'gone' );
};

subtest 'the active theme by path is refused; the same name elsewhere is not' => sub {
    my $r = del('lazysite/layouts/base/themes/one');
    ok( !$r->{ok}, 'refused' );
    like( $r->{error}, qr/active theme/i, 'as the active theme' );
    ok( -d "$L/base/themes/one", 'still there' );
    $r = del('/lazysite/layouts/other/themes/one/');
    ok( $r->{ok}, 'the theme of that name under another layout is deleted' ) or diag explain $r;
    ok( !-d "$L/other/themes/one", 'gone' );
};

subtest 'a theme a domain serves under that layout is refused, naming it' => sub {
    spit( "$d/lazysite/lazysite.conf",
        "control_api_enabled: true\nlayout: base\ntheme: one\n"
            . "alias_hosts: b.example\nalias.b.example.layout: other\n"
            . "alias.b.example.theme: pinned\n" );
    my $r = del('lazysite/layouts/other/themes/pinned');
    ok( !$r->{ok}, 'refused' );
    like( $r->{error}, qr/in use by.*b\.example/, 'naming the domain' );
    ok( -d "$L/other/themes/pinned", 'still there' );
};

subtest 'a served copy is refused naming the source; a non-theme path is refused' => sub {
    my $r = del('lazysite-assets/other/gone');
    ok( !$r->{ok}, 'refused' );
    is( $r->{kind}, 'served-artifact-refused', 'as a write into a served copy' );
    like( $r->{error}, qr{lazysite/layouts/other/themes/gone}, 'naming the source' );
    ok( -d "$d/lazysite-assets/other/gone", 'the copy is still there' );
    $r = del('lazysite/layouts/other/layout.tt');
    ok( !$r->{ok}, 'a path that is no theme is refused' );
    like( $r->{error}, qr/not a theme/, 'saying so' );
    ok( -f "$L/other/layout.tt", 'nothing removed' );
};

subtest 'creator-restricted: the side record of the layout the path names' => sub {
    local $ENV{DOCUMENT_ROOT} = $d;
    require Lazysite::Manager::Themes;
    no warnings 'once';
    local $Lazysite::Manager::Themes::DOCROOT      = $d;
    local $Lazysite::Manager::Themes::LAZYSITE_DIR = "$d/lazysite";
    local $Lazysite::Manager::Common::DOCROOT      = $d;
    Lazysite::Manager::Themes::_record_theme_creator( 'base', 'gone', 'agent' );
    my $r = Lazysite::Manager::Themes::action_theme_delete( 'lazysite/layouts/other/themes/gone',
        { restrict_to_creator => 1, user => 'agent' } );
    is( $r->{kind}, 'not-yours', 'a record under another layout is not this theme\'s' );
    ok( -d "$L/other/themes/gone", 'still there' );
    Lazysite::Manager::Themes::_record_theme_creator( 'other', 'gone', 'agent' );
    $r = Lazysite::Manager::Themes::action_theme_delete( 'lazysite/layouts/other/themes/gone',
        { restrict_to_creator => 1, user => 'agent' } );
    ok( $r->{ok}, 'its own record lets its creator delete it' ) or diag explain $r;
    ok( !-d "$L/other/themes/gone", 'gone' );
};

done_testing;
