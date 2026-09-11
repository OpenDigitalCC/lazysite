#!/usr/bin/perl
# SM852 S4: restoring a backup taken before a folder was protected keeps it
# protected.
#
# The restore extracted the archive's content straight into the docroot. A
# backup taken while members/ was public, restored after members/ was protected,
# put the folder's pages back in the served tree beside the private copies the
# engine serves - and as a public folder, so every later write under it left the
# store too. Nothing re-synced the store afterwards, and the rule still read as
# applied.
#
# Found by the SM836 review; reproduced before the fix.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path remove_tree);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper                 qw(site_tempdir);
use Lazysite::Manager::Backups qw(action_backup_create action_backup_restore);

my $d    = site_tempdir();
my $priv = "$d-lazysite-private";
make_path( "$d/lazysite", "$d/members" );

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t }

spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$d/about.md",               "# About\nPUBLIC-THEN\n" );
spit( "$d/members/handbook.md",    "# Handbook\nFROM-THE-BACKUP\n" );
{
    no warnings 'once';
    $Lazysite::Manager::Backups::DOCROOT      = $d;
    $Lazysite::Manager::Backups::LAZYSITE_DIR = "$d/lazysite";
    $Lazysite::Manager::Backups::auth_user    = 'tester';
}

my $b = action_backup_create('manual');
ok( $b->{ok}, 'the canary: a backup is taken while members/ is public' ) or BAIL_OUT( $b->{error} // '' );

# Now protect members/: the section moves into the private store, and is edited.
make_path("$priv/members");
rename "$d/members/handbook.md", "$priv/members/handbook.md" or die $!;
remove_tree("$d/members");
spit( "$priv/members/handbook.md", "# Handbook\nEDITED-SINCE\n" );
spit( "$d/about.md",               "# About\nEDITED-SINCE\n" );

my $r = action_backup_restore( $b->{name} );
ok( $r->{ok}, 'restored' ) or diag explain $r;

like( slurp("$d/about.md"), qr/PUBLIC-THEN/, 'a public page comes back where it was' );
like( slurp("$priv/members/handbook.md"), qr/FROM-THE-BACKUP/,
    'a page in the now-protected section comes back IN the private store' );
ok( !-e "$d/members", 'and no public copy of the section was made in the served tree' );

done_testing();
