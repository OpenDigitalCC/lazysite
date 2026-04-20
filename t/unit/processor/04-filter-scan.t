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

my %posts = (
    'post-one.md' =>
        "---\ntitle: First Post\ndate: 2026-01-15\n"
        . "tags:\n  - tutorial\nsearch: true\n---\nOne.\n",
    'post-two.md' =>
        "---\ntitle: Second Post\ndate: 2026-03-20\n"
        . "tags:\n  - tutorial\n  - advanced\nsearch: true\n---\nTwo.\n",
    'draft.md' =>
        "---\ntitle: Draft\ndate: 2026-04-01\nsearch: false\n---\nDraft.\n",
);
for my $f ( keys %posts ) {
    open my $fh, '>', "$docroot/blog/$f" or die $!;
    print $fh $posts{$f};
    close $fh;
}

load_processor($docroot);

# --- filter by searchable ---
{
    my $pages = main::resolve_scan('/blog/*.md filter=searchable:true');
    is( scalar @$pages, 2, 'filter searchable:true excludes draft' );
    ok( !( grep { $_->{title} eq 'Draft' } @$pages ), 'draft excluded' );
}

# --- filter by tag ---
{
    my $pages = main::resolve_scan('/blog/*.md filter=tags:advanced');
    is( scalar @$pages, 1, 'one tagged advanced' );
    is( $pages->[0]{title}, 'Second Post', 'correct page returned' );
}

# --- filter by date > ---
{
    my $pages = main::resolve_scan('/blog/*.md filter=date:>2026-02-01');
    is( scalar @$pages, 2, 'filter date>2026-02-01 keeps 2 posts' );
    ok( !( grep { $_->{title} eq 'First Post' } @$pages ),
        'first post excluded' );
}

# --- filter by date < ---
{
    my $pages = main::resolve_scan('/blog/*.md filter=date:<2026-02-01');
    is( scalar @$pages, 1, 'filter date<2026-02-01 keeps 1 post' );
    is( $pages->[0]{title}, 'First Post', 'only first post' );
}

# --- multiple filters ANDed ---
{
    my $pages = main::resolve_scan(
        '/blog/*.md filter=tags:tutorial filter=tags:advanced');
    is( scalar @$pages, 1, 'multiple filters ANDed' );
    is( $pages->[0]{title}, 'Second Post', 'only advanced tutorial survives' );
}

# --- filter + sort ---
{
    my $pages = main::resolve_scan(
        '/blog/*.md filter=searchable:true sort=date desc');
    is( $pages->[0]{title}, 'Second Post',
        'filter + sort date desc keeps newest searchable first' );
}

# --- unknown filter field excludes everything ---
{
    my $pages = main::resolve_scan('/blog/*.md filter=nonexistent:value');
    is_deeply( $pages, [], 'unknown field returns empty' );
}

done_testing();
