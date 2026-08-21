#!/usr/bin/perl
# SM458: the manager could not create a subfolder inside a GATED section.
#
# Reported by an operator: creating filestore/research inside a gated
# /intranet/ failed with "Invalid path". The same folder went in over WebDAV
# immediately afterwards - MKCOL 201 - so the path was legal, the parent
# existed, and the account could write there.
#
# CAUSE, reproduced before it was fixed: gating MOVES the section out of the
# document root into the private store (SM286). validate_path resolves
# "$DOCROOT/$rel", falls back to dirname() for a path being created, and
# realpath()s that - but for a gated section the docroot parent does not
# exist, so realpath returns undef and the containment test refuses. WebDAV was
# unaffected because its write path resolves through the private store.
#
# THE FIX DOES NOT WIDEN THE EXISTING CHECK, and that matters: the containment
# test carries two CVE-class fixes (the `..` rejection and boundary-safe
# containment against a superset sibling), and the code's own comment warns
# that rewriting them to span two trees is how a fix gets undone. So the
# docroot check is untouched and there is a SECOND, separate check against the
# private root. Each is strict in its own tree; a path must be wholly inside
# one of them.
#
# The security half of this file is therefore not decoration - it is the
# assertion that adding the second tree did not open a way out of either.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files  ();
use Lazysite::Manager::Common ();
use Lazysite::Private         ();

sub fixture {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite", "$d/open" );
    $Lazysite::Manager::Files::DOCROOT  = $d;
    $Lazysite::Manager::Common::DOCROOT = $d;
    # A gated section: the folder is MOVED out of the docroot, which is what
    # gating does and what the manager then could not see.
    make_path( Lazysite::Private::private_path( $d, 'intranet/filestore' ) );
    return $d;
}

subtest 'a subfolder can be created inside a gated section' => sub {
    my $d = fixture();
    my $r = Lazysite::Manager::Files::action_mkdir('intranet/filestore/research');
    ok( $r->{ok}, 'created' ) or diag explain $r;
    ok( -d Lazysite::Private::private_path( $d, 'intranet/filestore/research' ),
        'and it lands in the private store, where the section lives' )
        or diag( 'Creating it publicly would half-publish a gated section '
            . 'through an operation nobody thinks of as a permission change.' );
    ok( !-d "$d/intranet/filestore/research",
        'not in the document root' );
};

subtest 'an ordinary folder still works' => sub {
    my $d = fixture();
    ok( Lazysite::Manager::Files::action_mkdir('open/newdir')->{ok},
        'ungated creation is unaffected' );
};

subtest 'SECURITY: the escapes are still refused' => sub {
    # The point of the separate check. If adding the private tree had widened
    # the docroot test, these would pass.
    my $d = fixture();
    for my $bad ( 'intranet/../../etc/passwd', '../outside', 'a/../../b',
        '..', 'intranet/filestore/../../../..' )
    {
        my $r = Lazysite::Manager::Files::action_mkdir($bad);
        ok( !$r->{ok}, "refused: $bad" )
            or diag( 'A traversal that escapes EITHER tree is the CVE this '
                . 'validation exists to prevent.' );
    }
};

subtest 'SECURITY: a SYMLINK PIVOT out of the private tree is refused' => sub {
    # THIS IS THE CASE THAT ACTUALLY TESTS THE NEW CONTAINMENT, and the first
    # version of this subtest did not.
    #
    # It used a '../' spelling, which the `..` rejection at the top of
    # validate_path refuses before either tree is consulted - so removing the
    # private-root containment entirely left the test passing. A path with no
    # '..' in it, that RESOLVES outside the tree, is the only thing that
    # reaches the check. (The same trap SM418 recorded: every traversal case
    # hitting an earlier guard and proving nothing about the later one.)
    my $d     = fixture();
    my $proot = Lazysite::Private::private_root($d);
    my $outside = tempdir( CLEANUP => 1 );
    make_path("$outside/loot");
    make_path("$proot/intranet");
    symlink( $outside, "$proot/intranet/pivot" )
        or plan skip_all => 'symlinks unavailable here';

    my $r = Lazysite::Manager::Files::action_mkdir('intranet/pivot/loot/x');
    ok( !$r->{ok}, 'a symlink pointing out of the private store is refused' )
        or diag( 'realpath resolves the link, so without boundary-safe '
            . 'containment in the private tree this writes outside both '
            . 'trees - the escape the docroot check exists to stop, one '
            . 'directory across.' );
    ok( !-d "$outside/loot/x", 'and nothing was created out there' );

    # AND THE H3 CASE IN THE NEW TREE. private_root is
    # "<docroot>-lazysite-private"; a SIBLING named "<...>-private.bak" starts
    # with that string, so a bare index($real,$proot)==0 accepts it while
    # boundary-safe containment does not. Reached by symlink, because a '../'
    # spelling never gets this far.
    #
    # Without this case, replacing the containment with a bare prefix test
    # passes cleanly - which it did, until this was added.
    my $sibling = "$proot.bak";
    make_path("$sibling/loot");
    symlink( $sibling, "$proot/intranet/superset" )
        or plan skip_all => 'symlinks unavailable here';
    my $h3 = Lazysite::Manager::Files::action_mkdir('intranet/superset/loot/y');
    ok( !$h3->{ok},
        "a superset SIBLING of the private root is refused" )
        or diag( 'index($real, $proot) == 0 accepts '
            . '"<root>-private.bak" because the name is a string superset. '
            . 'That is H3, reintroduced one tree across.' );
    ok( !-d "$sibling/loot/y", 'and nothing was created there either' );
};

subtest 'SECURITY: the blocklist still applies to a private path' => sub {
    # rel must remain the DOCROOT key, because the blocklist string-matches on
    # it. If the private spelling leaked into rel, lazysite/ would stop being
    # blocked inside a gated section.
    my $d = fixture();
    make_path( Lazysite::Private::private_path( $d, 'lazysite/auth' ) );
    my $r = Lazysite::Manager::Files::action_mkdir('lazysite/auth/sneak');
    ok( !$r->{ok}, 'a blocked path is refused even via the private tree' )
        or diag( 'The blocklist keys on rel; a private spelling there would '
            . 'unblock the auth store.' );
    is( $r->{kind}, 'blocked',
        'refused BY THE BLOCKLIST, which means rel stayed the docroot key' )
        or diag( 'The blocklist keys on rel. A private spelling in rel would '
            . 'unblock the auth store.' );
};

done_testing();
