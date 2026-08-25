#!/usr/bin/perl
# SM199: files_summary - the file-list / table-of-contents over the content
# history, with per-file statistics (revision count, first + latest date, last
# author) and a site-level summary (total files, total revisions). It reuses the
# lineage-aware file_log (SM175), so a renamed file's count includes its
# pre-rename revisions AND a delete-then-recreate at a reused path does NOT
# inherit the deleted file's count (no leak) - both pinned here.
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

# index by path for the assertions
sub by_path {
    my $s = Lazysite::Git::files_summary($d);
    return ( { map { $_->{path} => $_ } @{ $s->{files} } }, $s->{summary} );
}

# --- a few files with distinct revision counts + authors ---------------------
spit( "$d/index.md", "home v1\n" );
Lazysite::Git::commit_paths( $d, 'alice', 'create index.md', 'index.md' );
spit( "$d/index.md", "home v2\n" );
Lazysite::Git::commit_paths( $d, 'bob', 'edit index.md', 'index.md' );
spit( "$d/index.md", "home v3\n" );
Lazysite::Git::commit_paths( $d, 'carol', 'edit index.md', 'index.md' );

spit( "$d/content/about.md", "about v1\n" );
Lazysite::Git::commit_paths( $d, 'dave', 'create content/about.md', 'content/about.md' );

my ( $rows, $summary ) = by_path();

# per-file revision counts
is( $rows->{'index.md'}{revisions},         3, 'index.md counts its three revisions' );
is( $rows->{'content/about.md'}{revisions}, 1, 'about.md counts its single revision' );

# first / latest dates: first <= latest, and index has three distinct commits
ok( $rows->{'index.md'}{first} <= $rows->{'index.md'}{latest},
    'index.md first date is at or before latest' );
ok( defined $rows->{'index.md'}{first} && $rows->{'index.md'}{first} > 0,
    'index.md carries a first-revision epoch' );

# last author = author of the most recent revision
is( $rows->{'index.md'}{last_author}, 'carol',
    'index.md last author is the most recent committer' );
is( $rows->{'content/about.md'}{last_author}, 'dave',
    'about.md last author is its only committer' );

# --- site-level summary totals ------------------------------------------------
# The versioned set = index.md + content/about.md + lazysite.conf + nav-less
# tracked config; the summary counts every tracked content path and sums the
# revisions. index (3) + about (1) at least; assert both files present and the
# totals are internally consistent.
ok( $summary->{files} >= 2, 'summary counts at least the two content files' );
my $sum_rev = 0;
$sum_rev += $_->{revisions} for values %{$rows};
is( $summary->{revisions}, $sum_rev, 'summary revision total equals the sum of per-file counts' );
is( $summary->{files}, scalar( keys %{$rows} ), 'summary file count equals the number of rows' );

# --- a renamed file's count includes its pre-rename revisions (SM175) --------
make_path("$d/content/a");
spit( "$d/content/a/page.md", "p v1\n" );
Lazysite::Git::commit_paths( $d, 'alice', 'create content/a/page.md', 'content/a/page.md' );
spit( "$d/content/a/page.md", "p v2\n" );
Lazysite::Git::commit_paths( $d, 'alice', 'edit content/a/page.md', 'content/a/page.md' );
make_path("$d/content/b");
rename( "$d/content/a/page.md", "$d/content/b/page.md" ) or die "rename: $!";
Lazysite::Git::commit_move( $d, 'alice',
    'move content/a/page.md -> content/b/page.md',
    'content/a/page.md',
    'content/a/page.md', 'content/b/page.md' );

( $rows, $summary ) = by_path();
ok( !exists $rows->{'content/a/page.md'}, 'the old path is gone from the file list' );
is( $rows->{'content/b/page.md'}{revisions}, 3,
    'renamed file counts create + edit + move (pre-rename revisions included)' );

# --- delete + recreate at a used path does NOT inherit the old count ---------
spit( "$d/content/note.md", "secret v1\n" );
Lazysite::Git::commit_paths( $d, 'alice', 'create content/note.md', 'content/note.md' );
spit( "$d/content/note.md", "secret v2\n" );
Lazysite::Git::commit_paths( $d, 'alice', 'edit content/note.md', 'content/note.md' );
unlink "$d/content/note.md";
Lazysite::Git::commit_paths( $d, 'alice', 'delete content/note.md', 'content/note.md' );
spit( "$d/content/note.md", "fresh unrelated\n" );
Lazysite::Git::commit_paths( $d, 'eve', 'create content/note.md', 'content/note.md' );

( $rows, $summary ) = by_path();
is( $rows->{'content/note.md'}{revisions}, 1,
    'recreated path counts ONLY its own revision (no leak of the deleted file)' );
is( $rows->{'content/note.md'}{last_author}, 'eve',
    'recreated path last author is the recreator, not the deleted file author' );

# --- SM571: the summary walks the history ONCE ------------------------------
# On edge the summary 504'd: files_summary ran file_log (several git
# invocations, following renames) per tracked path, O(files x history). A
# 40-file site with three commits each is small - and it still took 124 git
# processes. The summary must come from a bounded number of invocations (the
# HEAD listing plus one history walk) whatever the file count, with the same
# per-file counts the per-file walk gave.
subtest 'the summary is produced in a bounded number of git invocations' => sub {
    my $big = site();
    ok( Lazysite::Git::init( $big, 'installer' )->{ok}, 'big fixture initialised' );
    make_path("$big/content/bulk");
    my @authors = qw(alice bob carol);
    for my $i ( 1 .. 40 ) {
        my $rel = sprintf( 'content/bulk/page-%02d.md', $i );
        for my $rev ( 1 .. 3 ) {
            spit( "$big/$rel", "page $i rev $rev\n" );
            Lazysite::Git::commit_paths( $big, $authors[ $rev - 1 ], "edit $rel", $rel );
        }
    }

    my $calls = 0;
    my $orig  = \&Lazysite::Git::run_git;
    my $s;
    {
        no warnings 'redefine';
        local *Lazysite::Git::run_git = sub { $calls++; goto &{$orig} };
        $s = Lazysite::Git::files_summary($big);
    }
    diag("files_summary took $calls git invocation(s) for 40 files x 3 commits");
    cmp_ok( $calls, '<=', 3, 'at most three git invocations, whatever the file count' );

    my %by   = map  { $_->{path} => $_ } @{ $s->{files} };
    my @bulk = grep { m{^content/bulk/} } map { $_->{path} } @{ $s->{files} };
    is( scalar @bulk, 40, 'all forty files are listed' );
    is_deeply( [ map { $_->{path} } @{ $s->{files} } ],
        [ sort map { $_->{path} } @{ $s->{files} } ], 'rows are sorted by path' );
    my $bad = 0;
    for my $rel (@bulk) {
        my $row = $by{$rel};
        $bad++ unless $row->{revisions} == 3;
        $bad++ unless $row->{last_author} eq 'carol';
        $bad++ unless $row->{first} > 0 && $row->{first} <= $row->{latest};
        $bad++
            unless join( ',', sort keys %{$row} ) eq 'first,last_author,latest,path,revisions';
    }
    is( $bad, 0, 'every bulk row: 3 revisions, last author carol, first<=latest, exact keys' );
    my $sum = 0;
    $sum += $_->{revisions} for @{ $s->{files} };
    is( $s->{summary}{revisions}, $sum, 'summary revisions equal the sum of the rows' );
    is( $s->{summary}{files}, scalar @{ $s->{files} }, 'summary files equal the row count' );
    cmp_ok( $s->{summary}{revisions}, '>=', 120, 'the 120 bulk revisions are all counted' );
};

# --- disabled / no repo = empty, never an error ------------------------------
my $off = tempdir( CLEANUP => 1 );
make_path("$off/lazysite");
spit( "$off/lazysite/lazysite.conf", "site_name: T\n" );
Lazysite::Git::reset_cache();
my $es = Lazysite::Git::files_summary($off);
is_deeply( $es, { files => [], summary => { files => 0, revisions => 0 } },
    'disabled site yields an empty summary, not an error' );

done_testing();
