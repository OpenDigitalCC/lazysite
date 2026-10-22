#!/usr/bin/perl
# SM1118 (ruled 2026-10-20, #338): "ACCESS DURING MAINTENANCE" IS A CAPABILITY,
# assignable to any group like the others, granted to the operator group by
# default - on a fresh site and, by the SM645 top-up, on an upgraded one.
#
# Followed end to end the way audit_switch was: the list every surface derives
# from (@CAP_KEYS), the map an agent reads (describe), the users tool that seeds
# the operator group and assigns to others, and the CLI that issues the first
# operator. A capability in one of these and not the rest is "grantable and
# unlocks nothing" or "held and never listed".
#
# WHAT IS ASSERTED
#   it is in @CAP_KEYS, and the capability map describes it
#   a fresh `setup-sysop` makes an operator group that holds it
#   an upgraded operator group (a record that never saw it) gains it
#   an operator group that DECLINED it (0) keeps the decline - a top-up must not
#     undo a decision
#   a delegate group is not given it by the top-up, and an operator can assign it
#     to one, as to any other capability; a group holding it then holds it
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper               qw(repo_root site_tempdir run_child);
use Lazysite::Auth::Settings ();
use Lazysite::Capabilities   ();

my $root = repo_root();
my $tool = "$root/tools/lazysite-users.pl";
plan skip_all => "no $tool" unless -f $tool;

sub uapi {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $tool, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
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

# --- the lists ---------------------------------------------------------------
ok( ( grep { $_ eq 'maintenance_access' } @Lazysite::Auth::Settings::CAP_KEYS ), 'it is in @CAP_KEYS' );
ok( ( grep { $_ eq 'maintenance_access' } Lazysite::Capabilities::action_keys() ), '...as an action, not a channel' );
my $map  = Lazysite::Capabilities::describe( caps => { maintenance_access => 1 } );
my $json = encode_json($map);
like( $json, qr/maintenance_access/,                      'the capability map names it' );
like( $json, qr/Use the site while it is in maintenance/, '...with its title' );

# --- a fresh install ---------------------------------------------------------
{
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n";
    close $cf;
    my $out = qx($^X \Q$tool\E --docroot \Q$d\E setup-sysop --user sjm 2>&1);
    my $sys = groups_file($d)->{sysops} || {};
    is( $sys->{maintenance_access}, 1, 'a fresh operator group holds it' );
    ok( ( grep { $_ eq 'maintenance_access' } @{ $sys->{grantable} || [] } ), '...and may confer it' );
    for my $g ( grep { $_ ne 'sysops' && $_ ne 'cap-maintenance' } keys %{ groups_file($d) } ) {
        ok( !groups_file($d)->{$g}{maintenance_access}, "the shipped group '$g' does not hold it" );
    }
    # SM1118 (ruled 2026-10-20): the one bundle that carries it, drawn on by site-admins
    # (t/integration/321); no other shipped group holds it.
    is( groups_file($d)->{'cap-maintenance'}{maintenance_access}, 1, 'the cap-maintenance bundle holds it' );
}

# --- an upgraded site, a declined decision, a delegate -----------------------
my $d = site_tempdir();
make_path("$d/lazysite/auth");
open my $gs, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
print {$gs} encode_json( {
        sysops => {
            manager   => 1, assignable     => 1, seeded => 1, label => 'Site operator',
            ui        => 1, manage_content => 1, manage_users => 1,
            grantable => ['manage_content'],
        },
        'night-ops' => {    # a SECOND operator group that declined it
            manager => 1, assignable => 1, label => 'Night ops', ui => 1, manage_users => 1,
            maintenance_access => 0,
        },
        'content-editors' => { assignable => 1, manage_content => 1 },
} );
close $gs;
{
    open my $mf, '>', "$d/lazysite/auth/groups" or die $!;
    print {$mf} "sysops: someone\nnight-ops: nobody\n";
    close $mf;
}
ok( !exists groups_file($d)->{sysops}{maintenance_access}, 'the operator group has never seen it (not vacuous)' );
uapi( $d, { action => 'add', username => 'someone', password => 'pw-long-enough' } );
uapi( $d, { action => 'users-page', me => 'someone' } );

my $after = groups_file($d);
is( $after->{sysops}{maintenance_access}, 1, 'an existing operator group gains it on upgrade' );
ok( ( grep { $_ eq 'maintenance_access' } @{ $after->{sysops}{grantable} || [] } ), '...with authority to confer it' );
is( $after->{'night-ops'}{maintenance_access}, 0, 'an operator group that declined it keeps the decline' );
ok( !exists $after->{'content-editors'}{maintenance_access}, 'a delegate group is not given it' );

# --- assignable to any group like the others ---------------------------------
uapi( $d, { action => 'group-settings-set', group => 'content-editors', key => 'maintenance_access', value => 'on', actor => 'someone' } );
is( groups_file($d)->{'content-editors'}{maintenance_access}, 1, 'an operator assigns it to another group' );
{
    local $Lazysite::Auth::Settings::AUTH_DIR = "$d/lazysite/auth";
    open my $mf, '>>', "$d/lazysite/auth/groups" or die $!;
    print {$mf} "content-editors: ed\n";
    close $mf;
    ok( Lazysite::Auth::Settings::caps_for('ed')->{maintenance_access}, 'a member of that group holds it (caps_for)' );
    ok( !Lazysite::Auth::Settings::caps_for('nobody')->{maintenance_access}, '...and a member of the declining group does not' );
}

done_testing();
