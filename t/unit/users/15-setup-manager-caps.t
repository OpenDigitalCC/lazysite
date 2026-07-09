#!/usr/bin/perl
# Fresh-install regression (field report, 0.6.3): setup-manager ran cmd_group_add
# (which SEEDS group settings) before manager_groups was written to lazysite.conf,
# so the admin group got no capability entry and the new manager could not even
# add a user ("Creator 'manager' lacks create_sub_users permission"). setup-manager
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

# --- fresh install: setup-manager, then the manager adds a user ---------------
my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Fresh\n";    # deliberately NO manager_groups yet
close $cf;

like( run_cli( $d, 'setup-manager' ), qr/Manager ready/, 'fresh setup-manager runs' );

# The admin group must have a capability entry now.
open my $gs, '<', "$d/lazysite/auth/groups-settings.json" or die $!;
my $settings = decode_json( do { local $/; <$gs> } );
close $gs;
my $admin = $settings->{'lazysite-admins'};
ok( ref $admin eq 'HASH' && %{$admin}, 'admin group has a capability entry' );
ok( $admin->{create_sub_users}, 'admin group confers create_sub_users' );
ok( $admin->{manage_users},     'admin group confers manage_users' );
ok( $admin->{notifications},    'admin group confers notifications' );
ok( $admin->{ui},               'admin group confers ui' );
ok( !$admin->{api} && !$admin->{mcp},
    'admin group does NOT get the remote api/mcp channels (SM127)' );

# The reported failure: the manager creating an account must now succeed.
my $out = run_cli( $d, 'account-create', 'alice', 'pw12345678', '--by', 'manager' );
unlike( $out, qr/lacks create_sub_users/, 'no create_sub_users denial' );
open my $u, '<', "$d/lazysite/auth/users" or die $!;
my $users = do { local $/; <$u> };
close $u;
like( $users, qr/^alice:/m, 'manager can add a user on a fresh install' );

# --- repair: an install broken by the old ordering is fixed by re-running -----
my $d2 = tempdir( CLEANUP => 1 );
make_path("$d2/lazysite/auth");
open $cf, '>', "$d2/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Broken\nmanager: enabled\nmanager_groups: lazysite-admins\n";
close $cf;
# Simulate the broken state: seeded group settings WITHOUT the admin group.
open my $bg, '>', "$d2/lazysite/auth/groups-settings.json" or die $!;
print {$bg} '{"content-editors":{"label":"Content editors","ui":1}}';
close $bg;
open my $gr, '>', "$d2/lazysite/auth/groups" or die $!;
print {$gr} "lazysite-admins:manager\n";
close $gr;
open my $uf, '>', "$d2/lazysite/auth/users" or die $!;
print {$uf} "manager:sha256iter:1:x:y\n";
close $uf;

like( run_cli( $d2, 'setup-manager', 'newpass12345' ), qr/Manager ready/,
    're-running setup-manager on a broken install works' );
open $gs, '<', "$d2/lazysite/auth/groups-settings.json" or die $!;
$settings = decode_json( do { local $/; <$gs> } );
close $gs;
ok( $settings->{'lazysite-admins'}{create_sub_users},
    're-run repairs the missing admin-group capabilities' );

done_testing();
