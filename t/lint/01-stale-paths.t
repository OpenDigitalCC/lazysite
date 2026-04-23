#!/usr/bin/perl
# SM045 + SM062: grep-level invariant. The D013 rename moved the
# manager UI source from lazysite/themes/manager/ to
# lazysite/manager/. A stray "themes/manager" literal in any file
# that either (a) code actually reads as a path, or (b) docs the
# tree layout, means post-rename drift — the pattern has bitten
# twice (0.2.11 lost the functional fixes; SM062 cleaned up the
# four doc/comment leftovers that never made it past 0.2.11's
# partial recovery).
#
# Cheap-and-broad test to stop this class of regression, not a
# substitute for the feature-level tests on each specific case.
# SM062: extended to cover the four doc/comment files that
# originally fell off SM045's recovery list.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my @guarded = (
    # Functional paths (SM045 / SM046 / SM055 territory).
    'tools/lazysite-server.pl',
    'lazysite-manager-api.pl',
    # Doc/comment leftovers (SM062). Every one of these drifted
    # out of sync after the D013 rename and stayed stale through
    # 0.2.17 despite SM045's release notes claiming they'd land.
    'starter/lazysite.conf.example',
    '.gitignore',
    'starter/docs/ai-briefing-development.md',
    'starter/lazysite/manager/assets/manager.css',
);

for my $rel (@guarded) {
    my $path = "$root/$rel";
    open my $fh, '<', $path or do {
        fail("cannot open $rel: $!");
        next;
    };
    my $text = do { local $/; <$fh> };
    close $fh;

    unlike( $text, qr{themes/manager},
        "$rel has no stale D013 path 'themes/manager'" );
}

done_testing();
