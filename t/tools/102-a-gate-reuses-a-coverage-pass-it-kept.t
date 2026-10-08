#!/usr/bin/perl
# SM950 (3): A GATE REUSES A COVERAGE PASS AN EARLIER GATE KEPT, AND SAYS SO.
#
# coverage.sh skips when its inputs digest matches a recorded pass (SM736), but
# the only record it read was the one committed at the last release, so every
# gate between releases measured again - 74 minutes on 0.15.2 - however little
# had changed. release.sh now keeps every passing run under
# tmp/release-gate/coverage-passes/DIGEST.json, stamped with the commit that
# measured it, and offers coverage.sh a COPY of the one for its own digest.
# coverage.sh still decides, and the receipt says measured or reused, and from
# which run.
#
# Driven here: release.sh's coverage block and its three helpers, lifted from
# the script and run in a scratch origin and stage - the REAL coverage.sh in
# decide-only mode where a skip is asserted, a stand-in where a measurement is.
# Nothing is instrumented and the repository is not touched.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root    = repo_root();
my $release = "$root/tools/release.sh";
my $src     = do { open my $fh, '<', $release or die $!; local $/; <$fh> };

my ($store_line) = $src =~ /^(COV_STORE=.*)$/m;
my ($offer)      = $src =~ /^(coverage_offer\(\) \{\n.*?\n\})\n/ms;
my ($origin)     = $src =~ /^(coverage_origin\(\) \{\n.*?\n\})\n/ms;
my ($store)      = $src =~ /^(coverage_store\(\) \{\n.*?\n\})\n/ms;
my ($detached)   = $src =~ /^(detached\(\) \{.*\})$/m;
my ($block)      = $src =~ /^(COV_DIGEST=\$\(perl .*?\n)\nfi    # gate$/ms;
ok( $_->[1], "release.sh has $_->[0]" ) or BAIL_OUT('nothing to drive')
    for [ 'the store path', $store_line ], [ 'coverage_offer()', $offer ], [ 'coverage_origin()', $origin ],
    [ 'coverage_store()', $store ], [ 'detached()', $detached ], [ 'the coverage block', $block ];

sub spit {
    my ( $p, $t ) = @_;
    ( my $d = $p ) =~ s{/[^/]+$}{};
    make_path($d);
    open my $f, '>', $p or die "$p: $!";
    print {$f} $t;
    close $f;
}
sub slurp { open my $f, '<', $_[0] or return; local $/; my $t = <$f>; close $f; $t }

my $MEASURING = <<'SH';
#!/bin/sh
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$(perl "$ROOT/tools/coverage-inputs.pl" | awk '{print $1}')
OUT="${LAZYSITE_COVER_RECORD:-$ROOT/dist/config/coverage-last.json}"
mkdir -p "$(dirname "$OUT")"
printf '{"inputs_digest":"%s","result":"pass","captured":"2026-10-07T00:00:00Z"}\n' "$D" > "$OUT"
echo "coverage: all measured production CGIs at or above 75%"
SH

# One gate's coverage step: a fresh stage under ORIGIN, the given coverage.sh,
# a digest, and optionally a record committed in the stage.
sub gate {
    my (%o) = @_;
    my $stage = "$o{origin}/stage-$o{sha}";
    spit( "$stage/tools/coverage-inputs.pl", qq{print "$o{digest} 9\\n";\n} );
    if ( $o{real} ) { copy( "$root/tools/coverage.sh", "$stage/tools/coverage.sh" ) or die $! }
    else            { spit( "$stage/tools/coverage.sh", $MEASURING ) }
    spit( "$stage/dist/config/coverage-last.json", $o{committed} ) if $o{committed};
    my $mode = $o{mode} // 'gate';
    spit( "$o{origin}/run.sh", <<"RUN" );
set -e
ORIGIN="$o{origin}"
STATE_ROOT="$o{origin}"    # Q14b: an ordinary checkout is its own state root
STAGE="$stage"
MODE=$mode
TARGET_SHA=$o{sha}
VERSION=9.9.9
RECEIPT_DIR="$o{origin}/tmp/release-gate/9.9.9"
COV_LOG="\${STAGE}-coverage-check.txt"
export LAZYSITE_COVER_DECIDE_ONLY=1
unset LAZYSITE_COVER_RECORD LAZYSITE_COVER_FORCE PERL5OPT HARNESS_PERL_SWITCHES
mkdir -p "\$RECEIPT_DIR"
stage_disposition() { echo "stage kept" >&2; }
$store_line
$detached
$offer
$origin
$store
$block
echo "RESULT coverage=\$COV_MODE"
echo "RESULT coverage_from=\$COV_FROM"
RUN
    my $out = run_cmd( "bash", "$o{origin}/run.sh" );
    return ( $out, $stage );
}

sub stored {
    my ( $o, $d ) = @_;
    my $t = slurp("$o/tmp/release-gate/coverage-passes/$d.json") or return;
    return decode_json($t);
}

my $D = 'd' x 64;
my $E = 'e' x 64;

subtest 'a measured pass is kept, stamped with the commit that measured it' => sub {
    my $o = tempdir( CLEANUP => 1 );
    my ($out) = gate( origin => $o, sha => 'aaa111', digest => $D );
    like( $out, qr/^RESULT coverage=measured$/m, 'the gate measured' ) or diag($out);
    like( $out, qr/no recorded pass/,            'and said there was nothing to reuse' );
    my $j = stored( $o, $D );
    ok( $j, 'the pass is in the store under its digest' ) or return;
    is( $j->{measured_at_sha},      'aaa111', 'stamped with the commit' );
    is( $j->{measured_for_version}, '9.9.9',  'and the version' );
    ok( -f "$o/tmp/release-gate/9.9.9/coverage-last.json", 'the receipt directory has the record' );
    ok( !-e "$o/dist/config/coverage-last.json", 'and a gate leaves the working tree alone' );
};

subtest 'the next gate with the same digest REUSES it, and names the run' => sub {
    my $o = tempdir( CLEANUP => 1 );
    gate( origin => $o, sha => 'aaa111', digest => $D );
    my $kept = slurp("$o/tmp/release-gate/coverage-passes/$D.json");
    my ( $out, $stage ) = gate( origin => $o, sha => 'bbb222', digest => $D, real => 1 );
    like( $out, qr/coverage: SKIPPED/, 'the real coverage.sh skipped on the offered record' ) or diag($out);
    like( $out, qr/^RESULT coverage=reused$/m, 'the gate says reused' );
    like( $out, qr/^RESULT coverage_from=sha=aaa111 version=9\.9\.9 /m,
        'and names the gate that measured it' );
    like( $out, qr/coverage REUSED, not re-measured: the pass at sha=aaa111/, 'in its output too' );
    is( slurp("$o/tmp/release-gate/coverage-passes/$D.json"), $kept, 'the store file is untouched' );
    ok( -f "$stage-coverage-offer.json", 'what was offered was a copy beside the stage' );
};

subtest 'a different digest is measured, never reused' => sub {
    my $o = tempdir( CLEANUP => 1 );
    gate( origin => $o, sha => 'aaa111', digest => $D );
    my ($out) = gate( origin => $o, sha => 'ccc333', digest => $E, real => 1 );
    unlike( $out, qr/coverage: SKIPPED/, 'coverage.sh was not offered the other pass' ) or diag($out);
    like( $out, qr/^RESULT coverage=measured$/m, 'the gate says measured' );
};

subtest 'a stale committed record is never kept under this gate\'s name' => sub {
    my $o = tempdir( CLEANUP => 1 );
    my ($out) = gate( origin => $o, sha => 'ddd444', digest => $E, real => 1,
        committed => qq({"inputs_digest":"$D","result":"pass"}) );
    ok( !stored( $o, $D ), 'the committed record (another digest) is not stored as this gate\'s' )
        or diag($out);
    ok( !stored( $o, $E ), 'and nothing is stored for a digest nobody measured' );
    like( $out, qr/not kept for reuse/, 'and the gate says so' );
};

subtest 'a stored FAILURE is offered and refused' => sub {
    my $o = tempdir( CLEANUP => 1 );
    spit( "$o/tmp/release-gate/coverage-passes/$D.json", qq({"inputs_digest":"$D","result":"fail"}) );
    my ($out) = gate( origin => $o, sha => 'eee555', digest => $D, real => 1 );
    unlike( $out, qr/coverage: SKIPPED/, 'coverage.sh does not skip on a failure' ) or diag($out);
    like( $out, qr/^RESULT coverage=measured$/m, 'the gate says measured' );
};

subtest 'SM971: there is no rehearsal, and the record goes into the release commit' => sub {
    # The gate writes the release material into its stage, so every commit is
    # gated for real; the rehearsal and its receipt are gone, not disused.
    my $out = run_cmd( 'bash', $release, 'gate', '0.0.1', '--rehearse' );
    is( $? >> 8, 2, '--rehearse is an unknown flag' );
    like( $out, qr/unknown flag '--rehearse'/, 'saying so' );
    unlike( $src, qr/REHEARSE|result=rehearsal|--run-gate/, 'nothing in release.sh rehearses or gates inline' );
    like( $src, qr/^    echo "result=pass"$/m,                  'a receipt says pass' );
    like( $src, qr/\[ "\$\(receipt_field result\)" != pass \]/, 'and build accepts pass only' );
    like( $src, qr/cp "\$RECEIPT_DIR\/coverage-last\.json" "\$STAGE\/dist\/config\/coverage-last\.json"/,
        'build commits the gate\'s coverage record into the release commit' );
};

subtest 'the receipt carries the coverage verdict' => sub {
    like( $src, qr/^    echo "coverage=\$COV_MODE"$/m,      'coverage=measured|reused' );
    like( $src, qr/^    echo "coverage_from=\$COV_FROM"$/m, 'and where it came from' );
    like( $src, qr/coverage: \$\(receipt_field coverage\)/, 'and build prints it from the receipt' );
};

done_testing();
