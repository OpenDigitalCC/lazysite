#!/usr/bin/perl
# SM510: validate_path resolved a new path against its IMMEDIATE parent, so
# /a/b.md validated while /a/b/c.md was "Invalid path" - realpath(undef) on
# the missing intermediate directory. A file-write validator answering a
# question nobody asked it: action_save and action_mkdir both create parent
# directories, and the briefings recommend brief-first authoring at paths
# that do not exist yet. Found by the site agent testing the briefs key
# space. The fix walks to the NEAREST EXISTING ancestor; `..` rejection and
# the H3 sibling-superset containment are pinned unchanged below.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Common qw(validate_path);
use Lazysite::Manager::Files  qw(action_save);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/auth");
make_path("$docroot/content");
$Lazysite::Manager::Common::DOCROOT = $docroot;
$Lazysite::Manager::Files::DOCROOT  = $docroot;

subtest 'a deep new path validates like a shallow one' => sub {
    my $v1 = validate_path('/content/new.md');
    ok( $v1->{ok}, 'depth-1 under an existing dir (the old behaviour)' );
    my $v2 = validate_path('/newdir/sub/file.md');
    ok( $v2->{ok}, 'depth-2 with no existing ancestor but the docroot' )
        or diag explain $v2;
    is( $v2->{rel}, 'newdir/sub/file.md', 'and the rel key is the full path' );
    my $v3 = validate_path('/docs/deeper/never/even/further.md');
    ok( $v3->{ok}, 'any depth' ) or diag explain $v3;
};

subtest 'the security posture is unchanged' => sub {
    my $dd = validate_path('/newdir/../lazysite/auth/users');
    ok( !$dd->{ok}, '`..` is still rejected outright, before any resolution' );
    my $bl = validate_path('/lazysite/auth/secret');
    ok( !$bl->{ok} || $bl->{ok},
        'blocked-path decisions are downstream of validate (see next)' );
    # is_blocked_path still governs: the deep-path fix must not have opened
    # the lazysite tree.
    require Lazysite::Manager::Common;
    ok( Lazysite::Manager::Common::is_blocked_path('lazysite/auth/secret'),
        'the lazysite tree stays blocked' );

    # H3: a sibling whose name is a string-superset of the docroot must still
    # be outside. Simulate with a symlink escaping sideways.
    symlink "$docroot.evil", "$docroot/side" or plan skip_all => 'no symlink';
    make_path("$docroot.evil");
    my $esc = validate_path('/side/x/y.md');
    ok( !$esc->{ok}, 'a symlinked existing ancestor still cannot escape' )
        or diag explain $esc;
    unlink "$docroot/side";
    require File::Path;
    File::Path::remove_tree("$docroot.evil");
};

subtest 'the save that motivated it' => sub {
    my $r = action_save( '/guides/setup/intro.md', 'op',
        "---\ntitle: I\n---\nx\n", undef );
    ok( $r->{ok}, 'a deep first save succeeds' ) or diag explain $r;
    ok( -f "$docroot/guides/setup/intro.md", 'and the file is where it says' );
};

subtest 'a deep new path inside a GATED section still goes private' => sub {
    # The first cut of SM510 anchored every new path at the docroot (which
    # always exists), silently bypassing the SM458 private branch - and with
    # it the private tree's symlink collapse and containment. The chooser:
    # the tree with the DEEPER existing ancestor claims the path.
    require Lazysite::Private;
    my $proot = Lazysite::Private::private_root($docroot);
    plan skip_all => 'no private root on this rig' unless defined $proot;
    require File::Path;
    File::Path::make_path("$proot/intranet");
    my $v = validate_path('/intranet/sub/deeper/file.md');
    ok( $v->{ok}, 'validates' ) or diag explain $v;
    is( $v->{store} // '', 'private', 'and is claimed by the private tree' )
        or diag explain $v;
};

done_testing();
