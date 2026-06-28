#!/usr/bin/perl
# _install_layout_from_dir: refuses to overwrite a differing layout unless the
# update/force flag is set, in which case it snapshots then overwrites the layout
# files (leaving themes/ intact). Backs the install_layout(update:true) path.
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

# Installed layout (content A) with a theme.
my $tgt = "$docroot/lazysite/layouts/foo";
make_path("$tgt/themes/foo");
open my $a, '>', "$tgt/layout.tt" or die $!; print $a "AAA\n"; close $a;
open my $tj, '>', "$tgt/themes/foo/theme.json" or die $!; print $tj "{}\n"; close $tj;

# Release source with different content B.
my $src = "$docroot/src-foo";
make_path($src);
open my $b, '>', "$src/layout.tt" or die $!; print $b "BBB\n"; close $b;

sub slurp { local $/; open my $f, '<', $_[0] or return ''; <$f> }

subtest 'refuses to overwrite a differing layout without update' => sub {
    my $r = $install->( $src, 'foo', 'test', 'u' );
    ok( !$r->{ok}, 'not ok' );
    like( $r->{error}, qr/differs/i, 'error explains it differs' );
    is( slurp("$tgt/layout.tt"), "AAA\n", 'on-disk layout unchanged' );
};

subtest 'update=force overwrites, snapshots, keeps themes' => sub {
    my $r = $install->( $src, 'foo', 'test', 'u', 1 );
    ok( $r->{ok}, 'ok' ) or diag explain $r;
    is( $r->{action}, 'updated', 'reports updated' );
    is( slurp("$tgt/layout.tt"), "BBB\n", 'layout overwritten with new content' );
    ok( -f "$tgt/themes/foo/theme.json", 'themes/ left intact' );
    opendir my $dh, "$docroot/lazysite/layouts" or die $!;
    my @bk = grep { /^foo-backup-/ } readdir $dh;
    closedir $dh;
    is( scalar @bk, 1, 'a recovery snapshot was taken' );
};

subtest 'identical re-install is a no-op (not an update)' => sub {
    my $r = $install->( $src, 'foo', 'test', 'u', 1 );
    ok( $r->{ok}, 'ok' );
    is( $r->{action}, 'already_installed', 'no-op when byte-identical' );
};

done_testing;
