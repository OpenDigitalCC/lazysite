#!/usr/bin/perl
# 2026-07-10 review D7: documentation currency, mechanically. When a
# mechanism is retired, every doc that teaches it as CURRENT behaviour must
# be swept - the SM095 rot recurred with SM138's manager_groups within eight
# days of the review that named the systemic cause. This gate makes the
# sweep unskippable: a retired term appearing outside the historical
# allowlist fails the build. Seed new terms here at retirement time.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# term => the release that retired it (for the failure message)
my %retired = (
    'manager_groups' => 'SM138, 0.6.5 - manager access is granted by groups (ui / manage_users)',
);

# Files that legitimately DESCRIBE history: changelogs, migration notes,
# reviews, ADRs, scoping/backlog docs, and the code that implements the
# migration itself (plus its tests).
my @exclude = (
    ':(exclude)CHANGELOG.md',
    ':(exclude)UPGRADE.md',
    ':(exclude)docs/review/*',
    ':(exclude)docs/adr/*',
    ':(exclude)docs/feature-requests/*',
    ':(exclude)*.pl', ':(exclude)*.pm', ':(exclude)t/*',
);

for my $term ( sort keys %retired ) {
    my $out = qx(git -C \Q$root\E grep -nI -e \Q$term\E -- '*.md' ':(exclude)CHANGELOG.md' ':(exclude)UPGRADE.md' ':(exclude)docs/review/' ':(exclude)docs/adr/' ':(exclude)docs/feature-requests/' 2>/dev/null);
    # A doc may still MENTION the term while explicitly marking it retired -
    # that is currency, not rot. Anything else teaches it as current.
    my @bad = grep { !/retir|legacy|SM138|histor|migrat|no longer|removed/i }
        grep { length } split /\n/, $out;
    is( join( "\n", @bad ), '',
        "retired term '$term' not taught as current ($retired{$term})" )
        or diag( join "\n", @bad );
}

done_testing();
