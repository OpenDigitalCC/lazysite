#!/usr/bin/perl
# SM1114 (U12): a PUT that fails leaves nothing behind, and says why.
#
# Field report (xisl.com, 2026-10-16): "One failed 7.5 MB PUT left
# /assets/video/xitext-motif-print-room.mp4.tmp.545808 in the tree, visible
# over WebDAV, until it was deleted by hand." The temp file was removed on the
# three failures do_put had named; a short body, a die and a signal were not
# among them - and a short body was worse than a leftover, it was renamed into
# place as if it were the whole file.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use IPC::Open3;
use POSIX ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_dav_site run_dav repo_root site_tempdir run_child feed_child reap_child);

my $root = repo_root();
local $SIG{PIPE} = 'IGNORE';

sub tmps {
    my ($dir) = @_;
    opendir my $dh, $dir or return ();
    my @t = grep { /\.tmp\.\d+\z/ } readdir $dh;
    closedir $dh;
    return @t;
}

# --- a body shorter than CONTENT_LENGTH is refused, not stored --------------
{
    my $s = setup_dav_site();
    my $r = run_dav(
        $s->{docroot}, 'PUT', '/content/cut.bin',
        body               => 'x' x 30_000,
        CONTENT_LENGTH     => 100_000,
        HTTP_AUTHORIZATION => $s->{auth},
    );
    is( $r->{code}, 400, 'a body that ends before CONTENT_LENGTH is a 400' );
    like( $r->{body}, qr/30000 of 100000 bytes/, 'the body says how far it got' );
    ok( !-e "$s->{docroot}/content/cut.bin", 'the cut-off upload was not renamed into place' );
    is_deeply( [ tmps("$s->{docroot}/content") ], [], 'and left no temp file' );
}

# --- a fault between create and rename answers with a cause, leaves no temp --
{
    my $s = setup_dav_site();
    local $ENV{PERL5OPT} = "-I$root/lib -I$root/t/lib -MDavDieBeforeRename";
    local $ENV{LAZYSITE_TEST_DIE_IN_PUT} = 1;
    my $r = run_dav(
        $s->{docroot}, 'PUT', '/content/boom.bin',
        body               => 'y' x 5000,
        HTTP_AUTHORIZATION => $s->{auth},
    );
    is( $r->{code}, 500, 'a die between create and rename answers 500 from the engine' );
    like( $r->{body}, qr/Cannot store the file/, 'with a body, not the front\'s generic page' );
    ok( !-e "$s->{docroot}/content/boom.bin", 'nothing landed' );
    is_deeply( [ tmps("$s->{docroot}/content") ], [], 'and the temp file is gone' );
}

# --- a write failure: ENOSPC is 507 naming the cause; the temp goes ---------
# /dev/full fails every write with ENOSPC - the real errno, not a stand-in. It
# is reached through a symlink in a tempdir so the cleanup unlinks the link and
# never the device.
{
    my $d    = site_tempdir();
    my $link = "$d/target.tmp.1";
    symlink '/dev/full', $link or die $!;
    my $drv = "$d/driver.pl";
    open my $fh, '>', $drv or die $!;
    print {$fh} <<'PERL';
$ENV{LAZYSITE_DAV_LOAD_ONLY} = 1;
do "$ARGV[0]/lazysite-dav.pl" or die $@ || $!;
open STDIN, '<', $0 or die;
my $st = main::_stream_body( $ARGV[1], 1048576, 40 );
print "failed=", ( $st->{failed} // '' ), " errno=", ( $st->{errno} + 0 ), "\n";
main::_write_failure( 'write the file', $st->{errno}, "$ARGV[2]/x" );
PERL
    close $fh;
    my $o = run_child( [ $^X, $drv, $root, $link, $d ] )->{out};
    my $enospc = POSIX::ENOSPC();
    like( $o, qr/failed=write errno=$enospc\b/, 'a write to a full device fails with ENOSPC' );
    like( $o, qr/Status: 507/, 'which is answered 507 Insufficient Storage' );
    like( $o, qr/storage is full/i, 'with a body naming the cause' );
    ok( !-l $link && !-e $link, 'and the temp file is removed' );
    ok( -e '/dev/full', 'the device itself is untouched' );
}

# --- another write error is a 500 whose body names the error ----------------
{
    my $d = site_tempdir();
    my $drv = "$d/driver.pl";
    open my $fh, '>', $drv or die $!;
    print {$fh} <<'PERL';
$ENV{LAZYSITE_DAV_LOAD_ONLY} = 1;
do "$ARGV[0]/lazysite-dav.pl" or die $@ || $!;
main::_write_failure( 'write the file', do { local $! = 27; $! }, "$ARGV[1]/x" );
PERL
    close $fh;
    my $o = run_child( [ $^X, $drv, $root, $d ] )->{out};
    like( $o, qr/Status: 500/, 'a non-space write error is a 500' );
    like( $o, qr/Cannot write the file: File too large/, 'whose body names the cause' );
}

# --- SIGTERM mid-read (the front timing out) removes the temp ---------------
{
    my $s = setup_dav_site();
    my $d = "$s->{docroot}/content";
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}           = $s->{docroot};
    $ENV{REQUEST_METHOD}          = 'PUT';
    $ENV{PATH_INFO}               = '/content/slow.bin';
    $ENV{SCRIPT_NAME}             = '/dav';
    $ENV{REMOTE_ADDR}             = '127.0.0.1';
    $ENV{LAZYSITE_DAV_FAIL_DELAY} = 0;
    $ENV{HTTP_AUTHORIZATION}      = $s->{auth};
    $ENV{CONTENT_LENGTH}          = 1_000_000;
    # SM1245: this test drives the child itself - it signals it mid-body, so it
    # holds the pid. Its output goes to files no pipe can fill, and the body and
    # the wait are bounded.
    my $logs = tempdir( CLEANUP => 1 );
    open my $cout, '>', "$logs/stdout" or die $!;
    open my $cerr, '>', "$logs/stderr" or die $!;
    my $pid = open3( my $in, '>&' . fileno($cout), '>&' . fileno($cerr), $^X, "$root/lazysite-dav.pl" );
    binmode $in;
    feed_child( $in, 'z' x 200_000, label => 'lazysite-dav.pl' );
    my $seen = 0;
    for ( 1 .. 100 ) {
        if ( tmps($d) && -s "$d/" . ( tmps($d) )[0] ) { $seen = 1; last }
        select undef, undef, undef, 0.05;
    }
    ok( $seen, 'the temp file exists while the body is still arriving' );
    kill 'TERM', $pid;
    reap_child( $pid, label => 'lazysite-dav.pl' );
    is_deeply( [ tmps($d) ], [], 'after SIGTERM the temp file is gone' );
    ok( !-e "$d/slow.bin", 'and no half file was stored' );
}

# --- a leftover temp is never listed ----------------------------------------
{
    my $s = setup_dav_site();
    my $d = "$s->{docroot}/content";
    for my $f ( 'keep.md', 'a.mp4.tmp.545808' ) {
        open my $fh, '>', "$d/$f" or die $!;
        print {$fh} "x\n";
        close $fh;
    }
    my $r = run_dav( $s->{docroot}, 'PROPFIND', '/content/',
        HTTP_AUTHORIZATION => $s->{auth}, HTTP_DEPTH => 1 );
    like( $r->{body}, qr/keep\.md/, 'a real file is listed' );
    unlike( $r->{body}, qr/tmp\.545808/, 'the engine\'s own temp name is not' );
}

# --- the next PUT of the same name sweeps stale leftovers -------------------
{
    my $s = setup_dav_site();
    my $d = "$s->{docroot}/content";
    for my $f ( 'a.bin.tmp.111', 'a.bin.tmp.222', 'b.bin.tmp.333' ) {
        open my $fh, '>', "$d/$f" or die $!;
        print {$fh} "x\n";
        close $fh;
    }
    my $old = time - 7200;
    utime $old, $old, "$d/a.bin.tmp.111", "$d/b.bin.tmp.333";
    my $r = run_dav( $s->{docroot}, 'PUT', '/content/a.bin',
        body => 'ok', HTTP_AUTHORIZATION => $s->{auth} );
    is( $r->{code}, 201, 'the PUT succeeds' );
    ok( !-e "$d/a.bin.tmp.111", 'a stale leftover of the same name is removed' );
    ok( -e "$d/a.bin.tmp.222", 'a fresh one (another upload in flight) is kept' );
    ok( -e "$d/b.bin.tmp.333", 'and another file\'s leftover is not this PUT\'s business' );
}

done_testing;
