#!/usr/bin/perl
# SM667: put ONE seeded group back to its shipped permissions.
#
# reset-groups (SM644) restores every seeded group at once, from a shell. The
# operator's case is one group in the Groups panel whose row has drifted, and
# both of those are wrong for it: a shell they may not have, resetting nine
# groups to fix one.
#
# THE PART THAT NEEDED DESIGNING is not the capability row - _default_group_seed
# already computes it. It is that A RESET IS A CONFERRAL: it turns capabilities
# ON, so it must pass SM195's ceiling exactly as editing the row by hand does.
# Bypassing _may_confer because it is "only restoring the default" would be a
# privilege escalation with a reassuring name.
#
# And it must refuse WHOLESALE. A half-applied reset leaves a row that is
# neither the default nor what the operator had, and they cannot tell which half
# happened.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);
use JSON::PP;

my $root  = repo_root();
my $users = "$root/tools/lazysite-users.pl";
plan skip_all => 'users tool missing' unless -f $users;

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

sub run {
    my (@a) = @_;
    my $cmd = join ' ', map { quotemeta } ( $^X, $users, '--docroot', $d, @a );
    return qx($cmd 2>&1);
}
sub api {
    my ($req) = @_;
    my $json = encode_json($req);
    my $out  = qx(printf '%s' \Q$json\E | $^X \Q$users\E --api --docroot \Q$d\E 2>/dev/null);
    my $r    = eval { decode_json( $out // '' ) };
    return ref $r eq 'HASH' ? $r : { ok => 0, _raw => $out };
}
sub settings_for {
    open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or return {};
    local $/;
    my $j = eval { decode_json(<$fh>) } || {};
    close $fh;
    return $j;
}

# Seed the shipped groups by touching the store the way ordinary use does.
# `groups` alone does NOT seed - it reads. group-set is one of the commands that
# runs _ensure_groups_seeded, which is how a real site acquires them.
run( 'add', 'sjm', 'pw123456789' );
run( 'group-set', 'mine-own', 'ui', 'on' );

# A CAPABILITY group, not a role. SM631's three layers: a role like
# `content-editors` holds nothing on its own row and gets its capabilities
# through nesting, so resetting it would show no capability diff at all and the
# test would prove nothing. `cap-content` is where manage_content actually
# lives.
my $SEEDED = 'cap-content';
ok( settings_for()->{$SEEDED}, "the fixture has the seeded group $SEEDED" )
    or BAIL_OUT('nothing below tests anything without it');

subtest 'an operator-made group has no defaults to return to' => sub {
    my $r = api( { action => 'group-reset', group => 'mine-own' } );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error} // '', qr/created on this instance/,
        'and says why - there is no shipped default, and offering the action '
            . 'would imply there was' );
};

subtest 'the dry run reports the diff and writes nothing' => sub {
    run( 'group-set', $SEEDED, 'manage_domains', 'on' );    # drift: too much
    run( 'group-set', $SEEDED, 'manage_content', 'off' );   # drift: too little

    my $r = api( { action => 'group-reset', group => $SEEDED } );
    ok( $r->{ok}, 'the dry run succeeds' ) or diag( $r->{error} // '' );
    is( $r->{applied}, 0, 'and reports that it applied nothing' );
    ok( ( grep { $_ eq 'manage_content' } @{ $r->{capabilities_on} } ),
        'it names what would be turned ON' );
    ok( ( grep { $_ eq 'manage_domains' } @{ $r->{capabilities_off} } ),
        'and what would be turned OFF' )
        or diag( 'An operator shown only "Reset this group?" will not press '
            . 'it; one shown that the only change is manage_domains going off '
            . 'will.' );

    my $now = settings_for()->{$SEEDED};
    ok( $now->{manage_domains}, 'the drift is still there - nothing was written' );
};

subtest 'applying restores the row and keeps the members' => sub {
    # ITS MEMBERS ARE NESTED ROLES, not people - a backend group refuses a
    # person outright, which is SM631's layering doing its job. Membership is
    # membership either way, and a reset that cleared it would silently detach
    # every role that depends on this group for its capabilities.
    my $before = run('groups');
    my ($members_before) = $before =~ /^\Q$SEEDED\E:\s*(.+)$/m;
    ok( length( $members_before // '' ), 'the group has members before the reset' )
        or diag( 'Without members the next assertion proves nothing.' );

    my $r = api( { action => 'group-reset', group => $SEEDED, apply => 1 } );
    ok( $r->{ok} && $r->{applied}, 'applied' ) or diag( $r->{error} // '' );

    my $now = settings_for()->{$SEEDED};
    ok( !$now->{manage_domains}, 'the capability that drifted on is off' );
    ok( $now->{manage_content},  'and the one that drifted off is back' );
    ok( $now->{seeded},          'and it is still marked as shipped' );

    my ($members_after) = run('groups') =~ /^\Q$SEEDED\E:\s*(.+)$/m;
    is( $members_after, $members_before, 'the members are unchanged' )
        or diag( 'SM644 preserved membership deliberately: membership of the '
            . 'manager group is what identifies the administrators, and a '
            . 'reset that emptied it could lock every human out.' );
};

subtest 'the ceiling: a delegate may not confer what it does not hold' => sub {
    # A delegate with manage_users but NOT manage_content. Resetting a group
    # whose defaults include manage_content would confer it - which is exactly
    # the escalation SM195 exists to stop, wearing the words "restore defaults".
    run( 'add', 'delegate', 'pw123456789' );
    run( 'group-set', 'delegates', 'ui', 'on' );
    run( 'group-set', 'delegates', 'manage_users', 'on' );
    run( 'group-add', 'delegate', 'delegates' );
    run( 'group-set', $SEEDED, 'manage_content', 'off' );

    my $r = api( { action => 'group-reset', group => $SEEDED,
            actor => 'delegate', apply => 1 } );
    ok( !$r->{ok}, 'refused for the delegate' )
        or diag( '"Only restoring the default" is not a reason to skip the '
            . 'ceiling - the default is not automatically within the '
            . "resetting actor's authority." );
    is( $r->{kind}, 'forbidden', 'as a capability matter' );
    like( $r->{error} // '', qr/manage_content/, 'naming the capability' );
    like( $r->{error} // '', qr/Nothing has been changed/,
        'and saying plainly that nothing was written' );

    my $now = settings_for()->{$SEEDED};
    ok( !$now->{manage_content},
        'and nothing WAS written - not even the half it was allowed to do' )
        or diag( 'A partial reset leaves a row that is neither the default nor '
            . 'what the operator had.' );
};

done_testing();
