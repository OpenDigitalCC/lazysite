#!/usr/bin/perl
# SM363: the manager Stats page renders what the stats record.
#
# Sessions, journeys, devices and search terms were all computed, stored per day
# and - after the first half of this fix - carried in the payload the page
# fetches. The page rendered none of them.
#
# THE ONE THAT MATTERED is search terms, because it is the only stats setting an
# operator turns on deliberately. The sequence was: read the setting, weigh the
# privacy question, decide to accept it, switch it on - and see nothing happen.
# The reasonable conclusion is that it does not work, and the reasonable next
# step is to turn it off again or report a defect that is not there.
#
# A setting that appears to do nothing is the same defect class as a control
# that reports without acting, approached from the other end.
#
# THIS TESTS THE PAGE SOURCE, not a browser. What it can establish is that every
# field is read and rendered, and that the visitor-supplied one is escaped;
# what it cannot is that the result looks right, which is a manual check.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $page = do {
    open my $fh, '<', "$root/starter/manager/stats.md" or die $!;
    local $/;
    <$fh>;
};

subtest 'every field the payload carries is rendered' => sub {
    for my $field (qw(devices search_terms sessions journeys)) {
        like( $page, qr/\bd\.$field\b|\bj\.\w+\b/,
            "the page reads $field" );
    }
    like( $page, qr/d\.devices/,      'devices' );
    like( $page, qr/d\.search_terms/, 'search terms' );
    like( $page, qr/d\.sessions/,     'visit count' );
    like( $page, qr/d\.journeys/,     'journeys' );
    like( $page, qr/j\.entry/,        'entry pages' );
    like( $page, qr/j\.exit/,         'exit pages - the most actionable of them' );
    like( $page, qr/j\.depth/,        'the depth histogram' );
};

subtest 'the visitor-supplied field is escaped, and is not a link' => sub {
    # Search terms are the first field this page renders whose content a
    # STRANGER chooses: whatever was typed into a query string, stored and then
    # displayed to an operator. Everything else here is a path or a count.
    # From the guard to the next section, rather than a brace-counting regex -
    # the first version stopped at the first close brace it met, which was
    # inside the forEach, and reported the escaping missing when it was two
    # lines further down.
    my ($block) = $page =~ /(if \(d\.search_terms.*?)\/\/ Status codes/s;
    ok( $block, 'found the search-terms block' ) or return;

    like( $block, qr/sesc\(\s*t\.key\s*\)/,
        'the term is escaped on the way into the page' )
        or diag( 'This is attacker-controlled text. pageTable() escapes its '
            . 'keys for the same reason and this block must not be the '
            . 'exception.' );

    unlike( $block, qr/href/,
        'and is not put in an href - a search term is not a URL' )
        or diag( 'pageTable puts its key in an href because a page key IS a '
            . 'path. Copying that pattern here would hand a stranger the '
            . 'target of a link in the manager UI.' );
};

subtest 'the search-terms block is absent, not empty, when nothing was recorded'
    => sub {
    # An empty list reads as "nobody searched". The truth on a site that never
    # enabled the setting is "nobody was asked", and the payload omits the key
    # entirely so the page can tell those apart - which it only does if it
    # tests for content rather than rendering an empty table.
    my ($guard) = $page =~ /(if \(d\.search_terms[^)]*\))/;
    ok( $guard, 'the block is guarded' );
    like( $guard, qr/d\.search_terms\.length/,
        'on the list having entries, not merely on the key existing' );
    };

subtest 'and the floor is stated where the terms are shown' => sub {
    # An operator looking at a top-20 list of things people typed should be
    # told, at that moment, that a one-off never reaches it. The setting note
    # says so; the setting note is on a different page.
    my ($block) = $page =~ /(if \(d\.search_terms.*?)\/\/ Status codes/s;
    like( $block, qr/one-off is never stored|separate visits/i,
        'the page says a term needs several visits before it is kept' );
};

done_testing();
