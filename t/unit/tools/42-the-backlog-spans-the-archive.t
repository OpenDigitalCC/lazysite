#!/usr/bin/perl
# SM658: the filings are two directories and one corpus.
#
# 489 terminal filings moved to docs/feature-requests/archive/ so the top level
# shows open work at a glance. Everything that reads the corpus had to learn
# about both, or archiving would have silently removed 489 documents from the
# backlog, from the status lint, and from the CHANGELOG resolver - each of which
# globbed one directory, non-recursively.
#
# WHAT IS ASSERTED
#   the backlog spans both directories, and --all really means all
#   two documents sharing one SM number are BOTH indexed, and reported
#   the JSON is valid, and carries the relation graph
#   a relation to an SM that was never filed is dropped, not published
#   a filing does not relate to itself
#   the derived graph is not written back into any filing's frontmatter
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $tool = "$root/tools/backlog.pl";
my $dir  = "$root/docs/feature-requests";
plan skip_all => "no $tool" unless -f $tool;

my @top     = glob("$dir/SM*.md");
my @archive = glob("$dir/archive/SM*.md");
cmp_ok( scalar @archive, '>', 100,
    'the archive holds the terminal filings (test not vacuous)' );
cmp_ok( scalar @top, '>', 0, 'open filings stay at the top level' );

# --- the listing spans both -------------------------------------------------
my $all = qx($^X \Q$tool\E --all 2>/dev/null);
my ($count) = $all =~ /^(\d+) item\(s\) total\./m;
is( $count, scalar(@top) + scalar(@archive),
    '--all counts every filing in both directories' )
    or diag( "top=" . scalar(@top) . " archive=" . scalar(@archive) );

my $open = qx($^X \Q$tool\E 2>/dev/null);
my ($open_n) = $open =~ /^(\d+) open item\(s\)\./m;
cmp_ok( $open_n, '<', $count, 'the default listing is the open subset' );
cmp_ok( $open_n, '>', 0,      'and it is not empty' );

# --- JSON -------------------------------------------------------------------
my $json = qx($^X \Q$tool\E --all --json 2>/dev/null);
my $data = eval { decode_json($json) };
ok( ref $data eq 'ARRAY', 'the JSON parses as an array' )
    or BAIL_OUT("--json did not produce parseable JSON");
is( scalar @$data, $count, 'JSON carries the same records as the listing' );

for my $r ( @{$data}[ 0 .. 4 ] ) {
    ok( exists $r->{$_}, "a record carries $_" )
        for qw(id status title path relates);
}

# --- a number with two documents keeps both ---------------------------------
# A hash keyed by SM number drops one of these without a word, and an index
# that silently loses a document is worse than no index.
my %by_id;
push @{ $by_id{ $_->{id} } }, $_ for @$data;
my @dupes = grep { @{ $by_id{$_} } > 1 } sort keys %by_id;
cmp_ok( scalar @dupes, '>', 0,
    'the corpus really does carry a duplicated number (test not vacuous)' );
for my $d (@dupes) {
    my %paths = map { $_->{path} => 1 } @{ $by_id{$d} };
    is( scalar keys %paths, scalar @{ $by_id{$d} },
        "$d's documents are indexed under distinct paths" );
}

# And it says so, on STDERR, so a listing stays pipeable.
my $stderr = qx($^X \Q$tool\E --all 2>&1 >/dev/null);
like( $stderr, qr/\Q$dupes[0]\E names \d+ documents/,
    'a duplicated number is reported rather than quietly resolved' );

# --- the graph --------------------------------------------------------------
my %known = map { $_->{id} => 1 } @$data;
my $edges = 0;
for my $r (@$data) {
    $edges += scalar @{ $r->{relates} };
    ok( !( grep { $_ eq $r->{id} } @{ $r->{relates} } ),
        "$r->{id} does not relate to itself" )
        if grep { $_ eq $r->{id} } @{ $r->{relates} };
    my @dangling = grep { !$known{$_} } @{ $r->{relates} };
    is_deeply( \@dangling, [],
        "$r->{id} publishes no relation to an SM that was never filed" )
        if @dangling;
}
cmp_ok( $edges, '>', 200, 'the relation graph is real (test not vacuous)' );

# --- the graph is DERIVED, and stays that way -------------------------------
# Writing it into each filing's frontmatter would make a second copy of a fact
# the body already carries, and the two would drift the moment either was
# edited - which is what SM654 filed against the hand-kept unlocks map.
my $stored = 0;
for my $f ( @top, @archive ) {
    open my $fh, '<', $f or next;
    my $text = do { local $/; <$fh> };
    close $fh;
    my ($fm) = $text =~ /\A---\n(.*?)^---\n/ms;
    $stored++ if defined $fm && $fm =~ /^relates:/m;
}
is( $stored, 0,
    'no filing stores a derived relation list - the body is the one copy' );

done_testing();
