#!/usr/bin/perl
# N141B-B: `list` accepts a folder path with or without a leading slash.
#
# acl-get, acl-set, acl-remove and protected-sections all normalise the path.
# action_list alone required the slash, and DID NOT SAY SO: it stripped leading
# slashes into $list_rel to decide which tree the folder is in, then
# concatenated the ORIGINAL $dir_path onto that root - so "docs" built
# "<root>docs", realpath failed, and the caller was told:
#
#   'docs' is not a folder this site can list: it does not exist, or it
#   resolves outside the site tree.
#
# Neither was true. THAT is the part worth a test. A refusal that names the
# wrong cause is worse than a bare failure, because it sends the reader to
# check the folder and its permissions - the two things that were fine - and
# nothing in the message points at the slash.
#
# Found by an agent walking the ACL surface, who noticed that one action out of
# five wanted a different spelling from the rest.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir);
use Lazysite::Manager::Files;

my $d = site_tempdir();
make_path("$d/docs/deep");
for my $f ( "$d/docs/a.md", "$d/docs/deep/b.md" ) {
    open my $fh, '>', $f or die $!;
    print {$fh} "---\ntitle: x\n---\nbody\n";
    close $fh;
}

no warnings 'once';
$Lazysite::Manager::Files::DOCROOT = $d;
use warnings 'once';

sub listing { return Lazysite::Manager::Files::action_list( $_[0] ) }

# --- both spellings name the same folder -------------------------------------
my $with    = listing('/docs');
my $without = listing('docs');

ok( $with->{ok}, 'a path with a leading slash lists' );
ok( $without->{ok}, 'and so does the same path without one' )
    or diag( 'This is the defect: four sibling actions normalise the path and '
        . "this one did not. It answered: " . ( $without->{error} // '' ) );

is( scalar @{ $with->{entries} || [] },
    scalar @{ $without->{entries} || [] },
    'both spellings return the same number of entries' );

# The path the caller gets back is the normalised one, in the single shape
# every other field on the response already assumes.
is( $without->{path}, '/docs',
    'and the answer reports the path in one canonical shape' )
    or diag( 'Child paths are assembled from this field. Two shapes here means '
        . 'two shapes in every entry built from it.' );

# --- nesting is unaffected ---------------------------------------------------
my $deep = listing('docs/deep');
ok( $deep->{ok}, 'a nested path without a leading slash lists too' );
is( $deep->{path}, '/docs/deep', 'and is canonicalised the same way' );

# --- the root still works, spelled either way --------------------------------
#
# '/' and '' both mean the site root. The empty string is the interesting one:
# the normaliser re-inflates it, and a rule added carelessly could turn it into
# '//' or leave it bare.
for my $root ( '/', '' ) {
    my $r = listing($root);
    ok( $r->{ok}, "the site root lists when given as '$root'" );
    is( $r->{path}, '/', "and reports itself as '/'" );
}

# --- a folder that really is absent is still refused -------------------------
#
# The fix must not make every path list something. Both spellings must refuse.
for my $missing ( '/nope', 'nope' ) {
    my $r = listing($missing);
    is( $r->{ok}, 0, "a folder that does not exist is refused ('$missing')" );
    is( $r->{kind}, 'invalid-path', 'with the invalid-path kind' );
}

done_testing();
