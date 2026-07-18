#!/usr/bin/perl
# ADVERSARIAL / availability (breadth pass 2026-07): the per-IP login rate limiter
# (H-3) must FAIL OPEN. If its DB_File store is unusable, check_login_rate returns
# "allowed" rather than "blocked" - otherwise a corrupt or unwritable rate-limit
# file would lock every user out of the whole site (a self-inflicted denial of
# service, and an availability regression an attacker could try to induce). This
# test contrasts a WORKING store (which correctly rate-limits an over-limit IP)
# with a BROKEN store (a directory where the DB file should be, so the tie fails)
# and asserts the broken case lets the request through to credential-check.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use DB_File;
use Fcntl qw(O_RDWR O_CREAT);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
open my $uf, '>', "$docroot/lazysite/auth/users" or die $!;
print $uf "alice:dummy-not-a-real-hash\n";
close $uf;
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "site_name: R\nauth_redirect: /login\n";
close $cf;

my $rate_db      = "$docroot/lazysite/auth/.login-rate.db";
my $LOGIN_MAX    = 5;                                        # must match lazysite-auth.pl
my $LOGIN_WINDOW = 300;
my $ip           = '10.55.44.33';

# Guard the 300 s window rollover (as 03 does) so the seed and the request share
# a window.
my $into = time() % $LOGIN_WINDOW;
sleep( $LOGIN_WINDOW - $into + 1 ) if $into > $LOGIN_WINDOW - 8;

sub seed_over_limit {
    my %db;
    tie %db, 'DB_File', $rate_db, O_CREAT | O_RDWR, 0o600 or die "tie: $!";
    $db{ "$ip:" . int( time() / $LOGIN_WINDOW ) } = $LOGIN_MAX;
    untie %db;
}

sub login_once {
    my $body = "username=alice&password=wrong&next=/";
    local %ENV = (
        env_passthrough(),
        DOCUMENT_ROOT  => $docroot,
        REQUEST_METHOD => 'POST',
        QUERY_STRING   => 'action=login',
        CONTENT_LENGTH => length($body),
        REMOTE_ADDR    => $ip,
    );
    require IPC::Open2;
    my ( $cout, $cin );
    my $pid = IPC::Open2::open2( $cout, $cin, $^X, "$root/lazysite-auth.pl" );
    print $cin $body;
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return $out;
}

# --- control: a WORKING store rate-limits an over-limit IP ----------------------
seed_over_limit();
{
    my $out = login_once();
    like( $out, qr{Location:[^\n]*error=rate},
        'working store: an over-limit IP is rate-limited (error=rate)' );
}

# --- break the store: put a DIRECTORY where the DB file belongs -----------------
# DB_File cannot tie a directory as a Berkeley DB, so the tie fails - exactly the
# "store unusable" condition H-3 must survive.
unlink $rate_db;
make_path($rate_db);    # $rate_db is now a directory
ok( -d $rate_db, 'rate-limit store is now unusable (a directory)' );

# --- fail-open: the login is NOT rate-limited; it reaches credential-check ------
{
    my $out = login_once();
    unlike( $out, qr{error=rate},
        'broken store FAILS OPEN: the request is not rate-limited (no lockout of all logins)' );
    like( $out, qr{Location:[^\n]*error=1},
        '... it falls through to a normal credential failure instead' );
}

done_testing();
