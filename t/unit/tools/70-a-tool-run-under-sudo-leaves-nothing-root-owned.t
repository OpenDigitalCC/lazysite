#!/usr/bin/perl
# SM619: lazysite tools become the site's owner before writing into its tree.
#
# The rule was already written - lazysite-check.pl:2291 states it as SM139,
# "lazysite never writes into a site tree as root, because root-owned files
# there are exactly what stops the manager working afterwards" - and was
# enforced in exactly one probe. A fleet sweep after the 0.11.0 upgrade found 31
# sites with 16 identical failures each, all traceable to a tree owned root:root.
#
# ONE sudo run explains a whole tree: lazysite/auth is created setgid (02770), so
# once its group is root everything made beneath it afterwards INHERITS group
# root, including writes by code that is itself careful. That is why the damage
# widens with nobody running anything new, and why the fix has to be at the
# directory, above the file writes.
#
# WHY THE DECISION IS SPLIT FROM THE ACT: dropping privilege needs real root, so
# a test that could only exercise it as root would never run. target_identity()
# answers "who should I become?" as a pure function of a directory, and can be
# pointed at a genuinely root-owned tree - '/' - to exercise the refusal for
# real, rather than through a fake-root environment variable living inside a
# privilege-dropping function.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Util qw(target_identity drop_to_tree_owner);

my $root = "$FindBin::Bin/../../..";

# A tree whose group is NOT the caller's primary group. Without this the two
# candidate answers - "the group of the tree" and "the group in the user record"
# - are the same number, and every assertion about which one was used passes
# either way. A sabotage proved that: swapping the source still passed.
# On a site this difference is the whole point: the tree carries the WEB group
# the CGI shares, and the user's private group is not it.
my $OTHER_GID;
for my $g ( split ' ', $) ) {
    next if $g == ( split ' ', $) )[0];
    $OTHER_GID = $g, last if $g != ( getpwuid $< )[3];
}

sub tree_with_other_group {
    my $d = tempdir( CLEANUP => 1 );
    chown -1, $OTHER_GID, $d if defined $OTHER_GID;
    return $d;
}

# --- 1. a tree that knows who it belongs to names them ----------------------
{
    my $d = tree_with_other_group();
    my ( $uid, $gid ) = target_identity($d);
    is( $uid, $<,             'the identity to become is the tree owner' );
    is( $gid, ( stat $d )[5], 'and the group is the tree group' );
SKIP: {
        skip 'no secondary group on this host to distinguish the two', 1
            unless defined $OTHER_GID && $OTHER_GID != ( getpwuid $< )[3];
        isnt( $gid, ( getpwuid $< )[3],
            'which is NOT the user private group - the distinction that matters to the CGI' );
    }
}

# --- 2. a ROOT-OWNED tree refuses rather than guessing -----------------------
# '/' is genuinely root-owned on every host this runs on, so this exercises the
# real refusal rather than a simulation of one. Guessing here is precisely how
# the field damage spread.
{
    my ( $uid, $why ) = target_identity('/');
    is( $uid, undef, 'a root-owned tree yields no identity' );
    like( $why, qr/owned by root/,   'and says why' );
    like( $why, qr/--fix|--as-user/, 'and names a way forward rather than only refusing' );
}

# --- 3. --as-user names the owner; the TREE still decides the group ----------
# A site user's private group is not the group the CGI shares. Taking the group
# from the user record would write files the web server cannot read - the defect
# pointed the other way.
{
    my $d  = tree_with_other_group();
    my $me = ( getpwuid $< )[0];
    my ( $uid, $gid ) = target_identity( $d, as_user => $me );
    is( $uid, $<,             'as_user resolves the named owner' );
    is( $gid, ( stat $d )[5], 'and the group still comes from the tree' );
SKIP: {
        skip 'no secondary group on this host to distinguish the two', 1
            unless defined $OTHER_GID && $OTHER_GID != ( getpwuid $< )[3];
        isnt( $gid, ( getpwuid $< )[3],
            'not from the user record - a private group would lock the CGI out' );
    }
}

{
    my ( $uid, $why ) = target_identity( '/tmp', as_user => 'no_such_user_zzz' );
    is( $uid, undef, 'an unknown --as-user is refused' );
    like( $why, qr/no such user/, 'by name' );
}

# --- 4. unprivileged callers are untouched ----------------------------------
# The drop must be a no-op when not root: the overwhelming majority of runs are
# a developer or the site user, and changing their identity would be a defect of
# its own.
SKIP: {
    skip 'running as root - the non-root path cannot be observed', 3 if $> == 0;
    my $d      = tempdir( CLEANUP => 1 );
    my $before = "$>:$<";
    my $r      = drop_to_tree_owner($d);
    is( $r->{dropped}, 0, 'no drop happens when not root' );
    like( $r->{why}, qr/not running as root/, 'and it says so' );
    is( "$>:$<", $before, 'and the process identity is unchanged' );
}

# --- 5. the tool refuses to write into a root-owned tree as root -------------
# End to end through the real tool. Not root here, so the refusal cannot fire -
# what IS asserted is that the guard is wired into the tool at all, and that the
# ordinary unprivileged path still works. A source grep would pass whether or not
# the guard ran, so the tool is EXECUTED.
{
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    my $out = `$^X -I$root/lib $root/tools/lazysite-users.pl --docroot '$d' list 2>&1`;
    my $rc  = $?;
    is( $rc, 0, 'the tool still runs normally when not root' )
        or diag($out);
    ok( -d "$d/lazysite/auth", 'and created the auth store' );
    my $owner = ( stat "$d/lazysite/auth" )[4];
    is( $owner, $<, 'owned by the invoking user, not by anyone else' );
}

# --- 6. the guard is above the make_path, not merely before the file writes --
# The DIRECTORY is the thing whose ownership propagates through setgid. A guard
# placed after make_path would leave the one artefact that poisons every later
# write, so the ORDER is asserted rather than the presence.
{
    open my $fh, '<', "$root/tools/lazysite-users.pl" or die $!;
    my $src = do { local $/; <$fh> };
    close $fh;
    my $drop = index( $src, 'drop_to_tree_owner( $DOCROOT' );
    my $mk   = index( $src, 'make_path($AUTH_DIR)' );
    cmp_ok( $drop, '>', 0, 'the tool calls the drop' );
    cmp_ok( $mk,   '>', 0, 'and creates the auth dir' );
    cmp_ok( $drop, '<', $mk,
        'the drop happens BEFORE the directory whose group propagates is created' );
}

# --- 7. AS ROOT, for real: the tool refuses and exits non-zero ---------------
# `unshare -r` maps the caller to uid 0 in a new user namespace, so $> is
# genuinely 0 and the guard genuinely fires. This is the only assertion here
# that observes the root path rather than reasoning about it, and it is the one
# that matters: everything above tests what the tool would DECIDE, this tests
# that it acts on the decision instead of warning and carrying on.
SKIP: {
    my $have = system('unshare -r --map-root-user true >/dev/null 2>&1') == 0;
    skip 'no unprivileged user namespaces on this host', 3 unless $have;

    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite");
    my $out = `unshare -r --map-root-user $^X -I$root/lib $root/tools/lazysite-users.pl --docroot '$d' list 2>&1`;
    my $rc = $? >> 8;

    is( $rc, 2, 'as root on a tree it cannot attribute, the tool EXITS non-zero' )
        or diag($out);
    like( $out, qr/refusing to write/, 'saying it refuses' );
    like( $out, qr/--fix|--as-user/,   'and naming the way forward' );
}

# WHAT IS NOT MEASURED HERE, said rather than left as a gap: a SUCCESSFUL drop.
# It needs a root context with a second uid mapped, and `unshare -r` without
# newuidmap maps only one. So the branch that sets the ids and returns
# dropped => 1 is exercised by no test on this host - a mutation making it a
# silent no-op that still reports success passes the suite. Verifying it needs a
# real root run against a site tree owned by a site user, which is the field
# check the operator performs on upgrade.

done_testing();
