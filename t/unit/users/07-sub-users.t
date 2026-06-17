#!/usr/bin/perl
# SM071 Phase 2: sub-user accounts - provenance, creation, delegation.
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
use TestHelper qw(repo_root);

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

# --- top-level account has no provenance, no create permission ---------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'boss', 'pw' );
    my $s = settings( $d, 'boss' );
    ok( !defined $s->{created_by}, 'top-level account: created_by null' );
    ok( !$s->{create_sub_users},   'create_sub_users defaults off' );
    ok( !$s->{delegate_sub_user_creation}, 'delegate defaults off' );
}

# --- creator needs create_sub_users -----------------------------------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'boss', 'pw' );

    my $denied = cli( $d, 'account-create', 'worker', 'pw', '--by', 'boss' );
    isnt( $denied->{code}, 0, 'account-create denied without create_sub_users' );
    like( $denied->{err}, qr/create_sub_users/, 'error names the missing permission' );

    cli( $d, 'set', 'boss', 'create_sub_users', 'on' );
    my $ok = cli( $d, 'account-create', 'worker', 'pw', '--by', 'boss' );
    is( $ok->{code}, 0, 'account-create succeeds once granted' );

    my $s = settings( $d, 'worker' );
    is( $s->{created_by}, 'boss', 'worker created_by = boss' );
    is( $s->{managed_by}, 'boss', 'worker managed_by defaults to creator' );
    ok( $s->{created_at} && $s->{created_at} > 0, 'worker created_at stamped' );
    ok( !$s->{create_sub_users}, 'worker does not inherit create_sub_users' );
}

# --- delegation gates granting create_sub_users to the child ----------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'boss', 'pw' );
    cli( $d, 'set', 'boss', 'create_sub_users', 'on' );

    my $denied = cli( $d, 'account-create', 'w', 'pw', '--by', 'boss', '--create-subs' );
    isnt( $denied->{code}, 0, '--create-subs denied without delegate' );
    like( $denied->{err}, qr/delegate_sub_user_creation/, 'error names delegate permission' );

    cli( $d, 'set', 'boss', 'delegate_sub_user_creation', 'on' );
    my $ok = cli( $d, 'account-create', 'w', 'pw', '--by', 'boss', '--create-subs' );
    is( $ok->{code}, 0, '--create-subs succeeds once delegated' );
    ok( settings( $d, 'w' )->{create_sub_users}, 'delegated child can create sub-users' );
}

# --- error paths -------------------------------------------------------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'boss', 'pw' );
    cli( $d, 'set', 'boss', 'create_sub_users', 'on' );
    cli( $d, 'account-create', 'worker', 'pw', '--by', 'boss' );

    my $nocreator = cli( $d, 'account-create', 'x', 'pw', '--by', 'ghost' );
    isnt( $nocreator->{code}, 0, 'unknown creator rejected' );

    my $dup = cli( $d, 'account-create', 'worker', 'pw', '--by', 'boss' );
    isnt( $dup->{code}, 0, 'duplicate username rejected' );

    my $noby = cli( $d, 'account-create', 'y', 'pw' );
    isnt( $noby->{code}, 0, 'missing --by rejected' );
}

# --- API mode ----------------------------------------------------------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'boss', 'pw' );
    cli( $d, 'set', 'boss', 'create_sub_users', 'on' );
    cli( $d, 'set', 'boss', 'delegate_sub_user_creation', 'on' );

    my $r = api( $d, { action => 'account-create', username => 'api_worker',
        password => 'pw', created_by => 'boss', create_sub_users => 1 } );
    is( $r->{ok}, 1, 'API account-create ok' );
    my $s = settings( $d, 'api_worker' );
    is( $s->{created_by}, 'boss', 'API: provenance recorded' );
    ok( $s->{create_sub_users}, 'API: delegated permission granted' );
}

done_testing();
