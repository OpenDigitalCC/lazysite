#!/usr/bin/perl
# SM582: _remove_entry's failure return decides a MOVE's outcome - that is
# what SM284 fixed, after a MOVE out of an unwritable directory copied the
# entry, failed to remove the original and answered 201. Nothing in the unit
# suite ever made a removal fail: the only test that did is t/integration/41,
# which skip_alls as root, so on a root CI image the SM516 sabotage sweep
# could break the return outright and see nothing fail.
#
# rename() out of an unwritable directory fails with EACCES, which drops MOVE
# into its copy-then-remove fallback - and it is the remove there that cannot
# succeed either. Both kinds of entry go through it:
#
#   a FILE       unlink fails; the entry is untouched
#   a COLLECTION remove_tree empties the directory and then cannot unlink it
#                from its unwritable parent, so `!-e $abs` is false
#
# The collection branch had never been driven through a failure at all, and
# that is where the defect was: the source came back EMPTY while the answer
# said the move had not happened. The rollback of the destination copy then
# took the only complete copy with it. So these assertions are about the
# CONTENT surviving, not only the entry.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_dav_site run_dav);

# Same condition as t/integration/41: root writes through any mode bit, so
# the rig cannot make a removal fail and there is nothing to observe.
plan skip_all => 'running as root: no directory is unwritable, so no removal '
    . 'can be made to fail'
    if $> == 0;

my $BODY = "---\ntitle: Mover\n---\nthe content that has to survive\n";

# Build a docroot with one unwritable directory holding both a file and a
# collection, and return it. Skips the whole file if the mode does not take.
sub locked_site {
    my $s      = setup_dav_site();
    my $locked = "$s->{docroot}/content/locked";
    make_path("$locked/coll");
    for my $p ( "$locked/mover.md", "$locked/coll/inner.md" ) {
        open my $fh, '>', $p or die "write $p: $!";
        print {$fh} $BODY;
        close $fh;
    }
    chmod 0555, $locked or die "chmod: $!";
    return ( $s, $locked );
}

my ( $s, $locked ) = locked_site();
plan skip_all => 'could not make a directory unwritable here'
    if -w $locked;

# --- the FILE branch: unlink fails, and the MOVE says so --------------------
{
    my $r = run_dav(
        $s->{docroot}, 'MOVE', '/content/locked/mover.md',
        HTTP_DESTINATION   => 'http://localhost/dav/content/moved.md',
        HTTP_AUTHORIZATION => $s->{auth},
    );
    ok( $r->{code} >= 500 && $r->{code} <= 599,
        "a MOVE whose removal fails answers a server fault (got $r->{code})" );
    ok( -e "$locked/mover.md",
        'the source file is still there - which is WHY it failed' );
    ok( !-e "$s->{docroot}/content/moved.md",
        'and no copy is left at the destination reporting otherwise' );
}

# --- the COLLECTION branch: remove_tree empties it and cannot unlink it -----
{
    my $r = run_dav(
        $s->{docroot}, 'MOVE', '/content/locked/coll',
        HTTP_DESTINATION   => 'http://localhost/dav/content/moved-coll',
        HTTP_AUTHORIZATION => $s->{auth},
    );
    ok( $r->{code} >= 500 && $r->{code} <= 599,
        "a MOVE of a collection whose removal fails answers a server fault "
            . "(got $r->{code})" );
    ok( -d "$locked/coll", 'the source collection is still there' );
    ok( -e "$locked/coll/inner.md",
        'AND so is what was inside it - a move that reports failure must not '
            . 'have taken the content away' );

    if ( open my $fh, '<', "$locked/coll/inner.md" ) {
        my $got = do { local $/; <$fh> };
        close $fh;
        is( $got, $BODY, 'byte for byte what was there before the MOVE' );
    }
    else {
        fail('the source content is readable');
    }

    ok( !-e "$s->{docroot}/content/moved-coll",
        'and the destination copy is rolled back, so the caller is left with '
            . 'exactly what it had' );
}

# Leave the tree removable so the tempdir cleanup can do its job.
chmod 0755, $locked;

done_testing();
