#!/usr/bin/perl
# SM769: a backup reaches the private store without opening its parent.
#
# The store is the docroot's sibling; their parent is the domain folder, which
# on the Hestia layout is root-owned 0551 - traversable by the request path,
# not readable. GNU tar opens a -C directory O_RDONLY, so `-C parent leaf` died
# with "Cannot open: Permission denied" and the Backups page's own button had
# never worked on such a host. The fixture is that layout: a parent with x and
# no r. Root reads everything, so root skips.
use strict;
use warnings;
use Test::More;
use File::Temp     qw(tempdir);
use File::Path     qw(make_path);
use File::Basename qw(basename);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Backups qw(action_backup_create action_backup_restore);
use Lazysite::Private          qw(private_path private_root);

plan skip_all => 'root opens every directory; the layout cannot be reproduced' if $> == 0;

my $base   = tempdir( CLEANUP => 1 );
my $parent = "$base/domain";
my $d      = "$parent/public_html";
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

spit( "$d/open/public.md",                     "PUBLICBYTES\n" );
spit( private_path( $d, 'members/secret.md' ), "PRIVATEBYTES\n" );
my $LEAF = basename( private_root($d) );

# the layout: the parent may be walked through, never read
chmod 0311, $parent;
END { chmod 0755, $parent if defined $parent }
ok( !opendir( my $dh, $parent ), 'the fixture parent cannot be opened for reading' );

my $created = action_backup_create('manual');
ok( $created->{ok}, 'a backup is created through an unreadable parent' ) or diag( $created->{error} // '', ' ', $created->{detail} // '' );
my $name = $created->{name};

subtest 'the archive is the same archive as on a readable parent' => sub {
    my $listing = `tar tzf \Q$d/lazysite/backups/$name\E 2>/dev/null`;
    like( $listing, qr{^\Q$LEAF\E/members/secret\.md$}m, 'the store member keeps its spelling (leaf/..., no ../)' );
    like( $listing, qr{^\./open/public\.md$}m, 'and the docroot members keep theirs' );
    unlike( $listing, qr{\.\./}, 'nothing in the archive climbs' );
};

subtest 'and a restore puts the store back through the same parent' => sub {
    unlink private_path( $d, 'members/secret.md' );
    unlink "$d/open/public.md";
    my $r = action_backup_restore($name);
    ok( $r->{ok}, 'the restore succeeds' ) or diag( $r->{error} // '' );
    is( slurp( private_path( $d, 'members/secret.md' ) ), "PRIVATEBYTES\n", 'the gated file is back in the store' );
    is( slurp("$d/open/public.md"), "PUBLICBYTES\n", 'and the docroot content' );
    ok( !-e "$d/$LEAF", 'the store was not extracted into the docroot' );
};

subtest 'a failure names the unix user' => sub {
    # the docroot itself made unreadable: tar cannot -C into it
    chmod 0311, $d;
    my $r = action_backup_create('manual');
    chmod 0755, $d;
    ok( !$r->{ok}, 'the backup fails' );
    my ($who) = getpwuid($>);
    is( $r->{unix_user}, $who // $>, 'and says which unix user could not read the tree' );
    like( $r->{reason}, qr/tar exited/, 'with tar\'s exit status' );
    unlike( $r->{detail} // '', qr{\Q$base\E}, 'and never the host path' );
};

done_testing;
