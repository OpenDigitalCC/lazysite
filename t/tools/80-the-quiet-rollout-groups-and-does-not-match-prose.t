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
# SM889 residue: the grouping is a FUNCTION now, and the whole function body is
# what runs here - `bash -c` on the text between its braces, fed the same
# label<TAB>message lines the script feeds it. The first version of this test
# extracted the awk alone, and the three defects the 0.14.3 rollout showed were
# all OUTSIDE the awk: the trailing `| sort` that tore every "sites:" line away
# from its finding, and the absence of any step stripping the phase from the
# label or collapsing a site seen in four phases into one.
my ($body) = $src =~ /^group_findings\(\) \{\n(.+?)\n\}\n/ms;
ok( $body, 'the group_findings function was found' ) or do { done_testing(); exit };

# Run AS A FUNCTION, because it is one: the body's first line is `local TAB`,
# and `local` outside a function is a bash error - the first draft passed the
# bare body to `bash -c` and every case saw empty output. Wrapping it in a
# function of the same shape is also what "run it as the script runs it" means.
sub grouped {
    my (@lines) = @_;
    open my $w, '>', "$dir/findings" or die $!;
    print {$w} "$_\n" for @lines;
    close $w;
    open my $s, '>', "$dir/group.sh" or die $!;
    print {$s} "group_findings() {\n$body\n}\ngroup_findings\n";
    close $s;
    my $out = `bash \Q$dir/group.sh\E < \Q$dir/findings\E 2>&1`;
    return $out // '';
}

subtest 'one condition on twenty-one sites is one line, not twenty-one' => sub {
    my $warn = '[ warn ] a file the engine refuses is still being served';
    my $out  = grouped( ( map {"probe site$_\t$warn"} 1 .. 21 ),
        "probe other\t[ warn ] something else entirely" );

    my @lines = grep { /^\s*\[\d+\]/ } split /\n/, $out;
    is( scalar @lines, 2, 'two distinct messages, not twenty-two lines' )
        or diag("got:\n$out");
    like( $out, qr/\[21\]/, 'the repeated one is counted' );
    like( $out, qr/sites: .*site1.*site21|sites: .*site21/s,
        'and the sites it affects are named, so the count is checkable' );
};

# --- the three defects the first real fleet run showed -----------------------

subtest 'a site seen in four phases is ONE site' => sub {
    # The 0.14.3 rollout printed [123] for a warning that can occur once per
    # site on 29 sites: check, repair-before, repair-after and probe each
    # contributed a labelled copy. The number on the report is the number of
    # sites, because that is what an operator does something about.
    my $warn = '[ warn ] this site has an account called "manager"';
    my $out  = grouped(
        "example.test\t$warn",
        "repair example.test\t$warn",
        "repair example.test\t$warn",
        "probe example.test\t$warn",
        "other.test\t$warn",
    );
    like( $out, qr/^\s*\[2\] /m, 'two sites, counted as 2' )
        or diag("got:\n$out");
    unlike( $out, qr/\[[3-9]\]|\[\d\d+\]/, 'not four, not five' );
};

subtest 'the phase is not part of the site name' => sub {
    # "probe cloudient.net, repair cloudient.net, repair cloudient.net" is a
    # label leaking through, three times. The site is the last word.
    my $warn = '[ warn ] static requests are answered WITHOUT the engine';
    my $out  = grouped( "probe a.test\t$warn", "repair b.test\t$warn", "c.test\t$warn" );
    like( $out, qr/sites: a\.test, b\.test, c\.test/,
        'sites are named bare, in order, once each' )
        or diag("got:\n$out");
    unlike( $out, qr/sites: .*(probe|repair) /, 'no phase word in a site list' );
};

subtest 'each sites: line sits under its own finding' => sub {
    # Every "sites:" line used to print in a block after every "[N]" line - the
    # old pipeline sorted the output, and the two halves of each record sorted
    # apart. A list nobody can pair with its message is not a list.
    my $out = grouped(
        "b.test\t[ warn ] zebra condition",
        "a.test\t[ warn ] apple condition",
        "c.test\t[ warn ] apple condition",
    );
    my @l = split /\n/, $out;
    is( scalar @l, 4, 'two records, two lines each' ) or diag("got:\n$out");
    like( $l[0], qr/^\s*\[2\] \[ warn \] apple condition/, 'record 1: the finding' );
    like( $l[1], qr/^\s*sites: a\.test, c\.test$/,          'record 1: ITS sites, next line' );
    like( $l[2], qr/^\s*\[1\] \[ warn \] zebra condition/, 'record 2: the finding' );
    like( $l[3], qr/^\s*sites: b\.test$/,                   'record 2: its site' );
};

# --- and the last raw loop goes through run_quiet ----------------------------
subtest 'the ACL re-apply loop reports through run_quiet' => sub {
    # The one per-site phase still printing raw on the 0.14.3 rollout, and
    # most of its transcript. A source check, like the run_quiet assertions
    # above: the loop needs a Hestia host to run.
    like( $src, qr/run_quiet "\$d" sudo -u "\$u" perl "\$ACLTOOL" reapply/,
        'the reapply call is wrapped' )
        or diag( '21 x "No protected sections", every per-site summary, the '
            . '[INFO] log lines and the @group advisory six times over came '
            . 'from this loop.' );
};

done_testing();
