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

# --- SM371: the reasoning was never 404-specific ------------------------------
# SM355's helper strips the canonical an error page must not carry and adds the
# noindex it must. It was written for 404 and CALLED only from not_found(), so
# serve_402 and serve_403 - which render through process_md into
# $DOCROOT/402.html and 403.html, files the front end then serves at 200 - kept
# whatever canonical the layout emitted.
#
# Found on a 402 in the field: a canonical pointing at the payment-gated page
# the visitor had just been REFUSED.
#
# FOUR FIXTURES FAILED BEFORE THIS ONE, and the reason is worth keeping. The
# front-matter key is `auth_groups:` as an indented block, not `groups:` - so
# every attempt that wrote `groups: admins` left @required empty, the group
# check never ran, and the page answered 200. One of those attempts asserted
# "no canonical" against an ACL-refusal body that never had one, and PASSED
# WITH THE FIX REMOVED. A green test on the wrong branch is the failure mode
# this whole release has been about, so the key is named here rather than left
# for the next person to rediscover.
subtest 'a 403 has no canonical, in the body and in the cache' => sub {
    open my $gated, '>', "$docroot/zz-gated.md" or die $!;
    print {$gated} "---\ntitle: Gated\nauth: required\nauth_groups:\n  - admins\n---\n\nsecret\n";
    close $gated;

    open my $sys, '>', "$docroot/403.md" or die $!;
    print {$sys} "---\ntitle: Forbidden\n---\n\n# Forbidden\n";
    close $sys;

    # AUTHENTICATED and outside the group. Anonymous is a 302 to login (SM223)
    # and an ACL refusal is a different branch with its own minimal body -
    # neither reaches serve_403.
    my $out = run_processor(
        $docroot, '/zz-gated',
        LAZYSITE_AUTH_TRUSTED => '1',
        HTTP_X_REMOTE_USER    => 'stranger',
        HTTP_X_REMOTE_GROUPS  => 'visitors',
    );
    like( $out, qr/Status: 403/, 'the fixture reaches serve_403' )
        or diag( 'got: ' . substr( $out, 0, 300 ) );

    unlike( $out, qr/rel=["']canonical["']/i,
        'the served 403 carries no canonical' )
        or diag( 'An error page is not the canonical version of anything - the '
            . 'reasoning SM355 applied to 404 and nobody applied here.' );

    if ( -f "$docroot/403.html" ) {
        open my $cf, '<', "$docroot/403.html" or die $!;
        local $/;
        my $cached = <$cf>;
        close $cf;
        unlike( $cached, qr/rel=["']canonical["']/i,
            'and neither does the cache file the front end serves at 403.html' );
        like( $cached, qr/name=["']robots["'][^>]*noindex/i,
            'which is noindex too, being an indexable soft error page' );
    }
};

# --- SM371, the FIELD case itself: the 402, with a query string ---------------
# The 0.10.14 validation found /402.html carrying a VISITOR-SUPPLIED query
# string in its canonical, pointing at the payment-gated page the visitor had
# just been refused - and the changelog admitted the fix shipped untested. The
# 403 subtest above proves the sanitiser runs on ONE error path; this one
# proves it on the path the field actually caught, and asserts the sharper
# property underneath: REQUEST-CONTROLLED BYTES MUST NOT PERSIST INTO THE
# SHARED CACHE FILE. The cached 402.html is served to every later visitor, so
# a query string surviving into it is one visitor writing into every other
# visitor's page - the cache-poisoning shape, not just an SEO nit.
subtest 'a 402 has no canonical, and the query string dies with it' => sub {
    open my $paid, '>', "$docroot/zz-paid.md" or die $!;
    print {$paid}
        "---\ntitle: Paid\npayment: required\npayment_amount: 0.01\n"
        . "payment_address: 0xabc\npayment_asset: 0xdef\n---\n\npaid content\n";
    close $paid;

    open my $sys, '>', "$docroot/402.md" or die $!;
    print {$sys} "---\ntitle: Payment required\n---\n\n# Payment required\n";
    close $sys;

    my $poison = 'utm_source=EVIL-MARKER-8871';
    my $out    = run_processor( $docroot, '/zz-paid', QUERY_STRING => $poison );
    like( $out, qr/Status: 402/, 'the fixture reaches serve_402' )
        or diag( 'got: ' . substr( $out, 0, 300 ) );

    unlike( $out, qr/rel=["']canonical["']/i,
        'the served 402 carries no canonical' );
    unlike( $out, qr/EVIL-MARKER-8871/,
        'and no visitor-supplied byte survives into the body' );

    ok( -f "$docroot/402.html", 'the cache file the front end serves exists' );
    open my $cf, '<', "$docroot/402.html" or die $!;
    local $/;
    my $cached = <$cf>;
    close $cf;
    unlike( $cached, qr/rel=["']canonical["']/i,
        'the CACHED 402 carries no canonical' );
    unlike( $cached, qr/EVIL-MARKER-8871/,
        'and the query string is nowhere in the file every later visitor gets' );
    like( $cached, qr/name=["']robots["'][^>]*noindex/i, 'noindex, like the others' );
};

done_testing();