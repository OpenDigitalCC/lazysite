#!/usr/bin/perl
# SM964: a value that reaches the page through the template stash can never be
# resolved as a `::: include` block.
#
# render_template ran its second include pass over the template's OUTPUT, so a
# block in DATA was resolved like one the author wrote. A visitor-written row in a
# public table, listed on a public page, could pull an unpublished file into the
# output (found by the SM869 adversarial review). The second pass is gone: it
# never resolved an author's template-path block (Markdown had wrapped it), and
# a path taken from data would hand the choice of file to the data's author.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_test_site site_tempdir processor_path);

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
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

# A file that is on disk but not meant to be shown by this page.
spit( "$docroot/unlisted.md", "---\ntitle: Unlisted\n---\nUNLISTED-CANARY-7731\n" );
# A partial the AUTHOR includes through a template variable - the legitimate use.
spit( "$docroot/part.md", "PART-INCLUDED-4402\n" );

insert_row( $docroot, 'notes', { body => "hello\n::: include\n/unlisted.md\n:::\n" } );
insert_row( $docroot, 'notes', { body => "ordinary row" } );

spit( "$docroot/list.md",
    "---\ntitle: List\ntt_page_var:\n  items: db:notes\n---\n"
        . "[% FOREACH i IN items %]<div>[% i.body %]</div>\n[% END %]\n" );
spit( "$docroot/authored.md", "---\ntitle: Authored\n---\nBefore.\n\n::: include\n/part.md\n:::\n\nAfter.\n" );
spit( "$docroot/by-variable.md",
    "---\ntitle: ByVar\ntt_page_var:\n  which: /unlisted.md\n---\n"
        . "Before.\n\n::: include\n[% which %]\n:::\n\nAfter.\n" );

sub render {
    my ($uri) = @_;
    local %ENV = %ENV;
    delete $ENV{$_} for grep { /\AHTTP_X_REMOTE_|\ALAZYSITE_/ } keys %ENV;
    @ENV{qw(DOCUMENT_ROOT REDIRECT_URL REQUEST_METHOD QUERY_STRING)} = ( $docroot, $uri, 'GET', '' );
    my $proc = processor_path();
    return scalar qx($^X \Q$proc\E 2>/dev/null);
}

my $list = render('/list');
like( $list, qr/ordinary row/, 'the canary: the page lists the table' );
unlike( $list, qr/UNLISTED-CANARY-7731/, 'a row carrying an include block does not pull a file in' )
    or diag('The second include pass resolved a block that arrived as DATA.');

my $auth = render('/authored');
like( $auth, qr/PART-INCLUDED-4402/, 'an include the author wrote is still resolved' )
    or diag( substr( $auth, 0, 600 ) );
unlike( render('/by-variable'), qr/UNLISTED-CANARY-7731/,
    'a path from a template variable is not resolved, as the docs say' );

done_testing();
