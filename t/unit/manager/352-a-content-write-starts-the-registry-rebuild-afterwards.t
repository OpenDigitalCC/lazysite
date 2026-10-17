#!/usr/bin/perl
# SM1152 (SM1082 Q5): a write that changes content triggers the registry rebuild
# after it completes.
#
# The write drops the generated registries (SM087), so the next request used to
# build them inside itself. It now remembers that they are owed, and when the
# manager request has finished it starts the processor, detached, for one of
# them: that request rebuilds what is missing, and nobody who was meant to be
# served waits for it. Not from inside the action, which is why a unit test that
# calls an action never starts a process.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Copy qw(copy);
use Time::HiRes qw(sleep);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir setup_test_site);

my $root = repo_root();
my $d    = site_tempdir();
setup_test_site($d);
make_path("$d/lazysite/templates/registries");
copy( "$root/starter/lazysite/templates/registries/sitemap.xml.tt",
    "$d/lazysite/templates/registries/sitemap.xml.tt" ) or die $!;
my $reg = "$d/lazysite/cache/registries/_root/sitemap.xml";
make_path("$d/lazysite/cache/registries/_root");
sub put { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/; my $c = <$fh>; close $fh; return $c // '' }
put( $reg,          "<urlset/>" );
put( "$d/page.md",  "---\ntitle: Page\nregister:\n  - sitemap.xml\n---\nbody\n" );
put( "$d/other.md", "---\ntitle: Other\nregister:\n  - sitemap.xml\n---\nbody\n" );

BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
$ENV{DOCUMENT_ROOT}      = $d;
$ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";    # beside the API, as installed
{
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

is( Lazysite::Manager::Files::start_registry_rebuild(), 0, 'nothing is owed before a write' );

my $r = main::action_delete( '/other.md', 'op' );
ok( $r->{ok}, 'a page is deleted' );
ok( !-f $reg, 'which drops the registry, as before' );
ok( !-f $reg, 'and the action itself starts no process' );

is( Lazysite::Manager::Files::start_registry_rebuild(), 1, 'when the request is over, the rebuild is started' );
is( Lazysite::Manager::Files::start_registry_rebuild(), 0, 'and only once' );

my $built = 0;
for ( 1 .. 100 ) {
    if ( slurp($reg) =~ /<urlset/ && slurp($reg) =~ m{/page} ) { $built = 1; last }
    sleep 0.1;
}
ok( $built, 'the registry is rebuilt in the background' );
unlike( slurp($reg), qr{/other}, 'from the site as the write left it' );

# The hook that runs it once the response is out.
my $api = do { open my $fh, '<', "$root/lazysite-manager-api.pl" or die $!; local $/; <$fh> };
like( $api, qr/END\s*\{[^}]*start_registry_rebuild/s,
    'the manager runs it when the request has finished' );

done_testing;
