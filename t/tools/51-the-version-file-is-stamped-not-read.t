#!/usr/bin/perl
# SM375: the released tree's VERSION is the release, and it is written EARLY ENOUGH.
#
# VERSION sat at 0.10.9 while 0.10.10 through 0.10.14 were released. The remedy
# already existed - tools/bump-version.pl, written after a 2026 review found the
# same file "stuck at 0.2.18 while releases were at 0.3.x" - and its own header
# says the release process should call it after a tag is cut. Nothing ever did.
#
# So this is not a test that a bug was fixed. It is a test that the FIX IS
# WIRED IN, because the previous fix was written, committed and left uninvoked,
# and the defect came back identically five releases later.
#
# SM971: the wiring is tools/release-material.pl, which release.sh runs on the
# gate's stage and on the build's release commit, and which sets the pair with
# bump-version.pl itself - so VERSION is part of the tagged commit, not a stamp
# on a copy of it.
#
# THE ORDERING IS THE PART THAT WOULD BREAK SILENTLY. Three consumers read
# VERSION out of the stage - the compliance gate compares records against it,
# build-manifest and manifest-to-sbom default to it - so a write that happened
# after any of them would leave the same wrong answers while looking correct in
# a diff.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();
my $rel  = "$root/tools/release.sh";
my $gen  = "$root/tools/release-material.pl";
ok( -f $rel && -f $gen, 'release.sh and release-material.pl are present' ) or do { done_testing(); exit };

my $src  = do { open my $fh, '<', $rel or die $!; local $/; <$fh> };
my $gsrc = do { open my $fh, '<', $gen or die $!; local $/; <$fh> };

subtest 'the generator sets the pair, with the tool that owns it' => sub {
    like( $gsrc, qr/run_tool\('tools\/bump-version\.pl'\)/, 'release-material.pl runs bump-version.pl' );
    like( $gsrc, qr/spit\( "\$DIR\/NEXT_VERSION", "\$VERSION\\n" \);/,
        'after setting NEXT_VERSION to the release, which bump-version promotes' );
    unlike( $src, qr/>\s*"\$STAGE\/(?:NEXT_)?VERSION"/,
        'and release.sh no longer writes VERSION itself - one way, not two' );
};

subtest 'and release.sh runs it before everything that READS that file' => sub {
    my $stamp = index $src, 'perl "$STAGE/tools/release-material.pl" "${MATERIAL_ARGS[@]}"';
    cmp_ok( $stamp, '>', -1, 'the generator is run on the stage' ) or return;
    for my $reader (
        [ 'the compliance gate' => 'lazysite-compliance.pl --check' ],
        [ 'build-manifest'      => 'build-manifest.pl (channel:' ],
        [ 'manifest-to-sbom'    => 'manifest-to-sbom.pl --strict' ],
        [ 'the tarball'         => 'Building tarball' ],
        )
    {
        my ( $label, $needle ) = @$reader;
        my $at = index $src, $needle;
        cmp_ok( $at,    '>', -1,  "$label is in release.sh" ) or next;
        cmp_ok( $stamp, '<', $at, "the generator precedes $label" )
            or diag( "$label reads VERSION out of the stage. Written after it, "
                . 'the gate would keep asking its question about a version '
                . 'nobody released.' );
    }
};

# THE MECHANISM ITSELF, RUN: what the generator does to the pair, on a version
# whose successor crosses no boundary and one that does (SM383: the pair moves
# together, or the next release proposes a version already cut).
subtest 'the pair moves together, so the tree never contradicts itself' => sub {
    for my $case ( [ '0.10.15', '0.10.16' ], [ '1.2.9', '1.2.10' ] ) {
        my ( $v, $want ) = @$case;
        my $d = tempdir( CLEANUP => 1 );
        for my $f ( [ VERSION => '0.10.9' ], [ NEXT_VERSION => $v ] ) {
            open my $fh, '>', "$d/$f->[0]" or die $!;
            print {$fh} "$f->[1]\n";
            close $fh;
        }
        my $out = run_cmd( 'sh', '-c', "cd \Q$d\E && exec \Q$^X\E \Q$root/tools/bump-version.pl\E" );
        is( $? >> 8, 0, "$v: bump-version runs" ) or diag($out);
        my %got = map { open my $fh, '<', "$d/$_" or die $!; chomp( my $x = <$fh> ); ( $_ => $x ) } qw(VERSION NEXT_VERSION);
        is( $got{VERSION},      $v, "$v: VERSION is the release, the stale value gone" );
        is( $got{NEXT_VERSION}, $want, "$v: NEXT_VERSION is $want" );
    }
};

done_testing();
