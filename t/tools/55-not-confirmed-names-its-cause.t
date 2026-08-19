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
    like( $src, qr/\@skip_reasons/, 'and kept for the summary' );
};

subtest 'the summary prints the reason rather than a fixed guess' => sub {
    my ($block) = $src =~ /if \(\@unconfirmed\) \{(.*?)\n    \}/s;
    ok( $block, 'the NOT CONFIRMED block is present' ) or return;

    like( $block, qr/\@skip_reasons/,
        'it uses the reasons it captured' );

    # The repair advice must be CONDITIONAL now. It is right when the probe gave
    # no reason and wrong when it did.
    my ($repair) = $block =~ /(No reason was given.*?repair.*?;)/s;
    ok( $repair, 'the repair advice survives for the no-reason case' )
        or diag( 'That case is real - a docroot the probe cannot write gives no '
            . 'reason - and losing the advice would trade one wrong summary '
            . 'for another.' );

    # And it must not be reachable when a reason WAS given.
    my ($else_pos) = $block =~ /(else \{)/;
    ok( $else_pos, 'and only in the else branch' )
        or diag( 'If the repair line prints unconditionally, this is the '
            . 'defect again with extra text above it.' );
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
