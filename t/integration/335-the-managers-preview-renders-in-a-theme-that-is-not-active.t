#!/usr/bin/perl
# SM1290 (K-4): THE MANAGER'S PAGE PREVIEW TAKES `theme` TOO.
#
# MCP preview_page's `theme` renders a page in an installed theme that is not
# the active one. Its twin on the manager side, the cookie `preview` action,
# takes the same parameter with the same gate (manage_themes or manage_layouts,
# preview-grant's capability) and the same refusals, and it is driven here as a
# signed-in person through the manager API, as the manager UI calls it.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use JSON::PP       qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper     qw(repo_root);
use ManagerSession ();

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";
delete $ENV{HTTP_HOST};

my $ms = ManagerSession::new_site( root => $root,
    conf => "control_api_enabled: true\nsite_name: T\nlayout: default\ntheme: day\n" );
my $d = $ms->docroot;

sub spit {
    my ( $p, $t ) = @_;
    ( my $dir = $p ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $fh, '>:raw', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
spit( "$d/lazysite/layouts/default/layout.tt",
    '<html><head><meta name="theme-assets" content="[% theme_assets %]"></head><body>[% content %]</body></html>' );
spit( "$d/lazysite/layouts/alt/layout.tt", '<html><body>[% content %]</body></html>' );
for my $t (qw(day night)) {
    spit( "$d/lazysite/layouts/default/themes/$t/theme.json",
        encode_json( { name => $t, version => '1.0', layouts => ['default'] } ) );
}
spit( "$d/lazysite/layouts/alt/themes/elsewhere/theme.json",
    encode_json( { name => 'elsewhere', version => '1.0', layouts => ['alt'] } ) );
spit( "$d/index.md", "---\ntitle: Home\n---\nHome.\n" );
spit( "$d/about.md", "---\ntitle: About\n---\nABOUT-MARKER\n" );

my @ALL = qw(ui manage_content manage_themes manage_layouts);
$ms->add_user( 'tess', 'pw-tess-0123456789' );
$ms->grant( 'tess', 'designers', [qw(ui manage_content manage_themes)], \@ALL );
$ms->add_user( 'cleo', 'pw-cleo-0123456789' );
$ms->grant( 'cleo', 'editors', [qw(ui manage_content)], \@ALL );

sub pv {
    my ( $user, $theme ) = @_;
    my $q = 'action=preview&path=/about.md' . ( defined $theme ? "&theme=$theme" : '' );
    return $ms->call( $user, 'preview', query => $q );
}
sub theme_of { my ($html) = @_; my ($t) = ( $html // '' ) =~ m{content="/lazysite-assets/default/([^"]+)"}; return $t // '(none)' }

subtest 'the page renders in the named theme' => sub {
    my $r = pv( tess => 'night' );
    ok( $r->{ok}, 'ok' ) or diag explain $r;
    like( $r->{html} // '', qr/ABOUT-MARKER/, 'the page' );
    is( theme_of( $r->{html} ), 'night', 'in night, not the active day' );
    is( $r->{theme}, 'night', 'and says so' );
    ok( !-e "$d/about.html", 'no page cache was written' );
};

subtest 'without theme, the active one, for any manager' => sub {
    my $r = pv('cleo');
    ok( $r->{ok}, 'ok' ) or diag explain $r;
    is( theme_of( $r->{html} ), 'day', 'in day' );
};

subtest 'theme needs manage_themes or manage_layouts' => sub {
    my $r = pv( cleo => 'night' );
    ok( !$r->{ok}, 'a content-only manager is refused' );
    is( $r->{kind}, 'forbidden', 'as forbidden' ) or diag explain $r;
    unlike( $r->{html} // '', qr/ABOUT-MARKER/, 'with nothing rendered' );
};

subtest 'a theme that is not installed for this page is refused' => sub {
    is( pv( tess => 'nope' )->{kind}, 'not-found', 'no such theme' );
    my $e = pv( tess => 'elsewhere' );
    is( $e->{kind}, 'theme-not-installed', 'installed for another layout only' ) or diag explain $e;
    ok( !defined $e->{html}, 'and no render handed back' );
};

done_testing();
