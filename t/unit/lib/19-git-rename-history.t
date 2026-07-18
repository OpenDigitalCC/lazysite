#!/usr/bin/perl
# SM175: content history follows a rename (via the Lazysite-Renamed-From trailer
# and a lineage walk bounded to the current incarnation) and NEVER leaks across
# a delete+recreate at the same path. Empirically `git log --follow` does not
# give the second guarantee (it still lists every commit that touched the path),
# so the trailer walk is the mechanism.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Git ();

sub spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh }

sub site {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/content", "$d/lazysite/auth", "$d/lazysite/forms",
        "$d/lazysite/cache", "$d/lazysite/logs", "$d/lazysite/manager/locks" );
    spit( "$d/lazysite/lazysite.conf", "site_name: T\ngit_history: enabled\n" );
    spit( "$d/lazysite/auth/users",    "alice:hash\n" );
    return $d;
}

Lazysite::Git::reset_cache();
plan skip_all => 'git not installed on this host' unless Lazysite::Git::git_available();

my $d = site();
ok( Lazysite::Git::init( $d, 'installer' )->{ok}, 'content history initialised' );

# subjects for a path, newest-first
sub subjects { [ map { $_->{subject} } @{ Lazysite::Git::file_log( $d, $_[0] ) } ] }

# --- a move carries the file's history to the new path -----------------------
make_path("$d/content/a");
spit( "$d/content/a/page.md", "v1\n" );
Lazysite::Git::commit_paths( $d, 'alice', 'create content/a/page.md', 'content/a/page.md' );
spit( "$d/content/a/page.md", "v1\nv2\n" );
Lazysite::Git::commit_paths( $d, 'alice', 'edit content/a/page.md', 'content/a/page.md' );

make_path("$d/content/b");
rename( "$d/content/a/page.md", "$d/content/b/page.md" ) or die "rename: $!";
Lazysite::Git::commit_move( $d, 'alice',
    'move content/a/page.md -> content/b/page.md',
    'content/a/page.md',                           # the rename source (trailer)
    'content/a/page.md', 'content/b/page.md' );    # paths to stage (delete + add)

my $new = subjects('content/b/page.md');
ok( ( grep { /^move / } @$new ), 'new path shows the move commit' );
ok( ( grep { /edit content\/a/ } @$new ), 'new path shows the pre-move edit (history followed the rename)' );
ok( ( grep { /create content\/a/ } @$new ), 'new path shows the original create' );

my ( undef, $tval ) = Lazysite::Git::run_git( $d, 'log', '-n1',
    '--format=%(trailers:key=Lazysite-Renamed-From,valueonly)', 'HEAD' );
like( $tval, qr{content/a/page\.md}, 'move commit carries the Lazysite-Renamed-From trailer' );

# --- delete + recreate at the same path does NOT inherit the old history -----
spit( "$d/content/note.md", "secret v1\n" );
Lazysite::Git::commit_paths( $d, 'alice', 'create content/note.md', 'content/note.md' );
spit( "$d/content/note.md", "secret v2\n" );
Lazysite::Git::commit_paths( $d, 'alice', 'edit content/note.md', 'content/note.md' );
unlink "$d/content/note.md";
Lazysite::Git::commit_paths( $d, 'alice', 'delete content/note.md', 'content/note.md' );
spit( "$d/content/note.md", "fresh unrelated\n" );
Lazysite::Git::commit_paths( $d, 'alice', 'create content/note.md', 'content/note.md' );

my $note = subjects('content/note.md');
ok( ( grep { /^create content\/note/ } @$note ), 'recreated path shows its own create' );
ok( ( !grep { /^edit content\/note/ } @$note ), 'recreated path does NOT show the deleted file edits (no leak)' );
is( scalar(@$note), 1, 'only the current incarnation is listed (delete ended the prior thread)' );

done_testing();
