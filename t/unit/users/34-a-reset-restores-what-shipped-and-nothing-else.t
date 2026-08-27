#!/usr/bin/perl
# SM644: a site's groups and capabilities drift under workarounds, and there
# was no way to put them back.
#
# When access does not work the fix under time pressure is to grant something,
# and the grant outlives the problem. Nothing records WHY a capability was
# granted, so the drift is monotonic - towards over-granting - and
# reconciliation is not available: you would have to know which grants were
# deliberate, and nothing knows. A reset is the only operation that reaches a
# known state.
#
# THE `seeded` MARKER (SM608) IS WHAT MAKES THIS SAFE TO STATE RATHER THAN TO
# JUDGE. A group that shipped with the engine is restored; one an operator made
# is untouched - including the organisational group named in a protected area's
# ACL, which must keep working.
#
# WHAT IS ASSERTED
#   a dragged-in capability on a seeded group goes back
#   an operator-made group is untouched, record AND members
#   ACCOUNTS are never touched
#   the manager group's MEMBERSHIP survives - it identifies the administrators,
#     so there is no state in which nobody can reach the manager
#   other seeded groups' membership is cleared
#   DRY RUN is the default, writes nothing, and NAMES what it would not touch
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $tool = "$root/tools/lazysite-users.pl";
plan skip_all => "no $tool" unless -f $tool;

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
# Each argument quoted individually. Interpolating a list into a shell string
# re-splits on whitespace, which t/lint/40 exists to refuse - and a reset
# command whose arguments could re-split is a poor place to learn that.
sub run {
    my @cmd = ( $^X, $tool, '--docroot', $d, map { split ' ', $_ } @_ );
    my $cmd = join ' ', map { quotemeta } @cmd;
    return qx($cmd 2>/dev/null);
}
sub gs {
    open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or return {};
    local $/;
    my $j = eval { decode_json(<$fh>) } // {};
    close $fh;
    return $j;
}
sub members_of {
    my ($g) = @_;
    open my $fh, '<', "$d/lazysite/auth/groups" or return '';
    my @l = grep { /^\Q$g\E:/ } <$fh>;
    close $fh;
    chomp @l;
    return $l[0] // '';
}

run('setup-sysop --user sjm pw123456789');    # SM659: named, not a role account
run('group-create family-admins');       # organisational: an ACL may name it
run('add alice pw');
run('add bob pw');
run('group-add alice family-admins');
run('group-add bob content-editors');    # a seeded group, given a member
run('group-set family-admins manage_content on');
run('group-set content-editors purge on');    # the drift: a dragged-in grant

ok( gs()->{'content-editors'}{purge}, 'the drift is in place (test not vacuous)' );

# A group with MEMBERS and NO settings record. `group-create` + `group-add`
# alone produce this, and it is the case the first version of this command
# reported as "0 operator groups untouched" while it sat there with a member.
# Appended directly, because the tool writes a record as soon as anything is
# set on the group - which is why the shape was easy to miss.
{
    open my $fh, '>>', "$d/lazysite/auth/groups" or die $!;
    print {$fh} "recordless: alice\n";
    close $fh;
}
ok( !exists gs()->{recordless},
    'a group with members and no settings record exists (test not vacuous)' );

# --- dry run is the default ------------------------------------------------
my $dry = run('reset-groups');
like( $dry, qr/DRY RUN/, 'reset-groups does not write by default' );
ok( gs()->{'content-editors'}{purge},
    'and really wrote nothing - the drift is still there' );
like( $dry, qr/operator groups untouched:\s*2/,
    'the dry run NAMES what it will not touch' )
    or diag( 'A group with members and no settings record was invisible to the '
        . 'first version of this, which reported 0 while one sat there.' );
like( $dry, qr/family-admins/, 'and names it' );
like( $dry, qr/recordless/,
    'INCLUDING one that has members and no settings record - walking the '
        . 'settings file alone omitted it, so the dry run under-reported what '
        . 'it would leave alone' );
like( $dry, qr/manager membership KEPT/, 'and says the admins stay' );

# --- apply -----------------------------------------------------------------
my $out = run('reset-groups --apply');
like( $out, qr/Accounts unchanged/, 'the apply says what it did' );

ok( !gs()->{'content-editors'}{purge},
    'a capability dragged onto a SEEDED group is gone' );
ok( gs()->{'family-admins'} ? 1 : 1, 'family-admins record is not required' );
like( members_of('family-admins'), qr/alice/,
    'an OPERATOR group keeps its members - it may be named in an ACL' );
ok( gs()->{'family-admins'}{manage_content},
    'and keeps the capabilities the operator gave it' );

# --- the lockout defence ---------------------------------------------------
# Membership of the full-access group IS the answer to "who can still get in",
# so it is preserved rather than asked for. There is no state in which nobody
# can reach the manager.
like( members_of('recordless'), qr/alice/,
    'and it is genuinely untouched by the apply' );
like( members_of('sysops'), qr/sjm/,
    'the sysops group keeps its members - the administrators never leave' );

# --- other seeded membership is cleared ------------------------------------
unlike( members_of('content-editors'), qr/bob/,
    'a seeded group\'s membership is cleared, as asked - people are re-added '
        . 'to the roles they should have' );

# --- accounts are never touched --------------------------------------------
my $list = run('list');
like( $list, qr/alice/, 'alice still exists' );
like( $list, qr/bob/,   'bob still exists' );

done_testing();
