#!/usr/bin/perl
# SM1016: domain_set refuses a group or account the site does not have.
#
# RULED by the release manager on 2026-10-12: "lazysite-domains.pl should
# reject invalid groups". The check is in domain_set, so the Domains page, the
# control API's domain-set, MCP domain_set and every lazysite-domains.pl
# command get it (t/integration/150 and t/tools/120-121 drive those surfaces;
# this is the engine).
#
# A misspelt group in allowed_groups admits nobody, and a misspelt account in
# locked_users locks nobody, each while the write reported success. Now:
#   - every unknown NEW name is named, and nothing is written;
#   - @name and name are the same group;
#   - a name the list already holds is not asked about, so a list naming a
#     deleted group can still be written - including to take it out;
#   - a store that cannot be read refuses the write, naming the store;
#   - an empty value still clears the list.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                 qw(site_tempdir);
use Lazysite::Manager::Domains qw(domain_add domain_set);

my $d = site_tempdir();
make_path("$d/lazysite/auth");

sub put {
    my ( $rel, $text ) = @_;
    open my $fh, '>', "$d/$rel" or die "$rel: $!";
    print {$fh} $text;
    close $fh;
}
put( 'lazysite/lazysite.conf',             "site_name: Agency\n" );
put( 'lazysite/auth/groups',               "staff: bob\neditors: alice\n" );
put( 'lazysite/auth/groups-settings.json', '{"reviewers":{}}' );
put( 'lazysite/auth/users',                "alice:x\nbob:x\n" );
$Lazysite::Manager::Domains::DOCROOT = $d;

sub conf { open my $fh, '<', "$d/lazysite/lazysite.conf" or return ''; local $/; return <$fh> }
sub line { my ($k) = @_; my ($v) = conf() =~ /^alias\.a\.example\.\Q$k\E: (.*)$/m; return $v }

ok( domain_add( 'a.example', content_root => 'sites/a' )->{ok}, 'a domain to set' );

# --- groups --------------------------------------------------------------------
{
    my $r = domain_set( 'a.example', 'allowed_groups', 'staff, @editors, reviewers' );
    ok( $r->{ok}, 'groups the site has are accepted, with or without @' ) or diag explain $r;
    is( line('allowed_groups'), 'staff, editors, reviewers', 'and stored as names' );

    my $before = conf();
    $r = domain_set( 'a.example', 'allowed_groups', 'staff, staf, @nosuch' );
    ok( !$r->{ok}, 'a list naming groups the site does not have is refused' );
    is( $r->{kind}, 'unknown-principals', 'as unknown principals' );
    like( $r->{error}, qr/No groups \@staf, \@nosuch on this site/, 'naming every one' );
    is_deeply( $r->{unknown}, [qw(staf nosuch)], 'and listing them' );
    is( conf(), $before, 'and nothing is written' );

    $r = domain_set( 'a.example', 'allowed_groups', 'staff, staf' );
    like( $r->{error}, qr/No group \@staf on this site/, 'one unknown group is named alone' );
}

# --- a group deleted after it was allowed ----------------------------------------
{
    put( 'lazysite/auth/groups',               "staff: bob\n" );    # editors is gone
    put( 'lazysite/auth/groups-settings.json', '{}' );              # and reviewers
    my $r = domain_set( 'a.example', 'allowed_groups', 'staff, editors' );
    ok( $r->{ok}, 'a name the list already holds is not asked about' ) or diag explain $r;
    $r = domain_set( 'a.example', 'allowed_groups', 'staff' );
    ok( $r->{ok}, 'so the deleted group can be taken out' );
    is( line('allowed_groups'), 'staff', 'leaving the rest' );
    $r = domain_set( 'a.example', 'allowed_groups', 'staff, editors' );
    ok( !$r->{ok}, 'and once out it cannot be put back' );
}

# --- accounts --------------------------------------------------------------------
{
    my $r = domain_set( 'a.example', 'locked_users', 'alice, bob' );
    ok( $r->{ok}, 'accounts the site has are accepted' );
    $r = domain_set( 'a.example', 'locked_users', 'alice, carol' );
    ok( !$r->{ok}, 'an account the site does not have is refused' );
    like( $r->{error}, qr/No account carol on this site/, 'naming it' );
    is( line('locked_users'), 'alice, bob', 'and nothing is written' );
}

# --- clearing ----------------------------------------------------------------------
{
    ok( domain_set( 'a.example', 'locked_users', '' )->{ok}, 'an empty value clears the list' );
    is( line('locked_users'), '', 'cleared' );
}

# --- a store that cannot be read ------------------------------------------------
SKIP: {
    skip 'root reads a mode-000 file', 3 if $> == 0;
    chmod 0000, "$d/lazysite/auth/groups" or die $!;
    my $before = conf();
    my $r      = domain_set( 'a.example', 'allowed_groups', 'staff, bob' );
    chmod 0644, "$d/lazysite/auth/groups";
    ok( !$r->{ok}, 'with the groups file unreadable, a new group is refused' );
    like( $r->{error}, qr/lazysite\/auth\/groups cannot be read/, 'naming the store' );
    is( conf(), $before, 'and nothing is written' );
}

done_testing();
