#!/usr/bin/perl
# ADVERSARIAL / availability (breadth pass 2026-07), REVERSED BY RULING 206
# (2026-11-09, SM1417 item 4). The file keeps its name (other records cite it).
#
# This test used to hold that the per-IP login rate limiter (H-3) FAILS OPEN: an
# unusable DB_File store answered "allowed", so a corrupt counter disabled the
# limiter without anyone deciding to. Ruling 206 decides the other way - a broken
# store is a fault, the engine refuses, and the sysadmin repairs it from the
# command line (`lazysite check` names it; t/tools/70). Nothing a visitor sends
# can make the counter a directory, so the refusal is not one an attacker can
# induce. This test contrasts a WORKING store (which correctly rate-limits an
# over-limit IP) with a BROKEN store (a directory where the DB file should be, so
# the tie fails) and asserts the broken case refuses the sign-in as unavailable -
# never as "too many attempts", and never as a credential check.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use DB_File;
use Fcntl qw(O_RDWR O_CREAT);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root env_passthrough run_child);
use RateWindow qw(stay_in_one_window);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
open my $uf, '>', "$docroot/lazysite/auth/users" or die $!;
print $uf "alice:dummy-not-a-real-hash\n";
close $uf;
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
# SM798: switched on, as the installer leaves every site - the fail-open
# cases below are about a limiter that is on and cannot run.
print $cf "site_name: R\nauth_redirect: /login\nextensions:\n  - extensions/login-rate-limit.pl\n";
close $cf;

my $rate_db      = "$docroot/lazysite/auth/.login-rate.db";
my $LOGIN_MAX    = 5;                                        # must match lazysite-auth.pl
my $LOGIN_WINDOW = 300;
my $ip           = '10.55.44.33';

# Guard the 300 s window rollover (as 03 does) so the seed and the request share
# a window.
stay_in_one_window( $LOGIN_WINDOW, 8 );    # SM1163: the shared guard

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
    my $out = run_child( [ $^X, "$root/lazysite-auth.pl" ],
        stdin => $body, stderr => 'inherit' )->{out};
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

# --- ruling 206: the sign-in is refused as unavailable --------------------------
{
    my $out = login_once();
    unlike( $out, qr{error=rate}, 'broken store: not reported as too many attempts' );
    like( $out, qr{Location:[^\n]*error=unavailable},
        '... the sign-in is refused as unavailable (cannot tell), before any credential check' );
}

done_testing();
