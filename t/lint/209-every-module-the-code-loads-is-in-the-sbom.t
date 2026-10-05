#!/usr/bin/perl
# EVERY MODULE THE SHIPPED CODE LOADS IS DECLARED IN THE SBOM.
#
# The release build runs manifest-to-sbom.pl --strict and refuses a module that
# the code loads and dist/config/sbom-deps.json does not declare. That check ran
# ONLY in the release build - after a passing gate, in the release manager's
# terminal - so the 0.15.2 build was the first thing to notice that SM925 X2
# (the XMPP endpoint from the domain's SRV record) had added `require Net::DNS`
# without declaring it. Nothing in the suite looked, so every handoff passed.
#
# This runs the same strict check against the real tree, so an undeclared
# module fails the handoff that adds it rather than the release that ships it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $dir  = tempdir( CLEANUP => 1 );

my $mf = `$^X \Q$root/tools/build-manifest.pl\E --staged \Q$root\E --out \Q$dir/manifest.json\E 2>&1`;
is( $? >> 8, 0, 'the release manifest builds from the tree' ) or diag($mf);

my $out = `$^X \Q$root/tools/manifest-to-sbom.pl\E --strict --manifest \Q$dir/manifest.json\E --deps \Q$root/dist/config/sbom-deps.json\E --staged \Q$root\E --out \Q$dir/sbom.json\E 2>&1`;
is( $? >> 8, 0, 'every module the shipped code loads is declared in sbom-deps.json' )
    or diag( $out . "\nThe release build refuses exactly this; declare the module "
        . '(licence, distro packages, what uses it) in dist/config/sbom-deps.json.' );

done_testing();
