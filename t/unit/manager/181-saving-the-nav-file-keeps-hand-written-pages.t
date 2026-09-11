#!/usr/bin/perl
# SM852: saving the navigation file keeps every hand-written .html.
#
# Saving the nav file through the file editor, MCP write_file or the control
# API's save drops every rendered page, so the new menu reaches every page. The
# sweep deleted every .html under the docroot - including a legacy static page
# with no source beside it (SM133) and an author's include partial (SM072),
# which are content. Themes' sweeps have asked "is this a render?" since SM072;
# this one never did. The nav-save action used Themes' sweep and was safe, which
# is how the file-save path's went unnoticed.
#
# Found by the SM836 review of every write path; reproduced before the fix.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper               qw(site_tempdir);
use Lazysite::Manager::Files ();

my $d = site_tempdir();
make_path( "$d/lazysite", "$d/docs", "$d/partials" );

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

spit( "$d/about.md",             "# About\n" );
spit( "$d/about.html",           "<p>a render of about.md</p>" );
spit( "$d/docs/guide.url",       "https://example.test/guide\n" );
spit( "$d/docs/guide.html",      "<p>a render of guide.url</p>" );
spit( "$d/legacy.html",          "<p>a migrated static page, no source</p>" );
spit( "$d/partials/footer.html", "<footer>an author's include partial</footer>" );

{
    no warnings 'once';
    $Lazysite::Manager::Files::DOCROOT  = $d;
    $Lazysite::Manager::Common::DOCROOT = $d;
}
my $cleared = Lazysite::Manager::Files::_invalidate_all_html();

ok( !-e "$d/about.html", 'a render of a page is dropped, so it re-renders with the new nav' );
ok( !-e "$d/docs/guide.html", 'and a render of a remote page too' );
is( $cleared, 2, 'and the count says exactly those two' );
ok( -f "$d/legacy.html", 'a legacy static page with no source is content, and stays' );
ok( -f "$d/partials/footer.html", 'and so does an author\'s include partial' );

done_testing();
