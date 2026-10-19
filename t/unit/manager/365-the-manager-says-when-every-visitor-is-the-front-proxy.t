#!/usr/bin/perl
# SM1192: WHERE ADDRESS RULES ARE EDITED, THE MANAGER SAYS WHEN EVERY VISITOR IS
# THE PROXY. Field report (test plan 0.15.10, F-1): "edge sees every visitor as its
# front proxy ... `trusted_proxies` does not name the front end, so every address
# rule on edge (pages, groups, sign-in, manager) applies to everyone at once ...
# `lazysite check` warns, but the operator cannot run it from the manager."
#
# The server decides; the page only shows it. Both answers the address pages call
# (address-lists, which the Address lists and group editor pages read, and
# config-read, which the Config page reads) carry `proxy_warning` when
#   - the request's own peer address (REMOTE_ADDR, before any proxy rule) is private
#     or loopback, AND
#   - trusted_proxies is empty/absent or does not include that peer.
# Silent for a public peer, and silent when trusted_proxies names the peer.
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
    my ( $conf, $peer ) = @_;
    my $d = site($conf);
    local $ENV{REMOTE_ADDR} = $peer;
    delete local $ENV{HTTP_X_FORWARDED_FOR};
    local $Lazysite::Auth::Acl::DOCROOT         = $d;
    local $Lazysite::Manager::Config::LAZYSITE_DIR = "$d/lazysite";
    my $al = Lazysite::Manager::AddressLists::address_lists( actor => 'sjm', operator => 1 );
    my $cr = Lazysite::Manager::Config::action_config_read();
    return ( $al, $cr );
}

my $TEXT = qr/Every visitor reaches this site from 10\.2\.30\.177, which is not named in trusted_proxies, so an address rule here applies to every visitor at once\. Name the front proxy in trusted_proxies\./;

for my $case ( [ 'trusted_proxies absent', '' ], [ 'trusted_proxies empty', "trusted_proxies:\n" ],
    [ 'trusted_proxies another range', "trusted_proxies: 192.0.2.0/24\n" ], [ 'trusted_proxies none', "trusted_proxies: none\n" ] )
{
    my ( $name, $conf ) = @{$case};
    my ( $al, $cr ) = answers( $conf, '10.2.30.177' );
    ok( $al->{ok}, "$name: address-lists answers" );
    like( $al->{proxy_warning} // '', $TEXT, "$name: address-lists carries the warning" );
    like( $cr->{proxy_warning} // '', $TEXT, "$name: config-read carries the warning" );
}

{
    my ( $al, $cr ) = answers( "trusted_proxies: 10.2.30.177\n", '10.2.30.177' );
    ok( !exists $al->{proxy_warning}, 'trusted_proxies naming the peer: address-lists says nothing' );
    ok( !exists $cr->{proxy_warning}, 'trusted_proxies naming the peer: config-read says nothing' );
    ( $al, $cr ) = answers( "trusted_proxies: 10.0.0.0/8, 192.0.2.1\n", '10.2.30.177' );
    ok( !exists $al->{proxy_warning} && !exists $cr->{proxy_warning}, 'a range that holds the peer: silent' );
}

{
    my ( $al, $cr ) = answers( '', '203.0.113.9' );
    ok( !exists $al->{proxy_warning}, 'a public peer: address-lists says nothing' );
    ok( !exists $cr->{proxy_warning}, 'a public peer: config-read says nothing' );
}

{
    my ( $al, $cr ) = answers( '', '127.0.0.1' );
    like( $al->{proxy_warning} // '', qr/from 127\.0\.0\.1,/, 'a loopback peer is named too' );
    ( $al, $cr ) = answers( '', '' );
    ok( !exists $al->{proxy_warning} && !exists $cr->{proxy_warning}, 'no peer (a command line): silent' );
}

done_testing;
