#!/usr/bin/perl
# SM400: nothing durable recorded WHICH COMMIT a release had been validated at.
#
# The gate's own summary - files, tests, result - went to the terminal and to
# tmp/gate-result.txt, which is gitignored. So a promotion review three days
# later could establish which VERSION was being proposed and not which COMMIT
# had been gated, and had to reconstruct it from commit dates. Its conclusion -
# "the build that would go to beta is not the build that was validated" - was
# reasonable, and nothing cheap could disprove it.
#
# Two records now, answering the same question to two different readers:
#   the ARTEFACT attests its own gate, in release-manifest.json under `validated`
#   the REPO carries docs/releases/GATE-LOG.md, for whoever has the repo and not
#     the tarball, which is who asks later
#
# THE SHARPEST ASSERTION HERE IS THE PIPE. Capturing prove's output means piping
# it through tee, and `if ! ( ... | tee f )` tests TEE's exit status - tee
# succeeds whatever prove did. That would make the release gate itself a control
# that reports success without checking, which is the exact defect class this
# repo keeps finding. It is asserted below against a failing stand-in.
use strict;
use warnings;
use Test::More;
use File::Temp     qw(tempdir);
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use JSON::PP       qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root     = repo_root();
my $manifest = "$root/tools/build-manifest.pl";
my $release  = "$root/tools/release.sh";
plan skip_all => 'tools missing' unless -f $manifest && -f $release;

my $rel_src = do { open my $fh, '<', $release or die $!; local $/; <$fh> };

# ---------------------------------------------------------------------
# 1. The artefact attests its own gate
# ---------------------------------------------------------------------
sub write_file {
    my ( $path, $c ) = @_;
    make_path( dirname($path) ) unless -d dirname($path);
    open my $fh, '>', $path or die $!;
    print {$fh} $c;
    close $fh;
}

sub build {
    my (@extra) = @_;
    my $dir = tempdir( 'lazysite-gaterec-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    write_file( "$dir/bin/foo.pl", "script\n" );
    write_file(
        "$dir-cfg/classification.json",
        encode_json(
            { schema_version => "1",
                rules => [
                    { pattern => "^bin/(.+)\\.pl\$",
                        install_to => "{CGIBIN}/\$1.pl", bucket => "code" },
                ],
                exclude       => [],
                runtime_paths => [],
            }
        )
    );
    my @cmd = (
        $^X,         $manifest,
        '--staged',  $dir,
        '--config',  "$dir-cfg/classification.json",
        '--version', '1.2.3',
        '--out',     "$dir/release-manifest.json",
        @extra,
    );
    my $cmd = join( ' ', map { quotemeta } @cmd ) . ' 2>&1';
    my $out = qx($cmd);
    my $rc  = $? >> 8;
    my $m;
    if ( -f "$dir/release-manifest.json" ) {
        open my $fh, '<', "$dir/release-manifest.json" or die $!;
        $m = decode_json( do { local $/; <$fh> } );
        close $fh;
    }
    return ( $rc, $m, $out );
}

{
    my ( $rc, $m, $out ) = build();
    is( $rc, 0, 'a manifest builds without the gate facts' ) or diag $out;
    ok( !exists $m->{validated},
        'and carries NO validated block - a hand-built manifest attests nothing' );
}

{
    my ( $rc, $m, $out ) = build(
        '--commit',     'a' x 40,
        '--gate-files', '455',
        '--gate-tests', '8266',
    );
    is( $rc, 0, 'a manifest builds with them' ) or diag $out;
    ok( $m->{validated}, 'and carries a validated block' );
    is( $m->{validated}{commit}, 'a' x 40, 'naming the exact commit gated' );
    is( $m->{validated}{files},  455,      'with the file count' );
    is( $m->{validated}{tests},  8266,     'and the test count' );

    # Numbers, not strings - a reader comparing two builds should not have to
    # think about "8266" versus 8266.
    like( encode_json( $m->{validated} ), qr/"files":455/, 'counts are numeric in the JSON' );

    ok( !exists $m->{validated}{result},
        'and no result field - release.sh exits before this on failure, so it '
            . 'could only ever say PASS, which is a field that reads as evidence '
            . 'while carrying none' );
}

# Partial facts must not produce a half-attestation.
for my $missing (
    [ 'no commit' => [ '--gate-files', '1', '--gate-tests', '2' ] ],
    [ 'no counts' => [ '--commit',     'b' x 40 ] ],
    )
{
    my ( $label, $args ) = @$missing;
    my ( $rc,    $m )    = build(@$args);
    ok( !exists $m->{validated}, "$label produces no validated block at all" );
}

# ---------------------------------------------------------------------
# 2. release.sh wires it, and its pipe does not swallow a failure
# ---------------------------------------------------------------------
like( $rel_src, qr/--commit\s+"\$TARGET_SHA"/,
    'release.sh passes the commit it actually checked out' );
like( $rel_src, qr/--gate-files\s+"\$GATE_FILES"/, 'and the file count' );
like( $rel_src, qr/--gate-tests\s+"\$GATE_TESTS"/, 'and the test count' );
like( $rel_src, qr/GATE-LOG\.md/,                  'and appends the tracked log' );
like( $rel_src, qr/UNCOMMITTED:/,                  'and says the log needs committing' );

# It must REFUSE rather than record a release whose gate summary it could not
# read - a blank row is worse than no row, because it looks like a record.
like( $rel_src, qr/refusing to record a release as validated without it/,
    'an unreadable gate summary stops the release' );

# The pipe. Two stand-ins for prove: one that fails, one that succeeds, both
# piped through tee exactly as release.sh does it.
sub pipeline_status {
    my ($exit) = @_;
    my $d = tempdir( 'lazysite-pipe-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    write_file( "$d/fake-prove", "#!/bin/bash\necho 'Files=1, Tests=2, 0 wallclock secs'\nexit $exit\n" );
    chmod 0755, "$d/fake-prove";

    # The construct under test, lifted verbatim in shape from release.sh.
    write_file( "$d/run.sh", <<"RUN" );
set -e
if ! ( cd "$d" && set -o pipefail && ./fake-prove 2>&1 | tee "$d/out.txt" ); then
    echo REFUSED
    exit 0
fi
echo PROCEEDED
RUN
    my $out = qx(bash \Q$d/run.sh\E 2>&1);
    chomp $out;
    return ( split /\n/, $out )[-1] // '';
}

is( pipeline_status(1), 'REFUSED',
    'a failing gate is REFUSED - tee does not swallow prove exit 1' );
is( pipeline_status(0), 'PROCEEDED', 'and a passing gate proceeds' );

# The control: without pipefail the same construct reports success. If this
# stops being true the assertion above proves nothing.
{
    my $d = tempdir( 'lazysite-pipe2-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    write_file( "$d/fake-prove", "#!/bin/bash\nexit 1\n" );
    chmod 0755, "$d/fake-prove";
    write_file( "$d/run.sh", <<"RUN" );
set -e
if ! ( cd "$d" && ./fake-prove 2>&1 | tee "$d/out.txt" ); then
    echo REFUSED
    exit 0
fi
echo PROCEEDED
RUN
    my $out = qx(bash \Q$d/run.sh\E 2>&1);
    chomp $out;
    is( ( split /\n/, $out )[-1], 'PROCEEDED',
        'CONTROL: without pipefail the same pipe reports success on a failed gate' );
}

# The summary parse, against prove's real wording.
{
    my $d = tempdir( 'lazysite-parse-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    write_file( "$d/out.txt", <<'OUT' );
t/unit/users/24-ceiling-all-verbs.t .............................. ok
All tests successful.
Files=456, Tests=8266, 152 wallclock secs ( 1.88 usr  0.61 sys + 417.56 cusr 53.35 csys = 473.40 CPU)
Result: PASS
OUT
    my $f = qx(sed -n 's/^Files=\\([0-9]*\\),.*/\\1/p' \Q$d/out.txt\E | tail -1);
    my $t = qx(sed -n 's/^Files=[0-9]*, Tests=\\([0-9]*\\),.*/\\1/p' \Q$d/out.txt\E | tail -1);
    chomp( $f, $t );
    is( $f, '456',  'the file count is read from prove own summary line' );
    is( $t, '8266', 'and the test count' );
}

done_testing();
