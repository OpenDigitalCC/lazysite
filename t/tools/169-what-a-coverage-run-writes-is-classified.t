#!/usr/bin/perl
# SM1116: everything a coverage run writes into the tree is classified.
#
# The one-night coverage run of 2026-10-17 measured no group: it stopped in the
# first, processor, after 1h42m, because t/integration/259 builds the release
# manifest and the manifest REFUSES an unclassified file - and the run had just
# written one, cover_db-processor-suite.log. The per-group runner
# (tools/coverage-parts.sh) names its suite log cover_db-<group>-suite.log; the
# exclude list knew cover_db/, cover_db-<x>/ and the whole-suite
# cover_db-suite.log, and not the group's log. n594 (0.15.5) was the same
# defect for the group's DB folder.
#
# What this holds: each name the coverage tools write at the tree root, for the
# whole suite and for every group in the area map, matches an exclude rule in
# dist/config/classification.json. A new name the tools start writing fails
# here, in seconds, instead of two hours into the night.
use strict;
use warnings;
use Test::More;
use JSON::PP ();
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $cls  = do {
    open my $fh, '<', "$root/dist/config/classification.json" or die $!;
    local $/;
    JSON::PP::decode_json(<$fh>);
};
my @ex = map {qr/$_/} @{ $cls->{exclude} };
sub excluded { my ($p) = @_; return scalar grep { $p =~ $_ } @ex }

# The names, read from the tools that write them, so a rename is followed.
my $parts = do { open my $fh, '<', "$root/tools/coverage-parts.sh" or die $!; local $/; <$fh> };
my $whole = do { open my $fh, '<', "$root/tools/coverage.sh"       or die $!; local $/; <$fh> };
like( $parts, qr/cover_db\}-\$name-suite\.log/, 'coverage-parts.sh names a group log cover_db-<group>-suite.log' );
like( $whole, qr/cover_db-suite\.log/,           'coverage.sh names the whole-suite log cover_db-suite.log' );

my @groups = do {
    my $out = `\Q$^X\E \Q$root/tools/coverage-groups.pl\E --list 2>/dev/null`;
    grep {/\A[a-z][\w-]*\z/} split /\s+/, $out;
};
@groups = qw(processor tools) unless @groups;    # the shape, if the map cannot be listed

ok( excluded('cover_db-suite.log'), 'the whole-suite log is excluded' );
ok( excluded('cover_db/x'),         'the whole-suite DB is excluded' );
for my $g (@groups) {
    ok( excluded("cover_db-$g-suite.log"), "group $g: its suite log is excluded" );
    ok( excluded("cover_db-$g/structure/x"), "group $g: its DB is excluded" );
}
ok( !excluded('lazysite-processor.pl') && !excluded('lib/Lazysite/Util.pm'), 'and no rule reaches engine files' )
    or diag 'an exclude that matched engine code would drop it from the payload';

done_testing;
