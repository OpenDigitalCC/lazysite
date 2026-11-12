#!/usr/bin/perl
# SM1446 (ruling 206): lazysite check NAMES A BACKUP THAT DID NOT FINISH.
#
# A request killed mid-tar leaves the claimed name as an empty file, and a backup
# tar wrote through its own name (every one before SM885) can stop part way. The
# listing no longer offers either as a backup; the check says each is there, its
# date, and how to remove it - and a staging directory a killed backup left behind.
# A finished backup and an empty backups directory give no such line.
#
# Sabotage: drop the report_unfinished_backups() call and the named-file subtest fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $tool = repo_root() . '/tools/lazysite-check.pl';

sub spit { my ( $p, $t ) = @_; make_path( $p =~ s{/[^/]+\z}{}r ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh }

my $d  = site_tempdir();
my $bk = "$d/lazysite/backups";
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$d/index.md",               "---\ntitle: T\n---\nbody\n" );
make_path($bk);

sub run { return run_child( [ $^X, $tool, '--docroot', $d ], stderr => 'inherit' )->{out} // '' }

subtest 'no unfinished backup, no line' => sub {
    require IO::Compress::Gzip;
    IO::Compress::Gzip::gzip( \'whole' => "$bk/lazysite-manual-20261101T101010Z.tar.gz" )
        or die $IO::Compress::Gzip::GzipError;
    my $out = run();
    unlike( $out, qr/unfinished backup|staging directory/, 'a finished backup is not named' ) or diag $out;
};

subtest 'an empty claim, a cut-off archive and a staging directory are each named' => sub {
    spit( "$bk/lazysite-full-20261112T065507Z.tar.gz", '' );
    utime 1_794_466_507, 1_794_466_507, "$bk/lazysite-full-20261112T065507Z.tar.gz";
    spit( "$bk/lazysite-full-20260715T080000Z.tar.gz", "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03" . ( "\x55" x 64 ) );
    make_path("$bk/.stage-999999999-1794466507");
    my $out = run();
    like( $out, qr/an unfinished backup: lazysite\/backups\/lazysite-full-20261112T065507Z\.tar\.gz \(dated 2026-11-12 06:55 UTC, 0 bytes\) holds no finished archive; it is not listed or offered as a backup/,
        'the empty claim, with its date and size' ) or diag $out;
    like( $out, qr/if no backup is being taken now, remove it: Delete on the Backups page \(backup-delete name=lazysite-full-20261112T065507Z\.tar\.gz\), or rm lazysite\/backups\/lazysite-full-20261112T065507Z\.tar\.gz/,
        'and how to remove it' );
    like( $out, qr/an unfinished backup: lazysite\/backups\/lazysite-full-20260715T080000Z\.tar\.gz/,
        'the archive that stops part way' );
    like( $out, qr/a backup's staging directory is left in lazysite\/backups\/\.stage-999999999-1794466507 .*rm -r lazysite\/backups\/\.stage-999999999-1794466507/s,
        'and the staging directory, with its remedy' );
    unlike( $out, qr/lazysite-manual-20261101T101010Z/, 'the finished one is still not named' );
};

done_testing();
