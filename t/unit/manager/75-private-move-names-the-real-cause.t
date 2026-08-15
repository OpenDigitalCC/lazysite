#!/usr/bin/perl
# SM307: the private-store move says why it failed, having checked.
#
# THE DEFECT. move_in reported one of two causes and determined neither:
#
#     return ( 1, undef ) if rename $src, $dst;
#     # Cross-device, or a rename the filesystem refused.
#     return ( 0, 'cannot move a folder across filesystems' ) if -d $src;
#
# The comment was honest about the uncertainty. The message below it dropped the
# second half and stated the first as fact. rename() sets $!, so the distinction
# the comment already drew was one branch away from being made.
#
# On the host where it was found, the real fault was that public_html came back
# from a vhost rebuild without group write (SM270 recurring). The private store
# is a sibling of the docroot, so it inherits that exactly. Three operations on
# one docroot within minutes:
#
#   acl-set on a folder    ->  cannot move a folder across filesystems
#   acl-set on a file      ->  cannot create the private store
#   WebDAV PUT at the root ->  the target directory is not writable by the
#                              server. This is a server configuration fault,
#                              rather than a permission decision about your
#                              request - the operator must fix the directory
#                              permissions
#
# The third is correct, specific and actionable. The first two describe the same
# condition as each other and as the third, and disagree with both.
#
# WHY IT MATTERS MORE THAN AN ORDINARY WRONG MESSAGE. It contradicted a check
# that shipped ALONGSIDE it - SM296 added a `lazysite check` report naming the
# store's directory, owner and mode, which answers correctly on such a host. Two
# parts of one release gave an operator different accounts of one fault, and the
# wrong one is the one returned at the moment they act. Mount layout is not
# something an operator changes casually, so the suggested cause is credible
# enough to be investigated, and the real fix was a chown.
#
# WHAT IS NOT CHANGED. Refusing a cross-device DIRECTORY move is correct and
# stays. A recursive copy-then-delete would reintroduce the window in which half
# a section is public, on the operation whose whole purpose is to close it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Private ();

# The docroot sits INSIDE a tempdir of our own, never directly under /tmp.
#
# The private store is a SIBLING of the docroot, so reproducing the field
# condition means making the docroot's PARENT unwritable - and the first cut of
# this file used a bare tempdir, whose parent is /tmp. chmod 0555 /tmp is not
# something a test may attempt on a shared host. It failed harmlessly here
# because /tmp is root-owned and this does not run as root, so the SKIP fired
# and the permissions half silently never ran - a test that passes by not
# executing. Owning the parent is what makes the fixture both safe and real.
my $base    = tempdir( CLEANUP => 1 );
my $docroot = "$base/site";
mkdir $docroot           or die $!;
mkdir "$docroot/section" or die $!;
open my $fh, '>', "$docroot/section/index.md" or die $!;
print $fh "---\ntitle: S\n---\n\nBody.\n";
close $fh;
open my $lf, '>', "$docroot/loose.md" or die $!;
print $lf "---\ntitle: L\n---\n\nBody.\n";
close $lf;

# Running as a normal user, chmod on a directory we own is enough - this is the
# cheap half of the fixture, and the reason the permissions case is testable
# here while the cross-device case is not.
my $parent = $base;

SKIP: {
    skip 'running as root - a mode 0555 directory would still be writable', 3
        if $> == 0;

    my $mode = ( stat $parent )[2] & 07777;
    chmod 0555, $parent or skip "cannot chmod the fixture parent: $!", 3;

    # Prove the fixture actually bites before trusting anything it reports. The
    # first cut of this file skipped silently and passed.
    ok( !-w $parent, 'the fixture parent really is unwritable' );

    subtest 'a folder move names the real cause, not the filesystem layout' => sub {
        my ( $ok, $err ) = Lazysite::Private::move_in( $docroot, 'section' );
        ok( !$ok, 'the move fails, as it must on an unwritable store' );

        unlike( $err // '', qr/across filesystems/,
            'and does NOT blame the filesystem layout' )
            or diag( "Got: $err\n\n"
                . "This sends an operator to inspect mounts. The fault is\n"
                . "directory permissions, and the fix is a chown." );

        like( $err // '', qr/server configuration fault/i,
            'it names a server configuration fault, as the WebDAV layer does' );
        like( $err // '', qr/lazysite check/,
            'and points at the check that diagnoses it (SM296)' );
    };

    subtest 'a file and a folder describe one condition the same way' => sub {
        my ( undef, $folder_err ) = Lazysite::Private::move_in( $docroot, 'section' );
        my ( undef, $file_err )   = Lazysite::Private::move_in( $docroot, 'loose.md' );

        for my $pair ( [ folder => $folder_err ], [ file => $file_err ] ) {
            my ( $what, $err ) = @$pair;
            like( $err // '', qr/server configuration fault/i,
                "the $what path calls it a server configuration fault" );
            like( $err // '', qr/lazysite check/,
                "the $what path points at the same check" );
        }
    };

    subtest 'un-protecting reports the same way as protecting' => sub {
        # move_out carried the identical pair of lines, so one fault got two
        # different accounts depending on which direction the content was going.
        my ( $ok, $err ) = Lazysite::Private::move_out( $docroot, 'section' );

        # Nothing is in the store, so this is a no-op success rather than a
        # failure - which is itself the contract ("nothing to move is not a
        # failure"). Assert the contract rather than inventing a fixture that
        # would only prove the test could construct one.
        ok( $ok, 'move_out with nothing in the store succeeds, unchanged' );
        is( $err, undef, 'and reports no error' );
    };

    chmod $mode, $parent;
}

subtest 'a genuine cross-device folder move still refuses, and names both ends' => sub {
    # The one case the original message described correctly. Refusing is right
    # and stays; what changes is that it now says WHICH two locations, because
    # that is the operator's next question.
    #
    # No two filesystems here, so this drives the reporter directly with EXDEV
    # set - the branch, not the plumbing. The end-to-end case needs two mounts
    # and is fair to leave to a maintainer fixture, the way the 507-with-a-reason
    # path already is.
    local $! = 18;    # EXDEV
    my $msg = Lazysite::Private::_move_failure( '/a/src', '/b/dst', 1 );

    like( $msg, qr/across filesystems/, 'a real EXDEV on a directory says so' );
    like( $msg, qr{/a/src},             'and names the source' );
    like( $msg, qr{/b/dst},             'and names the destination' );
    like( $msg, qr/half a section public/,
        'and says why it refuses rather than copying' );
};

subtest 'EXDEV on a FILE is not reported as the directory case' => sub {
    # A file CAN be copied across devices - the fallback exists for exactly that
    # - so reaching the reporter with EXDEV on a file means the copy itself
    # failed, and the directory wording would be wrong twice over.
    local $! = 18;    # EXDEV
    my $msg = Lazysite::Private::_move_failure( '/a/src', '/b/dst', 0 );

    unlike( $msg, qr/cannot move a folder/,
        'a file does not borrow the folder message' );
    like( $msg, qr/server configuration fault/i, 'it uses the general form' );
};

done_testing();
