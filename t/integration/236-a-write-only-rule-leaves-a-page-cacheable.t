#!/usr/bin/perl
# SM1068 (ruled 2026-10-13, "Read/draft only"): only a rule that changes what a
# viewer sees - a `read` list, or `draft` - governs a page. A write-only rule
# says who may CHANGE the page and nothing about who may see it.
#
# The filing's check, run as written: on a site with one write-only rule on `/`,
# request `/` twice. It answered `no-store, private` and rendered in full every
# time, because _acl_governed asked "does ANY entry cover this path?". On a news
# site with a write rule per post, that made every post and every static under
# the content root uncacheable.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_auth_site site_tempdir run_processor);

sub put { my ( $p, $c ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $c; close $fh; return }

sub cache_control { my ($r) = @_; my ($cc) = $r =~ /^Cache-Control:\s*([^\r\n]*)/mi; return $cc // '' }

# A render served from the page cache is told apart from a fresh one by planting
# a marker in the cached file: only a cache hit can return it.
sub served_from_cache {
    my ( $docroot, $uri, $html ) = @_;
    my $first = run_processor( $docroot, $uri );
    return ( 0, $first, '' ) unless -f $html;
    my $body = do { open my $fh, '<', $html or die; local $/; <$fh> };
    $body =~ s{</body>}{CACHE-MARKER-1068</body>};
    put( $html, $body );
    utime time + 5, time + 5, $html;    # newer than its source and the conf
    my $second = run_processor( $docroot, $uri );
    return ( ( $second =~ /CACHE-MARKER-1068/ ? 1 : 0 ), $first, $second );
}

subtest 'THE FILING: one write-only rule on / leaves / cacheable' => sub {
    my $docroot = site_tempdir();
    setup_auth_site($docroot);
    put( "$docroot/lazysite/auth/acls.json", '{"/":{"owner":"root","write":["@admins"]}}' );
    my ( $hit, $first, $second ) = served_from_cache( $docroot, '/', "$docroot/index.html" );
    like( $first, qr/Home page\./, 'the page renders' );
    ok( $hit, 'the second request is a cache hit' ) or diag( substr( $second, 0, 300 ) );
    unlike( cache_control($first),  qr/no-store/, 'the first answer is not no-store' );
    unlike( cache_control($second), qr/no-store/, 'nor the second' );
};

subtest 'a post with its own write rule, under a write rule on /, is cacheable' => sub {
    my $docroot = site_tempdir();
    setup_auth_site($docroot);
    mkdir "$docroot/post";
    put( "$docroot/post/one.md", "---\ntitle: One\n---\nPost one.\n" );
    put( "$docroot/lazysite/auth/acls.json",
              '{"/":{"owner":"root","write":["@admins"]},'
            . '"post/one.md":{"owner":"bob","write":["bob","@admins"]}}' );
    my ( $hit, $first ) = served_from_cache( $docroot, '/post/one', "$docroot/post/one.html" );
    like( $first, qr/Post one\./, 'the post renders' );
    ok( $hit, 'and is served from the cache the second time' );
    unlike( cache_control($first), qr/no-store|private/, 'with no no-store, private' );
};

subtest 'a static file under a write-only rule is not no-store' => sub {
    my $docroot = site_tempdir();
    setup_auth_site($docroot);
    put( "$docroot/data.json",               qq({"ok":true}\n) );
    put( "$docroot/lazysite/auth/acls.json", '{"/":{"owner":"root","write":["@admins"]}}' );
    my $r = run_processor( $docroot, '/data.json' );
    like( $r, qr/"ok":true/, 'the file is served' );
    is( cache_control($r), 'no-cache, must-revalidate', 'with the public revalidation default' );
};

subtest 'THE CONTROL: the same site with a READ rule on / is still no-store' => sub {
    my $docroot = site_tempdir();
    setup_auth_site($docroot);
    put( "$docroot/lazysite/auth/acls.json", '{"/":{"read":["@admins"]}}' );
    my $r = run_processor( $docroot, '/', HTTP_X_REMOTE_USER => 'alice', HTTP_X_REMOTE_GROUPS => 'admins' );
    like( $r, qr/Home page\./, 'a reader on the list is served' );
    like( cache_control($r), qr/no-store, private/, 'no-store, private' );
    ok( !-f "$docroot/index.html", 'and nothing is written to the page cache' );
};

done_testing();
