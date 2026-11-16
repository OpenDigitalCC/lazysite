#!/usr/bin/perl
# SM1454 R1: A PATCH GATES ON ITS DIFF.
#
# 0.17.1 is one line in the auth wrapper; its gate spent 35 minutes in a full suite on
# a tree that differs from the passed 0.17.0 by that line. `release.sh gate --final
# --patch` (and tools/gate-main.sh --patch) runs every lint, bench --check and the
# tests the precheck selects for the diff from the line's last release, whose own gate
# receipt must say pass; it runs the whole suite instead, and says why in one line,
# when the change is to what judges the others or to a file nobody mapped to tests.
# The receipt says which. Build takes a patch receipt for a stable cut whose base is
# the receipt's.
#
# Driven through the REAL release.sh, patch-plan.pl, precheck-select.sh and
# precheck-areas.pl in a scratch repository (t/lib/ReleaseRig.pm); every stub test
# logs its label to STUB_RUN_LOG, so the test says what ran.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);
use ReleaseRig qw(spit slurp git commit logger rig_repo rig_release rig_receipt rig_base_receipt rig_notes rig_tags rig_runs);

plan skip_all => 'setsid missing' unless grep { -x "$_/setsid" } split /:/, $ENV{PATH};

my $root   = repo_root();
my $LOGDIR = tempdir( CLEANUP => 1 );
my $LOG    = "$LOGDIR/runs";
sub ran     { return rig_runs($LOG) }
sub receipt { slurp("$_[0]/tmp/release-gate/0.1.1/receipt") }

# A repository whose first release (v0.1.0) carries the plan's own tools and one
# test of each kind, and whose main differs from it by %$change.
sub patch_repo {
    my ($change) = @_;
    my $d = rig_repo(
        tools => [qw(patch-plan.pl precheck-select.sh precheck-areas.pl)],
        base  => {
            'lib/Lazysite/Foo.pm'     => "package Lazysite::Foo; 1;\n",
            't/unit/lib/10-foo.t'     => logger('area'),
            't/unit/other/20-other.t' => logger('other'),
            't/lint/00-a-lint.t'      => logger('lint'),
            't/lib/Helper.pm'         => "package Helper; 1;\n",
            'Makefile'                => "all:\n",
            'tools/gate-main.sh'      => "#!/bin/bash\n",
            't/lint/helper.pl'        => "1;\n",
            'docs/a.md'               => "a\n",
        },
        change => $change,
    );
    rig_base_receipt($d);
    return $d;
}

sub patch_gate {
    my ( $d, @a ) = @_;
    unlink $LOG;
    return rig_release( $d, { STUB_RUN_LOG => $LOG }, 'gate', '0.1.1', '--final', '--patch', '--commit', git( $d, 'rev-parse', 'main' ), @a );
}

subtest 'a patch runs every lint and the selection for its diff, and nothing else' => sub {
    my $d = patch_repo( { 'lib/Lazysite/Foo.pm' => "package Lazysite::Foo; 2;\n", 'docs/a.md' => "a changed\n" } );
    my ( $rc, $out ) = patch_gate($d);
    is( $rc, 0, 'the patch gate passes' ) or return diag($out);
    like( $out, qr/^==> --patch: every lint and 1 selected tests \(2 files since v0\.1\.0\)$/m, 'saying what it runs' );
    my %ran = map { $_ => 1 } @{ ran() };
    ok( $ran{lint},   'the lints ran' );
    ok( $ran{area},   'the test of the changed file\'s area ran' );
    ok( !$ran{other}, 'a test of another area did not' );
    ok( !$ran{suite}, 'nor did the suite (t/unit/00-...)' );
    my $r = receipt($d);
    like( $r, qr/^suite=patch \(base v0\.1\.0, 2 files\)$/m, 'the receipt says suite=patch, the base and the file count' );
    like( $r, qr/^suite_base=v0\.1\.0$/m, 'and names the base' );
    like( $r, qr/^result=pass$/m,         'passed' );
    like( slurp("$d/tmp/release-gate/0.1.1/suite-selection.txt"), qr{^t/unit/lib/10-foo\.t$}m, 'and keeps the selection beside it' );
    like( slurp("$d/tmp/release-gate/0.1.1/suite.txt"), qr/Files=\d+, Tests=\d+/, 'prove\'s summary is the gate\'s count' );

    # A recorded patch pass is not run again either (R2), under the patch's own key.
    ( $rc, $out ) = patch_gate($d);
    is( $rc, 0, 'the same patch again passes' ) or diag($out);
    like( $out, qr/already passed.*not run again/, 'from the record' );
    is_deeply( ran(), [], 'with nothing run' );

    # The same tree gated in full is another key: a patch pass is not a full one.
    unlink $LOG;
    ( $rc, $out ) = rig_release( $d, { STUB_RUN_LOG => $LOG }, 'gate', '0.1.1', '--final', '--commit', git( $d, 'rev-parse', 'main' ) );
    is( $rc, 0, 'a full gate of it passes' ) or diag($out);
    ok( ( grep { $_ eq 'suite' } @{ ran() } ), 'and runs the suite' );
    like( receipt($d), qr/^suite=full$/m, 'saying suite=full' );
    unlike( receipt($d), qr/^suite_base=/m, 'with no base' );
};

# Each change that makes the gate run the whole suite, and the reason it names.
my @FULL = (
    [ 't/lib/Helper.pm' => "package Helper; 2;\n", qr/the test harness \(t\/lib\/\) changed: t\/lib\/Helper\.pm/ ],
    [ 't/lint/helper.pl' => "2;\n", qr/a lint's own library changed: t\/lint\/helper\.pl/ ],
    [ 'tools/release.sh' => undef, qr/the release and precheck tools changed: tools\/release\.sh/ ],
    [ 'tools/gate-main.sh' => "#!/bin/bash\n# x\n", qr/the release and precheck tools changed: tools\/gate-main\.sh/ ],
    [ 'tools/precheck-select.sh' => undef, qr/the release and precheck tools changed: tools\/precheck-select\.sh/ ],
    [ 'tools/precheck-areas.pl' => undef, qr/the release and precheck tools changed: tools\/precheck-areas\.pl/ ],
    [ 'tools/patch-plan.pl' => undef, qr/the release and precheck tools changed: tools\/patch-plan\.pl/ ],
    [ 'Makefile' => "all:\n\ttrue\n", qr/the build control files changed: Makefile/ ],
    [ 'cpanfile' => "requires 'JSON::PP';\n", qr/the build control files changed: cpanfile/ ],
    [ 'dist/config/sbom-deps.json' => "{ }\n", qr/the build control files changed: dist\/config\/sbom-deps\.json/ ],
    [ 'weird/thing.txt' => "x\n", qr/not covered by the precheck's area map: weird\/thing\.txt/ ],
);

subtest 'each trigger makes it the whole suite, and says why' => sub {
    my $d = patch_repo( {} );
    for my $case (@FULL) {
        my ( $file, $text, $why ) = @$case;
        $text //= slurp("$d/$file") . "\n# changed\n";
        git( $d, 'checkout', '-q', '-B', 'trigger', 'v0.1.0' );
        # main's own SM2 change (release material), then the trigger.
        spit( "$d/CHANGELOG.md", "## Unreleased\n\n- SM2 (PENDING) **two.**\n\n## 0.1.0 - EDGE: one (2026-01-01)\n\n- SM1 (abcdef12) **one.**\n" );
        spit( "$d/$file", $text );
        my $sha = commit( $d, "trigger $file" );
        git( $d, 'checkout', '-q', 'main' );
        unlink $LOG;
        my ( $rc, $out ) = rig_release( $d, { STUB_RUN_LOG => $LOG }, 'gate', '0.1.1', '--final', '--patch', '--commit', $sha );
        is( $rc, 0, "$file: the gate passes" ) or diag($out);
        my @said = grep { /^==> --patch: the full suite - / } split /\n/, $out;
        is( scalar @said, 1, "$file: one line says it is the whole suite" );
        like( $said[0] // '', $why, "$file: and why" );
        my %ran = map { $_ => 1 } @{ ran() };
        ok( $ran{suite} && $ran{other}, "$file: the whole suite ran" );
        my $r = receipt($d);
        like( $r, qr/^suite=full \(--patch: .*\)$/m, "$file: the receipt says why it is full" );
        unlike( $r, qr/^suite_base=/m, "$file: and names no patch base" );
    }
};

subtest 'a changed document, the changelog and download/ are not a reason' => sub {
    my $d = patch_repo( { 'docs/a.md' => "more\n", 'docs/feature-requests/SM9-x.md' => "x\n", 'download/lazysite-0.1.0.tar.gz' => "newer\n" } );
    my ( $rc, $out ) = patch_gate($d);
    is( $rc, 0, 'the gate passes' ) or return diag($out);
    unlike( $out, qr/--patch: the full suite/, 'it is not the whole suite' );
    like( receipt($d), qr/^suite=patch \(base v0\.1\.0, 1 files\)$/m, 'only the document counts: the filing and download/ are release material' );
    ok( !( grep { $_ eq 'suite' } @{ ran() } ), 'no suite ran' );
};

subtest '--patch is refused unless the base passed, and off stable' => sub {
    my $d    = patch_repo( { 'docs/a.md' => "more\n" } );
    my $main = git( $d, 'rev-parse', 'main' );

    for my $ch ( ['edge'], [ 'beta', '--beta' ], [ 'certified', '--certified' ] ) {
        my ( $name, @flag ) = @$ch;
        my ( $rc, $out ) = rig_release( $d, {}, 'gate', '0.1.1', @flag, '--patch', '--commit', $main );
        is( $rc, 2, "$name: refused" );
        like( $out, qr/^release\.sh: --patch is for a stable gate \(--final\); the \Q$name\E channel runs the whole suite\.$/m, "$name: in one line" );
    }

    unlink "$d/tmp/release-gate/0.1.0/receipt";
    my ( $rc, $out ) = rig_release( $d, {}, 'gate', '0.1.1', '--final', '--patch', '--commit', $main );
    is( $rc, 2, 'no base receipt: refused' );
    like( $out, qr/whose gate receipt is missing:\nrelease\.sh:   \Q$d\E\/tmp\/release-gate\/0\.1\.0\/receipt/, 'naming what is missing' );
    ok( !-e "$d/tmp/release-gate/0.1.1/receipt", 'no receipt was written' );

    rig_base_receipt( $d, result => 'fail' );
    ( $rc, $out ) = rig_release( $d, {}, 'gate', '0.1.1', '--final', '--patch', '--commit', $main );
    is( $rc, 2, 'a base receipt that says fail: refused' );
    like( $out, qr/does not say pass\nrelease\.sh:   \(\Q$d\E\/tmp\/release-gate\/0\.1\.0\/receipt: result=fail\)/, 'naming it and what it says' );

    git( $d, 'tag', '-d', 'v0.1.0' );
    ( $rc, $out ) = rig_release( $d, {}, 'gate', '0.1.1', '--final', '--patch', '--commit', $main );
    is( $rc, 2, 'no earlier release of the line: refused' );
    like( $out, qr/needs an earlier release of the 0\.1 line to gate against; there is none below v0\.1\.1/, 'saying so' );

    ( $rc, $out ) = rig_release( $d, {}, 'build', '0.1.1', '--notes', rig_notes(), '--patch' );
    is( $rc, 2, 'build takes no --patch' );
    like( $out, qr/--patch is a gate option/, 'saying so' );
};

subtest 'tools/gate-main.sh --patch is refused off stable, before it does anything' => sub {
    my $out = run_cmd( 'bash', "$root/tools/gate-main.sh", '--version', '9.9.9', '--patch' );
    is( $? >> 8, 2, 'an edge gate-main --patch is refused' );
    is( $out, "gate-main: --patch is for a stable gate (--final); the edge channel runs the whole suite.\n", 'in one line' );
};

subtest 'gate-main: a patch receipt serves a --patch gate, not a full one' => sub {
    my $d = patch_repo( { 'docs/a.md' => "more\n" } );
    copy_gate_main($d);
    my $sha = rig_receipt( $d, version => '0.1.1', channel => 'stable', suite => 'patch (base v0.1.0, 1 files)', suite_base => 'v0.1.0' );
    my $run = sub {
        my (@a) = @_;
        my $o = run_cmd( 'bash', "$d/tools/gate-main.sh", '--version', '0.1.1', '--final', '--ref', $sha, @a );
        return ( $? >> 8, $o );
    };
    my ( $rc, $out ) = $run->('--patch');
    is( $rc, 0, 'asked for --patch: already gated' ) or diag($out);
    like( $out, qr/already gated - not running it again/, 'says so' );
    ( $rc, $out ) = $run->();
    unlike( $out, qr/already gated/, 'asked for the whole suite: not already gated' );
    like( $out, qr/heavy-lock\.sh/, 'it goes on to gate (and stops here, in a scratch tree with no heavy lock)' );

    rig_receipt( $d, version => '0.1.1', channel => 'stable', suite => 'full' );
    ( $rc, $out ) = $run->();
    is( $rc, 0, 'a full receipt serves a full gate' ) or diag($out);
    ( $rc, $out ) = $run->('--patch');
    is( $rc, 0, 'and a patch one' ) or diag($out);
};

sub copy_gate_main {
    my ($d) = @_;
    require File::Copy;
    File::Copy::copy( "$root/tools/gate-main.sh", "$d/tools/gate-main.sh" ) or die $!;
}

subtest 'build accepts a patch receipt for a stable whose base is the receipt\'s' => sub {
    my $d = patch_repo( { 'docs/a.md' => "more\n" } );
    my ( $rc, $out ) = patch_gate($d);
    is( $rc, 0, 'the patch gate passes' ) or return diag($out);
    ( $rc, $out ) = rig_release( $d, {}, 'build', '0.1.1', '--notes', rig_notes(), '--final' );
    is( $rc, 0, 'the stable build accepts the patch receipt' ) or return diag($out);
    like( $out, qr/^==>   suite: patch \(base v0\.1\.0, 1 files\) \(this gate\)$/m, 'and says what the gate ran' );
    is( git( $d, 'rev-parse', 'main^' ), git( $d, 'rev-parse', 'v0.1.1^{commit}' ), 'main is the release commit plus the stable download commit' );

   # A newer release of the line since the gate: the diff the gate read is not this cut's.
    my $e = patch_repo( { 'docs/a.md' => "more\n" } );
    rig_receipt( $e, channel => 'stable', suite => 'patch (base v0.0.9, 1 files)', suite_base => 'v0.0.9' );
    ( $rc, $out ) = rig_release( $e, {}, 'build', '0.1.1', '--notes', rig_notes(), '--final' );
    is( $rc, 1, 'a patch receipt against another base is refused' );
    like( $out, qr/a patch gate against v0\.0\.9 .*this build's base is v0\.1\.0 on channel stable\. Gate again/s, 'naming both bases' );
    is( rig_tags($e), '', 'nothing is tagged' );
};

done_testing();
