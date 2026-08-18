#!/usr/bin/perl
# SM355: every 404 on the site declared somebody else's URL as its canonical.
#
# MEASURED IN THE FIELD on edge/0.10.12 by the partner agent:
#
#   /404.html          HTTP 200  canonical -> /feed.xml
#   /no-such-page-zz   HTTP 404  canonical -> /feed.xml
#
# The same canonical from every missing URL, and /feed.xml itself 404s on that
# instance - so the page served for missing documents pointed crawlers at a
# missing document.
#
# THE MECHANISM, which is not what it looks like from outside. The rendered 404
# is cached as a FILE in the content root, and the render injects a canonical
# derived from `REDIRECT_URL` - the request being served at that moment. So the
# FIRST request to any missing URL bakes its own path into the file every later
# 404 is served from. On the instrument, a request for /feed.xml happened to be
# first.
#
# WHICH MAKES IT REMOTELY INFLUENCEABLE - AND THAT WAS DEMONSTRATED, not merely
# reasoned. On the live instance, from outside, by an agent with no host access:
#
#   before                             canonical -> /feed.xml
#   invalidate_cache /404.html
#   first missing-URL request          /zz-CANARY-CHOSEN-BY-A-STRANGER
#   then /zz-completely-unrelated-page  canonical -> /zz-CANARY-CHOSEN-BY-A-STRANGER
#
# An unrelated missing page named a path the visitor chose. The check could have
# failed - had the canonical stayed /feed.xml the mechanism would have been wrong
# or incomplete - which is what makes it evidence rather than agreement.
#
# It is same-origin and cannot point elsewhere, so this is not a redirect or an
# injection. But every missing page then tells search engines the real page is a
# URL a stranger picked.
#
# AND THE CACHE IS IN THE SERVED TREE, so the front end answers /404.html
# directly, with 200, without the engine involved - an indexable soft 404. That
# is the half the engine cannot fix by cleaning its own response, which is why
# the cache file is rewritten and why the page carries noindex.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site run_processor);

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);

open my $nf, '>', "$docroot/404.md" or die $!;
print $nf "---\ntitle: Not found\n---\n\n# Not found\n\nNo such page.\n";
close $nf;

subtest 'the first 404 does not decide what later ones point at' => sub {
    # The field case, reproduced in order: a request for /feed.xml misses first,
    # then unrelated URLs miss afterwards.
    my $first = run_processor( $docroot, '/feed.xml' );
    like( $first, qr/404 Not Found/, '/feed.xml is a 404 here' );

    for my $path ( '/no-such-page-zz', '/completely/unrelated', '/a/b/c' ) {
        my $out = run_processor( $docroot, $path );
        unlike( $out, qr{rel=["']canonical["']}i,
            "$path carries no canonical at all" )
            or diag( 'A missing page has no canonical URL. Carrying the FIRST '
                . 'missed path is how one visitor came to decide what every '
                . '404 on the site pointed at.' );
        unlike( $out, qr{/feed\.xml}i,
            "$path does not mention the first missed URL" );
    }
};

subtest 'the cached file is cleaned too, because the front end serves it' => sub {
    # /404.html sits in the served tree. nginx and Apache answer it directly and
    # never consult the engine, so cleaning only the response would fix the path
    # we control and leave the one we do not.
    run_processor( $docroot, '/feed.xml' );
    my $cache = "$docroot/404.html";
SKIP: {
        skip 'no 404 cache file was written on this path', 2 unless -f $cache;
        my $html = do { open my $fh, '<', $cache or die $!; local $/; <$fh> };
        unlike( $html, qr{rel=["']canonical["']}i,
            'the cached 404 carries no canonical' );
        like( $html, qr{name=["']robots["'][^>]*noindex}i,
            'and tells crawlers not to index it' )
            or diag( 'Served at /404.html with 200 by the front end, this is an '
                . 'indexable soft 404 the engine never sees. noindex is the '
                . 'only instruction that reaches it.' );
    }
};

subtest 'a 404 is still a 404' => sub {
    # The sanitiser rewrites the body. It must not turn the response into
    # something else, which would be a far worse defect than the one being fixed.
    my $out = run_processor( $docroot, '/still-missing' );
    like( $out, qr/404 Not Found/,          'the status is unchanged' );
    like( $out, qr/text\/html/,             'the content type is unchanged' );
    like( $out, qr/No such page|Not found/, 'the 404 body still renders' );
};

subtest 'a real page keeps its canonical' => sub {
    # The other direction, and the one that would make this fix worse than the
    # bug: SM151 gives every page a per-host canonical so each domain is a
    # first-class site to search engines. Stripping those would be a large SEO
    # regression shipped as a fix.
    my $out = run_processor( $docroot, '/index' );
    like( $out, qr{rel=["']canonical["']}i,
        'an existing page still declares its canonical' )
        or diag('The strip must be scoped to the 404 path only.');
    unlike( $out, qr{name=["']robots["'][^>]*noindex}i,
        'and is not marked noindex' );
};

# --- SM371: WIDENED IN THE CODE, NOT COVERED HERE -----------------------------
# serve_402 and serve_403 now run the same sanitiser, and there is deliberately
# no test for it, which is worse than a test and better than the test I tried to
# write.
#
# Four attempts at a fixture that reaches serve_403 produced, in order: an ACL
# refusal (a different branch with its own minimal body, no canonical to strip,
# so the assertion passed with the fix REMOVED), an anonymous request (a 302 to
# login, SM223), and twice a plain 200 because the page never asked for
# authentication. The first of those is the dangerous one: it was green, it
# looked like coverage, and sabotaging the fix did not disturb it.
#
# What would cover it: a fixture that reaches the GROUP refusal in check_auth -
# an authenticated user outside a group the page requires - which needs the
# page's auth metadata staged the way t/unit/processor/08 stages it rather than
# the way a content fixture does. And for 402, a payment-gated page with the
# payment plugin configured, which no integration fixture here sets up.
#
# Recorded rather than approximated. A test that cannot fail is the thing this
# whole release has been about.

done_testing();