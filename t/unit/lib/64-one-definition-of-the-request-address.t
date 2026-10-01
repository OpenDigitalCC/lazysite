#!/usr/bin/perl
# SM929: ONE DEFINITION OF THE REQUEST ADDRESS, and the forgery it has to refuse.
#
# Behind a front proxy every reader of REMOTE_ADDR saw the PROXY - one constant for
# every visitor a site will ever have. The one reader that did consult the
# forwarded header took its FIRST hop and trusted it blindly, which was measured on
# a live site 2026-10-01: `X-Forwarded-For: 203.0.113.7` made the page say
# 203.0.113.7. So this helper has two jobs that pull in opposite directions - find
# the real client behind a proxy we trust, and refuse an address a caller invented.
#
# EVERY CASE BELOW IS ONE DECISION, and the two that matter most are:
#   - a caller who forges the header THROUGH a trusted proxy gets the address the
#     proxy appended, not the one they chose (that is why the walk is rightmost
#     rather than first);
#   - a caller who forges it on a DIRECTLY-served site is ignored entirely, because
#     the peer is not in the trust set.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(site_tempdir);
use Lazysite::Util qw(request_address trusted_proxy_spec parse_trusted_proxies);

# The helper reads the environment, so each case sets it and nothing else.
sub addr {
    my ( $peer, $forwarded, $spec ) = @_;
    local $ENV{REMOTE_ADDR}          = $peer;
    local $ENV{HTTP_X_FORWARDED_FOR} = $forwarded;
    delete local $ENV{HTTP_X_FORWARDED_FOR} unless defined $forwarded;
    return request_address($spec);
}

my $RFC1918 = undef;    # the absent setting - the shipped default

# --- with no forwarded header, nothing changes for anybody -------------------
# The compatibility property, and it is the reason this change is safe to make in
# forty-four places at once: every one of them reads what it read before.
is( addr( '198.51.100.9', undef, $RFC1918 ),
    '198.51.100.9', 'no header, public peer: the peer, verbatim' );
is( addr( '10.2.30.177', undef, $RFC1918 ),
    '10.2.30.177', 'no header, trusted peer: still the peer' );
is( addr( '', undef, $RFC1918 ), '', 'no peer at all: empty, not a lie' );

# --- the proxy case the filing was raised about ------------------------------
is( addr( '10.2.30.177', '198.51.100.9', $RFC1918 ),
    '198.51.100.9', 'trusted proxy, one hop: the visitor, not the proxy' );
is( addr( '10.2.30.177', '198.51.100.9, 10.1.1.1', $RFC1918 ),
    '198.51.100.9', 'two proxies in the path: the hop neither of them contributed' );

# --- THE FORGERY, which the filing's own recommendation would have believed --
is( addr( '10.2.30.177', '203.0.113.7, 198.51.100.9', $RFC1918 ),
    '198.51.100.9',
    'a caller who forges the header through a trusted proxy gets the REAL address' );
isnt( addr( '10.2.30.177', '203.0.113.7, 198.51.100.9', $RFC1918 ),
    '203.0.113.7', 'and specifically NOT the address they chose' );
is( addr( '198.51.100.9', '203.0.113.7', $RFC1918 ),
    '198.51.100.9',
    'on a directly-served site the header is ignored: the peer is not trusted' );

# A hop that is not an address ENDS the walk. Stepping over it would move further
# left, which is the part of the chain the caller controls.
is( addr( '10.2.30.177', '203.0.113.7, nonsense', $RFC1918 ),
    '10.2.30.177', 'an unreadable hop ends the walk at the peer' );
is( addr( '10.2.30.177', '203.0.113.7, 1.2.3.4:5678', $RFC1918 ),
    '10.2.30.177', 'and so does a hop carrying a port' );
is( addr( '10.2.30.177', '', $RFC1918 ),
    '10.2.30.177', 'an empty header is not a hop' );

# --- the four states of the setting ------------------------------------------
is( addr( '10.2.30.177', '198.51.100.9', undef ),
    '198.51.100.9', 'ABSENT: the RFC1918 default trusts a 10/8 peer' );
# EMPTY IS THE DEFAULT, NOT "OFF", and that is a decision rather than a shrug: the
# Config page ships the field empty and pressing Save writes an empty value, so
# reading empty as "trust nothing" would silently undo the feature for any site
# whose operator merely saved the page.
is( addr( '10.2.30.177', '198.51.100.9', '' ),
    '198.51.100.9', 'EMPTY: the default, because Save writes empty' );
is( addr( '10.2.30.177', '198.51.100.9', '   ' ),
    '198.51.100.9', 'and whitespace is empty' );
is( addr( '10.2.30.177', '198.51.100.9', 'none' ),
    '10.2.30.177', 'NONE: the one way to say trust nothing, said out loud' );
is( addr( '10.2.30.177', '198.51.100.9', 'NONE' ),
    '10.2.30.177', 'spelt any case' );
is( addr( '192.0.2.5', '198.51.100.9', '192.0.2.0/24' ),
    '198.51.100.9', 'A LIST: a named range outside the private ones is honoured' );

# --- range arithmetic, where an off-by-one range is a silent trust failure ---
is( addr( '172.16.0.1', '198.51.100.9', $RFC1918 ),
    '198.51.100.9', '172.16/12 contains 172.16.0.1' );
is( addr( '172.31.255.254', '198.51.100.9', $RFC1918 ),
    '198.51.100.9', 'and 172.31.255.254, its last address' );
is( addr( '172.32.0.1', '198.51.100.9', $RFC1918 ),
    '172.32.0.1', 'but NOT 172.32.0.1 - the range ends where RFC1918 says' );
is( addr( '192.168.255.255', '198.51.100.9', $RFC1918 ),
    '198.51.100.9', '192.168/16 reaches its last address' );
is( addr( '192.169.0.1', '198.51.100.9', $RFC1918 ),
    '192.169.0.1', 'and stops there' );
is( addr( '127.0.0.1', '198.51.100.9', $RFC1918 ),
    '127.0.0.1',
    'LOOPBACK IS NOT IN THE DEFAULT: a same-host front end must be named' );

# A bare address with no prefix length means that address and no other.
is( addr( '10.9.9.9', '198.51.100.9', '10.9.9.9' ),
    '198.51.100.9', 'a bare address in the list trusts exactly it' );
is( addr( '10.9.9.10', '198.51.100.9', '10.9.9.9' ),
    '10.9.9.10', 'and not its neighbour' );

# --- IPv6 -------------------------------------------------------------------
is( addr( 'fd00::1', '2001:db8::5', 'fc00::/7' ),
    '2001:db8::5', 'an IPv6 proxy in a named ULA range' );
is( addr( 'fd00::1', '2001:DB8::5', 'fc00::/7' ),
    '2001:db8::5', 'and the answer has ONE spelling, whatever the hop looked like' );
is( addr( 'fd00::1', '198.51.100.9', 'fc00::/7' ),
    '198.51.100.9', 'an IPv4 visitor through an IPv6 proxy' );
is( addr( 'fd00::1', '2001:db8::5', '10.0.0.0/8' ),
    'fd00::1', 'an IPv4 range never contains an IPv6 peer' );
is( addr( '10.0.0.1', '2001:db8::5', 'fc00::/7' ),
    '10.0.0.1', 'nor the reverse' );

# --- what the parser refuses, and says it refuses ---------------------------
{
    my ( $set, $bad ) = parse_trusted_proxies('10.0.0.0/8, notanaddress, 192.168.0.0/16');
    is( scalar @{$set}, 2, 'two usable ranges' );
    is_deeply( $bad, ['notanaddress'], 'and the typo is NAMED, not silently dropped' );
}
{
    # /0 matches every peer, which makes the trust check vacuous - the exact fault
    # this change removes. Refused rather than honoured.
    my ( $set, $bad ) = parse_trusted_proxies('0.0.0.0/0');
    is_deeply( $set, [],            'a zero-length prefix buys no trust' );
    is_deeply( $bad, ['0.0.0.0/0'], 'and is reported as refused' );
    is( addr( '198.51.100.9', '203.0.113.7', '0.0.0.0/0' ),
        '198.51.100.9', 'so trust-everything cannot be spelt as a range' );
}
{
    my ( $set, $bad ) = parse_trusted_proxies('10.0.0.0/33');
    is_deeply( $bad, ['10.0.0.0/33'], 'a prefix wider than the family is refused' );
}

# --- the setting is read from the site conf, and absent differs from empty ---
{
    my $dir = site_tempdir();
    is( trusted_proxy_spec($dir), undef, 'no conf file at all: absent' );

    open my $fh, '>', "$dir/lazysite.conf" or die $!;
    print {$fh} "site_name: T\n";
    close $fh;
    is( trusted_proxy_spec($dir), undef, 'conf without the key: absent -> the default' );

    open my $fh2, '>', "$dir/lazysite.conf" or die $!;
    print {$fh2} "site_name: T\ntrusted_proxies:\n";
    close $fh2;
    is( trusted_proxy_spec($dir), '',
        'conf with an EMPTY value: present and empty, which means trust nothing' );

    open my $fh3, '>', "$dir/lazysite.conf" or die $!;
    print {$fh3} "site_name: T\ntrusted_proxies: 10.0.0.0/8, 192.0.2.1\n";
    close $fh3;
    is( trusted_proxy_spec($dir), '10.0.0.0/8, 192.0.2.1', 'and a list comes back whole' );
}

done_testing();
