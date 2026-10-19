#!/usr/bin/perl
# SM1192: WHERE ADDRESS RULES ARE EDITED, THE MANAGER SAYS WHEN EVERY VISITOR IS
# THE PROXY. Field report (test plan 0.15.10, F-1): "edge sees every visitor as its
# front proxy ... `trusted_proxies` does not name the front end, so every address
# rule on edge (pages, groups, sign-in, manager) applies to everyone at once ...
# `lazysite check` warns, but the operator cannot run it from the manager."
#
# The server decides; the page only shows it, and it decides as the ENGINE does
# (request_address): absent and empty trusted_proxies mean the private-range default,
# only `none` trusts nothing. Both answers the address pages call (address-lists, and
# config-read) carry `proxy_warning` when the peer (REMOTE_ADDR, before any proxy
# rule) is private or loopback AND no forwarded visitor address is being believed:
#   (a) the peer is not in the effective trust set -> name the set, "Name the front
#       proxy in trusted_proxies"
#   (b) the peer IS trusted but no X-Forwarded-For arrives -> "rebuild its vhost"
# Silent for a public peer, and when a trusted peer forwards a visitor address.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Auth::Acl         ();
use Lazysite::Manager::AddressLists ();
use Lazysite::Manager::Config   ();

sub site {
    my ($conf) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} "site_name: T\n" . $conf;
    close $fh;
    open my $s, '>', "$d/lazysite/auth/address-lists.json" or die $!;
    print {$s} encode_json( { office => { kind => 'allow', entries => [ { cidr => '203.0.113.0/24', note => '' } ] } } );
    close $s;
    return $d;
}

# Both doors, as the manager API runs them for one request.
sub answers {
    my ( $conf, $peer, $xff ) = @_;
    my $d = site($conf);
    local $ENV{REMOTE_ADDR} = $peer;
    local $ENV{HTTP_X_FORWARDED_FOR};
    $ENV{HTTP_X_FORWARDED_FOR} = $xff if defined $xff;
    local $Lazysite::Auth::Acl::DOCROOT            = $d;
    local $Lazysite::Manager::Config::LAZYSITE_DIR = "$d/lazysite";
    my $al = Lazysite::Manager::AddressLists::address_lists( actor => 'sjm', operator => 1 );
    my $cr = Lazysite::Manager::Config::action_config_read();
    return ( $al, $cr );
}

my $FIRST = qr/\AEvery visitor reaches this site from 10\.2\.30\.177,/;
my $A     = qr/$FIRST which is not named in trusted_proxies \((.+?)\), so an address rule here applies to every visitor at once\. Name the front proxy in trusted_proxies\.\z/;
my $B     = qr/$FIRST a trusted proxy, but no visitor address arrives in X-Forwarded-For, so an address rule here applies to every visitor at once\. The front end does not send the visitor's address in X-Forwarded-For: rebuild its vhost \(lazysite templates since 0\.15\.2, SM929\)\.\z/;

# (b) edge as found: no trusted_proxies line (the private-range default trusts the
# front end) and the front end sends no X-Forwarded-For.
for my $case ( [ 'trusted_proxies absent', '' ], [ 'trusted_proxies empty', "trusted_proxies:\n" ],
    [ 'trusted_proxies naming the proxy, no header', "trusted_proxies: 10.2.30.177\n" ] )
{
    my ( $name, $conf ) = @{$case};
    my ( $al, $cr ) = answers( $conf, '10.2.30.177' );
    ok( $al->{ok}, "$name: address-lists answers" );
    like( $al->{proxy_warning} // '', $B, "$name: address-lists names cause (b)" );
    like( $cr->{proxy_warning} // '', $B, "$name: config-read names cause (b)" );
}

# (a) the peer is not in what the engine trusts.
for my $case ( [ 'trusted_proxies none', "trusted_proxies: none\n", 'none' ],
    [ 'trusted_proxies another range', "trusted_proxies: 192.0.2.0/24\n", '192.0.2.0/24' ] )
{
    my ( $name, $conf, $set ) = @{$case};
    my ( $al, $cr ) = answers( $conf, '10.2.30.177' );
    like( $al->{proxy_warning} // '', $A, "$name: address-lists names cause (a)" );
    like( $cr->{proxy_warning} // '', $A, "$name: config-read names cause (a)" );
    my ($got) = ( $al->{proxy_warning} // '' ) =~ $A;
    is( $got, $set, "$name: and names the set" );
}
{
    my ($al) = answers( "trusted_proxies: 192.0.2.1\n", '127.0.0.1' );
    like( $al->{proxy_warning} // '', qr/from 127\.0\.0\.1, which is not named/, 'a loopback peer is named too' );
}

# silent: the engine believes a forwarded visitor, or the peer is public/absent.
{
    my ( $al, $cr ) = answers( "trusted_proxies: 10.2.30.177\n", '10.2.30.177', '198.51.100.7' );
    ok( !exists $al->{proxy_warning} && !exists $cr->{proxy_warning}, 'a list naming the proxy plus X-Forwarded-For: silent' );
    ( $al, $cr ) = answers( '', '10.2.30.177', '198.51.100.7' );
    ok( !exists $al->{proxy_warning} && !exists $cr->{proxy_warning}, 'the default trust plus X-Forwarded-For: silent' );
    ( $al, $cr ) = answers( '', '203.0.113.9' );
    ok( !exists $al->{proxy_warning} && !exists $cr->{proxy_warning}, 'a public peer: silent' );
    ( $al, $cr ) = answers( "trusted_proxies: none\n", '203.0.113.9' );
    ok( !exists $al->{proxy_warning} && !exists $cr->{proxy_warning}, 'a public peer, nothing trusted: silent' );
    ( $al, $cr ) = answers( '', '' );
    ok( !exists $al->{proxy_warning} && !exists $cr->{proxy_warning}, 'no peer (a command line): silent' );
}

done_testing;
