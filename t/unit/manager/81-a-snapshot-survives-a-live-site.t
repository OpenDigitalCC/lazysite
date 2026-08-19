#!/usr/bin/perl
# SM381: a backup of a LIVE docroot must not fail because the site is live.
#
# THE FIELD FAILURE THIS EXPLAINS. site_apply refused with "safety snapshot
# failed" on a busy instance while site_backup on the same host succeeded in
# both directions minutes later. SM378 made the refusal say why; this is what it
# was going to say.
#
# tar uses exit 1 for a WARNING - a file changed or vanished while being read -
# and 2 for a fatal error. The snapshot treated both as fatal. The render cache
# writes "<page>.html.tmp.<pid>" into the docroot and renames it into place, so
# a single visitor arriving mid-backup lets tar enumerate a file that is gone
# before it can be opened. Exit 1, and the whole apply refuses.
#
# It predicts every symptom that was reported: intermittent, traffic-correlated,
# invisible to a manual backup taken at a quiet moment, and reproducible only on
# a site with traffic.
#
# MEASURED, not argued: with the old behaviour this fixture failed 3 times out
# of 3 with "tar exited 1".
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

sub live_site {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/backups");
    # Enough files that the tar takes long enough for the race to happen at all.
    for my $i ( 1 .. 300 ) {
        open my $f, '>', "$d/page$i.html" or die $!;
        print {$f} 'x' x 2000;
        close $f;
    }
    return $d;
}

subtest 'a snapshot taken while pages are being rendered still succeeds' => sub {
    my $d = live_site();
    local $Lazysite::Manager::Backups::DOCROOT      = $d;
    local $Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";

    # A writer doing exactly what the render cache does: write a tempfile into
    # the docroot and rename it away.
    my $pid = fork();
    die 'fork failed' unless defined $pid;
    if ( !$pid ) {
        for ( 1 .. 4000 ) {
            my $t = "$d/index.html.tmp.$$";
            open my $f, '>', $t or next;
            print {$f} 'y' x 4000;
            close $f;
            rename $t, "$d/index.html";
        }
        exit 0;
    }

    my $r = Lazysite::Manager::Backups::action_backup_create('prerestore');
    kill 'TERM', $pid;
    waitpid $pid, 0;

    ok( $r->{ok}, 'the snapshot succeeds against a live docroot' )
        or diag( 'reason: '
            . ( $r->{reason} // '-' )
            . "\nA site with visitors could not be snapshotted at all, so a "
            . 'safety snapshot - the thing that makes an apply reversible - '
            . 'failed precisely on the sites where reversibility matters.' );
    ok( length( $r->{name} // '' ), 'and names the archive it wrote' );

    # The tolerance is not blanket: what tar produced has to be restorable.
    if ( $r->{ok} ) {
        my $out = "$d/lazysite/backups/$r->{name}";
        ok( -s $out, 'the archive is non-empty' );
        is( system( 'gzip', '-t', $out ), 0,
            'and is a readable gzip stream, which is what makes a warning '
                . 'acceptable rather than merely quiet' );
    }
};

subtest 'a genuinely broken tar still fails' => sub {
    # The tolerance must not swallow a real failure. A docroot that does not
    # exist is tar exit 2.
    my $d = live_site();
    local $Lazysite::Manager::Backups::DOCROOT      = "$d/no-such-docroot";
    local $Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";

    my $r = Lazysite::Manager::Backups::action_backup_create('prerestore');
    ok( !$r->{ok}, 'a fatal tar is still a failure' )
        or diag( 'Accepting exit 2 would mean an apply proceeding with no '
            . 'usable rollback, which is the one thing the refusal exists '
            . 'to prevent.' );
    like( $r->{error}, qr/tar exited/, 'and it still says why' );
};

done_testing();
