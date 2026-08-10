#!/usr/bin/perl
# SM268 03-F9, 03-F12: two ways an artefact operation destroyed or ran away
# with the thing it was operating on.
#
# F9  the snapshot filename is a one-second UTC stamp, and nothing claimed it.
#     Two snapshots in the same second - an apply's safety snapshot and a
#     concurrent backup-create or git-sync snapshot - produced the SAME name,
#     and both tar processes wrote the same inode. Every caller was told ok => 1
#     and handed a name; all but one described someone else's tarball. That is
#     the worst failure this feature has, because the operator believes they can
#     roll back. A check-then-create does not fix it: the window is between the
#     test and the write.
#
# F12 a content_root of `.` is the docroot itself and passed every validation:
#     the dotdir test wants a character after the dot, and path_is_reserved
#     normalises `.` away to nothing. package_create then staged its copy inside
#     the tree it was copying and fed itself until the kernel refused the path
#     length, dying uncaught in a CGI and leaving a ~50-deep tree behind.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

require Lazysite::Manager::Backups;
require Lazysite::Manager::Domains;
require Lazysite::Manager::SitePackage;

# --- F9 ---------------------------------------------------------------------

subtest 'concurrent snapshots do not share a filename' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/backups");
    make_path("$d/content");
    open my $fh, '>', "$d/content/page.md" or die $!;
    print {$fh} "body\n";
    close $fh;

    local $Lazysite::Manager::Backups::DOCROOT      = $d;
    local $Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";

    # Same process, same second, back to back: this is the sequential shape of
    # the collision, and it is the one a test can make deterministic. The
    # concurrent shape has the same cause and the same fix.
    my @names;
    for ( 1 .. 4 ) {
        my $r = Lazysite::Manager::Backups::action_backup_create('manual');
        ok( $r->{ok}, 'snapshot reported ok' ) or diag explain $r;
        push @names, $r->{name};
    }

    my %seen;
    $seen{$_}++ for @names;
    is( scalar( keys %seen ), scalar(@names),
        'every caller got a DISTINCT name - a caller told ok=1 and handed a '
            . "name that describes someone else's tarball is the defect" );

    opendir my $dh, "$d/lazysite/backups" or die $!;
    my @files = grep { /\.tar\.gz\z/ } readdir $dh;
    closedir $dh;
    is( scalar(@files), scalar(@names),
        'and there is one file on disk per caller, so nothing was overwritten' );
};

subtest 'a failed snapshot leaves no placeholder behind' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/backups");
    local $Lazysite::Manager::Backups::DOCROOT      = "$d/does-not-exist";
    local $Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";

    my $r = Lazysite::Manager::Backups::action_backup_create('manual');
    ok( !$r->{ok}, 'refused' );

    opendir my $dh, "$d/lazysite/backups" or die $!;
    my @files = grep { !/\A\.\.?\z/ } readdir $dh;
    closedir $dh;
    is( scalar(@files), 0,
        'the claimed name was released - a zero-byte tarball in the listing '
            . 'reads as a usable snapshot' );
};

# --- F12 --------------------------------------------------------------------

subtest 'a content root of . is refused' => sub {
    for my $bad ( '.', './', '././', '/./' ) {
        is( Lazysite::Manager::Domains::_clean_content_root($bad), undef,
            "'$bad' is the docroot itself, not a folder inside it" );
    }
};

subtest 'and ordinary content roots still pass' => sub {
    is( Lazysite::Manager::Domains::_clean_content_root('sites/foo'),
        'sites/foo', 'a plain path' );
    is( Lazysite::Manager::Domains::_clean_content_root('/sites/foo/'),
        'sites/foo', 'slashes trimmed' );
    is( Lazysite::Manager::Domains::_clean_content_root('sites/./foo'),
        'sites/foo',
        'a . segment is collapsed rather than refused - a guard that rejected '
            . 'every legitimate path would pass the subtest above for the '
            . 'wrong reason' );
    is( Lazysite::Manager::Domains::_clean_content_root('lazysite'),
        undef, 'the engine tree is still reserved' );
};

subtest 'the tree copier never descends into its own destination' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/src/sub");
    open my $fh, '>', "$d/src/sub/file.txt" or die $!;
    print {$fh} "x\n";
    close $fh;

    # The destination INSIDE the source: the F12 shape.
    my $dst = "$d/src/stage/out";
    Lazysite::Manager::SitePackage::_copy_tree( "$d/src", $dst );

    ok( -f "$dst/sub/file.txt", 'the real content was copied' );
    ok( !-e "$dst/stage/out",
        'and the destination was not copied into itself - this is where the '
            . 'walk used to feed on its own output until the kernel refused '
            . 'the path length, dying uncaught inside a CGI. The empty '
            . "$dst/stage that the walk creates on its way past is harmless; "
            . 'the recursion is the defect' );
};

# --- F11 --------------------------------------------------------------------
#
# install.pl's retention globs `lazysite-backup-*` - only the installer's own.
# Every manager artefact was out of its reach and nothing removed a prerestore
# snapshot ever. SM183 made every surface snapshot before an apply, and restore
# snapshots before every restore, each a full copy of the docroot content: an
# agent looping site_apply fills the disk, and on a shared instance that takes
# every hosted site down.
subtest 'snapshots are expired per kind' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/backups");
    make_path("$d/content");
    open my $fh, '>', "$d/content/page.md" or die $!;
    print {$fh} "body\n";
    close $fh;
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\nbackup_retention: 3\n";
    close $cf;

    local $Lazysite::Manager::Backups::DOCROOT      = $d;
    local $Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";

    my @manual;
    for ( 1 .. 5 ) {
        my $r = Lazysite::Manager::Backups::action_backup_create('manual');
        push @manual, $r->{name} if $r->{ok};
    }
    # A different kind, which must not be counted against manual's allowance.
    Lazysite::Manager::Backups::action_backup_create('prerestore') for 1 .. 2;

    opendir my $dh, "$d/lazysite/backups" or die $!;
    my @files = grep { /\.tar\.gz\z/ } readdir $dh;
    closedir $dh;

    my @kept_manual = grep { /manual/ } @files;
    is( scalar(@kept_manual), 3, 'the manual snapshots are held to the limit' );
    is( scalar( grep { /prerestore/ } @files ), 2,
        'and a different kind keeps its own - expiring an operator\'s deliberate '
            . 'snapshot because a plugin took twenty automatic ones would be the '
            . 'wrong trade' );

    # The newest survive, not an arbitrary three.
    my %kept = map { $_ => 1 } @kept_manual;
    ok( $kept{ $manual[-1] },
        'the snapshot taken most recently is still there - a retention rule that '
            . 'can delete the one you just took is worse than none' );
};

subtest 'retention 0 means unlimited' => sub {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/backups");
    make_path("$d/content");
    open my $fh, '>', "$d/content/page.md" or die $!;
    print {$fh} "body\n";
    close $fh;
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\nbackup_retention: 0\n";
    close $cf;

    local $Lazysite::Manager::Backups::DOCROOT      = $d;
    local $Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";

    Lazysite::Manager::Backups::action_backup_create('manual') for 1 .. 4;

    opendir my $dh, "$d/lazysite/backups" or die $!;
    my @files = grep { /\.tar\.gz\z/ } readdir $dh;
    closedir $dh;
    is( scalar(@files), 4,
        'matching install.pl, where 0 has always meant keep everything' );
};

done_testing();
