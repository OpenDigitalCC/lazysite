#!/usr/bin/perl
# SM087: a content delete/save/move invalidates the generated registries
# (sitemap.xml, llms.txt, feed.*) by removing their outputs, so the processor
# rebuilds them fresh on the next request - fixes "deleted page still in sitemap".
#
# SM433: THE OUTPUTS MOVED AND THIS TEST DID NOT FOLLOW THEM. SM293 step 3 put
# the generated registries in lazysite/cache/registries/<key>/<name> and served
# them from there; this fixture went on writing "generated output" to
# $DOCROOT/<name>, the pre-SM293 location, and asserting that THAT was removed.
# So it kept passing while the invalidator cleared a file nobody served - which
# is how the defect survived: the test agreed with the code about the wrong
# location, and both were wrong together.
#
# SM087's intent is unchanged and is what is asserted below: after a delete or
# a save, the registry a visitor would be served is gone and rebuilds. Only the
# path is corrected. The docroot copy now gets its own assertion, because since
# SM293 that path is where an operator may put their OWN sitemap and deleting
# it would be data loss.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/logs", "$d/lazysite/templates/registries" );
_put( "$d/lazysite/templates/registries/sitemap.xml.tt", "x" );
_put( "$d/lazysite/templates/registries/llms.txt.tt",    "x" );
make_path("$d/lazysite/cache/registries/_root");
_put( "$d/lazysite/cache/registries/_root/sitemap.xml", "<urlset/>" );    # SERVED
_put( "$d/lazysite/cache/registries/_root/llms.txt",    "old" );          # SERVED
_put( "$d/keep.html", "static" );     # NOT a registry output
_put( "$d/page.md",   "# page\n" );

BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
$ENV{DOCUMENT_ROOT} = $d;
my $root = repo_root();
{
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

my $r = main::action_delete( '/page.md', 'op' );
ok( $r->{ok}, 'page deleted' );
ok( !-f "$d/lazysite/cache/registries/_root/sitemap.xml",
    'the SERVED sitemap.xml is invalidated on delete' )
    or diag( 'SM433: the invalidator must clear what _serve_registry reads, '
        . 'not the pre-SM293 docroot location.' );
ok( !-f "$d/lazysite/cache/registries/_root/llms.txt",
    'and the served llms.txt with it' );
ok( -f "$d/keep.html", 'a non-registry generated file is untouched' );

# A save re-invalidates too (new page / changed lastmod).
_put( "$d/lazysite/cache/registries/_root/sitemap.xml", "<urlset/>" );
main::action_save( '/page.md', 'op', "# again\n", undef );
ok( !-f "$d/lazysite/cache/registries/_root/sitemap.xml",
    'the served sitemap.xml is invalidated on save' );

# SM433: an operator's OWN registry in the docroot is content, not output.
# _serve_registry prefers it, so it is a supported thing to have - and the
# invalidator used to delete it on any save or delete, without a word.
_put( "$d/sitemap.xml",                                 "MINE - hand written\n" );
_put( "$d/lazysite/cache/registries/_root/sitemap.xml", "<urlset/>" );
main::action_save( '/page.md', 'op', "# thrice\n", undef );
ok( -f "$d/sitemap.xml", "an operator's own sitemap.xml survives a save" )
    or diag( 'Deleting content an operator may have written deliberately, '
        . 'as a side effect of saving an unrelated page.' );

done_testing();

sub _put { my ( $p, $c ) = @_; open my $fh, '>', $p or die $!; print {$fh} $c; close $fh }
