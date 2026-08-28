#!/usr/bin/perl
# DM-1: an operator can see a table.
#
# WHAT THE LISTING HAS TO ANSWER. Somebody looking at a list of tables has
# exactly two questions about each one - CAN ANYBODY SEE IT, and IS IT REAL YET
# - and until DM-1 the listing answered neither. It gave a name and a title, so
# a table declared and never migrated looked identical to one holding a
# thousand rows, and an unpublished table looked identical to a public one.
#
# Both answers are DERIVED rather than remembered, per D2: `public` off the
# descriptor, existence off the database. The database is the state.
#
# They travel WITH the listing rather than behind a second request, because an
# operator with twelve tables should not cost twelve round trips to learn which
# of them anyone can read.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Tables qw(apply_schema insert_row);
use Lazysite::Manager::Data ();

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/tables");

sub conf {
    my ($on) = @_;
    open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
    print {$c} "site_name: T\n";
    print {$c} "plugins:\n  - plugins/data.pl\n" if $on;
    close $c;
}
sub descriptor {
    my ( $name, $body ) = @_;
    open my $f, '>', "$docroot/lazysite/db/tables/$name.yaml" or die $!;
    print {$f} $body;
    close $f;
}

conf(1);
descriptor( 'notes', "public: true\nkey: code\nfields:\n  code:\n    type: text\n" );
descriptor( 'draft', "key: code\nfields:\n  code:\n    type: text\n" );
apply_schema( $docroot, 'notes' );
insert_row( $docroot, 'notes', { code => 'N1' } );

$Lazysite::Manager::Data::DOCROOT = $docroot;

sub listing {
    my $r = Lazysite::Manager::Data::action_data_tables();
    return ( $r, { map { $_->{table} => $_ } @{ $r->{tables} || [] } } );
}

subtest 'SM679: the listing says how many rows, and says nothing when it cannot' => sub {
    my ( undef, $by ) = listing();

    is( $by->{notes}{row_count}, 1, 'a live table reports its row count' )
        or diag( 'This is the first thing anybody wants from a list of tables: '
            . 'which has anything in it, and did the import land.' );

    insert_row( $docroot, 'notes', { code => 'N2' } );
    ( undef, $by ) = listing();
    is( $by->{notes}{row_count}, 2, 'and the count is read, not remembered' )
        or diag( 'A cached or descriptor-derived number would not move here.' );

    # UNKNOWN IS NOT ZERO. `draft` has no schema applied, so it cannot be
    # counted - the field is ABSENT rather than 0. An operator deciding whether
    # an import worked reads "0 rows" as "the import failed"; the honest answer
    # is that nobody could tell.
    ok( $by->{draft}{pending_schema}, 'the unmigrated table is still pending' );
    ok( !exists $by->{draft}{row_count},
        'and carries NO row_count rather than a zero' )
        or diag( 'Reporting 0 for a table that could not be counted is the '
            . 'confident wrong answer this project keeps filing against.' );
};

subtest 'a published table says so, and an unpublished one says so' => sub {
    my ( $r, $by ) = listing();
    ok( $r->{ok}, 'the listing answers' ) or diag( $r->{error} );

    ok( $by->{notes}, 'the published table is listed' );
    ok( $by->{notes}{public}, 'and is marked public' )
        or diag( 'Without this an operator cannot tell, from the one page '
            . 'built to tell them, whether anybody can read a table.' );

    ok( $by->{draft}, 'the unpublished table is listed too' )
        or diag( 'It must be VISIBLE to an operator and invisible to the '
            . 'public - those are different questions.' );
    ok( !$by->{draft}{public}, 'and is not marked public' );
};

subtest 'a table that has never been migrated says THAT' => sub {
    my ( undef, $by ) = listing();
    ok( $by->{draft}{pending_schema}, 'the un-migrated table is flagged' )
        or diag( 'A declared table with no stored table reads as an empty '
            . 'table everywhere else, and empty is the hardest state to tell '
            . 'from broken.' );
    ok( !$by->{notes}{pending_schema}, 'and the migrated one is not' );

    # DERIVED, NOT REMEMBERED. Migrating it must change the answer with nothing
    # else being written down - the database is the state (D2).
    apply_schema( $docroot, 'draft' );
    my ( undef, $after ) = listing();
    ok( !$after->{draft}{pending_schema},
        'migrating it clears the flag, with no state file involved' );
};

subtest 'a descriptor that will not load is reported, not dropped' => sub {
    descriptor( 'broken', "fields:\n  x:\n    type: nosuchtype\n" );
    my ( undef, $by ) = listing();
    ok( $by->{broken}, 'the broken table still appears in the listing' )
        or diag( 'Dropping it would make a table an operator can SEE on disk '
            . 'vanish from the page that exists to show them their tables.' );
    ok( !$by->{broken}{ok}, 'marked as not ok' );
    like( $by->{broken}{error}, qr/nosuchtype/, 'with the reason' );
    unlink "$docroot/lazysite/db/tables/broken.yaml";
};

subtest 'OFF MEANS OFF here too' => sub {
    # SM409. The listing is a read, and a read is execution - it opens the
    # store and runs a query.
    conf(0);
    my ($r) = listing();
    ok( !$r->{ok}, 'a disabled plugin lists nothing' );
    like( $r->{error}, qr/disabled/i, 'and says why' )
        or diag( 'The page shows this text instead of an empty list, so a '
            . 'switched-off plugin cannot look like a site with no data.' );
    conf(1);
};

done_testing();
