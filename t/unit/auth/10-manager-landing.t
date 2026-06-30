#!/usr/bin/perl
# Manager-aware login landing: a recognised manager who logs in without a specific
# `next` lands in the manager UI; a non-manager lands on home; an explicit `next`
# is always honoured.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps);

my $root = repo_root();
my $auth = "$root/lazysite-auth.pl";
my $utl  = "$root/tools/lazysite-users.pl";

sub users_api {
    my ( $docroot, $payload ) = @_;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $utl, '--api', '--docroot', $docroot );
    print $cin encode_json($payload);
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return decode_json($out);
}

sub run_auth {
    my ( $env, $body ) = @_;
    $body //= '';
    local %ENV = ( %$env, CONTENT_LENGTH => length($body),
        CONTENT_TYPE => 'application/x-www-form-urlencoded',
        LAZYSITE_USERS_TOOL => $utl );
    my ( $wtr, $rdr );
    my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $auth );
    print $wtr $body;
    close $wtr;
    my $out = do { local $/; <$rdr> };
    do { local $/; <$err> };
    waitpid $pid, 0;
    return $out // '';
}

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: Test\nmanager: enabled\nmanager_groups: admin\n";
close $cf;

users_api( $d, { action => 'add', username => 'mgr',   password => 'pw' } );
users_api( $d, { action => 'add', username => 'plain', password => 'pw' } );
users_api( $d, { action => 'group-add', username => 'mgr', group => 'admin' } );

# SM095 (c2): a user whose group carries the `ui` channel capability lands in
# the manager even though that group is NOT a manager_group.
users_api( $d, { action => 'add', username => 'capui', password => 'pw' } );
grant_caps( $d, 'capui', 'ui' );

my %base = ( DOCUMENT_ROOT => $d, REMOTE_ADDR => '127.0.0.1', HTTPS => '' );
sub login {
    my ( $user, $next ) = @_;
    return run_auth(
        { %base, REQUEST_METHOD => 'POST', QUERY_STRING => 'action=login' },
        "username=$user&password=pw&next=$next" );
}

like( login( 'mgr', '/' ), qr{Location:\s*/manager/},
    'manager with default next lands in the manager' );

my $plain = login( 'plain', '/' );
like(   $plain, qr{Location:\s*/(\r|\n|$)}, 'non-manager lands on home' );
unlike( $plain, qr{Location:\s*/manager/}, 'non-manager does NOT land in the manager' );

like( login( 'mgr', '/about' ), qr{Location:\s*/about},
    'an explicit next is honoured for a manager' );

like( login( 'capui', '/' ), qr{Location:\s*/manager/},
    'a user with the ui capability (no manager group) lands in the manager' );

done_testing;
