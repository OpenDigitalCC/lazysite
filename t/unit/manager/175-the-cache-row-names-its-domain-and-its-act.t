#!/usr/bin/perl
# SM846: the Cache page, as the release manager reported it on 0.13.12.
#
# 1. THE BUTTON FLOATED IN THE MIDDLE. `.mg-row` is a three-column grid
#    (SM819: describes, metadata, acts). A cache row supplied FIVE cells - path,
#    host tag, status tag, age, button - so the last two wrapped to an implicit
#    second row, and the button landed in the middle column. The stylesheet was
#    right and lint 124 passed; the page built the wrong number of cells.
# 2. A ROW DID NOT SAY WHICH DOMAIN IT SERVES. Only alias-host copies carried a
#    tag, so every primary row was left to be inferred - on a multi-domain
#    instance, a list an operator cannot act on safely.
# 3. "INVALIDATE" NAMED THE CONSEQUENCE, NOT THE ACT. The button deletes a
#    cached copy; the next request renders the page afresh. It says Delete now,
#    and the button acting on every copy says Delete all.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use PageScript ();

my $root    = repo_root();
my $docroot = site_tempdir();
make_path( "$docroot/lazysite/cache/hosts/fr.example", "$docroot/sites/en" );

sub spew { my ( $p, $s ) = @_; open my $o, '>', $p or die "$p: $!"; print {$o} $s; close $o }

sub conf {
    my ($site_url) = @_;
    spew( "$docroot/lazysite/lazysite.conf",
        "site_name: T\nsite_url: $site_url\nalias_hosts: fr.example\n"
            . "alias.fr.example.content_root: sites/fr\n" );
}
spew( "$docroot/index.md",   'src' );
spew( "$docroot/index.html", '<p>primary</p>' );
spew( "$docroot/lazysite/cache/hosts/fr.example/index.html", '<p>fr</p>' );

BEGIN {
    $ENV{LAZYSITE_API_LOAD_ONLY} = 1;
    $ENV{DOCUMENT_ROOT}          = '/tmp';
}
{
    local $ENV{DOCUMENT_ROOT} = $docroot;
    package main;
    do "$root/lazysite-manager-api.pl" or die "load failed: $@";
}

sub domains {
    my %by;
    for my $e ( @{ main::action_cache_list()->{cached} || [] } ) {
        $by{ $e->{host} // '(primary)' } = $e->{domain};
    }
    return \%by;
}

# --- 2. every entry names its domain -----------------------------------------
conf('https://www.example.org');
{
    my $d = domains();
    is( $d->{'(primary)'}, 'www.example.org',
        'a primary copy names the domain its site_url gives' );
    is( $d->{'fr.example'}, 'fr.example', 'an alias copy names its own host' );
}

# The placeholder names no host; the primary then answers to whatever reaches
# it that is not an alias - which the request this listing came on is.
conf('https://${SERVER_NAME}');
{
    local $ENV{SERVER_NAME} = 'primary.test';
    is( domains()->{'(primary)'}, 'primary.test',
        'with a placeholder site_url, the request\'s own name is the primary\'s' );
}
{
    local $ENV{SERVER_NAME} = 'fr.example';
    is( domains()->{'(primary)'}, 'default site',
        'unless the request came in on an alias - then no name is given, not the wrong one' );
}

# --- 1 and 3. the row the page builds ----------------------------------------
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
SKIP: {
    skip 'node not installed', 12 unless length $node && -x $node;

    my $src = PageScript::page_source("$root/starter/manager/cache.md");
    my $js  = join "\n", map { PageScript::extract_function( $src, $_, 'cache.md' ) }
        qw(escHtml formatAge renderCache);

    my $dir = tempdir( CLEANUP => 1 );
    spew( "$dir/r.js", <<"JS" );
var list = { innerHTML: '' };
var document = { getElementById: function () { return list; } };
$js
renderCache([
  { path: '/index.html', domain: 'www.example.org', mtime: 0, has_source: 1 },
  { path: '/index.html', host: 'fr.example', domain: 'fr.example', mtime: 0, has_source: 0 }
]);
console.log(list.innerHTML);
JS
    my $html = `\Q$node\E \Q$dir/r.js\E 2>&1`;

    my @rows = $html =~ /<div class="mg-row">(.*?)<\/div>/g;
    is( scalar @rows, 2, 'both copies render a row' );

    for my $i ( 0 .. $#rows ) {
        my @cells = top_level_cells( $rows[$i] );
        is( scalar @cells, 3,
            "row $i has three cells - the grid has three columns (SM819)" )
            or diag( "cells:\n  " . join "\n  ", @cells );
        like( $cells[-1] // '', qr/<button\b[^>]*>Delete<\/button>/,
            "row $i: the LAST cell holds the button, so it sits on the right" );
    }
    like( $rows[0], qr/>www\.example\.org</, 'the primary row names its domain' );
    like( $rows[1], qr/>fr\.example</,       'the alias row names its domain' );

    # The delete stays surgical: only an alias host's copy passes its host.
    like( $rows[1], qr/deleteCached\('\/index\.html','fr\.example'\)/,
        'the alias row deletes only that host\'s copy' );
    like( $rows[0], qr/deleteCached\('\/index\.html'\)/,
        'the primary row passes no host' );

    unlike( $html, qr/>Invalidate</, 'no row button says Invalidate' );
    like( $src, qr/onclick="clearAll\(\)">Delete all<\/button>/,
        'the button for every copy says Delete all' );
    unlike( $src, qr/>Clear All Cache</, 'and no longer Clear All Cache' );
}

# The direct children of a row: counted by depth, so a tag nested inside a
# cell is part of that cell rather than a cell of its own.
sub top_level_cells {
    my ($row) = @_;
    my ( $depth, $start, @cells ) = ( 0, 0 );
    while ( $row =~ /<(\/?)([a-z]+)\b[^>]*>/g ) {
        my ( $close, $end, $from ) = ( $1, pos $row, $-[0] );
        if ($close) {
            $depth--;
            push @cells, substr( $row, $start, $end - $start ) if $depth == 0;
        }
        else {
            $start = $from if $depth == 0;
            $depth++;
        }
    }
    return @cells;
}

done_testing();
