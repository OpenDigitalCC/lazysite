#!/usr/bin/perl
# SM971: THE BUILD RE-CHECKS EVERY LINT THAT READS RELEASE MATERIAL.
#
# release.sh build writes the release commit - the CHANGELOG section, FEATURES,
# the version pair, the briefing, the index, the GATE-LOG row, the coverage
# record - and runs only the lints that read those files before it tags, not
# the hour-long gate again. That is sound only while the list is complete. It
# lives in tools/release-material.pl (--lints); this asserts that every lint
# naming a release-material path (--paths) by its file name - or reading the
# changelog through changelog_text() - is on it, so a new one cannot be missed.
use strict;
use warnings;
use Test::More;
use File::Basename qw(basename);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();
my $gen  = "$root/tools/release-material.pl";

my @paths = split /\n/, run_cmd( $^X, $gen, '--paths' );
ok( scalar @paths >= 9, 'the generator publishes its allowlist' ) or BAIL_OUT('no allowlist to check against');
my $listed = run_cmd( $^X, $gen, '--lints', '--dir', $root );
is( $?, 0, 'and its checks, every one a file in this tree' ) or diag($listed);
my %listed = map { $_ => 1 } split /\n/, $listed;

# A path is named by its file name; VERSION only as a quoted or path-final word,
# since the bare word is in half the lints' prose.
my %pattern = map {
    my $b = basename($_);
    ( $_ => $b eq 'VERSION' ? qr{'VERSION'|"VERSION"|/VERSION\b} : qr{\Q$b\E} )
} @paths;
$pattern{'CHANGELOG.md (changelog_text)'} = qr/\bchangelog_text\b/;

my @missing;
for my $lint ( sort glob "$root/t/lint/*.t" ) {
    ( my $rel = $lint ) =~ s{^\Q$root\E/}{};
    next if $rel =~ m{^t/lint/214-};           # this file names them all
    my $text  = do { open my $f, '<', $lint or die "$lint: $!"; local $/; <$f> };
    my @reads = grep { $text =~ $pattern{$_} } sort keys %pattern;
    push @missing, "$rel reads @reads" if @reads && !$listed{$rel};
}
is_deeply( \@missing, [], 'every lint that reads release material is one the build runs' )
    or diag( "Add each to \@LINTS in tools/release-material.pl - the build re-checks the\n"
        . 'release commit with exactly that list.' );

done_testing();
