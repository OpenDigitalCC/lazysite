#!/usr/bin/perl
# ADVERSARIAL / SSRF (SEC-2026-07, 0.8.1): domain-check (manage_domains) opens
# outbound TLS + HTTPS connections to a caller-influenced host. Without a guard a
# manage_domains delegate could point it at the server's own internal network -
# loopback, RFC1918, the cloud metadata endpoint (169.254.169.254), CGNAT, IPv6
# ULA/link-local - either directly (an IP-literal or 'localhost' host, both of
# which pass _valid_host) or via DNS rebinding (a public name resolving to an
# internal address). domain_check refuses the outbound probes unless EVERY
# resolved address is public. The resolve/tls/fetch hooks are injected, so this
# test never touches the network and proves the guard fires BEFORE any connect.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Domains qw(domain_check);

# Run domain_check with the host resolving to @ips; the tls/fetch hooks record
# whether they were EVER called (they must not be, under the guard).
sub run {
    my ( $host, @ips ) = @_;
    my %probed = ( tls => 0, fetch => 0 );
    my $r      = domain_check(
        $host,
        self_ips    => ['203.0.113.9'],
        instance_id => 'inst1',
        resolve     => sub { @ips },
        tls         => sub { $probed{tls}++;   { ok => 1, detail   => 'CONNECTED' } },
        fetch       => sub { $probed{fetch}++; { ok => 1, instance => 'inst1' } },
    );
    my %check = map { $_->{id} => $_ } @{ $r->{checks} };
    return ( $r, \%probed, \%check );
}

# --- every internal / reserved range is refused, with NO outbound connection ---
my %blocked = (
    'loopback v4'        => '127.0.0.1',
    'private 10/8'       => '10.0.0.5',
    'private 172.16/12'  => '172.16.5.5',
    'private 192.168'    => '192.168.1.1',
    'link-local/meta'    => '169.254.169.254',
    'CGNAT 100.64/10'    => '100.64.0.1',
    'unspecified'        => '0.0.0.0',
    'loopback v6'        => '::1',
    'ULA v6'             => 'fc00::1',
    'link-local v6'      => 'fe80::1',
    'v4-mapped loopback' => '::ffff:127.0.0.1',
);
for my $why ( sort keys %blocked ) {
    my ( $r, $probed, $check ) = run( 'target.example', $blocked{$why} );
    is( $check->{ssl}{pass}, 0, "refused ($why): ssl check fails" );
    like( $check->{ssl}{detail}, qr/SSRF guard|non-public/i, "  ... names the SSRF guard ($why)" );
    is( $check->{terminates}{pass}, 0, "  ... marker fetch refused ($why)" );
    is( $probed->{tls} + $probed->{fetch}, 0, "  ... NO outbound connection was attempted ($why)" );
}

# --- DNS rebinding: a mix of public + internal is refused (any internal blocks) -
{
    my ( $r, $probed, $check ) = run( 'rebind.example', '8.8.8.8', '10.1.2.3' );
    is( $check->{ssl}{pass}, 0, 'rebinding (public + internal) is refused' );
    is( $probed->{tls} + $probed->{fetch}, 0, 'no connection on a rebinding mix' );
}

# --- a genuinely public host IS probed (guard does not over-block) --------------
{
    my ( $r, $probed, $check ) = run( 'real.example', '93.184.216.34' );
    is( $probed->{tls},             1, 'public host: the TLS probe runs' );
    is( $probed->{fetch},           1, 'public host: the marker fetch runs' );
    is( $check->{ssl}{pass},        1, 'public host: ssl check reflects the probe' );
    is( $check->{terminates}{pass}, 1, 'public host: terminates check reflects the fetch' );
}

done_testing();
