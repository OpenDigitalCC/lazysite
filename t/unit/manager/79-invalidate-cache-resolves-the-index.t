#!/usr/bin/perl
# SM367: invalidate_cache("/") reported success and cleared nothing.
#
# FROM THE FIELD, 2026-08-18, during the 0.10.13 validation pass. The mechanism
# is one line: "$DOCROOT$rel_path" with ".html" appended turns "/" into
# "$DOCROOT/.html" - a file that has never existed - so the unlink found nothing
# and the call returned ok:1 regardless.
#
# WHAT IT COST, which is the reason this is worth more than its size. It
# produced two WRONG DIAGNOSES rather than two errors, and both were plausible:
#
#   - after a layout upgrade, invalidating "/" changed nothing, and the
#     conclusion drawn was that a stale index.html was shadowing the page. It
#     was not.
#   - the homepage served a 0.10.12 render on a 0.10.13 instance, read as a
#     failed upgrade. An engine upgrade does not invalidate rendered pages, and
#     the homepage is both the page most likely to be checked and the one most
#     likely to be stale.
#
# It also broke a version probe that read the homepage alone. A query string
# does not help: it busts client caches, not the render cache, which is keyed by
# path.
#
# So this fixes the resolution AND makes the response say what it cleared. ok:1
# answered "did the call succeed" and was read as "the cache is now gone". Those
# were different facts, and this is the release where that distinction keeps
# turning out to matter.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                qw(repo_root);
use Lazysite::Manager::Themes ();

my $docroot = tempdir( CLEANUP => 1 );
$Lazysite::Manager::Themes::DOCROOT      = $docroot;
$Lazysite::Manager::Themes::LAZYSITE_DIR = "$docroot/lazysite";
make_path("$docroot/lazysite");
make_path("$docroot/about");

sub seed {
    my ($rel) = @_;    # e.g. index, about/index
    ( my $dir = "$docroot/$rel" ) =~ s{/[^/]*$}{};
    make_path($dir) unless -d $dir;
    for my $ext (qw(md html)) {
        open my $fh, '>', "$docroot/$rel.$ext" or die $!;
        print {$fh} "seed\n";
        close $fh;
    }
    return;
}

sub cached { return -f "$docroot/$_[0].html" ? 1 : 0 }

subtest 'the root path is the homepage, not a file called .html' => sub {
    seed('index');
    ok( cached('index'), 'the homepage has a cached render' );

    my $r = Lazysite::Manager::Themes::action_cache_invalidate('/');
    ok( $r->{ok}, 'the call succeeds' );
    is( cached('index'), 0, 'and the homepage render is GONE' )
        or diag( 'This is the defect: "/" became "$DOCROOT/.html", the unlink '
            . 'found nothing, and ok:1 was returned anyway.' );
    is( $r->{cleared}, 1, 'and it says it cleared one' );
};

subtest 'a directory path is its index too' => sub {
    seed('about/index');
    my $r = Lazysite::Manager::Themes::action_cache_invalidate('/about/');
    ok( $r->{ok}, 'the call succeeds' );
    is( cached('about/index'), 0, 'the section index render is gone' );
    is( $r->{cleared},         1, 'reported' );
};

subtest 'an ordinary page still works, by every spelling' => sub {
    # The forms that DID work must keep working - they are what an agent falls
    # back to once it discovers "/" does nothing.
    for my $spelling ( '/index', '/index.md', '/index.html' ) {
        seed('index');
        my $r = Lazysite::Manager::Themes::action_cache_invalidate($spelling);
        ok( $r->{ok}, "$spelling: succeeds" );
        is( cached('index'), 0, "$spelling: and clears the render" );
    }
};

subtest 'clearing nothing says so, rather than saying nothing' => sub {
    # The half that turns a silent no-op into an answer. A page with no cached
    # render is a legitimate state and the caller is entitled to know it is the
    # state they are in - which is exactly what two field diagnoses needed and
    # could not get.
    unlink "$docroot/index.html";
    my $r = Lazysite::Manager::Themes::action_cache_invalidate('/');
    ok( $r->{ok}, 'still a success - nothing went wrong' );
    is( $r->{cleared}, 0, 'and it cleared nothing, and says so' )
        or diag( 'ok:1 answered "did the call succeed". It was read as "the '
            . 'cache is now gone". Those are different facts.' );
};

done_testing();
