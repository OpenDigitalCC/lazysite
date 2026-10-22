#!/usr/bin/perl
# SM385: a NOT CONFIRMED summary must say why, not guess.
#
# MEASURED IN A REAL DEPLOY, 0.10.15 to edge. The probe declined, correctly, and
# said exactly why:
#
#   [ warn ] ACL PROBE SKIPPED: running as root - protecting content here would
#            leave root-owned files in the site tree (SM139)
#
# and the summary three lines below it said:
#
#   Nothing was established either way. Usual cause is a docroot or
#   ACL store the probe could not write: run `lazysite repair` first.
#
# `lazysite repair` fixes nothing here. The cause was stated and then
# overwritten by a guess, in the summary - which is the part a deploy log reader
# actually sees. SM377 added the new skip and this text was not updated with it.
#
# Sending an operator after the wrong thing is the defect SM368 exists for, and
# it is worse in a summary than in a detail line.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $cli  = "$root/tools/lazysite-cli.pl";
plan skip_all => "no $cli" unless -f $cli;

my $src = do { open my $fh, '<', $cli or die $!; local $/; <$fh> };

subtest 'the skip reason is captured from the probe output' => sub {
    like( $src, qr/\QACL PROBE SKIPPED:\E\\s\*\(\.\+\?\)/,
        'the reason the probe gave is parsed out' )
        or diag( 'Without this the summary can only guess, and the probe has '
            . 'already done the work of saying why.' );
    like( $src, qr/_probe_unconfirmed_reason/, 'by the one sub that names a reason per site' );
};

subtest 'the summary prints the reasons, and no fixed guess' => sub {
    my ($block) = $src =~ /if \(\@unconfirmed\) \{(.*?)\n    \}/s;
    ok( $block, 'the NOT CONFIRMED block is present' ) or return;
    like( $block, qr/for my \$r \(\@whys\)/, 'it lists the reasons it captured' );

    # SM1237: the repair advice survived here for "the probe gave no reason",
    # on the argument that a docroot the probe cannot write gives none. It does
    # give one ("cannot create a probe directory in the docroot"), and the cases
    # that truly gave none - no usable answer, a check that did not run - now
    # get their own words. The guess had no case left that it was right for.
    unlike( $block, qr/No reason was given|usually means/, 'the guess is gone' );
};
subtest 'the root skip is the case that exposed this' => sub {
    # Named explicitly so a future reader knows which reason broke the guess,
    # and so removing the root skip does not silently orphan this test.
    my $chk = do {
        open my $fh, '<', "$root/tools/lazysite-check.pl" or die $!;
        local $/;
        <$fh>;
    };
    like( $chk, qr/ACL PROBE SKIPPED: \$reason/,
        'the check emits its skip reason in the designated form' );
    like( $chk, qr/running as root/,
        'and the root refusal is one of them' );
};

done_testing();
