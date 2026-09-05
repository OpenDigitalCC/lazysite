#!/usr/bin/perl
# SM753 (the sidecar half): when the manager's retention expires a snapshot, or
# an operator deletes one, the .sha256 that describes it goes too. install.pl's
# rotation has always done this (SM183); the manager's left a sidecar for every
# archive it removed, describing a file that no longer existed - found by the
# opportunistic-maintenance survey behind SM666's jobs.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Backups qw(action_backup_create action_backup_delete _apply_retention);

my $t = tempdir( CLEANUP => 1 );
mkdir "$t/site";
my $d = "$t/site/public_html";
make_path("$d/lazysite/logs");
open my $fh, '>', "$d/index.html" or die $!;
print {$fh} "<h1>x</h1>\n";
close $fh;
open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: t\nbackup_retention: 1\n";
close $c;
$Lazysite::Manager::Backups::DOCROOT      = $d;
$Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";
$Lazysite::Manager::Backups::auth_user    = 'op';

sub archives {
    opendir my $dh, "$d/lazysite/backups" or return ();
    my @e = sort grep { !/^\./ } readdir $dh;
    closedir $dh;
    return @e;
}

subtest 'retention retires the archive AND its sidecar' => sub {
    my $a = action_backup_create();
    ok( $a->{ok}, 'first snapshot' ) or diag $a->{error};
    ok( -f "$d/lazysite/backups/$a->{name}.sha256", 'it carries a sidecar' );

    # the second must sort newer: mtimes decide, so age the first
    my $old = "$d/lazysite/backups/$a->{name}";
    utime time - 100, time - 100, $old, "$old.sha256";
    my $b = action_backup_create();
    ok( $b->{ok}, 'second snapshot; retention 1 expires the first' ) or diag $b->{error};

    my @left = archives();
    ok( !-f $old,          'the old archive is gone' );
    ok( !-f "$old.sha256", 'and so is its sidecar - no orphan describing a missing archive' )
        or diag explain \@left;
    is_deeply( [ grep { /\.sha256$/ } @left ], ["$b->{name}.sha256"], 'exactly one sidecar remains, the survivor\'s' );
};

subtest 'a deliberate delete takes the sidecar too' => sub {
    my ($name) = grep { /\.tar\.gz$/ } archives();
    ok( -f "$d/lazysite/backups/$name.sha256", 'the survivor has a sidecar' );
    my $r = action_backup_delete($name);
    ok( $r->{ok},                               'deleted' ) or diag $r->{error};
    ok( !-f "$d/lazysite/backups/$name.sha256", 'sidecar removed with it' );
    is_deeply( [ archives() ], [], 'the directory is clean' );
};

done_testing();
