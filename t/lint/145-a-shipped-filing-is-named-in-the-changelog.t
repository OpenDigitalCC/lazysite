#!/usr/bin/perl
# N141C: a filing that says it SHIPPED is named in the CHANGELOG.
#
# t/lint/26 checks the other direction - everything the CHANGELOG claims to have
# shipped is marked accordingly in docs/feature-requests - and it is careful and
# correct about it. But it starts from what the CHANGELOG SAYS, so a filing can
# be marked `status: shipped`, be genuinely released, and appear nowhere in the
# record, and the whole suite stays green.
#
# THAT IS NOT HYPOTHETICAL. It is how 0.14.1's own work came to sit on main with
# an empty `## Unreleased` section and nothing complaining - and when this check
# was first run it found THREE OLDER FILINGS in the same state: SM731 and SM733
# (0.11.11) and SM763 (0.13.4), all shipped, none recorded. They are in the
# CHANGELOG now, under "Recorded late", because the honest response to a gate
# finding real omissions is to record them rather than to exclude them.
#
# WHY IT MATTERS MORE THAN TIDINESS. The CHANGELOG is what an operator reads to
# decide whether an upgrade contains the fix they are waiting for, and what a
# future reader uses to date a behaviour change. A fix nobody can find in it
# gets re-filed, re-investigated, and occasionally re-fixed.
#
# WHAT THIS DOES NOT ASK. It does not require a filing to be in the section of
# the release that shipped it, or to be phrased any particular way - t/lint/26
# already owns the "shipped versus mentioned" grammar. It asks only that the id
# appears, which is the weakest claim that still makes the item findable.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

my $log = do {
    open my $fh, '<', "$root/CHANGELOG.md" or BAIL_OUT("no CHANGELOG: $!");
    local $/;
    <$fh>;
};
ok( length $log, 'the CHANGELOG is readable' ) or do { done_testing(); exit };

# Every filing, open and archived: being archived does not unship it.
my @shipped;
for my $dir ( "$root/docs/feature-requests", "$root/docs/feature-requests/archive" ) {
    opendir my $dh, $dir or next;
    for my $f ( sort grep { /\.md\z/ } readdir $dh ) {
        open my $fh, '<', "$dir/$f" or next;
        my $t = do { local $/; <$fh> };
        close $fh;
        my ($fm) = $t =~ /\A---\n(.*?)\n---/s or next;
        next unless $fm =~ /^status:\s*shipped\s*$/m;
        my ($id) = $fm =~ /^id:\s*(\S+)/m or next;
        push @shipped, { id => $id, file => $f };
    }
    closedir $dh;
}

cmp_ok( scalar @shipped, '>', 50, 'found the shipped filings to check' )
    or diag( 'If this collapses, the frontmatter shape changed and this test '
        . 'is checking nothing - fix the extraction before trusting a pass.' );

my @absent = grep { $log !~ /\Q$_->{id}\E/ } @shipped;

is( scalar @absent, 0,
    'every filing marked shipped is named somewhere in the CHANGELOG' )
    or diag( "Shipped, and absent from the record:\n"
        . join( "\n", map { "  $_->{id}  ($_->{file})" } @absent )
        . "\n\nAdd a bullet naming the id and the commit that implemented it. "
        . "If the item did NOT actually ship, the filing's status is the thing "
        . "that is wrong - fix that instead, because a false `shipped` is read "
        . "by tools/backlog.pl as work nobody needs to do." );

done_testing();
