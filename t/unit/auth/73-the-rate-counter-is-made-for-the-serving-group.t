#!/usr/bin/perl
# SM1240: the sign-in rate limiter's counter (auth/.login-rate.db) was CREATED
# 0600. The 0.16.0 rollout found it 0600, owned by the site user in group
# www-data, on two production sites: the CGI runs as www-data, could not open it,
# and allowed every attempt. The doctor found it and --fix repaired it; the file
# must never be made that way.
#
# Whoever creates it, under whatever umask it runs with, the counter is 0660 and
# in the auth directory's group. Runs the real Lazysite::Auth::LoginRate.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";

plan skip_all => 'DB_File is not installed' unless eval { require DB_File; 1 };
use_ok('Lazysite::Auth::LoginRate');

sub site {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: R\nplugins:\n  - plugins/login-rate-limit.pl\n";
    close $cf;
    return $d;
}

sub count_once {
    my ( $d, $umask ) = @_;
    my $old = umask $umask;
    my $ok = Lazysite::Auth::LoginRate::check_login_rate( '192.0.2.7',
        auth_dir => "$d/lazysite/auth", docroot => $d );
    umask $old;
    return $ok;
}

sub mode_of { my @s = stat $_[0]; return @s ? $s[2] & 07777 : undef }

for my $um ( 077, 022, 027, 0002 ) {
    my $d  = site();
    my $db = "$d/lazysite/auth/.login-rate.db";
    ok( count_once( $d, $um ), sprintf( 'umask %04o: the first attempt is under the cap', $um ) );
    ok( -e $db, sprintf( 'umask %04o: the counter was created', $um ) );
    is( sprintf( '%04o', mode_of($db) // 0 ), '0660',
        sprintf( 'umask %04o: it is created 0660, so the serving group can open it', $um ) );
}

subtest 'the caller\'s umask is restored' => sub {
    my $d   = site();
    my $old = umask 077;
    Lazysite::Auth::LoginRate::check_login_rate( '192.0.2.8',
        auth_dir => "$d/lazysite/auth", docroot => $d );
    my $now = umask $old;
    is( sprintf( '%04o', $now ), '0077', 'the limiter put the umask back' );
};

subtest 'it takes the auth directory\'s group' => sub {
    # A group this process is in other than its primary one: the counter must
    # land in the DIRECTORY's group, not the creator's, or a creator whose primary
    # group is not the serving group leaves the CGI locked out again.
    my ($other) = grep { $_ != ( $) + 0 ) } split ' ', $);
    plan skip_all => 'this user is in no second group' unless defined $other;
    my $d    = site();
    my $auth = "$d/lazysite/auth";
    chown -1, $other, $auth or plan skip_all => "cannot set the test directory's group: $!";
    chmod 0770, $auth;    # no setgid: the limiter itself must set the group
    count_once( $d, 022 );
    is( ( stat "$auth/.login-rate.db" )[5], $other, 'the counter is in the auth directory\'s group' );
};

subtest 'a counter this process owns that lost group access gets it back' => sub {
    my $d  = site();
    my $db = "$d/lazysite/auth/.login-rate.db";
    count_once( $d, 022 );
    chmod 0600, $db;
    ok( count_once( $d, 022 ), 'the next attempt still counts' );
    is( sprintf( '%04o', mode_of($db) ), '0660', 'and the counter is 0660 again' );
};

subtest 'it still counts' => sub {
    my $d = site();
    stay_in_window();
    my @r = map { count_once( $d, 022 ) ? 1 : 0 } 1 .. 6;
    is_deeply( \@r, [ 1, 1, 1, 1, 1, 0 ], 'five allowed, the sixth refused' );
};

sub stay_in_window {
    require RateWindow;
    RateWindow::stay_in_one_window( 300, 10 );
}

done_testing;
