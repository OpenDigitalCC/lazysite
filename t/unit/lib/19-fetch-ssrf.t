#!/usr/bin/perl
# SEC-2026-07 (H6): the remote fetch (Lazysite::Fetch) must reject SSRF both
# for the URL it is handed AND for any redirect target - LWP would otherwise
# follow a 302 into a private range (cloud metadata, loopback) unguarded.
use strict;
use warnings;
use Test::More;
use IO::Socket::INET;
use FindBin;
use lib "$FindBin::Bin/../../../lib";    # repo lib/ for Lazysite::Fetch
require Lazysite::Fetch;

# --- is_safe_url: the range guard (pure, no network) -----------------------
my %reject = (
    'loopback v4'   => 'http://127.0.0.1/',
    'loopback name' => 'http://localhost/',          # resolves to 127.0.0.1
    'rfc1918 10'    => 'http://10.0.0.5/',
    'rfc1918 172'   => 'http://172.16.9.9/',
    'rfc1918 192'   => 'http://192.168.1.1/',
    'link-local v4' => 'http://169.254.169.254/',    # cloud metadata
    'multicast'     => 'http://224.0.0.1/',
    'cgnat'         => 'http://100.64.0.1/',
    'unspecified'   => 'http://0.0.0.0/',
    'loopback v6'   => 'http://[::1]/',
    'link-local v6' => 'http://[fe80::1]/',
    'unique-local6' => 'http://[fc00::1]/',
);
for my $name ( sort keys %reject ) {
    ok( !Lazysite::Fetch::is_safe_url( $reject{$name} ),
        "is_safe_url rejects $name ($reject{$name})" );
}
ok( Lazysite::Fetch::is_safe_url('http://8.8.8.8/'),
    'is_safe_url permits a public address' );

# --- redirect guard: a 302 into a private range is not followed ------------
# The mock listens on loopback (which the real guard would reject), so scope
# an override that permits ONLY the mock host and rejects every other target -
# so the redirect into 169.254.x is refused by the same code path.
{
    no warnings qw(redefine once);
    *Lazysite::Fetch::is_safe_url = sub {
        return $_[0] =~ m{//127\.0\.0\.1[:/]} ? 1 : 0;
    };
}

my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1', LocalPort => 0,
    Proto     => 'tcp', Listen => 5, ReuseAddr => 1,
) or BAIL_OUT("cannot bind mock server: $!");
my $port = $server->sockport;

my $pid = fork();
BAIL_OUT("fork failed: $!") unless defined $pid;
if ( $pid == 0 ) {
    my $handled = 0;
    while ( $handled < 3 ) {
        my $client = $server->accept or last;
        my $req    = <$client> // '';
        while ( my $l = <$client> ) { last if $l =~ /\A\r?\n\z/ }
        my ($path) = $req =~ m{\A[A-Z]+\s+(\S+)};
        $path //= '/';
        if ( $path eq '/redirect-bad' ) {
            print $client "HTTP/1.0 302 Found\r\n"
                . "Location: http://169.254.169.254/pwned\r\n"
                . "Content-Length: 0\r\n\r\n";
        }
        elsif ( $path eq '/redirect-ok' ) {
            print $client "HTTP/1.0 302 Found\r\n"
                . "Location: http://127.0.0.1:$port/plain\r\n"
                . "Content-Length: 0\r\n\r\n";
        }
        else {
            my $body = "hello from mock\n";
            print $client "HTTP/1.0 200 OK\r\n"
                . "Content-Type: text/plain\r\n"
                . "Content-Length: " . length($body) . "\r\n\r\n" . $body;
        }
        close $client;
        $handled++;
    }
    close $server;
    exit 0;
}
close $server;
my $base = "http://127.0.0.1:$port";

is( Lazysite::Fetch::fetch_url("$base/redirect-bad"), undef,
    'redirect into a private range is refused (returns undef)' );
like( Lazysite::Fetch::fetch_url("$base/redirect-ok") // '', qr/hello from mock/,
    'a redirect to a permitted host is still followed' );

waitpid $pid, 0;
done_testing();
