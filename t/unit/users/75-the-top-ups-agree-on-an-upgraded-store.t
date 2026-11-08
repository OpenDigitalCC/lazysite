#!/usr/bin/perl
# n776: THE SEED AND TOP-UP LOOPS AGREE ON AN UPGRADED STORE.
#
# Three branches changed tools/lazysite-users.pl's loops beside one another:
# n772 (ruling 155) keeps @OFF_BY_DEFAULT out of every manager-group seed and
# top-up, so publish_copies is offered and never given; n768 (ruling 71) tops
# up the capability an extension declares from the one it moved out of
# (manage_odoo from manage_connectors); n774 adopts the layer roles once
# (t/unit/users/74 holds that). Each branch tested its own rule on its own base.
# Here they run together, on ordinary use (SM645's trigger), on a store from
# before publish_copies and manage_odoo, on a site with Odoo enabled and indexed:
#
#   - the manager group gains manage_odoo (the manager top-up and the declared
#     top-up both reach it) and does not gain publish_copies;
#   - a group holding manage_connectors gains manage_odoo, and no publish_copies;
#   - a group with manage_odoo set to 0 by its operator keeps the 0;
#   - publish_copies stays grantable by the manager group, as offered;
#   - a second ordinary use changes nothing.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir run_cmd run_child);
use OdooTest   ();

my $tool = "$FindBin::Bin/../../../tools/lazysite-users.pl";

sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; $t }
sub spit  { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }
sub cli   { my ( $d, @a ) = @_; return run_cmd( $^X, $tool, '--docroot', $d, @a ) }
sub gs_file { "$_[0]/lazysite/auth/groups-settings.json" }
sub gs_read { decode_json( slurp( gs_file( $_[0] ) ) ) }

my $d = site_tempdir();
make_path("$d/lazysite/auth");
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$d/lazysite/auth/users",    "boss:x\n" );
OdooTest::enable_odoo($d);
cli( $d, 'setup-sysop', '--user', 'boss' );

# The store as an older release left it: neither capability decided anywhere.
my $gs = gs_read($d);
my ($mgr) = grep { ref $gs->{$_} eq 'HASH' && $gs->{$_}{manager} } sort keys %$gs;
ok( $mgr, "the site has a manager group ($mgr)" ) or BAIL_OUT('no manager group');
for my $g ( keys %$gs ) {
    next unless ref $gs->{$g} eq 'HASH';
    delete @{ $gs->{$g} }{qw(manage_odoo publish_copies)};
}
$gs->{connectors}  = { label => 'Connectors', assignable => 1, manage_connectors => 1 };
$gs->{declined}    = { label => 'Declined',   assignable => 1, manage_connectors => 1, manage_odoo => 0 };
$gs->{$mgr}{manage_connectors} = 1;
spit( gs_file($d), encode_json($gs) );

my $use = sub { run_child( [ $^X, $tool, '--api', '--docroot', $d ],
        stdin => encode_json( { action => 'users-page', me => 'boss' } ), stderr => 'inherit' ) };
$use->();
my $after = gs_read($d);

is( $after->{$mgr}{manage_odoo}, 1, 'the manager group gains manage_odoo' ) or diag explain $after->{$mgr};
ok( !exists $after->{$mgr}{publish_copies}, '... and is not given publish_copies (ruling 155)' );
ok( ( grep { $_ eq 'publish_copies' } @{ $after->{$mgr}{grantable} || [] } ), '... which it may still grant' );
is( $after->{connectors}{manage_odoo}, 1, 'a group holding manage_connectors gains manage_odoo (ruling 71)' )
    or diag explain $after->{connectors};
ok( !exists $after->{connectors}{publish_copies}, '... and no publish_copies' );
is( $after->{declined}{manage_odoo}, 0, 'an operator\'s 0 stays a 0' );
my @holders = grep { ref $after->{$_} eq 'HASH' && $after->{$_}{publish_copies} } sort keys %$after;
is_deeply( \@holders, [], 'no group anywhere holds publish_copies' );

my $once = slurp( gs_file($d) );
$use->();
is( slurp( gs_file($d) ), $once, 'a second ordinary use changes nothing' );

done_testing();
