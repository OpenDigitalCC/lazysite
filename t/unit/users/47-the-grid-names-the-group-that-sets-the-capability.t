#!/usr/bin/perl
# N141B-D and N141B-E: two defects in how the group graph is reported and
# unwound, both found by an agent walking grant authority on 0.13.16.
#
# D. THE GRID NAMED THE WRONG GROUP. The permissions grid's `granted_by` told an
# operator that `s05-child` granted `analytics` - and analytics is switched OFF
# on s05-child. It is set on `s05-parent`, the bundle the child is nested in.
#
# _caps_granted_by_group closes the graph upward and returns the UNION of every
# capability reachable from a group, which is exactly right for the delegation
# ceiling that asks "what does a person acquire here?" and needs only the set.
# The grid reused it and attributed the whole set to the group it asked about.
# Since SM631 every shipped role holds nothing of its own, so the grid named a
# role for capabilities that role has switched off.
#
# WHY IT MATTERS MORE THAN A WRONG LABEL: revocation is the operation this field
# is read for. An operator following the name lands on the one group where
# turning the capability off changes nothing, sees it already off, and concludes
# the access came from somewhere else - while the access stays.
#
# E. A DELETED GROUP STAYED A MEMBER OF ITS PARENT. cmd_group_delete removed the
# group's own member list and never looked for the group's NAME in anybody
# else's, so deleting a nested group left a phantom entry in every parent: a
# member that is not a user, not a group, and refers to nothing. The parent's
# own delete guard then counted it, so the PARENT became undeletable too -
# wedged by a group that no longer exists, with a message naming a member the UI
# cannot show and nobody can remove.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);

my $root  = do { my $d = $FindBin::Bin; $d =~ s{/t/unit/users$}{}; $d };
my $utool = "$root/tools/lazysite-users.pl";

sub w { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

my $d    = site_tempdir();
my $auth = "$d/lazysite/auth";
make_path($auth);

# The field's shape: a role with the capability OFF, nested in a bundle that
# has it ON. `analytics => 0` is written explicitly, because an absent key and
# a present-but-false key are different states and the defect showed on the
# second - the one that looks like a deliberate "no".
w( "$auth/groups-settings.json",
    encode_json( {
        'parent' => { analytics => 1, label => 'Analytics bundle',
            assignable => JSON::PP::false() },
        'child' => { analytics => 0, ui => 1, label => 'A role',
            assignable => JSON::PP::true() },
        'spare' => { label => 'Another role', assignable => JSON::PP::true() },
        # For E, a nested pair with NO people in either - so the delete guard
        # that refuses a group with members (which is correct, and not what
        # this tests) never enters into it.
        'holder' => { label => 'Holder', assignable => JSON::PP::false() },
        'orphan' => { label => 'Orphan', assignable => JSON::PP::true() },
    } ) );

# ada is in `child`; `child` is nested in `parent`.
# `orphan` is nested in `holder`, and nobody is in either.
w( "$auth/groups", "child: ada\nparent: child\nholder: orphan\n" );
w( "$auth/users",  "ada:x\n" );

# --- D: the capability is attributed to the group that SETS it ---------------
my $p = uapi( $d, { action => 'permissions-grid', username => 'ada' } );
ok( $p->{ok}, 'the permissions grid answered' ) or do { done_testing(); exit };

my $by = $p->{granted_by} || {};
ok( $by->{analytics}, 'analytics is reported as granted' )
    or diag( 'ada holds it through the nesting; if this is empty the closure '
        . 'itself is broken, not the attribution.' );

ok( ( grep { $_ eq 'parent' } @{ $by->{analytics} || [] } ),
    'and is attributed to the group where it is actually set' )
    or diag( 'granted_by says: ' . join( ', ', @{ $by->{analytics} || [] } )
        . " - an operator sent to revoke it there finds nothing to turn off." );

ok( !( grep { $_ eq 'child' } @{ $by->{analytics} || [] } ),
    'and NOT to the group where it is switched off' )
    or diag( 'This is the defect: the grid named the child role, whose own '
        . 'analytics flag is 0. Revoking there changes nothing and the access '
        . 'stays.' );

# A capability the role DOES hold directly is still attributed to the role.
ok( ( grep { $_ eq 'child' } @{ $by->{ui} || [] } ),
    'a capability set on the role itself is still attributed to the role' )
    or diag( 'The fix must not push every attribution up to a bundle.' );

# --- E: deleting a nested group un-nests it ----------------------------------
my $del = uapi( $d, { action => 'group-delete', group => 'spare' } );
ok( $del->{ok}, 'a group with no members deletes' ) or diag explain $del;

# Now the real case: delete the NESTED group. `orphan` holds no people, so the
# guard refusing a group with members - which is correct - never applies.
my $gone = uapi( $d, { action => 'group-delete', group => 'orphan' } );
ok( $gone->{ok}, 'the nested group deletes' ) or diag explain $gone;

# The membership file is the evidence: `holder: orphan` must not survive the
# deletion of `orphan`.
my $groups = do {
    open my $fh, '<', "$auth/groups" or die $!;
    local $/;
    <$fh>;
};
unlike( $groups, qr/^holder:.*\borphan\b/m,
    'the deleted group is no longer listed inside its parent' )
    or diag( "the groups file still says:\n$groups\n"
        . 'That entry is a member which is not a user and not a group - it '
        . 'refers to nothing, and the UI cannot show it to be removed.' );

# And the consequence that made it more than untidy: the parent is deletable
# again. Before the fix it counted the phantom and refused itself.
my $par = uapi( $d, { action => 'group-delete', group => 'holder' } );
ok( $par->{ok}, 'and the parent can now be deleted' )
    or diag( 'The parent answered: ' . ( $par->{error} // '?' )
        . ' - wedged undeletable by a group that no longer exists, naming a '
        . 'member nobody can remove.' );
unlike( $par->{error} // '', qr/remaining/,
    'rather than counting a phantom member' );

# --- the guard that IS correct still works -----------------------------------
#
# `child` has a real member. Deleting it must still be refused, or this fix has
# traded a phantom-member bug for silently stripping people's access.
my $busy = uapi( $d, { action => 'group-delete', group => 'child' } );
is( $busy->{ok}, 0, 'a group with a real member is still refused' );
like( $busy->{error} // '', qr/remaining/,
    'and still says how many are left' )
    or diag( 'The non-empty guard protects members from silently losing their '
        . 'permissions. Removing phantoms must not remove that.' );

done_testing();
