#!/usr/bin/perl
# _install_layout_from_dir installs the optional components/ subtree (D035), not
# just the root layout files - so content components reach a site via
# install_layout / the catalogue. A component change is detected and updated.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite");

BEGIN {
    $ENV{LAZYSITE_API_LOAD_ONLY} = 1;
    $ENV{DOCUMENT_ROOT}          = '/tmp';
}
{
    local $ENV{DOCUMENT_ROOT} = $docroot;
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

my $install = \&Lazysite::Manager::Layouts::_install_layout_from_dir;

# Release source: layout.tt + a components/ subtree.
my $src = "$docroot/src";
make_path("$src/components");
open my $l, '>', "$src/layout.tt" or die $!; print $l "LAYOUT\n"; close $l;
open my $h, '>', "$src/components/hero.tt" or die $!; print $h "HERO-A\n"; close $h;

my $tgt = "$docroot/lazysite/layouts/nova";

sub slurp { local $/; open my $f, '<', $_[0] or return ''; <$f> }

subtest 'new install copies layout.tt + the components subtree' => sub {
    my $r = $install->( $src, 'nova', 'test', 'u' );
    ok( $r->{ok}, 'ok' ) or diag explain $r;
    is( $r->{action}, 'installed', 'installed' );
    is( slurp("$tgt/layout.tt"), "LAYOUT\n", 'layout.tt installed' );
    ok( -f "$tgt/components/hero.tt", 'component file installed' );
    is( slurp("$tgt/components/hero.tt"), "HERO-A\n", 'component content correct' );
};

subtest 'a changed component is detected (refused without force)' => sub {
    open my $h2, '>', "$src/components/hero.tt" or die $!; print $h2 "HERO-B\n"; close $h2;
    my $r = $install->( $src, 'nova', 'test', 'u' );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error}, qr/components\/hero\.tt/, 'names the differing component' );
    is( slurp("$tgt/components/hero.tt"), "HERO-A\n", 'component unchanged on refusal' );
};

subtest 'update overwrites the component' => sub {
    my $r = $install->( $src, 'nova', 'test', 'u', 1 );
    ok( $r->{ok}, 'ok' );
    is( $r->{action}, 'updated', 'updated' );
    is( slurp("$tgt/components/hero.tt"), "HERO-B\n", 'component overwritten' );
};

done_testing;
