#!/usr/bin/perl
# SM657 part two: `type=row`.
#
# A data row was the one content object with nowhere to record WHY it is as it
# is. A page has a brief; a table has descriptor comments that round-trip
# verbatim; a folder, asset, layout, theme, nav and the site root already take a
# brief. A row has no path, no descriptor and no comment field - and on a
# data-driven site it is THE content object.
#
# THE ORDERING CONDITION THE FILING SET is what shapes this: "do not widen the
# key space until a brief can be listed and deleted", because rows are deleted
# constantly - every withdrawal, every superseding import, every correction -
# and each would otherwise leave an invisible, unclearable orphan. SM508 shipped
# that lifecycle for path-keyed briefs.
#
# So typed entries live in the SAME store under a reserved prefix, and the tests
# that matter most here are that the list SEES them and the delete CLEARS them.
# A second store would have needed its own listing and its own delete, which is
# the gap the condition was about, one layer down.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
require Lazysite::Manager::Briefs;

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/briefs");
make_path("$d/docs");

# THE PLUGIN MUST BE ENABLED. Every brief action is gated on it, and a fixture
# without it returns "the briefs plugin is disabled" for each one - which looks
# exactly like the feature not working.
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nplugins:\n  - plugins/briefs.pl\n";
close $cf;
open my $pg, '>', "$d/docs/page.md" or die $!;
print {$pg} "---\ntitle: p\n---\n\nBody.\n";
close $pg;

{
    no warnings 'once';
    $Lazysite::Manager::Briefs::DOCROOT = $d;
    $Lazysite::Manager::Common::DOCROOT = $d;
    $Lazysite::Manager::Briefs::auth_user = 'tester';
}

subtest 'the typed key refuses what is not a key' => sub {
    is( Lazysite::Manager::Briefs::typed_rel(), undef,
        'no type at all is not a typed reference' );
    is( Lazysite::Manager::Briefs::typed_rel( type => 'table', table => 't', key => 'k' ),
        undef, 'type=table is not built yet and is not silently accepted as row' );

    my $missing = Lazysite::Manager::Briefs::typed_rel( type => 'row', table => 'stock' );
    like( $missing->{error}, qr/needs a `key`/, 'a row needs a key' );

    for my $bad ( 'a/b', '../x', '', '.hidden' ) {
        my $r = Lazysite::Manager::Briefs::typed_rel(
            type => 'row', table => 'stock', key => $bad );
        ok( $r->{error}, "key '$bad' is refused" )
            or diag( 'A key carrying a slash would put the brief somewhere the '
                . 'key does not describe.' );
    }

    my $ok = Lazysite::Manager::Briefs::typed_rel(
        type => 'row', table => 'stock', key => 'SKU-1' );
    is( $ok->{rel}, '.typed/row/stock/SKU-1', 'a good key resolves under the reserved prefix' );
};

subtest 'a row brief can be written and read back' => sub {
    my %ref = ( type => 'row', table => 'stock', key => 'SKU-1' );
    my $r = Lazysite::Manager::Briefs::action_brief_append(
        undef, 'withdrawn after the supplier recall', %ref );
    ok( $r->{ok}, 'an entry is appended against a row' ) or diag( $r->{error} // '' );

    my $back = Lazysite::Manager::Briefs::action_brief_read( undef, %ref );
    ok( $back->{ok} && $back->{exists}, 'and reads back' );
    like( $back->{brief}, qr/supplier recall/, 'with the text' );
    like( $back->{brief}, qr/tester/, 'attributed' );
    is( $back->{table}, 'stock', 'and the reply echoes the reference' );
};

subtest 'the LIST sees it - the ordering condition' => sub {
    Lazysite::Manager::Briefs::action_brief_append( '/docs/page.md', 'a page brief' );
    my $l = Lazysite::Manager::Briefs::action_briefs_list();
    ok( $l->{ok}, 'the listing runs' );
    my ($row) = grep { $_->{path} =~ m{\.typed/row/stock/SKU-1} } @{ $l->{briefs} };
    ok( $row, 'a row brief appears in the listing' )
        or diag( 'If it does not, deleted rows leave orphans nobody can see - '
            . 'which is exactly what the filing said must not happen before '
            . 'the key space widened.' );
    is( $row->{type}, 'row', 'marked with its type' );

    # NOT reported as an orphan. The file test that decides orphanhood for a
    # path-keyed brief would call every typed entry an orphan, and invite an
    # operator to clear briefs that are doing their job.
    ok( !defined $row->{orphan},
        'and its liveness is reported as unknown, not guessed' );

    my ($page) = grep { $_->{path} eq '/docs/page.md' } @{ $l->{briefs} };
    ok( $page && !$page->{orphan}, 'a live page brief is still not an orphan' );
};

subtest 'the DELETE clears it - the other half of the condition' => sub {
    my $r = Lazysite::Manager::Briefs::action_brief_delete('/.typed/row/stock/SKU-1');
    ok( $r->{ok} && $r->{deleted}, 'a row brief can be deleted by its store path' )
        or diag( $r->{error} // '' );

    my $back = Lazysite::Manager::Briefs::action_brief_read(
        undef, type => 'row', table => 'stock', key => 'SKU-1' );
    ok( $back->{ok} && !$back->{exists}, 'and is gone' );

    my $l = Lazysite::Manager::Briefs::action_briefs_list();
    ok( !grep( { $_->{path} =~ m{SKU-1} } @{ $l->{briefs} } ),
        'and no longer listed' );
};

subtest 'a path brief is unaffected' => sub {
    my $back = Lazysite::Manager::Briefs::action_brief_read('/docs/page.md');
    ok( $back->{ok} && $back->{exists}, 'still readable' );
    like( $back->{brief}, qr/a page brief/, 'with its text' );
    ok( !defined $back->{type}, 'and carries no type' );
};

done_testing();
