#!/usr/bin/perl
# SM087: a content delete/save/move invalidates the generated registries
# (sitemap.xml, llms.txt, feed.*) by removing their outputs, so the processor
# rebuilds them fresh on the next request - fixes "deleted page still in sitemap".
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
_put( "$d/sitemap.xml", "<urlset/>" );    # generated output
_put( "$d/llms.txt",    "old" );          # generated output
_put( "$d/keep.html",   "static" );       # NOT a registry output
_put( "$d/page.md",     "# page\n" );

BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
$ENV{DOCUMENT_ROOT} = $d;
my $root = repo_root();
{
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

my $r = main::action_delete( '/page.md', 'op' );
ok( $r->{ok}, 'page deleted' );
ok( !-f "$d/sitemap.xml", 'sitemap.xml invalidated on delete' );
ok( !-f "$d/llms.txt",    'llms.txt invalidated on delete' );
ok( -f "$d/keep.html",    'a non-registry generated file is untouched' );

# A save re-invalidates too (new page / changed lastmod).
_put( "$d/sitemap.xml", "<urlset/>" );
main::action_save( '/page.md', 'op', "# again\n", undef );
ok( !-f "$d/sitemap.xml", 'sitemap.xml invalidated on save' );

done_testing();

sub _put { my ( $p, $c ) = @_; open my $fh, '>', $p or die $!; print {$fh} $c; close $fh }
