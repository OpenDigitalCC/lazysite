#!/usr/bin/perl
# SM1179 (inbox 2026-10-18-odoo-endpoint-builds-the-oom-registry-twice-per-request.md):
# "Lazysite::Odoo::operation_class is called twice per request and each call
# goes through Lazysite::Odoo::registry, building a new Odoo::Ops::Registry
# (loading every operation module of every namespace) each time, 210-240 ms per
# build, about 450 ms a request."
#
# The registry is built once per process for a given site configuration. The
# builds are counted by wrapping Odoo::Ops::Registry->new. What the registry
# contains is a function of the namespaces (odoo_packs), the pack directories,
# the cache directory and the OOM version, so a change to any of them, or a
# second docroot in the same process, builds its own and never sees another's.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready write_conf quiet);

BEGIN { oom_or_skip() }
my $NO_PACKS = $ENV{ODOO_OOM_PACK_DIRS};
use Lazysite::Odoo ();

my $builds = 0;
my ( $d, $fake ) = shop_ready();    # puts OOM on @INC
require Odoo::Ops::Registry;
{
    no warnings 'redefine';
    my $orig = \&Odoo::Ops::Registry::new;
    *Odoo::Ops::Registry::new = sub { $builds++; return $orig->(@_) };
}

my ($conn) = Lazysite::Odoo::connection();
ok( $conn, 'the shop site has a connection' ) or BAIL_OUT('no connection');

subtest 'one request that asks for an operation twice builds the registry once' => sub {
    $builds = 0;
    my ($c1) = quiet( sub { Lazysite::Odoo::operation_class( $conn, 'shop.products' ) } );
    my ($c2) = quiet( sub { Lazysite::Odoo::operation_class( $conn, 'shop.add' ) } );
    my ( undef, $k1 ) = quiet( sub { Lazysite::Odoo::operation_class( $conn, 'shop.products' ) } );
    is( $builds, 1, 'three lookups, one build' );
    my $r1 = Lazysite::Odoo::registry($conn);
    my $r2 = Lazysite::Odoo::registry($conn);
    is( $r1, $r2, 'registry() hands back the same object' );
    is( $builds, 1, 'and still one build' );
};

subtest 'a binding still resolves the same operation' => sub {
    my ($cls) = Lazysite::Odoo::operation_class( $conn, 'shop.products' );
    is( $cls->op_name, 'shop.products', 'the class is the named operation' );
    my ( $log, $cl, $w ) = quiet( sub { Lazysite::Odoo::operation_class( $conn, 'no.such.op' ) } );
    ok( !$cl, 'an unknown name is still not found' );
    like( $w, qr/no operation 'no.such.op' is installed/, 'with the same words' );
};

subtest 'a changed odoo_packs or odoo_pack_dirs builds a new registry' => sub {
    Lazysite::Odoo::registry($conn);
    $builds = 0;
    my %c2 = ( %$conn, packs => [ @{ $conn->{packs} }, 'Odoo::Test::OomdOps' ] );
    quiet( sub { Lazysite::Odoo::registry( \%c2 ) } );
    is( $builds, 1, 'another namespace list: a build' );
    quiet( sub { Lazysite::Odoo::registry( \%c2 ) } );
    is( $builds, 1, 'asked again: none' );
    my $pd = "$d/lazysite/odoo-packs";
    make_path($pd);
    my %c3 = ( %$conn, pack_dirs => [$pd] );
    quiet( sub { Lazysite::Odoo::registry( \%c3 ) } );
    is( $builds, 2, 'a pack directory: a build' );
    quiet( sub { Lazysite::Odoo::registry($conn) } );
    is( $builds, 2, 'the first configuration is still held' );
};

subtest 'two docroots in one process each get their own registry' => sub {
    my ( $d2 ) = shop_ready();
    my ($conn2) = Lazysite::Odoo::connection();
    $builds = 0;
    my $r2 = Lazysite::Odoo::registry($conn2);
    is( $builds, 1, 'the second site builds its own' );
    local $Lazysite::Odoo::DOCROOT = $d;
    my $r1 = Lazysite::Odoo::registry($conn);
    isnt( "$r1", "$r2", 'the first site is not handed the second\'s registry' );
    is( $builds, 1, 'the first was already held' );
    $Lazysite::Odoo::DOCROOT = $d2;
};

subtest 'the environment is back as it was' => sub {
    ok( !grep { exists $ENV{$_} } qw(ODOO_OPS_NAMESPACES XDG_CACHE_HOME), 'no pack variable left set' );
    # SM1185: OdooTest sets this one (no packs, so the host's are never read); it is back to that.
    is( $ENV{ODOO_OOM_PACK_DIRS}, $NO_PACKS, 'and the pack directories are what OdooTest set' );
};

done_testing;
