#!/usr/bin/perl
# SM1316 (ruling 45): THE HESTIA UPDATER IS NOT GIVEN ITS OWN STAGE.
#
# lazysite-hestia-update-all.sh takes STAGE_DIR and defaults it to the release
# it runs from (`dirname $0`/../..). Every command the docs, the deploy hook
# and the CLI's hint gave an operator named the stage twice -
#
#     bash STAGE/installers/hestia/lazysite-hestia-update-all.sh --force-security STAGE
#
# - and the release manager asked for it once. This fails on any line in the
# tree outside the release history that runs the updater by a path and then
# gives that same path again as an argument.
#
# The CLI builds its hint from payload_root() rather than writing it out, so
# t/tools/291 checks that hint as printed.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_child);

my $root = repo_root();
my $ls   = run_child( [ 'git', '-C', $root, 'ls-files', '-z' ], stderr => 'discard' );
plan skip_all => 'not a git checkout' if $ls->{status};

# The release history records the commands as they were given; it is not
# rewritten (CHANGELOG sections, released notes, filings, reviews).
my $HISTORY = qr{\A(?:CHANGELOG\.md|debian/changelog|docs/releases/|docs/feature-requests/|docs/review/)};
# This file quotes the old form in its header.
my $SELF    = 't/lint/' . ( $0 =~ s{.*/}{}r );
my @files   = grep { !/$HISTORY/ && $_ ne $SELF && -f "$root/$_" && !-l "$root/$_" } split /\0/, $ls->{out};
cmp_ok( scalar @files, '>', 100, 'the tracked tree was listed' );

my $UPDATER = qr{([^\s"'`]+)/installers/hestia/lazysite-hestia-update-all\.sh\b([^\n]*)};
my ( @twice, $seen );
for my $rel (@files) {
    open my $fh, '<', "$root/$rel" or next;
    my $n = 0;
    while ( my $line = <$fh> ) {
        $n++;
        next unless $line =~ $UPDATER;
        my ( $stage, $rest ) = ( $1, $2 );
        $seen++;
        push @twice, "$rel:$n: $line"
            if $rest =~ /(?:\A|[\s"'`])\Q$stage\E(?:[\s"'`;)]|\z)/;
    }
    close $fh;
}
cmp_ok( $seen // 0, '>', 2, 'commands that run the updater by a path were found' );
is( scalar @twice, 0, 'none of them gives the updater its own stage again' )
    or diag( "The updater's stage defaults to the release it runs from; drop the second one:\n"
        . join '', @twice );

done_testing();
