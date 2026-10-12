#!/usr/bin/perl
# SM1014: a group named @name is accepted where a group is written, and listed
# @name where it is shown beside people - storage unchanged.
#
# The manager offers a group as @name on every page (t/unit/manager/282). Two
# server-side surfaces follow:
#
#   - domain_set allowed_groups (the manager, the MCP domain_set tool, the
#     control API and lazysite-domains.pl all write through it) takes each
#     group with or without its @ and STORES the plain name, which is what
#     DomainAccess compares with the groups file. locked_users names accounts,
#     so an @ there is still refused.
#   - `lazysite-users.pl groups` lists a member that is itself a group as
#     @name, as the Groups page does; the groups file keeps the plain name.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                 qw(repo_root site_tempdir);
use Lazysite::Manager::Domains qw(domain_add domain_set);

my $d = site_tempdir();
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: Agency\nsite_url: https://agency.example\n";
close $cf;
$Lazysite::Manager::Domains::DOCROOT = $d;
# SM1016: a group allowed_groups names must exist.
open my $g0, '>', "$d/lazysite/auth/groups" or die $!;
print {$g0} "editors: alice, staff\nstaff: bob\n";
close $g0;

sub conf { open my $fh, '<', "$d/lazysite/lazysite.conf" or return ''; local $/; return <$fh> }

ok( domain_add( 'clienta.example', content_root => 'sites/clienta' )->{ok}, 'a domain to set' );

# --- allowed_groups ----------------------------------------------------------
{
    my $r = domain_set( 'clienta.example', 'allowed_groups', '@staff, editors, @staff' );
    ok( $r->{ok}, 'allowed_groups takes @staff and editors' ) or diag explain $r;
    is( $r->{value}, 'staff, editors', 'and returns the names it stored, once each' );
    like( conf(), qr/^alias\.clienta\.example\.allowed_groups: staff, editors$/m,
        'lazysite.conf holds the plain names' );
}
{
    my $r = domain_set( 'clienta.example', 'allowed_groups', '@@staff' );
    ok( !$r->{ok}, 'one @ comes off; a second is not part of any name' );
}

# --- locked_users -------------------------------------------------------------
{
    my $r = domain_set( 'clienta.example', 'locked_users', '@alice' );
    ok( !$r->{ok}, 'an @ is refused where the list names accounts' );
    like( $r->{error} // '', qr/Invalid name in locked_users: \@alice/, 'naming what it refused' );
}

# --- the users CLI lists a nested group as @name ----------------------------
{
    open my $gf, '>', "$d/lazysite/auth/groups" or die $!;
    print {$gf} "editors: alice, staff\nstaff: bob\n";
    close $gf;
    my $tool = repo_root() . '/tools/lazysite-users.pl';
    my $cmd  = join ' ', map { quotemeta } $^X, $tool, '--docroot', $d, 'groups';
    my $out  = `$cmd 2>&1`;
    like( $out, qr/^editors:\s+alice, \@staff\b/m, 'a member that is a group is listed @staff' );
    like( $out, qr/^staff:\s+bob\b/m,              'a person is listed by name' );
    open $gf, '<', "$d/lazysite/auth/groups" or die $!;
    my $kept = do { local $/; <$gf> };
    like( $kept, qr/^editors: alice, staff$/m, 'the groups file keeps the plain name' );
}

done_testing();
