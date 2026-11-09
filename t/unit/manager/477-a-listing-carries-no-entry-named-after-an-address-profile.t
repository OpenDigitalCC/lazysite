#!/usr/bin/perl
# SM1404 (triage T-93): A LISTING CARRIES NO ENTRY NAMED AFTER A RULE'S ADDRESS
# PROFILE. On 0.16.6 an operator's `list_files /zz78-addr` showed, beside the
# page, an entry named after the folder rule's profile (`zz78-allow`) with no
# type. What wrote it: SM1139's `address_profiles => [ { name } ]`, the
# permissions editor's picker choices, returned on EVERY listing answer by
# Manager::Files::action_list - so over MCP a list of nameless `{ name }` rows
# sat next to `entries`. SM1404 kept them on the manager API's listing alone; n785
# (T-113) takes them off every listing - the operator's door showed the same row -
# and the Files page reads them with the principals (t/unit/manager/532).
#
# Reverted, the first subtest fails: the bare listing carries the profile.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
my $d    = site_tempdir();
make_path( "$d/lazysite/auth", "$d/zz78-addr" );
sub spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh }
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$d/zz78-addr/page.md",      "---\ntitle: P\n---\nhello\n" );
spit( "$d/lazysite/auth/users",    "boss:x\n" );
spit( "$d/lazysite/auth/address-profiles.json",
    encode_json( { 'zz78-allow' => { entries => [ { cidr => '192.0.2.0/24', note => 'office' } ] } } ) );
spit( "$d/lazysite/auth/acls.json", encode_json( { 'zz78-addr' => { owner => 'boss', addresses => ['zz78-allow'] } } ) );

BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
{
    local $ENV{DOCUMENT_ROOT} = $d;
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}
no warnings 'once';
$Lazysite::Manager::Common::auth_user = 'boss';

subtest 'the listing as MCP list_files asks for it: the page, and nothing named after the profile' => sub {
    my $r = Lazysite::Manager::Files::action_list('/zz78-addr');
    ok( $r->{ok}, 'listed' ) or diag explain $r;
    is_deeply( [ map { $_->{name} } @{ $r->{entries} } ], ['page.md'], 'one entry, the page' );
    ok( !exists $r->{address_profiles}, 'no address_profiles list beside the entries' )
        or diag explain $r;
    my $json = encode_json($r);
    unlike( $json, qr/zz78-allow/, 'the profile\'s name is nowhere in the answer' );
    is( $r->{entries}[0]{governed_by}, 'zz78-addr', 'the entry still says which rule governs it' );
};

subtest 'the choices come with the principals, for the permissions editor' => sub {
    my $r = Lazysite::Manager::Users::action_principals();
    is_deeply( $r->{address_profiles}, [ { name => 'zz78-allow' } ], 'the choices, for the permissions editor' );
};

subtest 'neither the manager API nor MCP list_files asks a listing for pickers' => sub {
    open my $ah, '<', "$root/lazysite-manager-api.pl" or die $!;
    my $api = do { local $/; <$ah> };
    close $ah;
    unlike( $api, qr/action_list\([^)]*pickers/, 'the API\'s list branch passes no pickers' );
    open my $mh, '<', "$root/lazysite-mcp.pl" or die $!;
    my $mcp = do { local $/; <$mh> };
    close $mh;
    my ($tool) = $mcp =~ /list_files => \{(.*?)\n    \},/s;
    ok( defined $tool, 'the list_files tool is found' );
    unlike( $tool // '', qr/pickers/, 'and it never asks for the pickers' );
    open my $fh, '<', "$root/starter/manager/files.md" or die $!;
    my $page = do { local $/; <$fh> };
    close $fh;
    like( $page, qr/ADDRESS_PROFILES = d\.address_profiles/, 'the Files page reads the choices with the principals' );
};

done_testing;
