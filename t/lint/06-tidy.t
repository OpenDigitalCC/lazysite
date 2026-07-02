#!/usr/bin/perl
# Review D2: perltidy gate, CHANGED-CODE-ONLY. The existing tree keeps its
# hand-formatting; tools/tidy-check.pl flags only lines a change touched (since
# the last release tag) that are not in the .perltidyrc canonical form. Skips
# cleanly when perltidy or git is unavailable (e.g. a release tarball).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $tc   = "$root/tools/tidy-check.pl";

ok( -f $tc, 'tidy-check.pl present' );

my $out = `$^X \Q$tc\E 2>&1`;
my $rc  = $? >> 8;

if ( $out =~ /SKIP/ ) {
    diag($out);
    ok( 1, 'tidy gate skipped (no perltidy/git or no base tag)' );
}
else {
    is( $rc, 0, 'all code changed since the last release is perltidy-clean' )
        or diag($out);
}

done_testing();
