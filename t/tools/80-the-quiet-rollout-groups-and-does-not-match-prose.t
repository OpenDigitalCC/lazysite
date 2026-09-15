#!/usr/bin/perl
# SM889: the quiet fleet rollout reports findings ONCE, with the sites they
# affect, and does not mistake prose for a finding.
#
# THE 0.14.2 RUN PRINTED ~200 LINES TO SAY "29 updated, 0 failed". The two
# largest sources were both the filter matching a bare word:
#
#   `missing` matched 71 per-file "backup: missing <path>" lines.
#
#   `missing` ALSO matched, once per site, this line from the installer's
#   Next steps block:
#
#       deliberate, not a missing step, and there is no default login:
#
#   which is a sentence saying nothing is wrong. grep printed that one line out
#   of a fifteen-line block, so it arrived ending in a colon with its
#   continuation gone - and was filed as a SECOND defect, "a truncated
#   message". It is not truncated. It is this one.
#
# And the same ~45-word probe warning appeared 21 times verbatim: one condition
# affecting 21 sites, reported as though it were 21 findings.
#
# WHAT IS TESTED: the pattern and the grouping, in isolation, against the real
# lines from that run. Driving the whole updater needs a Hestia host, root and
# a fleet; the two pieces that regressed are a regex and an awk block, and they
# are exercised here directly rather than asserted from source.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $script = "$root/installers/hestia/lazysite-hestia-update-all.sh";

open my $fh, '<', $script or BAIL_OUT("no updater: $!");
my $src = do { local $/; <$fh> };
close $fh;

my ($noise_re) = $src =~ /^NOISE_RE='(.+)'$/m;
ok( $noise_re, 'the finding pattern was found in the script' )
    or do { done_testing(); exit };

# Exercise the pattern exactly as the script does: grep -E.
my $dir = tempdir( CLEANUP => 1 );
sub matches {
    my ($line) = @_;
    open my $w, '>', "$dir/in" or die $!;
    print {$w} "$line\n";
    close $w;
    my $out = `grep -E \Q$noise_re\E \Q$dir/in\E 2>/dev/null`;
    return ( defined $out && length $out ) ? 1 : 0;
}

subtest 'prose is not a finding' => sub {
    is( matches('     deliberate, not a missing step, and there is no default login:'),
        0, 'the installer\'s "not a missing step" reassurance is not a finding' )
        or diag( 'This single line, sliced out of a fifteen-line block, is what '
            . 'was filed as a truncated message. It is a sentence saying '
            . 'nothing is wrong.' );

    is( matches('  backup: missing /home/x/web/s/public_html/members.md (recorded in state but not on disk; skipped)'),
        0, 'a per-file backup note is not a finding' )
        or diag( '71 of these in one run, for pages an operator deleted on '
            . 'purpose.' );

    is( matches('  Preserved:  2 (operator-edited)'), 0, 'an install summary line is not a finding' );
    is( matches('No protected sections - nothing to re-apply.'), 0,
        'a no-op is not a finding' );
};

subtest 'real findings still match' => sub {
    is( matches('  [ warn ] a file the engine refuses is still being served to anonymous visitors'),
        1, 'a levelled warning matches' );
    is( matches('WARN: the private store is not usable'), 1, 'a WARN: prefix matches' );
    is( matches('  ERROR  could not write the config'),   1, 'an ERROR marker matches' );
    is( matches('  cp: cannot create regular file: Permission denied'),
        1, 'permission denied matches' );
    is( matches('  the engine refused to protect the probe folder'),
        1, 'a refusal matches' );
};

# --- the grouping -----------------------------------------------------------
#
# Extracted and run as the script runs it, so the assertion is about the awk
# that ships rather than a re-implementation of it.
my ($awk) = $src =~ /sort "\$FINDINGS_FILE" \| awk -F'\\t' '(.+?)'\s*\|\s*sort/s;
ok( $awk, 'the grouping block was found' ) or do { done_testing(); exit };

subtest 'one condition on twenty-one sites is one line, not twenty-one' => sub {
    my $warn = '[ warn ] a file the engine refuses is still being served';
    open my $w, '>', "$dir/findings" or die $!;
    print {$w} "probe site$_\t$warn\n" for 1 .. 21;
    print {$w} "probe other\t[ warn ] something else entirely\n";
    close $w;

    my $out = `sort \Q$dir/findings\E | awk -F'\\t' \Q$awk\E | sort`;
    $out //= '';

    my @lines = grep { /^\s*\[\d+\]/ } split /\n/, $out;
    is( scalar @lines, 2, 'two distinct messages, not twenty-two lines' )
        or diag("got:\n$out");
    like( $out, qr/\[21\]/, 'the repeated one is counted' );
    like( $out, qr/sites: .*site1.*site21|sites: .*site21/s,
        'and the sites it affects are named, so the count is checkable' );
};

done_testing();
