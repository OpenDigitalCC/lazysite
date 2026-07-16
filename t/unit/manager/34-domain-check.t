#!/usr/bin/perl
# SM156: domain_check() runs four ordered checks (dns -> host -> ssl ->
# terminates) and reports each as pass 1 / 0 / undef. The network operations are
# injected here (resolve/tls/fetch code-refs) so every branch is exercised with
# no DNS, TLS or HTTP - deterministic and offline.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";        # t/lib (TestHelper, if needed)
use lib "$FindBin::Bin/../../../lib";     # repo lib (Lazysite::*)
use Lazysite::Manager::Domains qw(domain_check instance_public_ips);

# --- everything configured (self_ips list, one matches) ---------------------
{
    my $r = domain_check(
        'clienta.com',
        self_ips    => [ '203.0.113.5', '2606:4700::1' ],
        instance_id => 'abc123',
        resolve     => sub { ( '2606:4700::1', '203.0.113.5' ) },
        tls         => sub { { ok => 1, detail => 'valid certificate' } },
        fetch       => sub { { ok => 1, instance => 'abc123' } },
    );
    is( $r->{ok},       1, 'check ran' );
    is( $r->{all_pass}, 1, 'all four checks pass' );
    is_deeply( [ map { $_->{id} } @{ $r->{checks} } ],
        [qw(dns host ssl terminates)], 'checks are in order' );
    is_deeply( [ map { $_->{pass} } @{ $r->{checks} } ],
        [ 1, 1, 1, 1 ], 'each check passes' );
    like( $r->{checks}[1]{detail}, qr/points here \((?:203\.0\.113\.5|2606:4700::1)\)/, 'host names the matched IP' );
}

# --- legacy scalar self_ip still accepted -----------------------------------
{
    my $r = domain_check(
        'clienta.com',
        self_ip     => '203.0.113.5',
        instance_id => 'abc',
        resolve     => sub { ('203.0.113.5') },
        tls         => sub { { ok => 1 } },
        fetch       => sub { { ok => 1, instance => 'abc' } },
    );
    is( $r->{checks}[1]{pass}, 1, 'scalar self_ip still drives the host check' );
}

# --- nothing configured (no DNS) --------------------------------------------
{
    my $r = domain_check(
        'new.invalid',
        self_ips    => ['203.0.113.5'],
        instance_id => 'abc123',
        resolve     => sub { () },
        tls         => sub { { ok => 0, detail => 'no trusted HTTPS' } },
        fetch       => sub { { ok => 0, detail => 'network error' } },
    );
    is( $r->{all_pass},         0, 'unconfigured domain fails overall' );
    is( $r->{checks}[0]{pass},  0, 'dns fails' );
    is( $r->{checks}[1]{pass},  0, 'host check skipped-as-fail without dns' );
    like( $r->{checks}[1]{detail}, qr/does not resolve/, 'host detail explains the skip' );
}

# --- resolves elsewhere + a different instance answers ----------------------
{
    my $r = domain_check(
        'other.com',
        self_ips    => ['203.0.113.5'],
        instance_id => 'abc123',
        resolve     => sub { ('198.51.100.9') },
        tls         => sub { { ok => 1, detail => 'valid certificate' } },
        fetch       => sub { { ok => 1, instance => 'zzz999' } },
    );
    is( $r->{checks}[1]{pass}, 0, 'points-to-this-server fails (wrong IP)' );
    like( $r->{checks}[1]{detail}, qr/not this server/, 'host detail explains the mismatch' );
    is( $r->{checks}[2]{pass}, 1, 'ssl is still valid' );
    is( $r->{checks}[3]{pass}, 0, 'terminates fails (different instance id)' );
    like( $r->{checks}[3]{detail}, qr/different server or instance/, 'terminates detail explains' );
}

# --- a certificate that doesn't cover the host is a distinct SSL result ------
# (_tls_probe returns kind=cert-mismatch with a "add this host to the cert"
# detail; domain_check surfaces it as a failed ssl check.)
{
    my $r = domain_check(
        'sub.clienta.com',
        self_ips    => ['203.0.113.5'],
        instance_id => 'abc',
        resolve     => sub { ('203.0.113.5') },
        tls         => sub {
            { ok => 0, kind => 'cert-mismatch',
                detail => 'a certificate is served (for clienta.com) but it does not '
                    . 'cover this host - add this host to the certificate (e.g. via Hestia SSL)' };
        },
        fetch => sub { { ok => 1, instance => 'abc' } },
    );
    is( $r->{checks}[2]{pass}, 0, 'ssl fails when the cert does not cover the host' );
    like( $r->{checks}[2]{detail}, qr/does not cover this host/,
        'ssl detail explains the coverage gap (points at the cert / Hestia SSL)' );
    is( $r->{all_pass}, 0, 'a cert coverage gap keeps the domain not-ready' );
}

# --- our public address unknown (proxy/NAT) => host indeterminate -----------
{
    my $r = domain_check(
        'other.com',
        self_ips    => [],                # nothing discovered
        instance_id => 'abc123',
        resolve     => sub { ('198.51.100.9') },
        tls         => sub { { ok => 1 } },
        fetch       => sub { { ok => 1, instance => 'abc123' } },
    );
    ok( !defined $r->{checks}[1]{pass}, 'host check is undef (indeterminate) with no known self IP' );
    like( $r->{checks}[1]{detail}, qr/canonical_ip/, 'host detail points at the canonical_ip config' );
    is( $r->{all_pass}, 1, 'an indeterminate check does not fail the whole result' );
}

# --- self-discovery: instance_public_ips (no network for these branches) ----
{
    is_deeply( [ instance_public_ips( canonical_ip => '2.59.188.206' ) ],
        ['2.59.188.206'], 'explicit public canonical_ip is used' );
    is_deeply( [ instance_public_ips( canonical_ip => '10.2.30.177' ) ],
        [], 'a private canonical_ip is rejected (not a public address)' );
    is_deeply( [ instance_public_ips( fallback_ip => '203.0.113.9' ) ],
        ['203.0.113.9'], 'a public SERVER_ADDR fallback is used' );
    is_deeply( [ instance_public_ips( fallback_ip => '10.2.30.177' ) ],
        [], 'a private SERVER_ADDR (behind a proxy) is not used' );
    is_deeply( [ instance_public_ips() ], [], 'nothing discovered => empty (indeterminate)' );
}

# --- an invalid host is rejected before any probe ---------------------------
{
    my $r = domain_check('not a host');
    ok( !$r->{ok}, 'an invalid host is rejected' );
    is( $r->{kind}, 'invalid', 'rejection is an invalid request' );
}

# --- graceful degradation when a TLS module is absent (0.7.20) ---------------
# Force `require IO::Socket::SSL` to fail even though it is installed, by hiding
# it from %INC and refusing it in @INC, then confirm the probe degrades to a
# clean {ok=>0} result instead of dying.
{
    local %INC = %INC;
    delete $INC{'IO/Socket/SSL.pm'};
    local @INC = ( sub { $_[1] eq 'IO/Socket/SSL.pm' ? die "blocked for test\n" : () }, @INC );
    my $r = Lazysite::Manager::Domains::_tls_probe( 'example.com', 1 );
    is( $r->{ok}, 0, 'TLS probe degrades (no crash) when IO::Socket::SSL is absent' );
    like( $r->{detail}, qr/unavailable/, 'TLS probe reports the module is unavailable' );
}

done_testing();
