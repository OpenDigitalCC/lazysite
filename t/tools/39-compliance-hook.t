#!/usr/bin/perl
# The release compliance hook must FAIL when a record is behind the version.
#
# WHY. The 2026-08-14 eight-dimension review found that every mechanised control
# in this project had held and every hand-maintained compliance record had gone
# stale within six weeks - the Declaration of Conformity three stable releases
# behind, the significant-change register stale over its own triggers, the
# feature timeline eight releases back, the rehearsal cadence lapsed for four
# stable cycles. tools/lazysite-compliance.pl exists to make that a build
# failure instead of a review finding.
#
# A currency gate that cannot fail is worse than no gate, because it reports
# green over a stale record - so the cases below drive it against records that
# ARE stale and require it to block, then against current ones and require it
# not to. The tool ships blocking on the real tree today (D8 F8.1 and D5 F5.1
# are both real), which is why the passing case is built rather than taken from
# the repository.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $tool = "$root/tools/lazysite-compliance.pl";
ok( -f $tool, 'the compliance hook is present' ) or do { done_testing; exit };

# Build a minimal tree in the shape the tool reads. Small on purpose: the point
# is the tool's DECISION, and a full copy of the repo would make it impossible
# to say which input produced which verdict.
sub build_tree {
    my (%o) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/docs/compliance", "$d/dist/config", "$d/tools" );
    copy( $tool, "$d/tools/lazysite-compliance.pl" ) or die "copy: $!";

    my $v = $o{version} // '1.2.3';
    spit( "$d/VERSION", "$v\n" );
    spit( "$d/docs/compliance/OBLIGATIONS.md",
        "reviewed_at_version: " . ( $o{obligations} // $v ) . "\n" );
    spit( "$d/docs/compliance/TECHNICAL-FILE.md",
        "covers_version: " . ( $o{technical} // $v ) . "\n" );
    spit( "$d/docs/DECLARATION-OF-CONFORMITY.md",
        "Version | " . ( $o{doc} // $v ) . "\n"
            . ( $o{doc_signed} ? "Signature | signed\n" : "Signature | (unsigned draft)\n" ) );
    spit( "$d/docs/SECURITY.md",
        "## Significant-change assessments\n\n### 2026-08-13 - covers $v\n" );
    # A STABLE heading, because the rehearsal rule is measured against the last
    # stable cut rather than a fixed window. Dated far back by default so an
    # ordinary fixture has a current rehearsal.
    spit( "$d/CHANGELOG.md",
        "## $v - STABLE: a release (" . ( $o{stable_date} // '2020-01-01' ) . ")\n" );
    spit( "$d/docs/FEATURES.md", "the timeline reaches $v\n" );
    spit( "$d/dist/config/bench-baseline.json",
        qq({ "captured_at" : "2026-08-14T00:00:00Z" }\n) );
    spit( "$d/docs/RELIABILITY.md",
        " " . ( $o{rehearsal} // _recent() ) . " | rehearsal | <1 s | ok\n" );
    return $d;
}

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

sub _recent {
    my @g = gmtime( time - 3 * 86_400 );
    return sprintf '%04d-%02d-%02d', $g[5] + 1900, $g[4] + 1, $g[3];
}

# TestHelper::run_cmd returns output only; this gate's whole contract is its
# EXIT CODE, so capture both here rather than reading the global $? and hoping
# nothing touched it in between.
sub run_hook {
    my ( $dir, @args ) = @_;
    my @argv = ( $^X, "$dir/tools/lazysite-compliance.pl", @args );
    my $pid  = open my $ph, '-|';
    die "cannot fork: $!" unless defined $pid;
    if ( !$pid ) {
        open STDERR, '>&', \*STDOUT or exit 127;
        exec @argv;
        exit 127;
    }
    my $out = do { local $/; <$ph> };
    close $ph;
    return { out => ( $out // '' ), rc => $? >> 8 };
}

subtest 'current records on edge: passes' => sub {
    my $d = build_tree();
    my $r = run_hook( $d, '--check', '--channel', 'edge' );
    is( $r->{rc}, 0, 'exits 0' ) or diag( $r->{out} );
    like( $r->{out}, qr/0 blocking/, 'and reports nothing blocking' );
};

subtest 'a register behind the version blocks on ANY channel' => sub {
    # The core case. This is not a stable-only concern: if the obligations
    # register was last walked two releases ago, nobody has considered this
    # release's obligations at all.
    my $d = build_tree( version => '2.0.0', obligations => '1.9.0' );
    my $r = run_hook( $d, '--check', '--channel', 'edge' );
    is( $r->{rc}, 1, 'exits non-zero' );
    like( $r->{out}, qr/FAIL.*obligations register/,
        'and names the register that is behind' );
    like( $r->{out}, qr/reviewed_at_version is 1\.9\.0, cutting 2\.0\.0/,
        'saying both versions, so the fix is obvious' );
};

subtest 'the technical file is checked the same way' => sub {
    my $d = build_tree( version => '2.0.0', technical => '1.0.0' );
    my $r = run_hook( $d, '--check', '--channel', 'edge' );
    is( $r->{rc}, 1, 'exits non-zero' );
    like( $r->{out}, qr/FAIL.*technical file/, 'and names it' );
};

subtest 'the declaration is advisory below certified and blocking there (ADR 0010)' => sub {
    # The distinction is deliberate, and it MOVED (ADR 0010, 2026-08-20): the
    # Declaration of Conformity attaches to a CERTIFIED release. Stable means
    # supported software; certification is the act of walking the records - so
    # neither an edge nor a stable cut is blocked by the declaration, and a
    # certified cut is. (Before the move it blocked stable, and three stable
    # releases had shipped against a stale declaration anyway - a gate placed
    # where nobody could honour it.)
    my $d = build_tree( version => '2.0.0', doc => '1.0.0' );

    my $edge = run_hook( $d, '--check', '--channel', 'edge' );
    is( $edge->{rc}, 0, 'edge: not blocked' );
    like( $edge->{out}, qr/WARN.*declaration of conformity/,
        'edge: but warned, naming a certified cut as where it bites' );

    my $stable = run_hook( $d, '--check', '--channel', 'stable' );
    is( $stable->{rc}, 0, 'stable: NOT blocked - the gate moved up (ADR 0010)' );

    my $cert = run_hook( $d, '--check', '--channel', 'certified' );
    is( $cert->{rc}, 1, 'certified: blocked' );
    like( $cert->{out}, qr/FAIL.*declaration of conformity/, 'certified: named' );
};

subtest 'an unsigned declaration blocks a certified cut' => sub {
    my $d = build_tree( version => '2.0.0', doc => '2.0.0' );
    my $r = run_hook( $d, '--check', '--channel', 'certified' );
    is( $r->{rc}, 1, 'a current-but-unsigned declaration still blocks' );
    like( $r->{out}, qr/FAIL.*unsigned/, 'and says so' );

    my $signed = build_tree( version => '2.0.0', doc => '2.0.0', doc_signed => 1 );
    my $ok     = run_hook( $signed, '--check', '--channel', 'certified' );
    like( $ok->{out}, qr/ok\s+declaration of conformity current and signed/,
        'the control: signed and current passes' );
};

subtest 'a lapsed rehearsal blocks a certified cut, and no longer a stable one' => sub {
    my $d = build_tree( version => '2.0.0', doc => '2.0.0', doc_signed => 1,
        rehearsal => '2020-01-01', stable_date => '2021-01-01' );
    my $st = run_hook( $d, '--check', '--channel', 'stable' );
    is( $st->{rc}, 0, 'stable: not blocked (ADR 0010 moved this gate too)' );
    my $r = run_hook( $d, '--check', '--channel', 'certified' );
    is( $r->{rc}, 1, 'certified: blocked' );
    like( $r->{out}, qr/FAIL.*restore rehearsal/,
        'naming the rehearsal, because RELIABILITY.md commits to one per '
            . 'stable cycle and that commitment lapsed for four of them' );
    like( $r->{out}, qr/older than the last stable cut \(2021-01-01\)/,
        'and says WHICH stable cut it is behind - the rule is per cycle, not '
            . 'a fixed number of days' );
};

subtest 'report mode never blocks' => sub {
    # So the state can be inspected at any time without gating anything.
    my $d = build_tree( version => '2.0.0', obligations => '1.0.0' );
    my $r = run_hook( $d, '--report' );
    is( $r->{rc}, 0, 'exits 0 even with a blocking finding' );
    like( $r->{out}, qr/FAIL/, 'while still reporting it' );
};

done_testing();
