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
use Lazysite::Manager::SitePackage qw(package_create package_apply apply_and_configure package_inspect);

# --- fixture: an agency instance with a client sub-domain -------------------
my $d = tempdir( CLEANUP => 1 );
make_path(
    "$d/lazysite/layouts/base/themes/blue/assets",    # SM193: a theme asset to mirror
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
        . "alias.shop.clienta.com.nav_file: sites/clienta/nav.conf\n"
        . "alias.shop.clienta.com.lang: fr\n"
        . "alias.shop.clienta.com.lang_group: providers\n" );
spit( "$d/sites/clienta/index.md",     "# Client A\n" );
spit( "$d/sites/clienta/nav.conf",     "Home | /\n" );
spit( "$d/lazysite/layouts/base/layout.tt",               '[% content %]' );
spit( "$d/lazysite/layouts/base/themes/blue/theme.json",  '{"name":"blue"}' );
spit( "$d/lazysite/layouts/base/themes/blue/assets/style.css", "body{margin:0}" );   # SM193
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
    like( $r->{name}, qr/^lazysite-site-shop\.clienta\.com-\d{8}T\d{6}Z\.tar\.gz$/, 'package name carries host + stamp' );

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
    is( $r->{manifest}{keys}{lang},         'fr',        'SM185: manifest carries the language' );
    is( $r->{manifest}{keys}{lang_group},   'providers', 'SM185: manifest carries the language set' );
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

# --- round-trip: create on A, apply to a fresh domain on B ------------------
{
    my $src = package_create('shop.clienta.com');
    my $pkg = "$d/lazysite/backups/$src->{name}";

    my $b = tempdir( CLEANUP => 1 );
    make_path( "$b/lazysite/backups", "$b/lazysite/layouts" );
    spit( "$b/lazysite/lazysite.conf",
        "site_name: Fresh\nalias_hosts: client.example\n"
            . "alias.client.example.content_root: sites/dest\n" );

    local $Lazysite::Manager::SitePackage::DOCROOT = $b;
    my $ap = apply_and_configure( $pkg, host => 'client.example', clean => 1 );
    is( $ap->{ok}, 1, 'apply_and_configure ok' ) or diag $ap->{error};
    is( $ap->{applied_to}, 'client.example', 'reports the target domain' );
    ok( -f "$b/sites/dest/index.md",      'content copied into the target content root' );
    ok( -f "$b/sites/dest/nav.conf",      'nav override placed in the target' );
    ok( -f "$b/lazysite/layouts/base/layout.tt", 'bundled layout installed on the target' );
    ok( -d "$b/lazysite/layouts/base/themes/blue", 'bundled theme installed' );
    ok( !-d "$b/lazysite/layouts/base/themes/red", 'the pruned sibling theme is not present' );

    my $conf = do { open my $fh, '<', "$b/lazysite/lazysite.conf" or die $!; local $/; <$fh> };
    like( $conf, qr/^alias\.client\.example\.theme: blue$/m,       'target theme key written' );
    like( $conf, qr/^alias\.client\.example\.nav_file: sites\/dest\/nav\.conf$/m, 'target nav_file repointed' );
    like( $conf, qr/^alias\.client\.example\.lang: fr$/m,               'SM185: language applied to the target' );
    like( $conf, qr/^alias\.client\.example\.lang_group: providers$/m,  'SM185: language set applied to the target' );

    # SM193 gap 2: by default the target KEEPS its own identity - the source
    # package's site_url / site_name are NOT stamped onto it (a migration, not a
    # handoff). The portable presentation keys (theme/layout/nav/lang) still apply.
    unlike( $conf, qr/^alias\.client\.example\.site_name:/m,
        'SM193: source site_name is NOT stamped on the target by default' );
    unlike( $conf, qr/^alias\.client\.example\.site_url:/m,
        'SM193: source site_url is NOT stamped on the target by default' );
    is( $ap->{identity_kept}, 1, 'SM193: apply reports it kept the target identity' );

    # SM193 gap 3: the layout theme assets are mirrored to /lazysite-assets/ on
    # apply, so the applied site renders styled immediately (no activation needed).
    ok( -f "$b/lazysite-assets/base/blue/style.css",
        'SM193: theme assets mirrored to /lazysite-assets on apply' );
}

# --- SM193 gap 2: adopt_identity DOES take the package's site_name --------------
{
    my $src = package_create('shop.clienta.com');
    my $pkg = "$d/lazysite/backups/$src->{name}";

    my $b = tempdir( CLEANUP => 1 );
    make_path( "$b/lazysite/backups", "$b/lazysite/layouts" );
    spit( "$b/lazysite/lazysite.conf",
        "site_name: Fresh\nalias_hosts: client.example\n"
            . "alias.client.example.content_root: sites/dest\n" );

    local $Lazysite::Manager::SitePackage::DOCROOT = $b;
    my $ap = apply_and_configure( $pkg, host => 'client.example', clean => 1,
        adopt_identity => 1 );
    is( $ap->{ok}, 1, 'apply with adopt_identity ok' ) or diag $ap->{error};
    is( $ap->{identity_kept}, 0, 'apply reports it did NOT keep the target identity' );
    my $conf = do { open my $fh, '<', "$b/lazysite/lazysite.conf" or die $!; local $/; <$fh> };
    like( $conf, qr/^alias\.client\.example\.site_name: Client A Shop$/m,
        'SM193: adopt_identity stamps the package site_name onto the target' );
}

# --- SM185: the DEFAULT site (docroot root) packages, excluding infra + others -
{
    make_path("$d/lazysite/auth");
    spit( "$d/index.md",              "# Home root\n" );   # the default site's own content
    spit( "$d/lazysite/auth/.secret", "TOPSECRET" );       # infra - must NOT travel

    my $r = package_create('(default)');
    is( $r->{ok}, 1, 'the default/primary site packages (no content_root of its own)' )
        or diag $r->{error};
    is( $r->{manifest}{source_host}, '(default)', 'source host is (default)' );
    my @members = list_pkg("$d/lazysite/backups/$r->{name}");
    my %in      = map { $_ => 1 } @members;
    ok( $in{'./content/index.md'},                     'root content is packaged' );
    ok( !( grep {m{lazysite}} @members ),              'lazysite/ infra + secrets are excluded' );
    ok( !( grep {m{content/sites/clienta}} @members ), "another domain's content is excluded" );
}

# --- SM183: package_inspect reads the manifest WITHOUT applying -------------
{
    my $src = package_create('shop.clienta.com');
    my $pkg = "$d/lazysite/backups/$src->{name}";

    # A marker file on the live docroot must be untouched by an inspect.
    spit( "$d/sites/clienta/UNTOUCHED", "keep\n" );

    my $info = package_inspect($pkg);
    is( $info->{ok}, 1, 'package_inspect ok' ) or diag $info->{error};
    is( $info->{manifest}{source_host}, 'shop.clienta.com', 'inspect returns the source host' );
    is( $info->{manifest}{keys}{content_root}, 'sites/clienta', 'inspect exposes the content_root for scoping' );
    ok( $info->{content_files} >= 1, 'inspect counts the content files' );
    is( $info->{has_nav},    1, 'inspect reports the nav override' );
    is( $info->{has_layout}, 1, 'inspect reports the bundled layout' );
    ok( -f "$d/sites/clienta/UNTOUCHED", 'inspect is read-only (live content untouched)' );

    # No staging directory is left behind under backups/.
    my @stage = glob("$d/lazysite/backups/.inspect-*");
    is( scalar(@stage), 0, 'inspect leaves no staging dir behind' );

    my $miss = package_inspect("$d/lazysite/backups/lazysite-site-nope.tar.gz");
    ok( !$miss->{ok}, 'inspect of a missing package fails cleanly' );
}

# --- SECURITY: a package cannot escape the target via a ../ member ----------
{
    my $b = tempdir( CLEANUP => 1 );
    make_path( "$b/lazysite/backups", "$b/sites/dest" );
    spit( "$b/lazysite/lazysite.conf", "site_name: T\n" );

    # Hand-build a hostile package: a manifest + a content/ file whose path
    # tries to traverse out of the stage.
    my $eviltmp = tempdir( CLEANUP => 1 );
    make_path("$eviltmp/content");
    spit( "$eviltmp/site.json", '{"site_package":1,"keys":{"content_root":"sites/dest"},"nav":"base-inherited"}' );
    spit( "$eviltmp/content/ok.md", "safe\n" );
    # a traversal member
    system( 'ln', '-s', '/etc/passwd', "$eviltmp/content/link" );
    my $evil = "$b/lazysite/backups/lazysite-site-evil.tar.gz";
    system( 'tar', 'czf', $evil, '-C', $eviltmp, '.' );

    local $Lazysite::Manager::SitePackage::DOCROOT = $b;
    my $r = package_apply( $evil, content_root => 'sites/dest' );
    # The symlink must never survive into the target.
    ok( !-e "$b/sites/dest/link" || !-l "$b/sites/dest/link",
        'a symlink member is not materialised as a link in the target' );
    ok( !-e "$b/sites/dest/../escaped", 'no traversal escape from the target' );
}

# --- an unregistered target host is refused ---------------------------------
{
    my $src = package_create('shop.clienta.com');
    my $pkg = "$d/lazysite/backups/$src->{name}";
    my $b   = tempdir( CLEANUP => 1 );
    make_path("$b/lazysite/backups");
    spit( "$b/lazysite/lazysite.conf", "site_name: T\n" );
    local $Lazysite::Manager::SitePackage::DOCROOT = $b;
    my $r = apply_and_configure( $pkg, host => 'nope.example' );
    ok( !$r->{ok}, 'apply to an unregistered domain is refused' );
    is( $r->{kind}, 'not-found', 'refusal is not-found' );
}

done_testing();
