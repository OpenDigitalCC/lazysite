#!/usr/bin/perl
# P16 (WORK-PLAN-0154, ruled 2026-10-12 "Add allow-lists"): what a CSP
# allow-list may name has one answer.
#
# Lazysite::SecurityHeaders::csp_origin_ok decides it for `lazysite check` and
# the module's policy; the processor, which loads no modules (ADR 0001), carries
# _csp_origin_ok and applies it to every page. This runs both over the same
# texts - the origins the ruling allows and the shapes it names as refused
# ('unsafe-*', a bare *, anything but scheme + host[:port]) - and requires the
# same answer, and the ruling's answer.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                qw(load_processor setup_minimal_site site_tempdir);
use Lazysite::SecurityHeaders ();

my $d = site_tempdir();
setup_minimal_site($d);
load_processor($d);

my @OK = qw(
    https://perl-ads.perlhacks.com https://example.com https://EXAMPLE.com
    https://*.example.com https://cdn.example.com:8443 https://a-b.c-d.example
);
my @REFUSED = (
    '*', 'https:', 'https://', 'http://example.com', "'self'", "'unsafe-inline'", "'unsafe-eval'",
    "'strict-dynamic'", "'sha256-abc='", "'nonce-abc'", 'https://example.com/', 'https://example.com/path',
    'https://*', 'https://*.com', 'https://localhost', 'https://*.*.example.com', 'https://ex ample.com',
    'https://example.com:0', 'https://example.com:123456', 'https://-x.example.com', 'example.com',
    'https://example.com?x', 'https://user@example.com', 'data:', 'blob:', 'wss://example.com', '',
    "https://example.com\n", 'https://example.com;script-src *',
);

for my $o (@OK) {
    ok( Lazysite::SecurityHeaders::csp_origin_ok($o), "module allows $o" );
    ok( main::_csp_origin_ok($o),                     "processor allows $o" );
}
for my $o (@REFUSED) {
    ( my $show = $o ) =~ s/\n/\\n/g;
    ok( !Lazysite::SecurityHeaders::csp_origin_ok($o), "module refuses '$show'" );
    ok( !main::_csp_origin_ok($o),                     "processor refuses '$show'" );
}

subtest 'the two policies agree with the same allow-lists' => sub {
    my %allow = ( script => ['https://ads.example.com'], connect => [ 'https://ads.example.com', '*' ],
        img => ['https://*.img.example.com'], frame => ['https://video.example.com:8443'] );
    my $mod = Lazysite::SecurityHeaders::content_security_policy( script_hashes => ["'sha256-x'"], allow => \%allow );
    my $proc = main::_content_security_policy( ["'sha256-x'"], \%allow );
    is( $proc, $mod, 'byte for byte' );
    like( $mod, qr/script-src 'self' https:\/\/ads\.example\.com 'sha256-x'\z/, 'script-src: the origin, then the hashes' );
    like( $mod, qr/connect-src 'self' https:\/\/ads\.example\.com;/, 'connect-src: the origin, and not the bare *' );
    is( main::_content_security_policy( [] ), Lazysite::SecurityHeaders::content_security_policy(),
        'and with none, the default unchanged' );
};

done_testing();
