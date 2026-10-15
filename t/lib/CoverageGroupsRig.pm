package CoverageGroupsRig;
# SM1083 coverage in parts: a stub tree for driving tools/coverage-parts.sh and
# tools/coverage-groups.pl (t/tools/161-165). Two gated files in two groups,
# one test each, the group floor file, and a STUB coverage.sh that records what
# it was asked to run, writes the pass record it was told to, and fails when
# $STUB_FAIL names its group. Nothing is instrumented.
use strict;
use warnings;
use Exporter   qw(import);
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

our @EXPORT_OK = qw(rig parts groups digest spit slurp);

my $ROOT = repo_root();

sub spit {
    my ( $p, $t ) = @_;
    ( my $dir = $p ) =~ s{/[^/]+$}{};
    make_path($dir);
    open my $f, '>', $p or die "$p: $!";
    print {$f} $t;
    close $f;
    return;
}
sub slurp { open my $f, '<', $_[0] or return ''; local $/; my $t = <$f>; close $f; return $t }

my $STUB = <<'SH';
#!/bin/sh
echo "RAN ${LAZYSITE_COVER_GROUP:-whole} tests=$(tr '\n' ',' <"$LAZYSITE_COVER_TESTS") files=$(tr '\n' ',' <"$LAZYSITE_COVER_FILES") floor=$(grep -c . "$LAZYSITE_COVER_FLOOR_FILE") db=$(basename "$LAZYSITE_COVER_DB")" >>"$STUB_CALLS"
if [ "${STUB_FAIL:-}" = "$LAZYSITE_COVER_GROUP" ]; then echo "COVERAGE BELOW FLOOR" >&2; exit 1; fi
printf '{ "inputs_digest": "x", "result": "pass", "captured": "2026-10-15T00:00:00Z" }\n' >"$LAZYSITE_COVER_RECORD"
exit 0
SH

sub rig {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/tools");
    copy( "$ROOT/tools/$_", "$d/tools/$_" ) or die "$_: $!"
        for qw(coverage-groups.pl coverage-parts.sh precheck-areas.pl heavy-lock.sh preflight.sh);
    spit( "$d/tools/coverage.sh", $STUB );
    chmod 0755, "$d/tools/coverage.sh", "$d/tools/coverage-parts.sh";
    spit( "$d/lazysite-processor.pl",      "print 1;\n" );
    spit( "$d/lazysite-auth.pl",           "print 2;\n" );
    spit( "$d/t/unit/processor/01-a.t",    "ok 1;\n" );
    spit( "$d/t/unit/auth/01-b.t",         "ok 1;\n" );
    spit( "$d/dist/config/coverage-floor", "floor=75\nbranch_floor=62\n" );
    spit( "$d/dist/config/coverage-floor-groups", "[processor]\nstatus=pre-rebaseline\n[auth]\nbranch_floor[lazysite-auth.pl]=60\n" );
    return $d;
}

# The driver, as the gate runs it: lock and guard already held.
sub parts {
    my ( $d, @args ) = @_;
    local $ENV{STUB_CALLS}          = "$d/calls";
    local $ENV{LAZYSITE_HEAVY_HELD} = 1;
    my $o = run_cmd( 'bash', "$d/tools/coverage-parts.sh", '--store', "$d/store", @args );
    return ( $? >> 8, $o );
}

sub groups { my ( $d, @a ) = @_; my $o = run_cmd( $^X, "$d/tools/coverage-groups.pl", @a ); chomp $o; return $o }
sub digest { my ( $d, $g ) = @_; return ( groups( $d, '--digest', $g ) =~ /^([0-9a-f]{64})/ )[0] }

1;
