#!/usr/bin/perl
# SM019: unit tests for check_upload_rate. Uses an isolated temp
# docroot so the .upload-rate.db file does not collide with a running
# dev server's rate state.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

eval { require DB_File };
plan skip_all => 'DB_File not available' if $@;

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/manager");

BEGIN {
    $ENV{LAZYSITE_API_LOAD_ONLY} = 1;
}
$ENV{DOCUMENT_ROOT} = $docroot;

my $root = repo_root();
{
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

sub write_conf {
    my ($body) = @_;
    open my $fh, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print $fh $body;
    close $fh;
    main::_reset_upload_limits_cache();
}

sub reset_rate_db {
    unlink "$docroot/lazysite/manager/.upload-rate.db";
}

# --- allow under limit ---

subtest 'allows request under count limit' => sub {
    write_conf("manager_upload_rate_count: 5\n"
             . "manager_upload_rate_mb: 100\n");
    reset_rate_db();
    for my $i ( 1 .. 3 ) {
        my $r = main::check_upload_rate( 'alice', 1024 );
        is( $r->{ok}, 1, "request $i under count limit ok" );
    }
};

subtest 'rejects when count limit reached' => sub {
    write_conf("manager_upload_rate_count: 2\n"
             . "manager_upload_rate_mb: 100\n");
    reset_rate_db();
    my $r1 = main::check_upload_rate( 'bob', 1024 );
    is( $r1->{ok}, 1, 'first request ok' );
    my $r2 = main::check_upload_rate( 'bob', 1024 );
    is( $r2->{ok}, 1, 'second request ok' );
    my $r3 = main::check_upload_rate( 'bob', 1024 );
    is( $r3->{ok}, 0, 'third request rejected' );
    like( $r3->{error}, qr/rate limit/i, 'error mentions rate limit' );
};

subtest 'rejects when bytes limit would be exceeded' => sub {
    write_conf("manager_upload_rate_count: 100\n"
             . "manager_upload_rate_mb: 1\n");    # 1 MB
    reset_rate_db();
    my $half_meg = 512 * 1024;
    my $r1 = main::check_upload_rate( 'carol', $half_meg );
    is( $r1->{ok}, 1, 'first 0.5MB ok' );
    my $r2 = main::check_upload_rate( 'carol', $half_meg );
    is( $r2->{ok}, 1, 'second 0.5MB ok (exactly at limit)' );
    my $r3 = main::check_upload_rate( 'carol', 1 );
    is( $r3->{ok}, 0, 'one byte over rejected' );
    like( $r3->{error}, qr/size limit/i, 'error mentions size limit' );
};

subtest 'both limits at 0 is a no-op' => sub {
    write_conf("manager_upload_rate_count: 0\n"
             . "manager_upload_rate_mb: 0\n");
    reset_rate_db();
    for my $i ( 1 .. 10 ) {
        my $r = main::check_upload_rate( 'dave', 999_999_999 );
        is( $r->{ok}, 1, "request $i bypasses rate when both disabled" );
    }
};

subtest 'users share no budget' => sub {
    write_conf("manager_upload_rate_count: 2\n"
             . "manager_upload_rate_mb: 100\n");
    reset_rate_db();
    main::check_upload_rate( 'eve',  1024 );
    main::check_upload_rate( 'eve',  1024 );
    main::check_upload_rate( 'faye', 1024 );
    my $e = main::check_upload_rate( 'eve',  1024 );
    my $f = main::check_upload_rate( 'faye', 1024 );
    is( $e->{ok}, 0, 'eve exceeded own budget' );
    is( $f->{ok}, 1, 'faye still under budget' );
};

subtest 'ages out buckets older than 2 hours' => sub {
    write_conf("manager_upload_rate_count: 2\n"
             . "manager_upload_rate_mb: 100\n");
    reset_rate_db();
    # Manually seed the DB with a stale bucket two hours ago
    my $stale_hour = int( time() / 3600 ) - 5;
    require DB_File;
    require Fcntl;
    my %db;
    tie %db, 'DB_File', "$docroot/lazysite/manager/.upload-rate.db",
        Fcntl::O_RDWR() | Fcntl::O_CREAT(), 0o600, $DB_File::DB_HASH
        or die "tie: $!";
    $db{"ghost:$stale_hour:count"} = 9999;
    $db{"ghost:$stale_hour:bytes"} = 9999;
    untie %db;

    # A new request should trigger the age-out loop
    my $r = main::check_upload_rate( 'newcomer', 1024 );
    is( $r->{ok}, 1, 'new request proceeds' );

    tie %db, 'DB_File', "$docroot/lazysite/manager/.upload-rate.db",
        Fcntl::O_RDWR(), 0o600, $DB_File::DB_HASH or die "re-tie: $!";
    ok( !exists $db{"ghost:$stale_hour:count"},
        'stale bucket aged out' );
    untie %db;
};

done_testing();
