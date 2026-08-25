#!/usr/bin/perl
# SM544: a restore's prerestore safety snapshot exists so the restore can be
# rolled back. _archive_scope decides what it covers, from the archive's
# members. It skipped bare top-level members and its deepening loop returned
# at tar's own directory entry for the prefix, so an archive carrying
# ./index.md and ./sites/edge/page.md was scoped to sites/ - and the restore
# overwrote index.md with no rollback copy. Found by the backups structural
# review (N1) and proven by probe tmp/bp-probe-archive-scope.t.
#
# The rule now: a bare file at any level widens the scope to its parent (the
# root, for a top-level file), and directory entries are skipped when
# deepening.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Backups ();

sub spit  { open my $fh, '>', $_[0] or die $!;    print {$fh} $_[1]; close $fh }
sub slurp { open my $fh, '<', $_[0] or return ''; local $/;          <$fh> }

sub members {
    my ($path) = @_;
    open my $fh, '-|', 'tar', 'tzf', $path or die "tar: $!";
    my @m = <$fh>;
    close $fh;
    chomp @m;
    return @m;
}

sub tar_of {
    my ( $out, $dir, @args ) = @_;
    system( 'tar', 'czf', $out, '-C', $dir, @args ) == 0 or die "tar failed";
    return $out;
}

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/backups", "$d/sites/edge" );
spit( "$d/lazysite/lazysite.conf", "site_name: probe\n" );
spit( "$d/index.md",               "OLD\n" );
spit( "$d/sites/edge/page.md",     "edge old\n" );
spit( "$d/sites/loose.md",         "loose\n" );
$Lazysite::Manager::Backups::DOCROOT      = $d;
$Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";
my $bk = "$d/lazysite/backups";

# --- the scope rule ---------------------------------------------------------
subtest 'a bare top-level file widens the scope to the root' => sub {
    my $arch = tar_of( "$bk/lazysite-manual-20260101T000000Z.tar.gz",
        $d, '--exclude=./lazysite', '--exclude=./sites/loose.md', '.' );
    is( Lazysite::Manager::Backups::_archive_scope($arch), undef,
        './index.md beside ./sites/edge/ means the whole content tree is the blast radius' );
};

subtest 'an unscoped archive of one subtree deepens past the directory entries' => sub {
    my $arch = tar_of( "$bk/lazysite-manual-20260101T000001Z.tar.gz",
        $d, '--no-recursion', './sites', './sites/edge', './sites/edge/page.md' );
    my @m = members($arch);
    ok( ( grep { $_ eq './sites/' } @m ) == 1,
        'tar listed the directory entry for sites/ itself' )
        or diag "@m";
    is( Lazysite::Manager::Backups::_archive_scope($arch), 'sites/edge',
        'scoped to sites/edge, as a scoped backup of that tree would be' );
};

subtest 'a bare file at a deeper level stops the scope at its parent' => sub {
    my $arch = tar_of( "$bk/lazysite-manual-20260101T000002Z.tar.gz",
        $d, './sites/loose.md', './sites/edge' );
    is( Lazysite::Manager::Backups::_archive_scope($arch), 'sites',
        './sites/loose.md beside ./sites/edge/ scopes to sites' );
};

# --- and the restore's safety snapshot follows it ----------------------------
subtest 'the safety snapshot carries the top-level file the restore overwrites' => sub {
    # Live site has moved on since the archive was taken.
    spit( "$d/index.md", "NEW\n" );
    my $r = Lazysite::Manager::Backups::action_backup_restore(
        'lazysite-manual-20260101T000000Z.tar.gz');
    is( $r->{ok},             1,       'restore ok' ) or diag explain $r;
    is( slurp("$d/index.md"), "OLD\n", 'the restore overwrote index.md' );
    ok( length( $r->{safety} // '' ), 'a safety snapshot was named' ) or return;
    my @m = members("$bk/$r->{safety}");
    ok( ( grep { $_ eq './index.md' } @m ),
        'the prerestore snapshot carries ./index.md - the rollback copy exists' )
        or diag "safety members: @m";
    open my $fh, '-|', 'tar', 'xzOf', "$bk/$r->{safety}", './index.md' or die $!;
    my $body = do { local $/; <$fh> };
    close $fh;
    is( $body, "NEW\n", 'and it is the pre-restore content' );
};

done_testing;
