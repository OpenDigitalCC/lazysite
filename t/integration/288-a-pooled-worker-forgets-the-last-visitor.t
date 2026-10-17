#!/usr/bin/perl
# SM1169 (SM1082 C1): THE THREE THINGS A POOLED WORKER KEPT FROM ONE REQUEST TO
# THE NEXT. Found by t/lint/269's scan of every file-scope variable in the code
# a worker keeps resident (the SM973 class). Each request here goes through
# handle_one_request(), as the accept loop runs it, in one process.
#
#   %PAYMENT_CONTEXT   the payer, the amount and whether it was paid, set for a
#                      payment-gated page and fed to the template stash of every
#                      LATER render in the worker, gated or not
#   _scan_identity     the first visitor's user and groups, kept for the worker's
#                      life, so every later `scan:` page was filtered as THEM
#   $RESPONSE_LANG     the last rendered page's language, sent as the
#                      Content-Language of a request that rendered nothing
#
# $RENDER_BY_ADDRESS (a latch) came up in the same scan and main() already resets
# it (SM1141); it is asserted here so it stays that way.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site site_tempdir repo_root);

my $root    = repo_root();
my $docroot = site_tempdir();
setup_test_site($docroot);

delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED)};
local $ENV{DOCUMENT_ROOT}  = $docroot;
local $ENV{REQUEST_METHOD} = 'GET';
local $ENV{QUERY_STRING}   = '';
local $ENV{REDIRECT_URL}   = '/__load__';

sub capture {
    my ($code) = @_;
    my $out = "$docroot/out.$$";
    open my $so, '>&', \*STDOUT    or die;
    open my $se, '>&', \*STDERR    or die;
    open STDOUT, '>',  $out        or die;
    open STDERR, '>',  '/dev/null' or die;
    $code->();
    open STDOUT, '>&', $so  or die;
    open STDERR, '>&', $se  or die;
    open my $fh, '<',  $out or die;
    local $/;
    return scalar(<$fh>) // '';
}

capture( sub { do "$root/lazysite-processor.pl"; die $@ if $@ } );
sub request { local $ENV{REDIRECT_URL} = $_[0]; capture( sub { main::handle_one_request() } ) }

{
    no warnings 'once';

    # the previous request left a payer in the context
    %main::PAYMENT_CONTEXT = ( payment_payer => '0xPAYER-OF-REQUEST-ONE', payment_paid => 1 );
    request('/nothing-here');
    is_deeply( {%main::PAYMENT_CONTEXT}, {}, 'the payment context is empty at the next request' );

    # the previous page's language
    $main::RESPONSE_LANG = 'fr';
    request('/nothing-here');
    is( $main::RESPONSE_LANG, 'en', 'the response language is back to the default' );

    # the address latch
    $main::RENDER_BY_ADDRESS = 1;
    request('/nothing-here');
    ok( !$main::RENDER_BY_ADDRESS, 'the render-by-address latch is clear' );
}

# the scan identity: request one is vouched for by the auth wrapper as alice
{
    local $ENV{LAZYSITE_AUTH_TRUSTED} = 1;
    local $ENV{HTTP_X_REMOTE_USER}    = 'alice';
    local $ENV{HTTP_X_REMOTE_GROUPS}  = 'staff';
    capture( sub { main::reset_request_state() } );
    my ($who) = main::_scan_identity();
    is( $who, 'alice', 'request one scans as alice' );
}
request('/nothing-here');
my ($who2) = main::_scan_identity();
ok( !defined $who2 || $who2 eq '', 'request two, anonymous, does not scan as alice' )
    or diag( 'scanned as ' . ( $who2 // 'undef' ) );

done_testing();
