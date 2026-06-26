#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Digest::SHA qw(sha256_hex);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my $script  = "$root/tools/lazysite-users.pl";
my $docroot = tempdir( CLEANUP => 1 );

ok( -f $script, 'tools/lazysite-users.pl present' );

sub run_cli {
    my (@args) = @_;
    my @cmd = ( $^X, $script, '--docroot', $docroot, @args );
    return qx(@cmd 2>&1);
}

# --- add user ---
{
    my $out = run_cli( 'add', 'alice', 'password123' );
    like( $out, qr/added/i, 'add produces confirmation' );
    ok( -f "$docroot/lazysite/auth/users", 'users file created' );

    open my $fh, '<', "$docroot/lazysite/auth/users" or die $!;
    my $content = do { local $/; <$fh> }; close $fh;
    # H-2: new format is sha256iter:SALT:ITERATIONS:HASH
    like( $content, qr{^alice:sha256iter:[0-9a-f]{32}:100000:[0-9a-f]{64}\s*$}m,
          'users file has a salted iterated hash for alice' );
}

# --- list users ---
{
    my $out = run_cli('list');
    like( $out, qr/^alice\b/m, 'alice appears in list' );
}

# --- change password ---
{
    my $out = run_cli( 'passwd', 'alice', 'newpass' );
    like( $out, qr/updated/i, 'passwd confirms' );
    open my $fh, '<', "$docroot/lazysite/auth/users" or die $!;
    my $content = do { local $/; <$fh> }; close $fh;
    # Capture the stored hash for alice and compare to a fresh sha256iter
    # derivation with the same salt — this proves the new password took
    # effect (salts differ per invocation so we cannot compare hashes
    # directly without reading the stored salt).
    my ($salt, $iters, $hash) =
        ( $content =~ m{^alice:sha256iter:([0-9a-f]{32}):(\d+):([0-9a-f]{64})}m );
    ok( $salt && $iters && $hash, 'new hash has sha256iter format' );
    my $derived = 'newpass';
    $derived = sha256_hex($salt . $derived) for 1 .. $iters;
    is( $hash, $derived, 'stored hash matches sha256iter(newpass) with stored salt' );
}

# --- group-add ---
{
    my $out = run_cli( 'group-add', 'alice', 'admins' );
    like( $out, qr/added/i, 'group-add confirms' );
    ok( -f "$docroot/lazysite/auth/groups", 'groups file created' );
}

# --- groups list shows membership ---
{
    my $out = run_cli('groups');
    like( $out, qr/admins.*alice/s, 'admins group shows alice' );
}

# --- group-remove ---
{
    my $out = run_cli( 'group-remove', 'alice', 'admins' );
    like( $out, qr/removed/i, 'group-remove confirms' );
    my $groups = run_cli('groups');
    unlike( $groups, qr/admins.*alice/s,
        'alice no longer in admins after group-remove' );
}

# --- remove user also removes from groups ---
{
    run_cli( 'group-add', 'alice', 'editors' );
    my $groups_before = run_cli('groups');
    like( $groups_before, qr/editors.*alice/s, 'alice in editors before remove' );

    my $out = run_cli( 'remove', 'alice' );
    like( $out, qr/removed/i, 'remove confirms' );

    my $groups_after = run_cli('groups');
    unlike( $groups_after, qr/alice/, 'alice gone from groups after remove' );

    my $list = run_cli('list');
    unlike( $list, qr/^alice\b/m, 'alice gone from users list' );
}

# --- add same user twice errors ---
{
    run_cli( 'add', 'bob', 'x' );
    my $out = run_cli( 'add', 'bob', 'y' );
    like( $out, qr/already exists/i, 'duplicate add reports error' );
}

# --- passwd on missing user errors ---
{
    my $out = run_cli( 'passwd', 'nobody', 'x' );
    like( $out, qr/not found/i, 'passwd on missing user reports error' );
}

# --- setup-manager: one-command first-run bootstrap ---
{
    open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: Test\n"; close $cf;

    my $out = run_cli('setup-manager');
    like( $out, qr/Manager ready/,            'setup-manager reports ready' );
    like( $out, qr/Password:\s*[0-9a-f]{24}/, 'generates a strong password' );

    open my $u, '<', "$docroot/lazysite/auth/users" or die $!;
    my $users = do { local $/; <$u> }; close $u;
    like( $users, qr/^manager:sha256iter:/m, 'manager account created with a password' );

    open my $g, '<', "$docroot/lazysite/auth/groups" or die $!;
    my $groups = do { local $/; <$g> }; close $g;
    like( $groups, qr/^lazysite-admins:.*\bmanager\b/m, 'manager added to the admin group' );

    open my $c, '<', "$docroot/lazysite/lazysite.conf" or die $!;
    my $conf = do { local $/; <$c> }; close $c;
    like( $conf, qr/^manager:\s*enabled/m,             'conf enables the manager' );
    like( $conf, qr/^manager_groups:\s*lazysite-admins/m, 'conf names the admin group' );

    # idempotent + explicit password
    my $out2 = run_cli( 'setup-manager', 'chosenpass' );
    like( $out2, qr/Password:\s*chosenpass/, 'honours an explicit password' );
    open my $c2, '<', "$docroot/lazysite/lazysite.conf" or die $!;
    my $conf2 = do { local $/; <$c2> }; close $c2;
    my $count = () = $conf2 =~ /^manager_groups:/mg;
    is( $count, 1, 'conf keys not duplicated on re-run' );
}

done_testing();
