#!/usr/bin/perl
# SM496: the store can say "decided: no". Turning a capability off used to
# DELETE the key, so absent meant both "an operator declined this" and "this
# capability did not exist when the group was seeded" - the ambiguity that
# forced SM471 to warn forever. Now off writes an explicit 0, absent means
# UNDECIDED, and group-settings-get derives each manager group's `pending`
# list server-side so the Groups page renders a decision instead of policy.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $script = repo_root() . '/tools/lazysite-users.pl';
my $d      = tempdir( CLEANUP => 1 );
mkdir "$d/lazysite";
mkdir "$d/lazysite/auth";
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

sub api {
    my (%req) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $script, '--api', '--docroot', $d );
    print {$i} encode_json( \%req );
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } || {};
}
sub view { ( api( action => 'group-settings-get' )->{groups} || {} )->{'ops'} || {} }

# A manager group with two decided capabilities and nothing else - every
# other capability is UNDECIDED because the store has never seen it.
api( action => 'group-add',          group => 'ops' );
api( action => 'group-settings-set', group => 'ops', key => 'manager', value => 'on' );
api( action => 'group-settings-set', group => 'ops', key => 'manage_content', value => 'on' );

subtest 'SM645 CHANGED WHAT A MANAGER GROUP HAS LEFT TO DECIDE' => sub {
    # SM496 built `pending` so an operator DECIDES about a capability a release
    # added. It is computed for MANAGER GROUPS ONLY - see the guard in the view
    # - and SM645 now fills a manager group's never-decided keys automatically,
    # at the release manager's direction, so that population has nothing left
    # to decide. The banner is inert for manager groups by design rather than
    # by accident, and this says so instead of the file quietly losing an
    # assertion.
    #
    # SM496's MECHANISM IS NOT REMOVED and its other properties still hold
    # below: off is a decision rather than a deletion, and a dismissal is not a
    # lock. If the decision surface is ever wanted back, the natural population
    # is delegate groups, which have never had it.
    my $g       = view();
    my %pending = map { $_ => 1 } @{ $g->{pending} || [] };
    ok( !$pending{feedback},
        'a manager group has no undecided capability - SM645 fills them' );
    ok( !$pending{manage_content}, 'a granted one is not pending either' );
    ok( !$pending{api} && !$pending{mcp},
        'the remote channels are never offered to a manager group (SM127) - '
            . 'and SM645 does not grant them, so that rule is intact' );

    # The one that matters after an auto-grant: the channels must NOT have been
    # swept in with everything else, or a manager group becomes remotely
    # reachable and SM127 is undone by a migration.
    my $s = ( api( action => 'group-settings-get' )->{groups} || {} )->{ops} || {};
    ok( !$s->{api} && !$s->{mcp},
        'and the top-up did not grant them either' );
};

subtest 'off is a DECISION now, not a deletion' => sub {
    my $r = api( action => 'group-settings-set', group => 'ops', key => 'feedback', value => 'off' );
    ok( $r->{ok}, 'dismissing (off) succeeds' ) or diag explain $r;
    open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or die $!;
    my $store = decode_json( do { local $/; <$fh> } );
    close $fh;
    ok( exists $store->{ops}{feedback}, 'the key SURVIVES in the store' )
        or diag( 'Deleted: the store just forgot the decision, which is the '
            . 'pre-SM496 behaviour this file exists to prevent.' );
    ok( !$store->{ops}{feedback}, 'as an explicit false' );
    my %pending = map { $_ => 1 } @{ view()->{pending} || [] };
    ok( !$pending{feedback},       'and a declined capability stops pending' );
    ok( !view()->{caps}{feedback}, 'while the grid shows it unticked' );
};

subtest 'a dismissal is a decision, not a lock' => sub {
    my $r = api( action => 'group-settings-set', group => 'ops', key => 'feedback', value => 'on' );
    ok( $r->{ok},                 're-granting from the grid works' ) or diag explain $r;
    ok( view()->{caps}{feedback}, 'granted' );
};

subtest 'a non-manager group is not nagged' => sub {
    api( action => 'group-add', group => 'writers' );
    api( action => 'group-settings-set', group => 'writers', key => 'manage_content', value => 'on' );
    my $g = ( api( action => 'group-settings-get' )->{groups} || {} )->{writers} || {};
    is_deeply( $g->{pending}, [],
        'pending is empty: the release-capability question is a manager-group question' );
};

done_testing();
