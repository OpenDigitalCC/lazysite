#!/usr/bin/perl
# SM645: an upgraded site could never adopt a capability a later release added.
#
# _ensure_manager_group_caps returned early for any group that already had a
# record, so it reached FRESH sites only. `housekeeping` and `purge` arrived
# with SM591 and were therefore absent from every manager group that already
# existed - nobody on those sites held them.
#
# THE CIRCLE THAT CLOSED: the SM195 ceiling lets a non-'local' actor confer
# only what they hold or have grant authority for, and it applies to GRANTING a
# capability as well as to conferring it. So the Groups page listed the new
# capability as a pending decision (SM496) and then refused to let the operator
# make that decision - they could not grant it because they did not hold it,
# because it had never been granted. `_may_confer` deliberately does not treat
# manage_users as operator (an adversarial review found that exact bypass), so
# nothing reachable through the manager could break it. The only escape was the
# CLI as `local`.
#
# WHAT IS ASSERTED
#   an existing manager group gains a capability it never decided on
#   an explicit DECLINE (0) is left alone - a top-up must not undo a decision
#   grant authority is topped up too, so delegation survives
#   a DELEGATE group is untouched - the ceiling still bounds the population it
#     exists to bound
#   the operator can then actually do the thing that was refused
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $tool = "$root/tools/lazysite-users.pl";
plan skip_all => "no $tool" unless -f $tool;

sub uapi {
    my ( $d, $p ) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $tool, '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}

sub groups_file {
    my ($d) = @_;
    my $f = "$d/lazysite/auth/groups-settings.json";
    return {} unless -f $f;
    open my $fh, '<', $f or return {};
    local $/;
    my $j = eval { decode_json(<$fh>) } // {};
    close $fh;
    return $j;
}

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");

# A SITE AS IT WAS BEFORE THE RELEASE: a manager group with a record, holding
# the capabilities of its day, and never having seen `housekeeping` or `purge`.
# Written directly, because that is what an upgraded site's store looks like -
# there is no way to reach this state through the tool once it heals.
open my $gs, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
print {$gs} encode_json( {
        'lazysite-admins' => {
            manager        => 1,
            assignable     => 1,
            seeded         => 1,
            label          => 'lazysite-admins',
            ui             => 1,
            manage_content => 1,
            manage_users   => 1,
            audit          => 0,          # DECLINED, deliberately
            grantable      => ['manage_content'],
        },
        'content-editors' => {            # a delegate group, for contrast
            assignable     => 1,
            manage_content => 1,
        },
} );
close $gs;

my $before = groups_file($d);
ok( !exists $before->{'lazysite-admins'}{housekeeping},
    'the manager group has never decided on housekeeping (test not vacuous)' );
is( $before->{'lazysite-admins'}{audit}, 0, 'and has explicitly DECLINED audit' );

# THE TRIGGER IS AN ORDINARY MANAGER READ, and finding that out was the fix.
# _ensure_manager_group_caps was only ever reached from cmd_setup_manager - the
# first-run command - so healing the healer alone changed nothing on any site
# that already existed, which is every site the defect affects. It is now
# called from _ensure_groups_seeded, which the manager's own reads run, so a
# site adopts the release the next time somebody opens the Users page rather
# than on a command nobody runs twice.
uapi( $d, { action => 'add', username => 'someone', password => 'pw' } );
uapi( $d, { action => 'group-add', username => 'someone',
        group => 'lazysite-admins' } );
uapi( $d, { action => 'users-page', me => 'someone' } );

my $after = groups_file($d);
my $adm   = $after->{'lazysite-admins'} || {};

# --- the never-decided keys are filled -------------------------------------
is( $adm->{housekeeping}, 1, 'the manager group now holds housekeeping' );
is( $adm->{purge},        1, 'and purge' );

# --- an explicit decline is NOT overwritten --------------------------------
# The sharpest failure available here: a top-up that ignored the difference
# between "never decided" and "declined" would silently undo an operator's
# deliberate decision on upgrade day, on every site at once.
is( $adm->{audit}, 0,
    'a capability the operator DECLINED stays declined - absent and 0 are not '
        . 'the same state' );

# --- grant authority is topped up too --------------------------------------
my %g = map { $_ => 1 } @{ $adm->{grantable} || [] };
ok( $g{housekeeping}, 'grant authority covers the new capability' );
ok( $g{manage_content}, 'and keeps what it already had' );

# --- the delegate group is untouched ---------------------------------------
my $ed = $after->{'content-editors'} || {};
ok( !exists $ed->{housekeeping},
    'a DELEGATE group gains nothing - it is the population the ceiling bounds' );
ok( !exists $ed->{grantable},
    'and gains no grant authority' );

# --- and the operator can now do what was refused --------------------------
# The point of the whole change: not that a key appeared in a file, but that
# the refusal stops happening.
uapi( $d, { action => 'group-create', group => 'family-admins' } );
uapi( $d, { action => 'group-settings-set', group => 'family-admins',
        key => 'housekeeping', value => 'on', actor => 'someone' } );
my $fam = groups_file($d)->{'family-admins'} || {};
is( $fam->{housekeeping}, 1,
    'an operator holding the capability can now grant it - the circle is open' );

done_testing();
