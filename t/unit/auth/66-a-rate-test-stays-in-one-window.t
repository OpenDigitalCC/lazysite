#!/usr/bin/perl
# SM1163: a test that counts attempts against a FIXED rate window must keep
# them inside one window. The 2026-10-17 integration ran six wrong-password
# calls in t/unit/account/02 across a 300 s boundary: the counter restarted, the
# sixth came back 'forbidden' not 'rate', and the right password then got in.
#
# Proved in process, with the real limiter and its window shortened to two
# seconds through the module's own package variable (no production knob), and
# the sequence deliberately started a quarter second before a boundary - the
# worst place:
#   - control: started there with no guard, six attempts straddle the boundary
#     and the sixth is NOT refused. That is the fixed window as shipped (noted in
#     the filing, not changed here).
#   - RateWindow::stay_in_one_window waits out the boundary, and then the same
#     six attempts are all in one window and the sixth IS refused.
# Remove the stay_in_one_window call below and the second subtest fails every time.
use strict;
use warnings;
use Test::More;
use Time::HiRes qw(time sleep);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use RateWindow qw(stay_in_one_window);
use Lazysite::Auth::LoginRate qw(check_login_rate);

BEGIN { eval { require DB_File; 1 } or plan skip_all => 'DB_File is not installed' }

my $WINDOW = 2;
local $Lazysite::Auth::LoginRate::LOGIN_WINDOW = $WINDOW;
my $MAX = $Lazysite::Auth::LoginRate::LOGIN_MAX;

sub site {
    my $d = site_tempdir();
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print $cf "site_name: R\nplugins:\n  - plugins/login-rate-limit.pl\n";
    close $cf;
    return $d;
}

# Wait until the clock is $before seconds short of the next boundary.
sub park_before_boundary {
    my ($before) = @_;
    my $t    = time();
    my $left = $WINDOW - ( $t - $WINDOW * int( $t / $WINDOW ) );
    sleep( $left > $before ? $left - $before : $left - $before + $WINDOW );
    return;
}

# MAX+1 attempts 0.1 s apart (as slow CGI calls would be); the verdicts.
sub guesses {
    my ($d) = @_;
    my @v;
    for my $i ( 1 .. $MAX + 1 ) {
        push @v, check_login_rate( '203.0.113.9', auth_dir => "$d/lazysite/auth", docroot => $d );
        sleep(0.1);
    }
    return @v;
}

subtest 'control: a sequence that straddles a boundary is not capped' => sub {
    my $d = site();
    park_before_boundary(0.25);
    my @v = guesses($d);
    ok( $v[-1], 'the last of ' . scalar(@v) . ' attempts is let through: the count restarted at the boundary' );
};

subtest 'the helper keeps the same sequence inside one window' => sub {
    my $d = site();
    park_before_boundary(0.25);
    my $slept = stay_in_one_window( $WINDOW, 1 );
    ok( $slept > 0, 'it was parked before a boundary, so the helper waited' );
    my @v = guesses($d);
    is( scalar( grep { $_ } @v ), $MAX, "the first $MAX attempts are allowed" );
    ok( !$v[-1], 'and the next is refused: all of them counted in one window' );
};

subtest 'the helper does not wait when there is room' => sub {
    my $left = $WINDOW - ( time() % $WINDOW );
    sleep( $left + 0.05 ) if $left < 1.2;    # start a fresh window
    is( stay_in_one_window( $WINDOW, 0.5 ), 0, 'plenty of the window left: no sleep' );
};

done_testing();
