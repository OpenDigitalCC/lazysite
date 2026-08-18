#!/usr/bin/perl
# SM378: a refusal that will not say why is its own defect.
#
# MEASURED IN THE FIELD. A partner agent packaging one domain and applying it to
# another was stopped by:
#
#   {"ok":false,"error":"Refusing to apply: safety snapshot failed",
#    "kind":"snapshot-failed"}
#
# with no path, no errno and no detail - while site_backup on the SAME host
# succeeded in both directions minutes later, including after the apply had
# already failed. So the host could be snapshotted and the apply path's snapshot
# of it could not, and nothing in the refusal could tell the two apart. Three
# attempts, two surfaces, with and without `clean`, identical refusal.
#
# THE CAUSE WAS NOT MISSING, IT WAS DISCARDED - at two levels. tar's exit status
# and stderr were thrown away by action_backup_create in favour of the string
# 'Backup failed', and then even that was thrown away by the apply in favour of
# 'safety snapshot failed'. THREE call sites did the same discard.
#
# The refusal itself is correct and stays: an apply overwrites content, and the
# only thing worse than being unable to roll back is believing you can.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                 ();
use Lazysite::Manager::Backups ();

sub fixture {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/backups");
    open my $f, '>', "$d/index.md" or die $!;
    print {$f} "hi\n";
    close $f;
    return $d;
}

subtest 'a healthy snapshot is unaffected' => sub {
    my $d = fixture();
    local $Lazysite::Manager::Backups::DOCROOT      = $d;
    local $Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";
    my $r = Lazysite::Manager::Backups::action_backup_create('prerestore');
    ok( $r->{ok}, 'the snapshot succeeds' ) or diag( $r->{error} // '' );
    ok( length( $r->{name} // '' ), 'and names the archive it wrote' );
};

subtest 'a failed snapshot reports the cause it was handed' => sub {
    my $d = fixture();
    local $Lazysite::Manager::Backups::DOCROOT      = "$d/no-such-docroot";
    local $Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";
    my $r = Lazysite::Manager::Backups::action_backup_create('prerestore');

    ok( !$r->{ok}, 'it still refuses' );
    like( $r->{error}, qr/tar exited \d+/,
        'and the error names what actually failed' )
        or diag( 'Got: ' . ( $r->{error} // 'undef' ) . "\n"
            . 'A bare "Backup failed" turns a diagnosable fault into a wall - '
            . 'which is what a partner agent met, three times, on two '
            . 'surfaces.' );
    ok( length( $r->{detail} // '' ), 'and carries the underlying message' );

    # THE STANDING RULE: filesystem paths are never exposed. tar's stderr is
    # full of them, so the detail is scrubbed rather than passed through raw -
    # a remote caller learns about their site, not about the host.
    unlike( $r->{detail}, qr{\Q$d\E},
        'with the real filesystem path scrubbed out' )
        or diag('tar names absolute paths in almost every message it emits.');
    like( $r->{detail}, qr/<site>|<path>/,
        'replaced by a placeholder that still shows the shape' );
};

subtest 'the three conditions are told apart' => sub {
    # tar exiting non-zero, tar writing nothing, and tar writing an empty
    # archive are different faults. Sharing one message is what made the
    # original unusable.
    my $src = do {
        my $p = "$FindBin::Bin/../../../lib/Lazysite/Manager/Backups.pm";
        $p = "$FindBin::Bin/../../lib/Lazysite/Manager/Backups.pm" unless -f $p;
        open my $fh, '<', $p or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/tar reported success but wrote no archive/,
        'the missing-archive case has its own words' );
    like( $src, qr/tar wrote an empty archive/,
        'and so does the empty-archive case' );
};

subtest 'no caller discards the cause any more' => sub {
    my $root = "$FindBin::Bin/../../..";
    $root = "$FindBin::Bin/../.." unless -d "$root/lib/Lazysite";
    for my $rel (
        'lib/Lazysite/Manager/SitePackage.pm',
        'lib/Lazysite/Manager/Backups.pm',
        'lazysite-manager-api.pl',
        )
    {
        my $p = "$root/$rel";
        next unless -f $p;
        my $src = do { open my $fh, '<', $p or die $!; local $/; <$fh> };
        unlike( $src, qr/safety snapshot failed'\s*\}/,
            "$rel does not return a bare refusal" )
            or diag( 'This is the discard, in one of the three places that had '
                . 'it. The cause exists; returning without it is the defect.' );
    }
};

done_testing();
