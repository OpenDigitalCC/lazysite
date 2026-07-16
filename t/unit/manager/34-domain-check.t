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
use Lazysite::Manager::Domains qw(domain_check);

# --- everything configured --------------------------------------------------
{
    my $r = domain_check(
        'clienta.com',
        self_ip     => '203.0.113.5',
        instance_id => 'abc123',
        resolve     => sub { ('203.0.113.5') },
        tls         => sub { { ok => 1, detail => 'valid certificate' } },
        fetch       => sub { { ok => 1, instance => 'abc123' } },
    );
    is( $r->{ok},       1, 'check ran' );
    is( $r->{all_pass}, 1, 'all four checks pass' );
    is_deeply( [ map { $_->{id} } @{ $r->{checks} } ],
        [qw(dns host ssl terminates)], 'checks are in order' );
    is_deeply( [ map { $_->{pass} } @{ $r->{checks} } ],
        [ 1, 1, 1, 1 ], 'each check passes' );
}

# --- nothing configured (no DNS) --------------------------------------------
{
    my $r = domain_check(
        'new.invalid',
        self_ip     => '203.0.113.5',
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
        self_ip     => '203.0.113.5',
        instance_id => 'abc123',
        resolve     => sub { ('198.51.100.9') },
        tls         => sub { { ok => 1, detail => 'valid certificate' } },
        fetch       => sub { { ok => 1, instance => 'zzz999' } },
    );
    is( $r->{checks}[1]{pass}, 0, 'points-to-this-server fails (wrong IP)' );
    is( $r->{checks}[2]{pass}, 1, 'ssl is still valid' );
    is( $r->{checks}[3]{pass}, 0, 'terminates fails (different instance id)' );
    like( $r->{checks}[3]{detail}, qr/different server or instance/, 'terminates detail explains' );
}

# --- this server's own address unknown => host is indeterminate -------------
{
    my $r = domain_check(
        'other.com',
        instance_id => 'abc123',
        resolve     => sub { ('198.51.100.9') },
        tls         => sub { { ok => 1 } },
        fetch       => sub { { ok => 1, instance => 'abc123' } },
    );
    ok( !defined $r->{checks}[1]{pass}, 'host check is undef (indeterminate) with no self_ip' );
    is( $r->{all_pass}, 1, 'an indeterminate check does not fail the whole result' );
}

# --- an invalid host is rejected before any probe ---------------------------
{
    my $r = domain_check('not a host');
    ok( !$r->{ok}, 'an invalid host is rejected' );
    is( $r->{kind}, 'invalid', 'rejection is an invalid request' );
}

done_testing();
