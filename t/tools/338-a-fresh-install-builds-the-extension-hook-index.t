#!/usr/bin/perl
# SM1369 X2 (ruling 166): A FRESH INSTALL BUILDS THE EXTENSION HOOK INDEX, AS
# THE UPGRADE DOES.
#
# The index carries what the installed extensions declare - capabilities and
# actions, X2's `declared` view - so a new site without one could not grant a
# declared capability until its first upgrade or toggle. install.pl's HOOKS step
# (run_hook_index_build, the installed lib's rebuild_hook_index_main as the site
# user) now runs on a provision too. By the real install.pl:
#
#   - a provisioned site has an index: Odoo, installed with the engine, is in
#     the `declared` view, and the enabled extensions whose descriptors declare
#     no hooks (the login rate limiter a new site switches on) have no entry in
#     `extensions` - X1's rule, nothing runs;
#   - a site provisioned with an extension that declares hooks already enabled
#     has that extension named in `extensions`;
#   - X1's rule at the file level stands: with no installed extension
#     declaring, the same call leaves no index.
#
# Sabotage: with the HOOKS step guarded by `$mode ne 'fresh'` again, a
# provisioned site has no index - this fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper    qw(repo_manifest_guard);
use PreRenameSite qw(new_site install slurp spit);

my $MF_GUARD = repo_manifest_guard();

# A new site, as it ships.
my ( $docroot, $cgibin, $root ) = new_site();
my ( $rc, $out ) = install( $docroot, $cgibin, 'provision' );
is( $rc, 0, 'the site is provisioned' ) or diag $out;
my $index = "$docroot/lazysite/extensions.index.json";
ok( -e $index, 'and has an extension index from the install itself' ) or diag $out;
my $built = -e $index ? decode_json( slurp($index) ) : {};
ok( $built->{declared}{odoo}, 'which declares what the installed Odoo extension declares' );
like( slurp("$docroot/lazysite/lazysite.conf") // '', qr{^\s*-\s*extensions/login-rate-limit\.pl}m,
    'the new site has an extension enabled' );
is_deeply( $built->{extensions}, {}, 'and no hooks are indexed for one that declares none' );
like( $out, qr/declarations indexed: odoo/, 'the install names the declaration' );
unlike( $out, qr/hooks (?:indexed|refused)/, 'and says nothing about hooks' );
unlike( $out, qr/HOOKS:/, 'with no warning' );

# A new site whose conf already enables an extension that declares hooks.
my ( $docroot2, $cgibin2 ) = new_site();
make_path("$docroot2/lazysite");
spit( "$docroot2/lazysite/lazysite.conf", "site_name: Example\nextensions:\n  - extensions/odoo.pl\n" );
( $rc, $out ) = install( $docroot2, $cgibin2, 'provision' );
is( $rc, 0, 'a site with Odoo enabled from the start is provisioned' ) or diag $out;
my $index2 = "$docroot2/lazysite/extensions.index.json";
my $built2 = -e $index2 ? decode_json( slurp($index2) ) : {};
ok( $built2->{extensions}{odoo}, 'and its index names the enabled extension that declares hooks' )
    or diag $out;
is( $built2->{extensions}{odoo}{key}, 'extensions/odoo.pl', 'by its conf key' );
like( $out, qr/hooks indexed: odoo/, 'and the install says so' );

# X1's rule: nothing installed declares, nothing is written. The same call the
# install makes, against the first site with Odoo taken away.
unlink "$root/extensions/odoo.pl" or die "remove odoo.pl: $!";
unlink $index if -e $index;
my $cmd = join ' ', map { quotemeta } ( $^X, "-I$root/lib", '-MLazysite::Manager::Extensions', '-e',
    'exit Lazysite::Manager::Extensions::rebuild_hook_index_main(@ARGV)', $docroot );
my $o3 = `$cmd 2>&1`;
is( $? >> 8, 0, 'a build with nothing declaring succeeds' ) or diag $o3;
ok( !-e $index, 'and writes no index' );
is( $o3, '', 'and prints nothing' );

done_testing();
