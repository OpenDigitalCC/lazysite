package RateWindow;

# SM1163: keep a test's counted attempts inside ONE fixed rate window.
#
# The sign-in limiter (Lazysite::Auth::LoginRate), the WebDAV limiter and the
# hourly upload budget count in FIXED windows: int(time()/WINDOW). A test that
# makes several attempts and expects the cap to bite (or not to) is only right
# if no window boundary falls between its first and last attempt - a boundary
# restarts the count. In the 2026-10-17 integration the guesses in
# t/unit/account/02 ran across a :00 five-minute boundary: the sixth came back
# 'forbidden', not 'rate', and the right password then succeeded.
#
#   RateWindow::stay_in_one_window( $window_seconds, $need_seconds )
#
# Call it once, after the fixture is built and before the first COUNTED
# attempt. If fewer than $need_seconds remain in the current window it sleeps
# until the next one begins (plus a hair), and returns the seconds slept (0 when
# it did not). Choose $need generously for the real window: each attempt may be
# a CGI process on a loaded host. It sleeps only in the last $need seconds of a
# window, so most runs wait for nothing.

use strict;
use warnings;
use Time::HiRes qw(time sleep);
use Exporter 'import';

our @EXPORT_OK = qw(stay_in_one_window);

sub stay_in_one_window {
    my ( $window, $need ) = @_;
    die "stay_in_one_window: a window length is required\n" unless $window && $window > 0;
    $need //= 60;
    $need = $window if $need > $window;
    my $left = $window - ( time() % $window );
    return 0 if $left > $need;
    my $nap = $left + 0.05;
    sleep($nap);
    return $nap;
}

1;
