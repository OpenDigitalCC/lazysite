#!/usr/bin/perl
# SM154 (P2): the domain engine (Lazysite::Manager::Domains) - the single logic
# behind the manager domain-* actions and the lazysite-domains CLI. Registers /
# lists / configures / removes a domain as alias_hosts + alias.<host>.<key> in
# lazysite.conf plus a content-root directory, with strict host/content-root
# validation. Never touches DNS/vhost/TLS (out of scope by design).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Domains qw(domains_list domain_add domain_remove domain_set);

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: Agency\nsite_url: https://agency.example\ntheme: base\n";
close $cf;
$Lazysite::Manager::Domains::DOCROOT = $d;

sub conf { open my $fh, '<', "$d/lazysite/lazysite.conf" or return ''; local $/; <$fh> }

# --- add: writes alias keys + alias_hosts, provisions + seeds the content root
{
    my $r = domain_add( 'clienta.com',
        content_root => 'sites/clienta', site_url => 'https://clienta.com', seed => 1 );
    ok( $r->{ok}, 'add clienta.com' ) or diag explain $r;
    is( $r->{content_root}, 'sites/clienta', 'returns the cleaned content root' );
    like( conf(), qr/^alias\.clienta\.com\.content_root: sites\/clienta$/m, 'content_root line written' );
    like( conf(), qr/^alias\.clienta\.com\.site_url: https:\/\/clienta\.com$/m, 'site_url override written' );
    like( conf(), qr/^alias_hosts: clienta\.com$/m, 'host added to alias_hosts' );
    ok( -d "$d/sites/clienta",          'content root directory created' );
    ok( -f "$d/sites/clienta/index.md", 'content root seeded with index.md' );
}

# --- a second domain appends to alias_hosts ---------------------------------
{
    my $r = domain_add( 'clientb.com', content_root => 'sites/clientb' );
    ok( $r->{ok}, 'add clientb.com' );
    like( conf(), qr/^alias_hosts: clienta\.com,clientb\.com$/m, 'alias_hosts appended in order' );
}

# --- list: primary + aliases, inheritance surfaced --------------------------
{
    my $r = domains_list();
    ok( $r->{ok}, 'list ok' );
    my %by = map { $_->{host} => $_ } @{ $r->{domains} };
    ok( $by{'(default)'}{is_primary}, 'primary row present' );
    is( $by{'clienta.com'}{content_root}, 'sites/clienta', 'clienta content_root' );
    is( $by{'clienta.com'}{site_url}, 'https://clienta.com', 'clienta has its own site_url' );
    is( $by{'clientb.com'}{site_url}, 'https://agency.example', 'clientb inherits base site_url' );
    is( $by{'clientb.com'}{site_url_inherited}, 1,              'inheritance flagged' );
}

# --- set: override a presentation key ---------------------------------------
{
    my $r = domain_set( 'clientb.com', 'theme', 'ocean' );
    ok( $r->{ok}, 'set clientb theme' );
    like( conf(), qr/^alias\.clientb\.com\.theme: ocean$/m, 'theme override written' );
    my $bad = domain_set( 'clientb.com', 'evil_key', 'x' );
    ok( !$bad->{ok}, 'set rejects an unknown key' );
    my $nf = domain_set( 'nope.com', 'theme', 'x' );
    ok( !$nf->{ok}, 'set rejects an unregistered host' );
}

# --- validation: host + content_root ----------------------------------------
{
    ok( !domain_add( 'a/../b', content_root => 'x' )->{ok}, 'reject traversal host' );
    my $up = domain_add( 'UP.example', content_root => 'sites/up' );
    ok( $up->{ok} && $up->{host} eq 'up.example', 'a mixed-case host is accepted, lowercased' );
    ok( !domain_add( 'ok.com', content_root => '../escape' )->{ok}, 'reject traversal content_root' );
    ok( !domain_add( 'ok.com', content_root => 'lazysite/auth' )->{ok}, 'reject lazysite/ content_root' );
    ok( !domain_add( 'clienta.com', content_root => 'sites/x' )->{ok}, 'reject duplicate host' );
}

# --- remove: unregister, keep content by default ----------------------------
{
    my $r = domain_remove('clienta.com');
    ok( $r->{ok}, 'remove clienta.com' );
    is( $r->{purged}, 0, 'content kept by default' );
    unlike( conf(), qr/^alias\.clienta\.com\./m, 'alias lines stripped' );
    like( conf(), qr/^alias_hosts: clientb\.com/m, 'host dropped from alias_hosts' );
    ok( -d "$d/sites/clienta", 'content directory left in place' );
}

# --- remove --purge also removes the content tree ---------------------------
{
    my $r = domain_remove( 'clientb.com', purge => 1 );
    ok( $r->{ok}, 'remove clientb.com --purge' );
    is( $r->{purged}, 1, 'content purged' );
    ok( !-d "$d/sites/clientb", 'content directory removed on purge' );
}

done_testing();
