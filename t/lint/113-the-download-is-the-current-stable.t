#!/usr/bin/perl
# The download/ directory holds the current STABLE release, and only that.
#
# It exists because somebody asked to download the engine without building it,
# and a tracked file is the shortest path from a repository to a file. The cost
# is that binaries in git are permanent - roughly 8 MB per stable release, never
# reclaimed - so the directory holds ONE release, replaced rather than
# accumulated, and this is what enforces "one".
#
# WHY THIS NEEDS A LINT AT ALL. A download directory is the archetype of a thing
# that goes stale invisibly: nothing fails, nothing warns, the files are still
# perfectly valid, and somebody downloads a year-old build believing it is
# current. There is no runtime signal for that, ever - the only moment it can be
# caught is here.
#
# IT READS GATE-LOG, NOT VERSION, and the difference is the whole point. VERSION
# is the last release on ANY channel, so after an edge cut it names a build that
# was never meant for a download link. The gate log records the channel of every
# release, so "newest stable" is a fact that can be read rather than assumed.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $dir  = "$root/download";

plan skip_all => 'no download directory' unless -d $dir;

# --- the newest stable, from the release log -------------------------------
my $gate = "$root/docs/releases/GATE-LOG.md";
open my $gh, '<', $gate or BAIL_OUT("no gate log: $!");
my @stable;
while ( my $line = <$gh> ) {
    next unless $line =~ /^\|\s*(\d+\.\d+\.\d+)\s*\|\s*stable\s*\|/;
    push @stable, $1;
}
close $gh;

@stable = sort {
    my @x = split /\./, $a;
    my @y = split /\./, $b;
    $x[0] <=> $y[0] || $x[1] <=> $y[1] || $x[2] <=> $y[2];
} @stable;

my $want = $stable[-1];
ok( defined $want, 'the gate log records at least one stable release' )
    or BAIL_OUT( 'no stable row in GATE-LOG - this test would otherwise pass '
        . 'by having nothing to compare against, which is the failure mode it '
        . 'exists to catch one level down' );

diag("newest stable per GATE-LOG: $want");

# --- what is actually there -------------------------------------------------
opendir my $dh, $dir or BAIL_OUT("cannot read download/: $!");
my @files = sort grep { !/\A\.\.?\z/ && $_ ne 'README.md' } readdir $dh;
closedir $dh;

subtest 'every artefact is the current stable version' => sub {
    my @wrong = grep { !/\Q$want\E/ } @files;
    is_deeply( \@wrong, [], "nothing in download/ is from another release" )
        or diag( join "\n  ",
        '',
        "These name a version that is not $want:",
        @wrong,
        '',
        'download/ holds ONE release. Replace its contents at the next stable '
            . 'cut rather than adding to them - the history keeps every version '
            . 'ever committed here whether or not the file is still present.' );
};

subtest 'the set is complete enough to be useful' => sub {
    # A downloader needs the engine and the glue for their web server, or the
    # tarball. Half a set is worse than none: it looks like a choice was made.
    my %have = map { $_ => 1 } @files;

    ok( $have{"lazysite-$want.tar.gz"}, 'the tarball is present' );
    ok( $have{"lazysite-$want.tar.gz.sha256"},
        'and its checksum, so the download can be verified' );

    for my $flavour (qw(common nginx apache hestia)) {
        ok( $have{"lazysite-${flavour}_${want}-1_all.deb"},
            "the $flavour package is present" );
    }
};

subtest 'the README names the version it is describing' => sub {
    # Instructions carrying a stale version number are worse than none: they
    # are copy-pasteable and wrong.
    my $readme = "$dir/README.md";
    ok( -f $readme, 'download/README.md exists' ) or return;

    open my $fh, '<', $readme or die $!;
    my $text = do { local $/; <$fh> };
    close $fh;

    like( $text, qr/\Q$want\E/, "it names $want" );

    my @stale = grep { $_ ne $want } ( $text =~ /(\d+\.\d+\.\d+)/g );
    is_deeply( [ sort keys %{ { map { $_ => 1 } @stale } } ], [],
        'and mentions no other version, so no install line is copy-pasteable and wrong' );
};

done_testing();
