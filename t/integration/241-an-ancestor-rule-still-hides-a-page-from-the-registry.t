#!/usr/bin/perl
# SM1069: the registry rebuild finds each page's rule by looking up its
# ancestors rather than walking every key. A rule on an ANCESTOR - not the
# page's own, nor its folder's - must still keep a read-restricted or draft page
# out of the sitemap, with write-only rules on the page and on folders between,
# while a page under write-only rules alone is listed (SM1068).
use strict;
use warnings;
use Test::More;
use File::Copy qw(copy);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site site_tempdir run_processor repo_root);

sub put { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

my $d = site_tempdir();
setup_test_site($d);
make_path( "$d/lazysite/templates/registries", "$d/lazysite/auth",
    "$d/held/deep/er", "$d/soon/deep/er", "$d/open/deep/er" );
copy( repo_root() . '/starter/lazysite/templates/registries/sitemap.xml.tt',
    "$d/lazysite/templates/registries/sitemap.xml.tt" ) or die "copy: $!";

for my $sec (qw(held soon open)) {
    put( "$d/$sec/deep/er/page.md", "---\ntitle: $sec\nregister:\n  - sitemap.xml\n---\nbody\n" );
}
put( "$d/lazysite/auth/acls.json", <<'JSON' );
{
  "/":                       { "owner": "root", "write": ["@admins"] },
  "held/":                   { "read": ["alice"] },
  "/held/deep":              { "owner": "bob", "write": ["bob"] },
  "held/deep/er/page.md":    { "owner": "bob", "write": ["bob"] },
  "soon":                    { "draft": true },
  "soon/deep/er/":           { "owner": "bob", "write": ["bob"] },
  "open/deep":               { "owner": "bob", "write": ["bob"] },
  "open/deep/er/page.md":    { "owner": "bob", "write": ["bob"] }
}
JSON

my $r = run_processor( $d, '/sitemap.xml' );
like( $r, qr{/open/deep/er/page}, 'a page under write-only rules alone is listed' );
unlike( $r, qr{/held/},           'a read rule two folders up keeps its page out' );
unlike( $r, qr{/soon/},           'and so does a draft flag two folders up' );

done_testing();
