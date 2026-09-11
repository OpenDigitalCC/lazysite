#!/usr/bin/perl
# SM850: the file surfaces reach a carve-out in the engine tree wherever it is.
#
# The parts of the engine tree a partner edits by path - lazysite/nav.conf, the
# layouts and themes, brands - are named `lazysite/...`, and validate_path, which
# the manager's file editor, the control API and MCP's write_file all go
# through, joined every path to the docroot. On a site whose tree moved beside
# the docroot (SM293) a save to lazysite/nav.conf made a stray engine tree
# inside the served tree and answered ok - created, even - while the read said
# the file did not exist and the live nav never changed.
#
# The engine tree is confined as strictly as the docroot: a symlink in it that
# points outside is refused, and the key stays the `lazysite/...` rel the
# blocklist and the audit rule on.
#
# Found reading for SM850; reproduced before the fix.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper                qw(site_tempdir);
use Lazysite::Paths           ();
use Lazysite::Manager::Files  ();
use Lazysite::Manager::Common ();

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t }

my $d  = site_tempdir();
my $lz = Lazysite::Paths::external_lazysite_dir($d);
make_path( $d, "$lz/cache", "$lz/manager/locks", "$lz/layouts/plain" );
spit( "$lz/lazysite.conf", "site_name: T\n" );
spit( "$lz/nav.conf",      "Old | /\n" );
{
    no warnings 'once';
    $Lazysite::Manager::Files::DOCROOT       = $d;
    $Lazysite::Manager::Files::LAZYSITE_DIR  = $lz;
    $Lazysite::Manager::Files::LOCK_DIR      = "$lz/manager/locks";
    $Lazysite::Manager::Common::DOCROOT      = $d;
    $Lazysite::Manager::Common::LAZYSITE_DIR = $lz;
}
is( Lazysite::Paths::lazysite_dir($d), $lz, 'the canary: the fixture is a migrated site' );

my $v = Lazysite::Manager::Common::validate_path('lazysite/nav.conf');
is( $v->{full}, "$lz/nav.conf", 'the nav file resolves into the engine tree' ) or diag explain $v;
is( $v->{rel}, 'lazysite/nav.conf', 'and keeps its rel, which the blocklist and the audit key on' );

my $r = Lazysite::Manager::Files::action_read('lazysite/nav.conf');
like( $r->{content} // '', qr/Old/, 'the file editor reads the nav the site renders with' ) or diag explain $r;

my $s = Lazysite::Manager::Files::action_save( 'lazysite/nav.conf', 'op', "New | /new\n" );
ok( $s->{ok},       'and saves it' ) or diag explain $s;
ok( !$s->{created}, 'as the existing file, not a new one' );
like( slurp("$lz/nav.conf"), qr/New \| \/new/, 'into the engine tree' );

my $l = Lazysite::Manager::Files::action_save( 'lazysite/layouts/plain/layout.tt', 'op', "<html></html>\n" );
ok( $l->{ok},                         'a layout file saves' ) or diag explain $l;
ok( -f "$lz/layouts/plain/layout.tt", 'beside the others' );

ok( !-e "$d/lazysite", 'no stray engine tree was made inside the served tree' );

SKIP: {
    my $outside = site_tempdir( leaf => 'elsewhere' );
    skip 'no symlinks here', 1 unless symlink $outside, "$lz/layouts/escape";
    my $e = Lazysite::Manager::Common::validate_path('lazysite/layouts/escape/x.tt');
    ok( !$e->{ok}, 'a symlink out of the engine tree is refused, as one out of the docroot is' )
        or diag explain $e;
}

done_testing();
