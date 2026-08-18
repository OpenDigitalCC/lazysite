#!/usr/bin/perl
# SM375: release.sh stamps VERSION in the stage, and does it EARLY ENOUGH.
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
# THE ORDERING IS THE PART THAT WOULD BREAK SILENTLY. Three consumers read
# VERSION out of the stage - the compliance gate compares records against it,
# build-manifest and manifest-to-sbom default to it - so a stamp that happened
# after any of them would leave the same wrong answers while looking correct in
# a diff.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $rel  = "$root/tools/release.sh";
ok( -f $rel, 'release.sh is present' ) or do { done_testing(); exit };

my $src = do { open my $fh, '<', $rel or die $!; local $/; <$fh> };

subtest 'the stamp exists and writes the released version' => sub {
    like( $src, qr/>\s*"\$STAGE\/VERSION"/,
        'release.sh writes to the stage VERSION' )
        or diag( 'Without this the tarball ships whatever VERSION happened to '
            . 'be committed, which is how 0.10.14 shipped one reading 0.10.9.' );
    like( $src, qr/printf\s+'%s\\n'\s+"\$VERSION"\s*>\s*"\$STAGE\/VERSION"/,
        'and writes $VERSION into it, rather than deriving it again' );
};

subtest 'and it happens before everything that READS that file' => sub {
    my $stamp = index $src, '> "$STAGE/VERSION"';
    cmp_ok( $stamp, '>', -1, 'the stamp is present' ) or return;

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
        cmp_ok( $stamp, '<', $at, "the stamp precedes $label" )
            or diag( "$label reads VERSION out of the stage. Stamped after it, "
                . 'the gate would keep asking its question about a version '
                . 'nobody released.' );
    }
};

# THE LINE ITSELF, RUN. Extracted from release.sh rather than retyped, so this
# drives the shipped code and not a copy of it that could agree with a broken
# original.
subtest 'the extracted stamp actually rewrites a stale file' => sub {
    my ($line) = $src =~ /^(printf\s+'%s\\n'\s+"\$VERSION"\s*>\s*"\$STAGE\/VERSION")\s*$/m;
    ok( $line, 'the stamp is one self-contained line' ) or return;

    my $stage = tempdir( CLEANUP => 1 );
    open my $vf, '>', "$stage/VERSION" or die $!;
    print {$vf} "0.10.9\n";
    close $vf;

    my $rc = system( 'sh', '-c', "STAGE='$stage' VERSION='9.9.9'; $line" );
    is( $rc, 0, 'the line runs clean' );

    open my $rf, '<', "$stage/VERSION" or die $!;
    chomp( my $got = <$rf> );
    close $rf;
    is( $got, '9.9.9', 'and the stale value is gone, replaced by the release' );
};

done_testing();
