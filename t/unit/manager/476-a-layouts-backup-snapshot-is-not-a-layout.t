#!/usr/bin/perl
# SM1400 (triage T-87): A LAYOUT'S BACKUP SNAPSHOT IS NOT A LAYOUT.
#
# delete_layout keeps `<name>-backup-<stamp>` beside the layouts, and the one
# listing every door reads installed layouts and themes from (themes-list-all:
# the Appearance page, MCP list_themes, the control API) walked every directory
# under layouts/, so the snapshot came back as a layout of its own with the
# deleted layout's theme under it, and a second delete removed it. The listing
# now leaves every snapshot out of `themes` and lists it under `backups`.
#
# Reverted, the first subtest fails: the snapshot is a `themes` row.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use JSON::PP qw(encode_json);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $root    = repo_root();
my $docroot = site_tempdir();
make_path("$docroot/lazysite");
open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "layout: default\ntheme: default\n";
close $cf;

sub write_layout_theme {
    my ( $layout, $theme ) = @_;
    my $tdir = "$docroot/lazysite/layouts/$layout/themes/$theme";
    make_path($tdir);
    open my $lf, '>', "$docroot/lazysite/layouts/$layout/layout.tt" or die $!;
    print {$lf} "<html>[% content %]</html>\n";
    close $lf;
    open my $tj, '>', "$tdir/theme.json" or die $!;
    print {$tj} encode_json( { name => $theme, version => '1.0', layouts => [$layout] } );
    close $tj;
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
my $gone = main::action_layout_delete('studio');
ok( $gone->{ok}, 'the studio layout is deleted' ) or diag explain $gone;
opendir my $dh, "$docroot/lazysite/layouts" or die $!;
my ($snap) = grep { /^studio-backup-\d{8}T\d{6}Z\z/ } readdir $dh;
closedir $dh;
ok( $snap, 'and its snapshot is kept beside the layouts' );
ok( -f "$docroot/lazysite/layouts/$snap/themes/studio/theme.json", 'with the theme inside it' );

# a theme snapshot too, as an activate leaves one
make_path("$docroot/lazysite/layouts/default/themes/default-backup-20260101T000000Z");

subtest 'the listing holds no snapshot as a layout or a theme' => sub {
    my $r = Lazysite::Manager::Themes::action_themes_list_all();
    ok( $r->{ok}, 'listed' ) or diag explain $r;
    my @as_layout = grep { $_->{layout} =~ /-backup-/ } @{ $r->{themes} };
    is( scalar @as_layout, 0, 'no themes row names the snapshot as its layout' )
        or diag explain \@as_layout;
    my @as_theme = grep { $_->{name} =~ /-backup-/ } @{ $r->{themes} };
    is( scalar @as_theme, 0, 'and none is a theme snapshot' );
    is_deeply( [ map { "$_->{layout}/$_->{name}" } @{ $r->{themes} } ], ['default/default'],
        'the one real theme is the one listed' );
};

subtest 'the snapshots are listed as backups, with the path artifact-backups-delete takes' => sub {
    my $r = Lazysite::Manager::Themes::action_themes_list_all();
    my %b = map { $_->{name} => $_ } @{ $r->{backups} || [] };
    is_deeply( $b{$snap},
        { artifact => 'layout', layout => 'studio', name => $snap, path => "lazysite/layouts/$snap" },
        'the layout snapshot: artifact layout, under its base name' )
        or diag explain $r->{backups};
    is_deeply( $b{'default-backup-20260101T000000Z'},
        { artifact => 'theme', layout => 'default', name => 'default-backup-20260101T000000Z',
            path => 'lazysite/layouts/default/themes/default-backup-20260101T000000Z' },
        'the theme snapshot: artifact theme, under its layout' );
    my $del = main::action_artifact_backups_delete( $b{$snap}{path} );
    ok( $del->{ok}, 'the listed path deletes that one snapshot' ) or diag explain $del;
    ok( !-d "$docroot/lazysite/layouts/$snap", 'which is gone' );
    ok( -d "$docroot/lazysite/layouts/default", 'and the layout is not' );
};

subtest 'the installable list and the catalogue annotation never see a snapshot' => sub {
    make_path("$docroot/lazysite/layouts/old-backup-20260101T000000Z/themes/x");
    open my $lf, '>', "$docroot/lazysite/layouts/old-backup-20260101T000000Z/layout.tt" or die $!;
    print {$lf} "x\n";
    close $lf;
    my $r = main::action_layouts_available();
    is_deeply( $r->{layouts}, ['default'], 'layouts-available lists the real layout only' );
};

subtest 'the Appearance page draws the server\'s backups, and MCP list_themes is this listing' => sub {
    open my $fh, '<', "$root/starter/manager/appearance.md" or die $!;
    my $page = do { local $/; <$fh> };
    close $fh;
    like( $page, qr/BACKUPS = Array\.isArray\(ta\.backups\)/, 'the page reads `backups` from themes-list-all' );
    like( $page, qr/var allBackups = BACKUPS\.slice\(\)/,      'and seeds its backups panel from it' );
    open my $mh, '<', "$root/lazysite-mcp.pl" or die $!;
    my $mcp = do { local $/; <$mh> };
    close $mh;
    like( $mcp, qr/list_themes => \{.*?run => sub \{ action_themes_list_all\(\) \}/s,
        'list_themes answers with the same listing' );
};

done_testing;
