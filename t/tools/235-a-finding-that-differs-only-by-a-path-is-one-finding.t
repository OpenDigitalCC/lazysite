#!/usr/bin/perl
# SM1235: the quiet rollout reports a message that differs only by a path ONCE.
#
# THE 0.16.0 ROLLOUT (2026-10-22, 32 sites) gave sumaya.fund about seventy lines
# of
#
#   WARNING: both trees held 'docs/X.md': the private store's copy is kept ...
#   the document root's copy was moved to <dir>/docs/X.md, where it can be
#   recovered
#
# one per file, because findings were grouped one line per DISTINCT MESSAGE and
# every path made a message distinct. The operator could no longer copy the
# report. These lines are now one finding: the count, the directories the paths
# are under (the displaced directory, for this one), three examples, and a file
# with the full list.
#
# The function is extracted from the script and RUN, as t/tools/80 runs it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $script = repo_root() . '/installers/hestia/lazysite-hestia-update-all.sh';
my $src    = do { open my $fh, '<', $script or die $!; local $/; <$fh> };
my ($fn)   = $src =~ /^(group_findings\(\) \{\n.*?^\}\n)/ms;
ok( $fn, 'the group_findings function was found' ) or do { done_testing; exit };

my $dir = tempdir( CLEANUP => 1 );

sub grouped {
    my (@lines) = @_;
    unlink "$dir/full.txt";
    open my $w, '>', "$dir/in" or die $!;
    print {$w} "$_\n" for @lines;
    close $w;
    open my $s, '>', "$dir/g.sh" or die $!;
    print {$s} "set -u\n$fn\nFINDINGS_FULL='$dir/full.txt' group_findings\n";
    close $s;
    return scalar `bash \Q$dir/g.sh\E < \Q$dir/in\E 2>&1`;
}

my $DISP = '/home/sumaya/web/sumaya.fund/public_html-lazysite/displaced/20261022T101010Z-4242';
my @held = map {
    "sumaya.fund\tWARNING: both trees held 'docs/$_.md': the private store's copy is kept - "
        . "it is the one the rule governs and the engine serves - and the document root's copy "
        . "was moved to $DISP/docs/$_.md, where it can be recovered"
} map { "page$_" } 1 .. 70;

subtest 'seventy per-file lines are one finding' => sub {
    my $out = grouped(@held);
    my @rec = grep {/^\s*\[\d+\]/} split /\n/, $out;
    is( scalar @rec, 1, 'one finding, not seventy' ) or diag $out;
    like( $out, qr/^\s*\[1\] WARNING: both trees held '<path>':.*moved to <path>, where it can be recovered$/m,
        'the message, with its paths as <path>' );
    like( $out, qr/70 instance\(s\)/, 'the count' );
    like( $out, qr{sumaya\.fund: docs/ \| \Q$DISP\E/docs/$}m,
        'the displaced directory, where the files were moved to' );
    like( $out, qr{e\.g\. docs/page1\.md, docs/page10\.md, docs/page11\.md}, 'three examples' );
    like( $out, qr{full list: \Q$dir\E/full\.txt}, 'the file holding the full list is named' );
    open my $fh, '<', "$dir/full.txt" or die "no full list: $!";
    my @full = grep {/^sumaya\.fund\t/} <$fh>;
    is( scalar @full, 70, 'and it holds every line' );
    my $lines = () = $out =~ /\n/g;
    cmp_ok( $lines, '<=', 8, 'in a handful of lines' ) or diag $out;
};

subtest 'other per-path findings collapse too' => sub {
    # The same check warning naming each site's own docroot, and the same
    # refusal naming different files - neither is the both-trees line.
    my $out = grouped(
        "repair a.test\t[ FAIL ] the private store exists but the engine cannot write to it (/home/a/web/a.test/public_html-lazysite-private, owner u:u, mode 2700)",
        "repair b.test\t[ FAIL ] the private store exists but the engine cannot write to it (/home/b/web/b.test/public_html-lazysite-private, owner u:u, mode 2700)",
        "c.test\tNOT MOVED: '/members/x.pdf' the rule is stored",
        "c.test\tNOT MOVED: '/members/y.pdf' the rule is stored",
        "d.test\t[2026-10-22 10:00:01] [ERROR] [lazysite] something failed",
    );
    my @rec = grep {/^\s*\[\d+\]/} split /\n/, $out;
    is( scalar @rec, 3, 'two sites\' docroot paths are one finding, two files are one finding' )
        or diag $out;
    like( $out, qr/^\s*\[2\] \[ FAIL \] the private store exists but the engine cannot write to it \(<path>, owner/m,
        'counted as two sites' );
    like( $out, qr/^\s*\[1\] NOT MOVED: '<path>' the rule is stored$/m, 'a quoted path is a path' );
    like( $out, qr/^\s*\[1\] \[ERROR\] \[lazysite\] something failed$/m,
        'a leading log timestamp is not part of the message' );
};

subtest 'a message with no path, or one copy, reads as before' => sub {
    my $out = grouped( "a.test\t[ warn ] the same words", "b.test\t[ warn ] the same words",
        "a.test\tWARN: could not read /home/a/x (Permission denied)" );
    like( $out, qr/^\s*\[2\] \[ warn \] the same words\n\s*sites: a\.test, b\.test$/m, 'unchanged' );
    like( $out, qr{^\s*\[1\] WARN: could not read /home/a/x \(Permission denied\)$}m,
        'a single path-bearing line is printed whole, path and all' );
    ok( !-e "$dir/full.txt", 'and no full-list file is written when nothing collapsed' );
};

subtest 'a URL is not a path' => sub {
    my $out = grouped( "a.test\t[ warn ] fetch https://a.test/x failed",
        "b.test\t[ warn ] fetch https://b.test/x failed" );
    my @rec = grep {/^\s*\[\d+\]/} split /\n/, $out;
    is( scalar @rec, 2, 'two different URLs stay two findings' ) or diag $out;
};

done_testing();
