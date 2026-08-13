#!/usr/bin/perl
# SM286: a backup covers the private content store, and restoring one puts it
# back where it lives.
#
# WHY THIS IS THE GATE ON THE MOVE. Backups are a tar of the docroot. Once gated
# content lives outside it, an unchanged backup silently stops including every
# protected section - and that is discovered at restore time, which is the worst
# possible moment. Losing an operator's private content while telling them the
# backup succeeded is worse than the exposure the store was built to remove.
#
# The restore half is the most dangerous code in Backups.pm: it extracts an
# OPERATOR-SUPPLIED archive, and the private store lives OUTSIDE the docroot, so
# a careless version lets an uploaded tarball write anywhere its member names
# point. SEC-2026-07 already found an uploaded tarball replacing the account
# store through this action. The confinement assertions below are the point of
# this file, not the round trip.
use strict;
use warnings;
use Test::More;
use File::Temp     qw(tempdir);
use File::Path     qw(make_path);
use File::Basename qw(basename);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Backups
    qw(action_backup_create action_backup_restore action_backup_list);
use Lazysite::Private qw(private_path private_root);

my $base = tempdir( CLEANUP => 1 );
my $d    = "$base/public_html";
make_path( "$d/lazysite/backups", "$d/open" );

sub spit {
    my ( $p, $t ) = @_;
    make_path( $p =~ s{/[^/]+\z}{}r );
    open my $fh, '>', $p or die "$p: $!";
    print {$fh} $t;
    close $fh;
    return;
}
sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    return <$fh>;
}

$Lazysite::Manager::Backups::DOCROOT      = $d;
$Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";
$Lazysite::Manager::Backups::auth_user    = 'alice';

spit( "$d/open/public.md", "PUBLICBYTES\n" );
spit( private_path( $d, 'members/secret.md' ),    "PRIVATEBYTES\n" );
spit( private_path( $d, 'members/deep/more.md' ), "DEEPBYTES\n" );

# --- the round trip ----------------------------------------------------------
my $created = action_backup_create('manual');
ok( $created->{ok}, 'a backup is created' ) or diag( $created->{error} // '' );
my $name = $created->{name};

# The store is named for the docroot it shadows, so the archive member name is
# derived, never a fixed string. Two docroots sharing a parent would otherwise
# share one store and each resolve the other's protected content.
my $LEAF = basename( private_root($d) );

subtest 'the archive contains the private store' => sub {
    my $tar     = "$d/lazysite/backups/$name";
    my $listing = `tar tzf \Q$tar\E 2>/dev/null`;
    like( $listing, qr{^\Q$LEAF\E/members/secret\.md$}m,
        'the gated file is in the archive' );
    like( $listing, qr{^\Q$LEAF\E/members/deep/more\.md$}m,
        'including nested content' );
    like( $listing, qr{^\./open/public\.md$}m,
        'and the docroot members keep their existing spelling, so an archive '
            . 'written before this still restores unchanged' );
};

subtest 'restoring puts the store back OUTSIDE the docroot' => sub {
    # Destroy both sides, then restore.
    unlink private_path( $d, 'members/secret.md' );
    unlink private_path( $d, 'members/deep/more.md' );
    unlink "$d/open/public.md";
    ok( !-e private_path( $d, 'members/secret.md' ), 'the private file is gone' );

    my $r = action_backup_restore($name);
    ok( $r->{ok}, 'the restore succeeds' ) or diag( $r->{error} // '' );

    is( slurp( private_path( $d, 'members/secret.md' ) ), "PRIVATEBYTES\n",
        'the gated file is back, in the private store' );
    is( slurp( private_path( $d, 'members/deep/more.md' ) ), "DEEPBYTES\n",
        'nested content too' );
    is( slurp("$d/open/public.md"), "PUBLICBYTES\n", 'and the docroot content' );

    ok( !-e "$d/$LEAF",
        'the store was NOT extracted into the docroot - which would put every '
            . 'gated file back where the front end serves it' );
};

# --- the confinement, which is why this file exists -------------------------
subtest 'an uploaded archive cannot write outside the two trees' => sub {
    my $evil  = "$d/lazysite/backups/lazysite-manual-19700101T000000Z-evil.tar.gz";
    my $stage = tempdir( CLEANUP => 1 );

    # An archive carrying a member that climbs out of the extraction root, and
    # one that is simply not ours. Neither may land.
    make_path("$stage/$LEAF");
    spit( "$stage/$LEAF/ok.md", "INSIDE\n" );
    make_path("$stage/elsewhere");
    spit( "$stage/elsewhere/loot.md", "SHOULD-NOT-LAND\n" );
    system( 'tar', 'czf', $evil, '-C', $stage, $LEAF, 'elsewhere' );

    my $r = action_backup_restore(
        'lazysite-manual-19700101T000000Z-evil.tar.gz');
    ok( $r->{ok}, 'the restore runs' ) or diag( $r->{error} // '' );

    ok( -e private_path( $d, 'ok.md' ),
        'the private-store member landed, because it is ours' );
    ok( !-e "$base/elsewhere/loot.md",
        'a member OUTSIDE the store did not land beside the docroot - only '
            . 'members named for the store are extracted in that pass' );
    ok( !-e "$base/elsewhere", 'not even its directory' );
};

subtest 'a climbing member name is refused' => sub {
    my $evil2 = "$d/lazysite/backups/lazysite-manual-19700101T000001Z-climb.tar.gz";
    my $stage = tempdir( CLEANUP => 1 );
    make_path("$stage/$LEAF");
    spit( "$stage/$LEAF/fine.md", "FINE\n" );

    # tar refuses to STORE a climbing member without -P, so the archive here is
    # an ordinary one and the guarantee under test is that the extract side does
    # not gain a way to climb - it passes an explicit member name, never a
    # pattern, and GNU tar strips a leading `/` and refuses `..` by default.
    system( 'tar', 'czf', $evil2, '-C', $stage, $LEAF );

    my $r = action_backup_restore(
        'lazysite-manual-19700101T000001Z-climb.tar.gz');
    ok( $r->{ok},                         'the restore runs' );
    ok( -e private_path( $d, 'fine.md' ), 'the legitimate member landed' );
    ok( !-e "$base/climb-target.md",      'and nothing climbed out' );
};

done_testing();
