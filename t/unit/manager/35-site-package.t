#!/usr/bin/perl
# SM158: Lazysite::Manager::SitePackage::package_create - package one domain's
# SITE (content root + nav override + bundled theme/layout + manifest) into a
# portable tar.gz alongside the backups. Excludes plugins/settings/secrets.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::SitePackage qw(package_create);

# --- fixture: an agency instance with a client sub-domain -------------------
my $d = tempdir( CLEANUP => 1 );
make_path(
    "$d/lazysite/layouts/base/themes/blue",
    "$d/lazysite/layouts/base/themes/red",     # a sibling theme that must be pruned
    "$d/sites/clienta",
);
sub spit { open my $fh, '>', $_[0] or die $!; print {$fh} $_[1]; close $fh }
spit( "$d/lazysite/lazysite.conf",
        "site_name: Agency\n"
        . "alias_hosts: shop.clienta.com, plain.example\n"
        . "alias.shop.clienta.com.content_root: sites/clienta\n"
        . "alias.shop.clienta.com.site_name: Client A Shop\n"
        . "alias.shop.clienta.com.theme: blue\n"
        . "alias.shop.clienta.com.layout: base\n"
        . "alias.shop.clienta.com.nav_file: sites/clienta/nav.conf\n" );
spit( "$d/sites/clienta/index.md",     "# Client A\n" );
spit( "$d/sites/clienta/nav.conf",     "Home | /\n" );
spit( "$d/lazysite/layouts/base/layout.tt",               '[% content %]' );
spit( "$d/lazysite/layouts/base/themes/blue/theme.json",  '{"name":"blue"}' );
spit( "$d/lazysite/layouts/base/themes/red/theme.json",   '{"name":"red"}' );

$Lazysite::Manager::SitePackage::DOCROOT   = $d;
$Lazysite::Manager::SitePackage::auth_user = 'tester';

sub list_pkg { my $f = shift; my @l = `tar tzf \Q$f\E 2>/dev/null`; chomp @l; return @l }

# --- a domain WITH its own content root packages cleanly --------------------
{
    my $r = package_create('shop.clienta.com');
    is( $r->{ok}, 1, 'package_create ok for a domain with a content root' ) or diag $r->{error};
    my $pkg = "$d/lazysite/backups/$r->{name}";
    ok( -f $pkg, 'the package tarball is written under lazysite/backups' );
    like( $r->{name}, qr/^site-shop\.clienta\.com-\d{8}T\d{6}Z\.tar\.gz$/, 'package name carries host + stamp' );

    my %in = map { $_ => 1 } list_pkg($pkg);
    ok( $in{'./site.json'},                 'package has the manifest' );
    ok( $in{'./content/index.md'},          'package has the content tree' );
    ok( $in{'./layout/layout.tt'},          'package bundles the layout' );
    ok( $in{'./layout/themes/blue/theme.json'}, 'package bundles the referenced theme' );
    ok( !$in{'./layout/themes/red/theme.json'}, 'a sibling theme is pruned out' );
    ok( $in{'./nav'},                       'package carries the nav override' );

    # manifest content
    is( $r->{manifest}{nav}, 'override', 'manifest records an override nav' );
    is( $r->{manifest}{keys}{content_root}, 'sites/clienta', 'manifest carries the content_root key' );
    is( $r->{manifest}{keys}{site_name},    'Client A Shop', 'manifest carries the per-domain site title' );
    is( $r->{manifest}{source_host},        'shop.clienta.com', 'manifest names the source host' );
}

# --- a domain with NO content root of its own is refused --------------------
{
    my $r = package_create('plain.example');
    ok( !$r->{ok}, 'a default-serving domain (no content root) is not packageable' );
    is( $r->{kind}, 'invalid', 'refusal is an invalid request' );
}

# --- an unregistered host is refused ----------------------------------------
{
    my $r = package_create('nope.example');
    ok( !$r->{ok}, 'an unregistered host is refused' );
    is( $r->{kind}, 'not-found', 'refusal is not-found' );
}

# --- a base-inherited nav is NOT packaged (kept out of infra) ---------------
{
    make_path("$d/sites/clientb");
    spit( "$d/sites/clientb/index.md", "# B\n" );
    open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "alias_hosts: shop.clienta.com, plain.example, b.example\n";
    print {$cf} "alias.b.example.content_root: sites/clientb\n";
    close $cf;
    my $r = package_create('b.example');
    is( $r->{ok}, 1, 'domain with no nav override still packages' ) or diag $r->{error};
    is( $r->{manifest}{nav}, 'base-inherited', 'a base nav is recorded as inherited, not packaged' );
    my %in = map { $_ => 1 } list_pkg("$d/lazysite/backups/$r->{name}");
    ok( !$in{'./nav'}, 'no nav file is bundled when it is base-inherited (infra untouched)' );
}

done_testing();
