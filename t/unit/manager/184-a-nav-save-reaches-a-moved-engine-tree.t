#!/usr/bin/perl
# SM850: a nav save on a site whose engine tree moved out of the docroot lands
# in that tree - the file the processor renders with.
#
# The nav file is named site-relative - `lazysite/nav.conf` by default, or a
# domain's `alias.<host>.nav_file: lazysite/nav-2.conf` - and the manager joined
# it to the docroot. On a migrated site (`<docroot>-lazysite/`, SM293) that is a
# directory that is not there: the save made a stray engine tree inside the
# served tree, answered ok, and the live nav did not change. Lazysite::Paths::
# site_path now says where a site-relative path lives, and a leading `lazysite/`
# means the engine tree wherever it is; the processor's _nav_file_for carries
# the same rule and t/lint/37 drives the two against each other.
#
# Found by the SM836 review; reproduced before the fix.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper                 qw(site_tempdir);
use Lazysite::Paths            ();
use Lazysite::Manager::Nav     ();
use Lazysite::Manager::Domains ();
use Lazysite::Manager::Themes  ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t }

my $d  = site_tempdir();
my $lz = Lazysite::Paths::external_lazysite_dir($d);
make_path( $d, "$lz/cache" );
spit( "$lz/lazysite.conf",
    "site_name: T\nalias_hosts: sub.example\nalias.sub.example.nav_file: lazysite/nav-sub.conf\n" );
spit( "$lz/nav.conf",     "Old | /\n" );
spit( "$lz/nav-sub.conf", "Old sub | /\n" );
{
    no warnings 'once';
    $Lazysite::Manager::Nav::DOCROOT         = $d;
    $Lazysite::Manager::Nav::LAZYSITE_DIR    = $lz;
    $Lazysite::Manager::Domains::DOCROOT     = $d;
    $Lazysite::Manager::Themes::DOCROOT      = $d;
    $Lazysite::Manager::Themes::LAZYSITE_DIR = $lz;
}
is( Lazysite::Paths::lazysite_dir($d), $lz, 'the canary: the fixture is a migrated site' );

my $r = Lazysite::Manager::Nav::action_nav_save( [ { label => 'New', url => '/new', children => [] } ] );
ok( $r->{ok}, 'the primary nav saves' ) or diag explain $r;
like( slurp("$lz/nav.conf"), qr/New \| \/new/, 'into the engine tree, where the processor reads it' );

$r = Lazysite::Manager::Nav::action_nav_save( [ { label => 'Sub', url => '/s', children => [] } ], 'sub.example' );
ok( $r->{ok}, "a domain's own nav saves" ) or diag explain $r;
like( slurp("$lz/nav-sub.conf"), qr/Sub \| \/s/, 'into its configured file in the engine tree' );

my $read = Lazysite::Manager::Nav::action_nav_read('sub.example');
is( $read->{items}[0]{label}, 'Sub', 'and reads back from there' ) or diag explain $read;

ok( !-e "$d/lazysite", 'no stray engine tree was made inside the served tree' );

done_testing();
