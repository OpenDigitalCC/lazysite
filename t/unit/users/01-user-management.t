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
    my $expected = sha256_hex('password123');
    like( $content, qr/^alice:\Q$expected\E/m,
          'users file has correct hash for alice' );
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
    my $expected = sha256_hex('newpass');
    like( $content, qr/\Q$expected\E/, 'new hash written' );
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

done_testing();
