#!/usr/bin/perl
# SM428: save_acls wrote 0640, and lazysite-check requires group-write.
#
# The ACL store is written by TWO identities on a group-shared docroot: the
# site user (CLI verbs, `acl reapply`) and the www-data CGI (the manager's
# permissions UI). 0640 leaves it readable but not writable by whichever one
# did not write it last - so the manager silently loses the ability to save a
# permission change, which is exactly what lazysite-check reports:
#
#   [ FAIL ] lazysite/auth/acls.json (0640, ispadmin:www-data) is not writable
#            by the CGI (www-data) - the manager cannot save it
#
# IT WAS REACHING THE FIELD ON EVERY DEPLOY. The upgrade's `acl reapply` step
# rewrote the store as the site user, dropping it to 0640, and the health pass
# that follows repaired it to 0660 - so the only trace was a repair that ran
# every single time. A repair that always runs is not a repair; it is a writer
# disagreeing with its own checker once per deploy, with a window in between
# where the manager cannot save.
#
# The mode is asserted against what the CHECKER demands rather than a literal,
# so the two cannot drift apart again - which is the whole defect.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Auth::Acl ();

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
$Lazysite::Auth::Acl::LAZYSITE_DIR = "$d/lazysite";
$Lazysite::Auth::Acl::DOCROOT      = $d;

my $ok = Lazysite::Auth::Acl::save_acls(
    { 'upcoming' => { owner => 'op', read => ['members'] } } );
ok( $ok, 'the store was written' ) or BAIL_OUT('save_acls failed');

my $path = "$d/lazysite/auth/acls.json";
ok( -f $path, 'acls.json exists' ) or BAIL_OUT('no store');
my $mode = ( stat $path )[2] & 07777;

subtest 'both identities can write it' => sub {
    ok( $mode & 0200, 'owner can write' );
    ok( $mode & 0020,
        'GROUP can write - the CGI and the site user share the group, and '
            . 'whichever wrote last must not lock the other out' )
        or diag( sprintf 'mode is %04o; lazysite-check requires group-write '
            . 'on this file and repairs it to 0660 when it is not', $mode );
};

subtest 'and nothing else can read it' => sub {
    is( $mode & 0007, 0, 'no world bits - it is an access-control store' );
};

subtest 'the mode matches the sibling files the checker treats the same way' => sub {
    # users and groups are in the same list in lazysite-check's group-writable
    # loop. Asserting parity with them rather than a literal keeps the writer
    # and the checker from drifting apart, which is the defect itself.
    my $chk = "$FindBin::Bin/../../../tools/lazysite-check.pl";
SKIP: {
        skip 'no lazysite-check.pl', 1 unless -f $chk;
        open my $fh, '<', $chk or die $!;
        my $src = do { local $/; <$fh> };
        close $fh;
        like( $src, qr{lazysite/auth/acls\.json},
            'the checker still lists acls.json among the files the CGI must '
                . 'be able to write' );
    }
};

done_testing();
