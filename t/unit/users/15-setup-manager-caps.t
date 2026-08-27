#!/usr/bin/perl
# Fresh-install regression (field report, 0.6.3): setup-sysop ran cmd_group_add
# (which SEEDS group settings) before manager_groups was written to lazysite.conf,
# so the admin group got no capability entry and the new manager could not even
# add a user ("Creator 'manager' lacks create_sub_users permission"). setup-sysop
# must guarantee the admin group confers capabilities - and re-running it must
# repair an affected install.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP qw(decode_json);
use FindBin;

my $script = "$FindBin::Bin/../../../tools/lazysite-users.pl";

sub run_cli {
    my ( $docroot, @args ) = @_;
    my @cmd = ( $^X, $script, '--docroot', $docroot, @args );
    my $out = do {
        local $/;
        open my $fh, '-|', @cmd or die $!;
        <$fh>;
    };
    return $out // '';
}

# --- fresh install: setup-sysop, then the manager adds a user ---------------
my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Fresh\n";    # deliberately NO manager_groups yet
close $cf;

# SM659: --link is the default, so a first run issues a registration link for
# the NAMED account rather than reporting a ready `manager` login.
like( run_cli( $d, 'setup-sysop', '--user', 'sjm' ), qr/single-use self-service link/,
    'fresh setup-sysop runs and issues a link' );

# The admin group must have a capability entry now.
open my $gs, '<', "$d/lazysite/auth/groups-settings.json" or die $!;
my $settings = decode_json( do { local $/; <$gs> } );
close $gs;
my $admin = $settings->{'sysops'};
ok( ref $admin eq 'HASH' && %{$admin}, 'admin group has a capability entry' );
ok( $admin->{create_sub_users}, 'admin group confers create_sub_users' );
ok( $admin->{manage_users},     'admin group confers manage_users' );
ok( $admin->{notifications},    'admin group confers notifications' );
ok( $admin->{ui},               'admin group confers ui' );
ok( !$admin->{api} && !$admin->{mcp},
    'admin group does NOT get the remote api/mcp channels (SM127)' );

# The reported failure: the manager creating an account must now succeed.
# SM659: the bootstrap admin is a NAMED account now, not one called `manager`.
my $out = run_cli( $d, 'account-create', 'alice', 'pw12345678', '--by', 'sjm' );
unlike( $out, qr/lacks create_sub_users/, 'no create_sub_users denial' );
open my $u, '<', "$d/lazysite/auth/users" or die $!;
my $users = do { local $/; <$u> };
close $u;
like( $users, qr/^alice:/m, 'manager can add a user on a fresh install' );

# --- repair: an install broken by the old ordering is fixed by re-running -----
my $d2 = tempdir( CLEANUP => 1 );
make_path("$d2/lazysite/auth");
open $cf, '>', "$d2/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Broken\nmanager: enabled\nmanager_groups: sysops\n";
close $cf;
# Simulate the broken state: seeded group settings WITHOUT the admin group.
open my $bg, '>', "$d2/lazysite/auth/groups-settings.json" or die $!;
print {$bg} '{"content-editors":{"label":"Content editors","ui":1}}';
close $bg;
open my $gr, '>', "$d2/lazysite/auth/groups" or die $!;
print {$gr} "sysops:manager\n";
close $gr;
open my $uf, '>', "$d2/lazysite/auth/users" or die $!;
print {$uf} "manager:sha256iter:1:x:y\n";
close $uf;

like( run_cli( $d2, 'setup-sysop', '--user', 'sjm', 'newpass12345' ), qr/Manager ready/,
    're-running setup-sysop on a broken install works' );
open $gs, '<', "$d2/lazysite/auth/groups-settings.json" or die $!;
$settings = decode_json( do { local $/; <$gs> } );
close $gs;
ok( $settings->{'sysops'}{create_sub_users},
    're-run repairs the missing admin-group capabilities' );

# --- self-heal: a broken install repairs on ANY read (no setup-sysop) -------
my $d3 = tempdir( CLEANUP => 1 );
make_path("$d3/lazysite/auth");
open $cf, '>', "$d3/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Broken2\nmanager: enabled\nmanager_groups: sysops\n";
close $cf;
open my $bg2, '>', "$d3/lazysite/auth/groups-settings.json" or die $!;
print {$bg2} '{"content-editors":{"label":"Content editors","ui":1}}';
close $bg2;
open my $gr2, '>', "$d3/lazysite/auth/groups" or die $!;
print {$gr2} "sysops:manager\n";
close $gr2;
open my $uf2, '>', "$d3/lazysite/auth/users" or die $!;
print {$uf2} "manager:sha256iter:1:x:y\n";
close $uf2;

run_cli( $d3, 'settings', 'manager' );    # any settings read triggers the healer
open $gs, '<', "$d3/lazysite/auth/groups-settings.json" or die $!;
$settings = decode_json( do { local $/; <$gs> } );
close $gs;
ok( $settings->{'sysops'}{create_sub_users},
    'a plain read self-heals the missing manager-group entry' );
ok( !$settings->{'sysops'}{api},
    'the healed entry has no remote api channel (SM127)' );
is_deeply( $settings->{'content-editors'}, { label => 'Content editors', ui => 1 },
    'existing entries are untouched by the healer' );

# SM138: the migration retires the conf key itself.
open my $cc, '<', "$d3/lazysite/lazysite.conf" or die $!;
my $conf_after = do { local $/; <$cc> };
close $cc;
unlike( $conf_after, qr/^manager_groups:/m,
    'the retired manager_groups line is removed from lazysite.conf' );
like( $conf_after, qr/^manager:\s*enabled/m, 'other conf keys survive the removal' );

done_testing();
