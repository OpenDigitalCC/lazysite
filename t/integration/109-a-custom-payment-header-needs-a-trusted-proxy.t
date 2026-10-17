#!/usr/bin/perl
# SM972: a custom payment header name is honoured only from a trusted proxy.
#
# payment_header_verified (and _payer) rename the headers the paid-content gate
# believes. The trust gate stripped only the fixed X-Payment-* names, so with a
# custom name configured and no auth_proxy_trusted, a visitor sending that
# header was served the paid body. SM960 closed the same hole for auth headers.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site run_processor site_tempdir);

sub site {
    my (%o) = @_;
    my $d = site_tempdir();
    setup_test_site($d);
    open my $p, '>', "$d/zz-paid.md" or die $!;
    print {$p} "---\ntitle: Paid\npayment: required\npayment_amount: 0.01\n---\n\nPAID-BODY-7731\n";
    close $p;
    open my $c, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} "\npayment_header_verified: Payment-Ok\n";
    print {$c} "auth_proxy_trusted: true\nauth_proxy_trusted_from: 127.0.0.1\n" if $o{proxy};
    close $c;
    return $d;
}

my $control = run_processor( site(), '/zz-paid' );
like( $control, qr/Status: 402/, 'the control: an unpaid request gets 402' );

my $spoof = run_processor( site(), '/zz-paid', HTTP_PAYMENT_OK => 1 );
like( $spoof, qr/Status: 402/, 'a visitor-sent custom payment header does not pass' )
    or diag( substr( $spoof, 0, 300 ) );
unlike( $spoof, qr/PAID-BODY-7731/, 'and the paid body is not served' );

my $proxy = run_processor( site( proxy => 1 ), '/zz-paid', HTTP_PAYMENT_OK => 1 );
unlike( $proxy, qr/Status: 402/, 'from a trusted proxy the custom header is honoured' )
    or diag( substr( $proxy, 0, 300 ) );
like( $proxy, qr/PAID-BODY-7731/, 'and the body is served' );

done_testing();
