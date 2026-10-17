#!/usr/bin/perl
# SM1141 (slice D of SM1134), checked when the slices were stacked: A LAYOUT
# UPDATE DROPS THE RENDERS MADE WITH THE OLD ONE.
#
# SM1141's note: "a layout edited in place to add in_list after pages were cached
# is not caught until the cache is invalidated". What happens, measured on the
# code: the layout being served cannot be edited in place on any surface (SM749,
# Manager::Common::active_artifact_refusal - manager, control API, MCP, WebDAV);
# activating a layout or theme drops every render (Themes::_invalidate_html_cache).
# The one path that changed the served layout and kept the renders was an UPDATE
# (layout-install / layouts-install / install_layout with update): it switches the
# new version in under the same name (SM756) and swept nothing, so every cached
# page kept the old layout - a layout that added `visitor.in_list` to hold a block
# back from outside addresses went on serving the block in every cached page until
# something else invalidated it. A cached render is checked against its source,
# the conf, the nav, its section indexes, the engine and its recorded includes
# (try_serve_cache), never the layout file, so the update has to drop them.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                 qw(repo_root site_tempdir);
use Lazysite::Manager::Themes  ();
use Lazysite::Manager::Layouts ();

my $docroot = site_tempdir();
make_path("$docroot/lazysite/layouts/base/themes");
$Lazysite::Manager::Themes::DOCROOT       = $docroot;
$Lazysite::Manager::Themes::LAZYSITE_DIR  = "$docroot/lazysite";
$Lazysite::Manager::Layouts::DOCROOT      = $docroot;
$Lazysite::Manager::Layouts::LAZYSITE_DIR = "$docroot/lazysite";

sub put { my ( $p, $c ) = @_; make_path( ( $p =~ m{(.*)/} )[0] ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh }

put( "$docroot/lazysite/lazysite.conf", "site_name: t\nlayout: base\n" );
put( "$docroot/lazysite/layouts/base/layout.tt", "V1 [% content %]\n" );

sub release {
    my ($tt) = @_;
    my $d = tempdir( CLEANUP => 1 );
    put( "$d/layout.tt", $tt );
    return $d;
}

sub cache_pages {
    put( "$docroot/page.md",     "---\ntitle: P\n---\nP\n" );
    put( "$docroot/page.html",   "V1 rendered\n" );
    put( "$docroot/partial.html", "an author's partial, no source\n" );
    return;
}

subtest 'the same layout again changes nothing and drops nothing' => sub {
    cache_pages();
    my $r = Lazysite::Manager::Layouts::_install_layout_from_dir( release("V1 [% content %]\n"), 'base', 'layout-install', 'op', 1 );
    is( $r->{action}, 'already_installed', 'nothing to update' ) or diag explain $r;
    ok( -f "$docroot/page.html", 'the render is kept' );
};

subtest 'an update to the served layout drops the renders made with the old one' => sub {
    cache_pages();
    my $r = Lazysite::Manager::Layouts::_install_layout_from_dir(
        release("V2 [% IF visitor.in_list('office') %]internal[% END %] [% content %]\n"),
        'base', 'layout-install', 'op', 1 );
    is( $r->{action}, 'updated', 'the layout is updated' ) or diag explain $r;
    ok( !-f "$docroot/page.html", 'the page rendered with the old layout is dropped, so the next request renders with the new one' );
    ok( -f "$docroot/partial.html", 'an .html with no source is content, and kept' );
};

done_testing();
