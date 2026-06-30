#!/usr/bin/perl
# action_layout_delete: removes a layout and its themes, snapshots first,
# refuses the active layout, and clears the web-served asset mirror.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use JSON::PP qw(encode_json);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite");

# Active layout = default (so deleting it must be refused).
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "layout: default\ntheme: default\n";
close $cf;

sub write_layout_theme {
    my ( $layout, $theme ) = @_;
    my $tdir = "$docroot/lazysite/layouts/$layout/themes/$theme";
    make_path($tdir);
    open my $lf, '>', "$docroot/lazysite/layouts/$layout/layout.tt" or die $!;
    print $lf "<html>[% content %]</html>\n";
    close $lf;
    open my $tj, '>', "$tdir/theme.json" or die $!;
    print $tj encode_json({ name => $theme, version => '1.0', layouts => [$layout],
        config => { colours => { primary => '#000' } } });
    close $tj;
    # Web-served mirror that delete must also remove.
    my $mir = "$docroot/lazysite-assets/$layout/$theme";
    make_path($mir);
    open my $css, '>', "$mir/main.css" or die $!; print $css "x{}\n"; close $css;
}

BEGIN {
    $ENV{LAZYSITE_API_LOAD_ONLY} = 1;
    $ENV{DOCUMENT_ROOT}          = '/tmp';
}
{
    local $ENV{DOCUMENT_ROOT} = $docroot;
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

write_layout_theme( 'default', 'default' );
write_layout_theme( 'studio',  'studio' );

subtest 'refuses to delete the active layout' => sub {
    my $r = main::action_layout_delete('default');
    ok( !$r->{ok}, 'not ok' );
    like( $r->{error}, qr/active/i, 'error mentions active' );
    ok( -d "$docroot/lazysite/layouts/default", 'default layout still present' );
};

subtest 'deletes a non-active layout, its themes, and its mirror' => sub {
    my $r = main::action_layout_delete('studio');
    ok( $r->{ok}, 'ok' ) or diag explain $r;
    is( $r->{deleted}, 'studio', 'deleted name echoed' );
    is_deeply( $r->{themes_removed}, ['studio'], 'theme listed as removed' );
    ok( !-d "$docroot/lazysite/layouts/studio", 'layout dir gone' );
    ok( !-d "$docroot/lazysite-assets/studio",  'asset mirror gone' );

    # A recovery snapshot was taken alongside the layouts dir.
    opendir my $dh, "$docroot/lazysite/layouts" or die $!;
    my @bk = grep { /^studio-backup-/ } readdir $dh;
    closedir $dh;
    is( scalar @bk, 1, 'one backup snapshot created' );
    ok( -f "$docroot/lazysite/layouts/$bk[0]/layout.tt",
        'snapshot contains the layout' );
};

subtest 'a backup snapshot is not itself an installable layout' => sub {
    my $r = main::action_layouts_available();
    ok( !( grep { /-backup-/ } @{ $r->{layouts} } ),
        'available list excludes -backup- dirs' );
    ok( !( grep { $_ eq 'studio' } @{ $r->{layouts} } ),
        'deleted layout no longer listed' );
};

subtest 'missing layout' => sub {
    my $r = main::action_layout_delete('nope');
    ok( !$r->{ok}, 'not ok' );
    like( $r->{error}, qr/not found/i, 'error mentions not found' );
};

subtest 'artifact-backups-delete purges layout + theme backups, spares the active layout' => sub {
    make_path("$docroot/lazysite/layouts/old-backup-20260101T000000Z/themes/x");
    make_path("$docroot/lazysite/layouts/default/themes/default-backup-20260101T000000Z");
    my $r = main::action_artifact_backups_delete('');
    ok( $r->{ok}, 'purge ok' );
    ok( $r->{deleted} >= 2, 'removed both backups' ) or diag explain $r;
    ok( !-d "$docroot/lazysite/layouts/old-backup-20260101T000000Z", 'backup layout removed' );
    ok( !-d "$docroot/lazysite/layouts/default/themes/default-backup-20260101T000000Z", 'theme backup removed' );
    ok(  -d "$docroot/lazysite/layouts/default", 'active layout preserved' );
};

subtest 'artifact-backups-delete by path: one backup; rejects a non-backup path' => sub {
    make_path("$docroot/lazysite/layouts/default/themes/default-backup-20260202T000000Z");
    my $bad = main::action_artifact_backups_delete('lazysite/layouts/default');
    ok( !$bad->{ok}, 'a non-backup path is refused' );
    ok( -d "$docroot/lazysite/layouts/default", 'real layout untouched' );
    my $one = main::action_artifact_backups_delete(
        'lazysite/layouts/default/themes/default-backup-20260202T000000Z' );
    ok( $one->{ok} && $one->{deleted} == 1, 'a single named backup is deleted' );
    ok( !-d "$docroot/lazysite/layouts/default/themes/default-backup-20260202T000000Z", 'it is gone' );
};

done_testing;
