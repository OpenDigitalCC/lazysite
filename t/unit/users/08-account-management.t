#!/usr/bin/perl
# SM071 Phase 2: account management - disable/enable, cascade, ancestry
# authorisation, reassign; plus end-to-end disabled enforcement over DAV.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root run_dav setup_dav_site dav_users_tool grant_caps);

my $root   = repo_root();
my $script = "$root/tools/lazysite-users.pl";

sub fresh_docroot {
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    return $d;
}

sub cli {
    my ( $docroot, @args ) = @_;
    my ( $wtr, $rdr );
    my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $script, '--docroot', $docroot, @args );
    close $wtr;
    my $out  = do { local $/; <$rdr> };
    my $eout = do { local $/; <$err> };
    waitpid $pid, 0;
    return { out => $out // '', err => $eout // '', code => $? >> 8 };
}

sub api {
    my ( $docroot, $payload ) = @_;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $script, '--api', '--docroot', $docroot );
    print $cin encode_json($payload);
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}

sub settings { return api( $_[0], { action => 'settings-get', username => $_[1] } )->{settings} }

# Build a tree:  root -> a -> { b, c }
sub build_tree {
    my $d = fresh_docroot();
    cli( $d, 'add', 'root', 'pw' );
    grant_caps( $d, 'root', 'create_sub_users', 'delegate_sub_user_creation' );
    cli( $d, 'account-create', 'a', 'pw', '--by', 'root', '--create-subs' );
    cli( $d, 'account-create', 'b', 'pw', '--by', 'a' );
    cli( $d, 'account-create', 'c', 'pw', '--by', 'a' );
    return $d;
}

# --- disable / enable single account ----------------------------------
{
    my $d = build_tree();
    cli( $d, 'account-disable', 'b' );
    ok( settings( $d, 'b' )->{disabled}, 'b disabled' );
    ok( !settings( $d, 'c' )->{disabled}, 'sibling c unaffected' );
    cli( $d, 'account-enable', 'b' );
    ok( !settings( $d, 'b' )->{disabled}, 'b re-enabled' );
}

# --- cascade disable / enable over the sub-tree -----------------------
{
    my $d = build_tree();
    cli( $d, 'account-disable', 'a', '--cascade' );
    ok( settings( $d, 'a' )->{disabled}, 'cascade: a disabled' );
    ok( settings( $d, 'b' )->{disabled}, 'cascade: b disabled' );
    ok( settings( $d, 'c' )->{disabled}, 'cascade: c disabled' );

    cli( $d, 'account-enable', 'a', '--cascade' );
    ok( !settings( $d, 'a' )->{disabled}, 'cascade enable: a' );
    ok( !settings( $d, 'b' )->{disabled}, 'cascade enable: b' );
    ok( !settings( $d, 'c' )->{disabled}, 'cascade enable: c' );
}

# --- ancestry authorisation -------------------------------------------
{
    my $d = build_tree();
    my $ok = cli( $d, 'account-disable', 'b', '--actor', 'a' );
    is( $ok->{code}, 0, 'a (ancestor) may disable b' );

    my $sibling = cli( $d, 'account-disable', 'c', '--actor', 'b' );
    isnt( $sibling->{code}, 0, 'b may not disable sibling c' );

    my $upward = cli( $d, 'account-disable', 'root', '--actor', 'a' );
    isnt( $upward->{code}, 0, 'a may not disable its ancestor root' );
}

# --- reassign ----------------------------------------------------------
{
    my $d = build_tree();
    cli( $d, 'account-reassign', 'c', '--to', 'root' );
    my $s = settings( $d, 'c' );
    is( $s->{managed_by}, 'root', 'reassign: managed_by updated to root' );
    is( $s->{created_by}, 'a',    'reassign: created_by (provenance) preserved' );

    my $cycle = cli( $d, 'account-reassign', 'a', '--to', 'b' );
    isnt( $cycle->{code}, 0, 'reassign into own sub-tree rejected (cycle)' );

    my $unauth = cli( $d, 'account-reassign', 'c', '--to', 'b', '--actor', 'b' );
    isnt( $unauth->{code}, 0, 'non-ancestor actor may not reassign' );
}

# --- end-to-end: a disabled account is denied over DAV ----------------
{
    my $s = setup_dav_site();   # user 'deploy', webdav on
    my $before = run_dav( $s->{docroot}, 'OPTIONS', '/',
        HTTP_AUTHORIZATION => $s->{auth} );
    is( $before->{code}, 200, 'enabled webdav user: OPTIONS 200' );

    dav_users_tool( $s->{docroot}, 'account-disable', $s->{user} );
    my $after = run_dav( $s->{docroot}, 'OPTIONS', '/',
        HTTP_AUTHORIZATION => $s->{auth} );
    is( $after->{code}, 403, 'disabled account: DAV denied 403' );
    like( $after->{body}, qr/disabled/i, 'denial body mentions disabled' );
}

done_testing();
