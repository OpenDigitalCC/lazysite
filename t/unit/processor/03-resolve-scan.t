#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
make_path("$docroot/blog");

# Create test files BEFORE loading processor so $DOCROOT is fixed.
my %posts = (
    'post-one.md' =>
        "---\ntitle: First Post\nsubtitle: Intro\ndate: 2026-01-15\n"
        . "tags:\n  - tutorial\nsearch: true\n---\nContent one.\n",
    'post-two.md' =>
        "---\ntitle: Second Post\nsubtitle: Follow-up\ndate: 2026-03-20\n"
        . "tags:\n  - tutorial\n  - advanced\nsearch: true\n---\nContent two.\n",
    'draft.md' =>
        "---\ntitle: Draft\ndate: 2026-04-01\nsearch: false\n---\nDraft content.\n",
);
for my $f ( keys %posts ) {
    open my $fh, '>', "$docroot/blog/$f" or die $!;
    print $fh $posts{$f};
    close $fh;
}

# Gallery registry cards with custom front-matter keys (passthrough + sort).
make_path("$docroot/gallery");
my %cards = (
    'nova.md'  => "---\ntitle: NOVA\nkind: Statement\ndemo: /nova\naccent: \"#7C5CFF\"\norder: 10\n---\nx\n",
    'basic.md' => "---\ntitle: BASIC\nkind: Basic\ndemo: /basic\naccent: \"#1166ee\"\norder: 2\n---\ny\n",
);
for my $f ( keys %cards ) {
    open my $fh, '>', "$docroot/gallery/$f" or die $!;
    print $fh $cards{$f};
    close $fh;
}

load_processor($docroot);

# --- custom front-matter keys pass through (self-describing cards) ---
{
    my $pages = main::resolve_scan('/gallery/*.md');
    my ($nova) = grep { $_->{title} eq 'NOVA' } @$pages;
    ok( $nova, 'gallery card found' );
    is( $nova->{kind},   'Statement', 'custom key kind passed through' );
    is( $nova->{demo},   '/nova',     'custom key demo passed through' );
    is( $nova->{accent}, '#7C5CFF',   'quoted hex value has its quotes stripped' );
}

# --- sort=order is numeric (2 before 10), not lexical ---
{
    my $pages = main::resolve_scan('/gallery/*.md sort=order');
    is_deeply( [ map { $_->{title} } @$pages ], [ 'BASIC', 'NOVA' ],
        'sort on a custom key is numeric-aware (order 2 before 10)' );
    my $desc = main::resolve_scan('/gallery/*.md sort=order desc');
    is( $desc->[0]{title}, 'NOVA', 'sort=order desc reverses' );
}

# --- basic scan returns all .md files ---
{
    my $pages = main::resolve_scan('/blog/*.md');
    is( scalar @$pages, 3, 'three pages found' );
}

# --- page object fields ---
{
    my $pages = main::resolve_scan('/blog/*.md');
    my ($p) = grep { $_->{title} eq 'First Post' } @$pages;
    ok( $p, 'first post found' );
    is( $p->{url},      '/blog/post-one', 'url derived correctly' );
    is( $p->{subtitle}, 'Intro',          'subtitle preserved' );
    is( $p->{date},     '2026-01-15',     'date from front matter' );
    is_deeply( $p->{tags}, ['tutorial'],  'tags as arrayref' );
    is( $p->{searchable}, 1, 'searchable=true parsed as 1' );
    ok( length $p->{excerpt} > 0,        'excerpt present' );
    ok( length $p->{excerpt} <= 500,     'excerpt within 500 chars' );
}

# --- searchable false ---
{
    my $pages = main::resolve_scan('/blog/*.md');
    my ($d) = grep { $_->{title} eq 'Draft' } @$pages;
    ok( $d, 'draft found' );
    is( $d->{searchable}, 0, 'searchable=false parsed as 0' );
}

# --- sort by date asc ---
{
    my $pages = main::resolve_scan('/blog/*.md sort=date asc');
    is( $pages->[0]{title}, 'First Post', 'sort date asc - oldest first' );
    is( $pages->[-1]{title}, 'Draft',     'sort date asc - newest last' );
}

# --- sort by date desc ---
{
    my $pages = main::resolve_scan('/blog/*.md sort=date desc');
    is( $pages->[0]{title},  'Draft',      'sort date desc - newest first' );
    is( $pages->[-1]{title}, 'First Post', 'sort date desc - oldest last' );
}

# --- sort by title asc ---
{
    my $pages = main::resolve_scan('/blog/*.md sort=title asc');
    is( $pages->[0]{title}, 'Draft', 'sort title asc puts D before F/S' );
}

# --- path traversal rejected ---
{
    my $pages = main::resolve_scan('/../../../etc/*.conf');
    is_deeply( $pages, [], 'non-md pattern returns empty' );
}

# --- non-.md pattern rejected ---
{
    my $pages = main::resolve_scan('/blog/*.html');
    is_deeply( $pages, [], 'non-md pattern rejected' );
}

# --- missing directory returns empty ---
{
    my $pages = main::resolve_scan('/nonexistent/*.md');
    is_deeply( $pages, [], 'missing directory returns empty' );
}

# --- docroot-relative pattern must start with / ---
{
    my $pages = main::resolve_scan('blog/*.md');
    is_deeply( $pages, [], 'pattern not starting with / returns empty' );
}

done_testing();
