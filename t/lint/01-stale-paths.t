#!/usr/bin/perl
# SM045: grep-level invariant. The D013 rename moved the manager UI
# source from lazysite/themes/manager/ to lazysite/manager/. A stray
# "themes/manager" literal in code that actually reads the path
# (tools/lazysite-server.pl for the dev-server seed, the manager-api
# default blocked-paths list) means the post-rename plumbing is
# pointing at a phantom.
#
# Cheap-and-broad test to stop this class of regression, not a
# substitute for the feature-level tests on each specific case.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my @files = (
    'tools/lazysite-server.pl',
    'lazysite-manager-api.pl',
);

for my $rel (@files) {
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
