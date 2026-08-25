#!/usr/bin/perl
# SM535: a WebDAV DELETE of a COLLECTION removes every page under it, but
# do_delete keyed its registry and alias housekeeping on the request path
# ending in .md - which a directory never does. So after DELETE of
# content/sec/ the sitemap kept listing /content/sec/p and the alias map kept
# answering /old-page with it: a 301 to a 404. The single-file DELETE was
# already right, and the manager has no counterpart (it refuses a non-empty
# directory), so this surface is the only one that can get it wrong.
#
# The assertions are on what a visitor meets - the alias lookup and the
# rendered sitemap - not on a log line.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper        qw(setup_dav_site run_dav run_processor);
use Lazysite::Aliases ();

my $s = setup_dav_site();
my $d = $s->{docroot};
my $a = $s->{auth};
make_path("$d/lazysite/templates/registries");
open my $tf, '>', "$d/lazysite/templates/registries/sitemap.xml.tt" or die $!;
print {$tf} "[%- FOREACH p IN pages -%]\nURL: [% p.url %]\n[% END -%]\n";
close $tf;

sub registry_cached {
    my @f = glob("$d/lazysite/cache/registries/*/sitemap.xml");
    return scalar @f;
}

my $page = "---\ntitle: P\nregister:\n  - sitemap.xml\naliases:\n  - /old-page\n---\nx\n";

# --- the collection ----------------------------------------------------------
is( run_dav( $d, 'MKCOL', '/content/sec', HTTP_AUTHORIZATION => $a )->{code},
    201, 'the collection is created' );
is( run_dav( $d, 'PUT', '/content/sec/p.md', body => $page, HTTP_AUTHORIZATION => $a )->{code},
    201, 'a page is published under it' );
like( run_processor( $d, '/sitemap.xml' ), qr{URL: .*content/sec/p\b},
    'the page registers' );
ok( registry_cached(), 'the registry is cached' );
is( Lazysite::Aliases::lookup( $d, '/old-page' ), '/content/sec/p',
    'the alias is indexed by the PUT' );

my $del = run_dav( $d, 'DELETE', '/content/sec', HTTP_AUTHORIZATION => $a );
is( $del->{code}, 204, 'DELETE of the collection answers 204' ) or diag $del->{body};
ok( !-e "$d/content/sec/p.md", 'the page is gone from disk' );
ok( !defined Lazysite::Aliases::lookup( $d, '/old-page' ),
    'the deleted page\'s alias is deindexed - no 301 to a 404' )
    or diag( '/old-page still maps to ' . Lazysite::Aliases::lookup( $d, '/old-page' ) );
ok( !registry_cached(), 'the collection DELETE clears the registry cache' )
    or diag('the registry cache survived the collection DELETE');
unlike( run_processor( $d, '/sitemap.xml' ), qr{URL: .*content/sec/p\b},
    'the re-rendered sitemap no longer lists the deleted page' );

# --- the control: a single-file DELETE was already right ----------------------
is( run_dav( $d, 'PUT', '/content/q.md', body => $page, HTTP_AUTHORIZATION => $a )->{code},
    201, 'control: a single page is published' );
run_processor( $d, '/sitemap.xml' );
ok( registry_cached(), 'control: the registry is cached again' );
is( run_dav( $d, 'DELETE', '/content/q.md', HTTP_AUTHORIZATION => $a )->{code},
    204, 'control: the single-file DELETE answers 204' );
ok( !registry_cached(), 'control: the single-file DELETE clears the registry cache' );
ok( !defined Lazysite::Aliases::lookup( $d, '/old-page' ),
    'control: the single-file DELETE deindexes the alias' );

done_testing();
