#!/usr/bin/perl
# SM526: one answer to "is this address public?".
#
# Manager/Domains.pm carried two classifiers. _ip_is_public is the SSRF guard
# domain_check applies to every RESOLVED address before it connects.
# _is_public_ip was the filter instance_public_ips applied when deciding which
# addresses count as "this server" for the points-to-this-server check. They
# disagreed on 8 of 15 inputs (tmp/tl-probe-ip-twins.pl): CGNAT, multicast,
# 240/4, a malformed octet, the unspecified ::, fe90::/10 and the IPv4-mapped
# loopback and RFC1918 forms were all "public" to the second. So a mapped
# loopback in canonical_ip, or a proxy's CGNAT SERVER_ADDR, was handed to the
# check as an address of this install, and a domain pointing at nothing
# passed.
#
# The self-address filter now IS the guard: an address the guard would refuse
# to connect to can never be offered as this server.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use Lazysite::Manager::Domains qw(instance_public_ips);

# The eight inputs on which the two classifiers disagreed, each with the
# reason the guard refuses it.
my %refused = (
    '100.64.0.1'       => '100.64/10 CGNAT',
    '224.0.0.1'        => '224/4 multicast',
    '240.0.0.1'        => '240/4 reserved',
    '999.1.1.1'        => 'a malformed octet',
    '::'               => 'the unspecified address',
    'fe90::1'          => 'fe80::/10 link-local',
    '::ffff:127.0.0.1' => 'IPv4-mapped loopback',
    '::ffff:10.0.0.1'  => 'IPv4-mapped RFC1918',
);

subtest 'canonical_ip is filtered by the one classifier' => sub {
    for my $ip ( sort keys %refused ) {
        is_deeply( [ instance_public_ips( canonical_ip => $ip ) ], [],
            "$ip ($refused{$ip}) is never offered as this server" );
    }
    is_deeply( [ instance_public_ips( canonical_ip => '2.59.188.206' ) ],
        ['2.59.188.206'], 'a routable v4 address still is' );
    is_deeply( [ instance_public_ips( canonical_ip => '2001:db8::1' ) ],
        ['2001:db8::1'], 'and a global-unicast v6 address' );
};

subtest 'the SERVER_ADDR fallback is filtered the same way' => sub {
    for my $ip ( '100.64.0.1', '::ffff:127.0.0.1' ) {
        is_deeply( [ instance_public_ips( fallback_ip => $ip ) ], [],
            "a proxy's $ip is not taken for the public address" );
    }
    is_deeply( [ instance_public_ips( fallback_ip => '203.0.113.9' ) ],
        ['203.0.113.9'], 'a public SERVER_ADDR still is' );
};

subtest 'the module holds one classifier' => sub {
    ok( !Lazysite::Manager::Domains->can('_is_public_ip'),
        'the second classifier, _is_public_ip, is gone' )
        or diag( 'Two answers to the same question drifted apart once (SM526). '
            . 'One sub is how they stop drifting.' );
    ok( Lazysite::Manager::Domains->can('_ip_is_public'),
        'the SSRF guard, _ip_is_public, is the one that remains' );
};

done_testing();
