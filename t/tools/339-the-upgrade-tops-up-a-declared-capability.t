#!/usr/bin/perl
# SM1369 X2 (ruling 167): THE UPGRADE RUNS RULING 71'S TOP-UP ITSELF.
#
# manage_odoo was carved out of manage_connectors (ruling 71), and every group
# holding manage_connectors is topped up with it - on the users tool's ordinary
# use (SM645's trigger) and now by the upgrade, so a site nobody touches after
# the upgrade does not leave a manage_connectors token refused the Odoo
# connection's actions. By the real install.pl (a reinstall runs the upgrade's
# steps at the version under test), on a provisioned site whose group store
# predates manage_odoo:
#
#   - a group holding manage_connectors with manage_odoo unset gains it;
#   - a group whose operator set manage_odoo to 0 keeps the 0;
#   - a group holding neither, and one already holding manage_odoo, are left;
#   - the upgrade prints ONE line naming the groups it topped up;
#   - a second upgrade, with nothing left to top up, prints nothing about it.
#
# Sabotage: with the run_capability_top_up call taken out of cmd_install, the
# group is not topped up and no line is printed - this fails.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper    qw(repo_manifest_guard);
use PreRenameSite qw(new_site install slurp spit);

my $MF_GUARD = repo_manifest_guard();

my ( $docroot, $cgibin ) = new_site();
my ( $rc, $out ) = install( $docroot, $cgibin, 'provision' );
is( $rc, 0, 'the site is provisioned' ) or diag $out;

my $gsf = "$docroot/lazysite/auth/groups-settings.json";
my $gs  = -e $gsf ? decode_json( slurp($gsf) ) : {};
$gs->{connectors}   = { label => 'Connectors',   manage_connectors => 1 };
$gs->{declined}     = { label => 'Declined',     manage_connectors => 1, manage_odoo => 0 };
$gs->{content}      = { label => 'Content',      manage_content    => 1 };
$gs->{already}      = { label => 'Already',      manage_connectors => 1, manage_odoo => 1 };
$gs->{connectors_b} = { label => 'Connectors B', manage_connectors => 1 };
spit( $gsf, encode_json($gs) );

( $rc, $out ) = install( $docroot, $cgibin, 'reinstall' );
is( $rc, 0, 'the site is upgraded' ) or diag $out;
my $after = decode_json( slurp($gsf) );
is( $after->{connectors}{manage_odoo},   1, 'a group holding manage_connectors gains manage_odoo' );
is( $after->{connectors_b}{manage_odoo}, 1, 'as does every such group' );
is( $after->{declined}{manage_odoo},     0, 'a 0 an operator set stays' );
ok( !exists $after->{content}{manage_odoo}, 'a group holding neither is left alone' );
is( $after->{already}{manage_odoo}, 1, 'and one that held it already keeps it' );

my @lines = grep { /topped up/ } split /\n/, $out;
is( scalar @lines, 1, 'the upgrade prints one line about the top-up' ) or diag $out;
like( $lines[0] // '', qr/connectors \(manage_odoo\), connectors_b \(manage_odoo\)\s*\z/,
    'naming the groups it topped up, and only those' );

( $rc, $out ) = install( $docroot, $cgibin, 'reinstall' );
is( $rc, 0, 'a second upgrade succeeds' ) or diag $out;
unlike( $out, qr/topped up/, 'and, with nothing to top up, says nothing about it' );
is( decode_json( slurp($gsf) )->{declined}{manage_odoo}, 0, 'the 0 still stands' );

done_testing();
