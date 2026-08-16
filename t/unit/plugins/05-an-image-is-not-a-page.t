#!/usr/bin/perl
# SM329: an image is not a page.
#
# WHAT WAS MEASURED on edge, 0.10.10, over a 30-day window:
#
#   2 of the 15 entries in top_pages were static assets
#   /assets/img/msg-breaking.jpg and /assets/img/msg-corporate.jpg were the
#     SECOND and THIRD most popular "pages" on the site, at 124 hits each
#   524 of 5,000 sampled events were .jpg, .png, .css or .js
#
# WHY IT IS NOT A COSMETIC MISCOUNT. `top_pages` keeps a FIXED number of entries,
# so every asset in it is a real page the site owner cannot see - and assets
# crowd out content by CONSTRUCTION rather than by accident, because one article
# with four images generates four asset hits per human page view.
#
# And every derived metric inherits it. Measured against the same data, "visitors
# who saw more than one page" fell from 41% to 5% once an image stopped counting
# as a page and a session had a boundary. That is the difference between a
# flattering number and a true one.
#
# RECORDING IS SEPARATE FROM COUNTING. An asset request stays in the event
# stream, where it still feeds classification and the browser-versus-bot
# heuristic. It is excluded from the page-facing aggregates, and counted on its
# own so the exclusion is auditable rather than invisible - a silent exclusion
# would be its own defect, indistinguishable from traffic that never happened.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $plugin = "$root/plugins/stats.pl";
ok( -f $plugin, 'the stats plugin is present' );

my $src = do { open my $fh, '<', $plugin or die $!; local $/; <$fh> };

# The predicate, evaluated in isolation so this tests behaviour rather than
# matching the source text.
my ($sub) = $src =~ /(my \$ASSET_RE = qr\{.*?\n\}xi;\n\nsub _is_asset \{.*?\n\}\n)/s;
ok( $sub, 'the asset predicate was found' ) or do { done_testing; exit };
eval "package AssetCheck; $sub 1;"          or die "could not evaluate it: $@";

subtest 'the things that are assets' => sub {
    for my $p (
        '/assets/img/msg-breaking.jpg',    # the actual field case
        '/assets/img/msg-corporate.jpg',
        '/img/hero.png', '/x.gif',   '/y.webp',   '/z.avif',
        '/logo.svg',     '/fav.ico', '/main.css', '/app.js',
        '/mod.mjs',      '/app.js.map',
        '/f.woff',       '/f.woff2', '/f.ttf', '/f.otf',
        )
    {
        ok( AssetCheck::_is_asset($p), "$p is an asset" );
    }
};

subtest 'the things that are pages' => sub {
    # The risk in the other direction: excluding real content. A page URL has no
    # extension in this engine, so the list must not reach anything page-shaped.
    for my $p (
        '/', '/about', '/docs/', '/docs/guide',
        '/news/2026-08-a-post-about-css',    # 'css' in the SLUG, not an extension
        '/sitemap.xml', '/feed.rss', '/llms.txt', '/robots.txt',
        '/downloads/report.pdf',             # a document IS content someone chose
        '/data/services.json',
        )
    {
        ok( !AssetCheck::_is_asset($p), "$p is NOT an asset" );
    }
};

subtest 'a cache-buster does not change what a file is' => sub {
    # Assets are versioned with ?v=<version> in this project, so a predicate that
    # matched only bare paths would exclude nothing on a real site.
    ok( AssetCheck::_is_asset('/manager/assets/manager.css?v=0.10.12'),
        'a versioned stylesheet is still an asset' );
    ok( AssetCheck::_is_asset('/x.png?a=1&b=2'), 'and any query at all' );
};

subtest 'both readers use the one predicate' => sub {
    # There are two counting sites - the first-party event stream and the access
    # log - and they had identical page-counting logic. A fix applied to one is
    # the shape SM318 and SM304 were filed about.
    my $uses = () = $src =~ /_is_asset\(\$path\)/g;
    cmp_ok( $uses, '>=', 2,
        'the predicate is applied on both the first-party and access-log paths' );

    my $excluded = () = $src =~ /&&\s*!\$is_asset/g;
    cmp_ok( $excluded, '>=', 2, 'and both exclude assets from top_pages' );
};

subtest 'the exclusion is auditable, not silent' => sub {
    # A count that vanishes is indistinguishable from traffic that never
    # happened. asset_hits is what lets a reader check the subtraction.
    like( $src, qr/asset_hits\s*=>/, 'asset_hits is reported' );
    my $reported = () = $src =~ /asset_hits\s*=>/g;
    cmp_ok( $reported, '>=', 3,
        'on the daily buckets and the rollups, not just one of them' );
};

subtest 'every view reports every class (SM330)' => sub {
    # The index enumerated human/ai/bot/noise and omitted `scanner` - the
    # LARGEST class on a public site, 71.7% of events on edge against 17.2%
    # human. The front page therefore showed a breakdown summing to a small
    # fraction of the traffic, with nothing to say a part was missing.
    #
    # The full-day view already reported all five: two hand-maintained lists of
    # one fact, and the shorter one was the one people saw first.
    like( $src, qr/our \@CLASSES = qw\(human ai bot noise scanner\)/,
        'there is one canonical class list' );

    # No view may enumerate the classes by hand any more, or the next class added
    # gets left out of whichever list nobody remembered.
    my @handwritten = $src =~ /qw\(\s*human\s+ai\s+bot\s+noise\s+scanner\s*\)/g;
    is( scalar @handwritten, 1,
        'and it is written out exactly once - the declaration itself' )
        or diag( 'A second hand-written copy is how scanner went missing from '
            . 'the index while the day view had it.' );

    # The index row specifically, since that is where it was wrong. Anchored on
    # the variable being built rather than on the row's punctuation: the first
    # version of this matched perltidy's current column alignment, so it found
    # nothing at all in the shipped source and returned early - it would have
    # passed over the defect it exists to catch.
    my ($idx) = $src =~ /\@days_idx = map \{(.*?)\n    \} \@dk;/s;
    ok( $idx, 'the index row was found' ) or return;
    like( $idx, qr/\@CLASSES/,
        'the index derives its classes rather than listing them' );
    unlike( $idx, qr/human\s*=>.*bot\s*=>/s,
        'and no longer enumerates a subset by hand' );
};

done_testing();
