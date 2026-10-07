#!/usr/bin/perl
# SM869 adversarial review, second pass (n271): a db: row value - written by a
# visitor through a form, listed on a public page - stays text after the
# Markdown-shaped passes that read the template's OUTPUT, and keeps an `api:`
# page valid JSON.
#
# A row value is HTML-escaped where it enters the stash (_escape_db_rows), like a
# query value. The page body was converted from Markdown before the template
# pass, so the value itself is never Markdown - but the code-span restore and
# convert_p_links read the output after it, and an api page puts the value
# inside a JSON string. Structural assertions: no new element, valid JSON.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_test_site site_tempdir processor_path);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; require JSON::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP/JSON::PP not available';
}
use Lazysite::Data::Tables qw(apply_schema insert_row);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $docroot = site_tempdir();
setup_test_site($docroot);
make_path("$docroot/lazysite/db/tables");
spit( "$docroot/lazysite/db/tables/notes.yaml",
    "title: Notes\npublic: true\nfields:\n  body:\n    type: text\n" );
apply_schema( $docroot, 'notes' );
open my $cf, '>>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$cf} "plugins:\n  - plugins/data.pl\n";
close $cf;

my @ROWS = (
    'ordinary row',
    '[m](javascript:void)',
    'CODEBLOCK_0_END',
    "a trailing backslash \\",
    "a control \x01 character",
    "two\nlines",
    "a tab\there",
);
insert_row( $docroot, 'notes', { body => $_ } ) for @ROWS;

spit( "$docroot/list.md",
    "---\ntitle: List\ntt_page_var:\n  items: db:notes\n---\n"
        . "\nAn author code span `literal` here.\n\n"
        . "[% FOREACH i IN items %]<div class=\"r\">[% i.body %]</div>\n[% END %]\n" );
spit( "$docroot/rows.md",
    "---\napi: true\ntt_page_var:\n  items: db:notes\n---\n"
        . "[[% FOREACH i IN items %]{\"b\":\"[% i.body %]\"}[% UNLESS loop.last %],[% END %][% END %]]\n" );

sub render {
    my ($uri) = @_;
    local %ENV = %ENV;
    delete $ENV{$_} for grep { /\AHTTP_X_REMOTE_|\ALAZYSITE_/ } keys %ENV;
    @ENV{qw(DOCUMENT_ROOT REDIRECT_URL REQUEST_METHOD QUERY_STRING)} = ( $docroot, $uri, 'GET', '' );
    my $proc = processor_path();
    my $out  = scalar qx($^X \Q$proc\E 2>/dev/null);
    my ( undef, $body ) = split /\r?\n\r?\n/, $out, 2;
    return $body // '';
}

our $TODO;
my $list = render('/list');
like( $list, qr/ordinary row/, 'the canary: the page lists the table' );
my @cells = $list =~ m{<div class="r">(.*?)</div>}sg;
is( scalar @cells, scalar @ROWS, 'one cell per row' );
{
    local $TODO = 'n271 before: a row can spell a placeholder';
    ok( !( grep {/</} @cells ), 'every row value is text: no cell opens a tag' );
    # BEFORE (measured): the row rendered <a href="javascript:void">. SM966.
    { local $TODO; unlike( $list, qr/href="javascript/i, 'a row cannot become a link' ); }
    is( scalar( () = $list =~ /<code\b/g ), 1, 'a row cannot copy the author code span' );
}

# BEFORE (measured): the backslash, control character, tab and line break rows
# reached the JSON strings raw, and the page did not parse. SM966.
my $json = render('/rows');
my $d    = eval { JSON::PP->new->decode($json) };
ok( ref $d eq 'ARRAY', 'an api page listing the rows is valid JSON' )
    or diag( 'got: ' . ( $json =~ s/([\x00-\x1f])/sprintf '\\x%02x', ord $1/ger ) );
is( scalar @{ $d || [] }, scalar @ROWS, 'one object per row' );

done_testing();
