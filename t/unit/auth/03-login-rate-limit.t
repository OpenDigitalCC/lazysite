#!/usr/bin/perl
# Login rate-limit saturation. Verifies the exact boundary:
#   - Nth failed attempt still passes the gate (gets "login failed")
#   - (N+1)th attempt trips rate-limit and gets "rate" error
#
# We don't iterate 6 real attempts - each failed login sleeps
# $LOGIN_DELAY seconds and that would make the suite slow. Instead
# we seed the DB_File state directly to place ourselves at the
# boundary, then make one real request either side of it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use DB_File;
use Fcntl qw(:flock O_RDWR O_CREAT);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
mkdir "$docroot/lazysite";
mkdir "$docroot/lazysite/auth";

# A real user so the post-limit path isn't short-circuited by the
# "no such user" check. The gate happens before that anyway.
open my $uf, '>', "$docroot/lazysite/auth/users" or die $!;
print $uf "alice:dummy-not-a-real-hash\n";
close $uf;

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "site_name: R\nauth_redirect: /login\n";
close $cf;

my $rate_db = "$docroot/lazysite/auth/.login-rate.db";
my $LOGIN_MAX    = 5;         # must match lazysite-auth.pl
my $LOGIN_WINDOW = 300;
my $ip           = '10.99.88.77';    # private, irrelevant; just a key

sub seed_count {
    my ($count) = @_;
    my %db;
    tie %db, 'DB_File', $rate_db, O_CREAT | O_RDWR, 0o600
        or die "cannot tie db: $!";
    my $window = int( time() / $LOGIN_WINDOW );
    $db{"$ip:$window"} = $count;
    untie %db;
}

sub read_count {
    my %db;
    tie %db, 'DB_File', $rate_db, O_RDWR, 0o600 or return undef;
    my $window = int( time() / $LOGIN_WINDOW );
    my $v = $db{"$ip:$window"};
    untie %db;
    return $v;
}

sub login_once {
    my ($user, $pass) = @_;
    my $body = "username=$user&password=$pass&next=/";
    local %ENV = (
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        QUERY_STRING   => 'action=login',
        CONTENT_LENGTH => length($body),
        REMOTE_ADDR    => $ip,
    );
    require IPC::Open2;
    my ( $cout, $cin );
    my $pid = IPC::Open2::open2( $cout, $cin,
        $^X, "$root/lazysite-auth.pl" );
    print $cin $body;
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return $out;
}

# --- At count = MAX - 1 (i.e. 4), the next attempt must still be
#     allowed through to credential-check. It will fail credentials
#     ("login failed"), but NOT be rate-limited. ---
{
    seed_count( $LOGIN_MAX - 1 );
    my $out = login_once( 'alice', 'wrong' );
    like( $out, qr/Status: 302 Found/,          'credential fail → 302' );
    like( $out, qr{Location:[^\n]*error=1},     'failed-login error code, NOT rate' );
    unlike( $out, qr{error=rate},                'not rate-limited at count=4+1' );
    my $after = read_count();
    is( $after, $LOGIN_MAX, "counter advanced to $LOGIN_MAX" );
}

# --- At count = MAX (i.e. 5), the NEXT attempt (the 6th) must be
#     rate-limited even if the password were correct. ---
{
    seed_count( $LOGIN_MAX );
    my $out = login_once( 'alice', 'wrong' );
    like( $out, qr/Status: 302 Found/,      'over-limit → 302' );
    like( $out, qr{Location:[^\n]*error=rate},
          'over-limit redirects with error=rate' );
    unlike( $out, qr{error=1\b},            'not a plain credential failure' );
}

# --- A different IP is not affected (per-IP accounting) ---
{
    seed_count( $LOGIN_MAX );      # saturate original IP
    my $body = "username=alice&password=wrong&next=/";
    local %ENV = (
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        QUERY_STRING   => 'action=login',
        CONTENT_LENGTH => length($body),
        REMOTE_ADDR    => '10.99.88.78',  # different IP
    );
    require IPC::Open2;
    my ( $cout, $cin );
    my $pid = IPC::Open2::open2( $cout, $cin,
        $^X, "$root/lazysite-auth.pl" );
    print $cin $body;
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    like( $out, qr{error=1},   'different IP passes credential check path' );
    unlike( $out, qr{error=rate},
            'different IP NOT rate-limited (per-IP counter)' );
}

done_testing();
