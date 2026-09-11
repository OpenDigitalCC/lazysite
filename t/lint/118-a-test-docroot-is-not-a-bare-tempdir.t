#!/usr/bin/perl
# SM754: a test that uses a bare tempdir() as a docroot leaks the docroot's
# siblings into /tmp - the private store at <docroot>-lazysite-private, the
# Hestia layout's plugins/ tools/ lib/ at ../ - because File::Temp cleans only
# the directory it made. Measured on the dev host: 15,386 entries, 356 MB, and
# a leaked /tmp/plugins/stats.pl that made a "not found" assertion pass for the
# wrong reason.
#
# TestHelper::site_tempdir() puts the docroot one level down so every sibling
# write lands inside what CLEANUP removes. This file counts the tests that still
# hand a bare tempdir to the engine as a docroot, against a ceiling that ONLY
# GOES DOWN (the SM728 pattern): a new test must use the helper, and converting
# an old one lowers the number.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my @files = sort( glob("$root/t/*/*.t"), glob("$root/t/*/*/*.t") );
cmp_ok( scalar @files, '>', 500, 'the suite was found' );

# A test is a "bare tempdir docroot" when it calls tempdir() itself AND hands a
# path to the engine as a docroot (DOCUMENT_ROOT, $DOCROOT, --docroot, or by
# building lazysite/ inside it), AND does not use the helper.
my @bare;
for my $f (@files) {
    open my $fh, '<', $f or next;
    my $s = do { local $/; <$fh> };
    close $fh;
    next unless $s =~ /\btempdir\s*\(/;
    next unless $s =~ /DOCUMENT_ROOT|DOCROOT|--docroot|lazysite\//;
    next if $s =~ /\bsite_tempdir\s*\(/;
    ( my $rel = $f ) =~ s{^\Q$root\E/}{};
    push @bare, $rel;
}

my $ceiling = 470;
cmp_ok( scalar @bare, '<=', $ceiling,
    'tests handing a bare tempdir to the engine as a docroot: ' . scalar(@bare) . " <= ceiling $ceiling" )
    or diag( "A NEW test must use TestHelper::site_tempdir() (or put its docroot a level down by hand and say why).\n"
        . "If you converted some, LOWER the ceiling in this file. Newest offenders are the ones not in the previous count." );

# The exemplars that do it by hand, so the helper's rule is visible in the
# tests that predate it.
for my $ex ( 't/unit/daemon/05-the-real-jobs-do-real-work.t', 't/unit/manager/155-an-update-to-the-served-artefact-switches-in.t' ) {
    open my $fh, '<', "$root/$ex" or next;
    my $s = do { local $/; <$fh> };
    close $fh;
    like( $s, qr/mkdir "\$t\/site";|site_tempdir/, "$ex: one level down" );
}

done_testing();
