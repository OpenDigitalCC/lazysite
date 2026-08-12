#!/usr/bin/perl
# SM286 step 1, foundation: the private content store.
#
# The property being built is that gated bytes are not in a directory any front
# end serves - which makes SM283 structurally impossible instead of fixed once
# per deployment shape. This tests the mechanism that moves them, before any
# surface is wired to it.
#
# The invariant under test is narrow and absolute: a path is in EXACTLY ONE
# tree. A copy left in the docroot is the exposure this exists to remove, so
# every failure mode below is checked for which side it leaves the content on.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Private
    qw(private_root private_path resolve is_private move_in move_out stray_public);

my $base = tempdir( CLEANUP => 1 );
my $doc  = "$base/public_html";
make_path("$doc/upcoming");

sub spit {
    my ( $p, $t ) = @_;
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}

# --- the store is OUTSIDE the docroot, which is the entire point ------------
subtest 'the private root is a sibling of the docroot, never inside it' => sub {
    my $root = private_root($doc);
    ok( $root, 'a private root is derived from the docroot' );
    unlike( $root, qr{\A\Q$doc\E/},
        'and it is NOT under the docroot - a subdirectory is exactly what a '
            . 'front end serves, which would defeat the whole mechanism' );
    is( $root, "$base/lazysite-private", 'it is a sibling' );
};

# --- moving in --------------------------------------------------------------
subtest 'a file moves in, and stops existing in the docroot' => sub {
    spit( "$doc/upcoming/secret.pdf", 'SECRETBYTES' );

    my ( $ok, $err ) = move_in( $doc, 'upcoming/secret.pdf' );
    ok( $ok, 'the move succeeds' ) or diag $err;

    ok( !-e "$doc/upcoming/secret.pdf",
        'the docroot copy is GONE - no front end can serve what is not there' );
    ok( -e private_path( $doc, 'upcoming/secret.pdf' ),
        'and the private store holds it' );

    my ( $abs, $where ) = resolve( $doc, 'upcoming/secret.pdf' );
    is( $where, 'private', 'resolve reports where it lives' );
    ok( is_private( $doc, 'upcoming/secret.pdf' ), 'and is_private agrees' );

    open my $fh, '<', $abs or die $!;
    my $got = do { local $/; <$fh> };
    close $fh;
    is( $got, 'SECRETBYTES', 'the bytes survived the move intact' );
};

# --- a whole folder moves in one step ---------------------------------------
# rename() moves a directory atomically, which is what makes protecting a
# SECTION safe: there is no window in which half of it is still public.
subtest 'a folder moves as one unit' => sub {
    make_path("$doc/section/deep");
    spit( "$doc/section/a.md",      'A' );
    spit( "$doc/section/deep/b.md", 'B' );

    my ( $ok, $err ) = move_in( $doc, 'section' );
    ok( $ok,                'the folder moves' ) or diag $err;
    ok( !-e "$doc/section", 'nothing of it is left in the docroot' );
    ok( -e private_path( $doc, 'section/deep/b.md' ),
        'including the files nested inside it' );
};

# --- moving back out --------------------------------------------------------
subtest 'un-protecting moves it back' => sub {
    my ( $ok, $err ) = move_out( $doc, 'section' );
    ok( $ok,                         'the folder moves back' ) or diag $err;
    ok( -e "$doc/section/deep/b.md", 'the docroot has it again' );
    ok( !-e private_path( $doc, 'section' ),
        'and the private store no longer does' );
};

# --- the invariant: never both ----------------------------------------------
subtest 'a path is never in both trees' => sub {
    # Contrive the fault: a private copy plus a stray public one.
    spit( "$doc/upcoming/stray.txt", 'PUBLIC' );
    my ($ok) = move_in( $doc, 'upcoming/stray.txt' );
    ok( $ok, 'moved in' );
    spit( "$doc/upcoming/stray.txt", 'PUBLIC AGAIN' );    # somebody re-created it

    ok( stray_public( $doc, 'upcoming/stray.txt' ),
        'the fault is DETECTED rather than papered over' );

    # Private wins, deliberately: the public copy is already reachable by the
    # front end, and serving it from the engine too would hide the fault from
    # anything comparing the two.
    my ( undef, $where ) = resolve( $doc, 'upcoming/stray.txt' );
    is( $where, 'private',
        'resolution prefers the governed copy, so the stray stays visible as a '
            . 'fault instead of quietly becoming the answer' );

    # And a second move-in refuses rather than overwriting the governed copy.
    my ( $ok2, $err2 ) = move_in( $doc, 'upcoming/stray.txt' );
    ok( !$ok2, 'moving in again is refused' );
    like( $err2, qr/already holds/i, 'and says why' );
    is( do { open my $f, '<', private_path( $doc, 'upcoming/stray.txt' ); local $/; <$f> },
        'PUBLIC', 'the governed copy was not overwritten by the stray' );
};

# --- failure leaves the content on ONE side ---------------------------------
subtest 'a move that cannot complete leaves the content where it was' => sub {
    spit( "$doc/upcoming/keep.txt", 'KEEP' );

    # Destination occupied by something else: the move must refuse and leave the
    # original alone rather than half-complete.
    make_path( private_path( $doc, 'upcoming' ) );
    spit( private_path( $doc, 'upcoming/keep.txt' ), 'OTHER' );

    my ( $ok, $err ) = move_in( $doc, 'upcoming/keep.txt' );
    ok( !$ok, 'refused' ) or diag $err;
    ok( -e "$doc/upcoming/keep.txt",
        'the original is still there - a failed move never destroys content' );
};

subtest 'moving out refuses when the docroot already has the path' => sub {
    spit( "$doc/upcoming/both.txt",                  'PUBLIC' );
    spit( private_path( $doc, 'upcoming/both.txt' ), 'PRIVATE' );

    my ( $ok, $err ) = move_out( $doc, 'upcoming/both.txt' );
    ok( !$ok, 'refused rather than overwriting the public copy' );
    like( $err, qr/already holds/i, 'and says why' );
};

# --- nothing to move is not a failure ---------------------------------------
# Protecting a path that has no content yet is ordinary - an operator gates a
# section before filling it - and must not report an error.
subtest 'moving a path that does not exist succeeds quietly' => sub {
    my ( $ok, $err ) = move_in( $doc, 'nowhere/at/all.md' );
    ok( $ok, 'move_in on a missing path is not an error' ) or diag $err;
    my ( $ok2, $err2 ) = move_out( $doc, 'nowhere/at/all.md' );
    ok( $ok2, 'nor is move_out' ) or diag $err2;
};

# --- confinement ------------------------------------------------------------
subtest 'a traversing path cannot escape either tree' => sub {
    spit( "$base/outside.txt", 'OUTSIDE' );
    my ( $ok, $err ) = move_in( $doc, '../outside.txt' );
    ok( !$ok, 'move_in refuses to reach outside the docroot' ) or diag $err;
    ok( -e "$base/outside.txt", 'and the file outside is untouched' );
};

done_testing();
