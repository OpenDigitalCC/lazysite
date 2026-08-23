#!/usr/bin/perl
# SM480: a table can be removed. Until now it could not, by any route at all.
#
# HOW THE GAP WAS FOUND, which is the part worth keeping: the field agent
# finished a testing session and tried to tidy up after themselves. There is no
# data-table-drop, no data-table-delete, no MCP tool, and the descriptor lives
# under lazysite/ where every write channel refuses on purpose - so there was
# no manual route either. Rows could be deleted one at a time; the table could
# not be removed at all.
#
# The consequence is not inconvenience. A table declared by mistake, or
# misnamed, or made for one afternoon's testing, was PERMANENT - and every test
# table on the edge site was going to outlive the testing that made it.
#
# IT TAKES EVERYTHING, so it asks first, and the confirmation is the table's
# own NAME rather than a yes: somebody who types the name has read the name.
# That is the shape DP-5 already uses for a destructive migration.
#
# AND THE SAFETY EXPORT COMES FIRST. The table is not recoverable; the data is.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Tables
    qw(apply_schema insert_row read_rows list_tables load_table drop_table);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/tables");
open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\n";
close $c;

sub declare {
    my ($name) = @_;
    open my $f, '>', "$docroot/lazysite/db/tables/$name.yaml" or die $!;
    print {$f} "key: code\nfields:\n  code:\n    type: text\n"
        . "  note:\n    type: text\n";
    close $f;
    apply_schema( $docroot, $name );
}

subtest 'IT ASKS FIRST, AND THE ANSWER IS THE NAME' => sub {
    declare('doomed');
    insert_row( $docroot, 'doomed', { code => 'D1', note => 'keep me' } );

    my $r = drop_table( $docroot, 'doomed' );
    ok( !$r->{ok}, 'without confirmation it refuses' );
    is( $r->{kind}, 'needs_confirmation', 'saying what it needs' );
    like( $r->{error}, qr/doomed/, 'and naming the table to type back' )
        or diag( 'A yes/no can be clicked by somebody who did not read which '
            . 'table they were on. A name has to be read to be typed.' );

    my $wrong = drop_table( $docroot, 'doomed', confirm => 'DOOMED' );
    ok( !$wrong->{ok}, 'a near-miss confirmation is refused' )
        or diag( 'Case-insensitive matching here would accept a confirmation '
            . 'the operator did not actually give.' );

    # AND NOTHING HAPPENED YET.
    ok( ( grep { $_ eq 'doomed' } @{ list_tables($docroot) } ),
        'the table is still declared' );
    is( scalar @{ read_rows( $docroot, 'doomed', as => 'operator' )->{rows} },
        1, 'and still holds its row' );
};

subtest 'confirmed, it takes the descriptor and the rows together' => sub {
    my $r = drop_table( $docroot, 'doomed', confirm => 'doomed' );
    ok( $r->{ok}, 'it drops' ) or diag( $r->{error} );
    is( $r->{rows_dropped}, 1, 'reporting how many rows went' );

    ok( !( grep { $_ eq 'doomed' } @{ list_tables($docroot) } ),
        'the table is no longer declared' );
    ok( !-f "$docroot/lazysite/db/tables/doomed.yaml",
        'the descriptor file is gone' )
        or diag( 'A descriptor left behind would leave the table reading as '
            . 'declared-but-never-migrated, which is a state somebody has to '
            . 'then work out how to clear.' );

    my $gone = load_table( $docroot, 'doomed' );
    ok( !$gone->{ok}, 'and loading it fails as a table that does not exist' );
};

subtest 'THE DATA SURVIVES EVEN THOUGH THE TABLE DOES NOT' => sub {
    declare('archive_me');
    insert_row( $docroot, 'archive_me', { code => 'A1', note => 'precious' } );
    insert_row( $docroot, 'archive_me', { code => 'A2', note => 'also' } );

    my $r = drop_table( $docroot, 'archive_me', confirm => 'archive_me' );
    ok( $r->{ok}, 'it drops' );

    my $path = "$docroot/" . ( $r->{safety_export} // '' );
    ok( -f $path, 'a safety export was written' )
        or diag( 'The rows are about to stop existing. A copy on disk is the '
            . 'difference between a mistake and a loss.' );

    my $doc = decode_json( do {
        open my $fh, '<', $path or die $!;
        local $/;
        <$fh>;
    } );
    is( scalar @{ $doc->{rows} || [] }, 2, 'holding every row' );
    like( encode_json($doc), qr/precious/, 'with the values intact' );
};

subtest 'THE PATH IT REPORTS IS SITE-RELATIVE' => sub {
    # The field agent found the rebuild export handing back
    # /home/<account>/web/<domain>/... - the hosting account name and the
    # server's filesystem layout, both guessable for the next site. Same
    # disclosure class as the manager edit link.
    declare('pathcheck');
    my $r = drop_table( $docroot, 'pathcheck', confirm => 'pathcheck' );
    ok( $r->{ok}, 'it drops' );
    unlike( $r->{safety_export}, qr{\A/},
        'the reported path does not start at the server root' )
        or diag( "reported: $r->{safety_export}" );
    like( $r->{safety_export}, qr{\Alazysite/db/rebuilds/},
        'it is rooted at the site, where an operator can reach it' );
};

subtest 'IF THE EXPORT CANNOT BE WRITTEN, NOTHING IS DROPPED' => sub {
    # The safety property the whole ordering exists for. An export that fails
    # while the drop proceeds anyway is worse than having no export at all: the
    # operator was promised a copy, told the drop succeeded, and has neither.
    #
    # Provoked by putting a FILE where the exports directory belongs, which
    # needs no permission games and behaves the same on any host.
    my $d2 = tempdir( CLEANUP => 1 );
    make_path("$d2/lazysite/db/tables");
    open my $cf, '>', "$d2/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\n";
    close $cf;
    open my $df, '>', "$d2/lazysite/db/tables/fragile.yaml" or die $!;
    print {$df} "key: code\nfields:\n  code:\n    type: text\n";
    close $df;
    apply_schema( $d2, 'fragile' );
    insert_row( $d2, 'fragile', { code => 'F1' } );

    open my $block, '>', "$d2/lazysite/db/rebuilds" or die $!;
    print {$block} "not a directory\n";
    close $block;

    my $r = drop_table( $d2, 'fragile', confirm => 'fragile' );
    ok( !$r->{ok}, 'the drop is refused' )
        or diag( 'The export failed. Dropping anyway would destroy the rows '
            . 'the export existed to preserve.' );
    like( $r->{error}, qr/nothing was dropped/,
        'and says plainly that nothing was dropped' );

    ok( ( grep { $_ eq 'fragile' } @{ list_tables($d2) } ),
        'the table is still declared' );
    is( scalar @{ read_rows( $d2, 'fragile', as => 'operator' )->{rows} },
        1, 'and its row is still there' );
};

subtest 'a table that does not exist is not a drop' => sub {
    my $r = drop_table( $docroot, 'never_existed', confirm => 'never_existed' );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error}, qr/never_existed/, 'naming what was not found' );
};

done_testing();
