#!/usr/bin/perl
# DP-5: a blocked change can be made to happen, once it is confirmed BY NAME.
#
# apply_schema applies what is safe and refuses the rest - a type change, a
# tightening to NOT NULL, a dropped column. That is right as a default and
# wrong as a permanent state: a refusal with no path through is a dead end, and
# an operator who meets one edits the store by hand, which is the outcome the
# refusal existed to prevent.
#
# SQLITE CANNOT ALTER A COLUMN, so all three are one operation: build the new
# shape, copy what carries over, drop the old table, rename. That is a rewrite,
# which is exactly why it is not something a migration does because a
# descriptor changed.
#
# THE CONFIRMATION NAMES THE COLUMNS, and that is the design decision worth
# defending. A boolean - "yes, destructive" - would let an operator who had
# read about one dropped column agree to a second they had not noticed.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}

use Lazysite::Data::Tables
    qw(apply_schema insert_row read_rows rebuild_table load_table);

sub site {
    my ($yaml) = @_;
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/db/tables");
    open my $fh, '>', "$d/lazysite/db/tables/items.yaml" or die $!;
    print {$fh} $yaml;
    close $fh;
    return $d;
}
sub redescribe {
    my ( $d, $yaml ) = @_;
    open my $fh, '>', "$d/lazysite/db/tables/items.yaml" or die $!;
    print {$fh} $yaml;
    close $fh;
    return;
}

my $WITH = "key: code\nfields:\n  code:\n    type: text\n    required: true\n"
    . "  colour:\n    type: text\n  qty:\n    type: integer\n";
my $WITHOUT = "key: code\nfields:\n  code:\n    type: text\n    required: true\n"
    . "  qty:\n    type: integer\n";

subtest 'a rebuild that drops a column is REFUSED until the column is named' => sub {
    my $d = site($WITH);
    apply_schema( $d, 'items' );
    insert_row( $d, 'items', { code => 'A1', colour => 'red', qty => 2 } );
    redescribe( $d, $WITHOUT );

    my $r = rebuild_table( $d, 'items' );
    ok( !$r->{ok}, 'unconfirmed, it refuses' );
    is( $r->{kind}, 'needs_confirmation', 'with a kind a surface can act on' );
    is_deeply( $r->{lost}, ['colour'], 'and it says which column it would drop' )
        or diag( 'An operator cannot agree to a loss nobody named.' );

    my $wrong = rebuild_table( $d, 'items', confirm_lost => ['qty'] );
    ok( !$wrong->{ok}, 'confirming the WRONG column is not confirmation' )
        or diag( 'This is why the confirmation is a list of names rather than '
            . 'a boolean: "yes, destructive" would have passed here.' );

    # The table is untouched by either refusal.
    is( scalar @{ read_rows( $d, 'items', as => 'operator' )->{rows} }, 1, 'the row is still there' );
    is( read_rows( $d, 'items', as => 'operator' )->{rows}[0]{colour}, 'red', 'with its column' );
};

subtest 'confirmed, it rebuilds - and takes a safety export first' => sub {
    my $d = site($WITH);
    apply_schema( $d, 'items' );
    insert_row( $d, 'items', { code => 'A1', colour => 'red', qty => 2 } );
    insert_row( $d, 'items', { code => 'B2', colour => 'blue', qty => 7 } );
    redescribe( $d, $WITHOUT );

    my $r = rebuild_table( $d, 'items', confirm_lost => ['colour'] );
    ok( $r->{ok}, 'the rebuild runs' ) or diag( $r->{error} );
    is_deeply( $r->{lost}, ['colour'], 'reporting what was dropped' );
    is( $r->{rows}, 2, 'and how many rows it held' );

    ok( $r->{safety_export} && -s $r->{safety_export},
        'a safety export was written BEFORE the drop' )
        or diag( 'The operation drops a table. If anything about the copy is '
            . 'wrong, the rows must exist in one other place and the operator '
            . 'must be told where.' );

    my $rows = read_rows( $d, 'items', as => 'operator', order_by => 'code' )->{rows};
    is( scalar @{$rows}, 2, 'both rows survive the rebuild' );
    is( $rows->[0]{qty}, 2, 'the carried column keeps its value' );
    ok( !exists $rows->[0]{colour}, 'and the dropped column is gone' );
};

subtest 'a type change goes through the same door' => sub {
    my $d = site("key: code\nfields:\n  code:\n    type: text\n"
            . "  n:\n    type: text\n" );
    apply_schema( $d, 'items' );
    insert_row( $d, 'items', { code => 'A1', n => '42' } );

    redescribe( $d, "key: code\nfields:\n  code:\n    type: text\n"
            . "  n:\n    type: integer\n" );
    my $blocked = apply_schema( $d, 'items' );
    ok( ( grep { $_->{kind} eq 'type' } @{ $blocked->{blocked} } ),
        'the ordinary migration still refuses it' );

    # No column is LOST by a type change, so nothing needs naming.
    my $r = rebuild_table( $d, 'items' );
    ok( $r->{ok}, 'and the rebuild needs no confirmation, because nothing is dropped' )
        or diag( $r->{error} );
    is( read_rows( $d, 'items', as => 'operator' )->{rows}[0]{n}, 42, 'the value carries over' );
};

subtest 'a failure leaves the table standing' => sub {
    # The steps drop a table and rename another into its place. Half of that is
    # a site with no table at all, so they run in a transaction.
    my $d = site($WITH);
    apply_schema( $d, 'items' );
    insert_row( $d, 'items', { code => 'A1', colour => 'red' } );

    require Lazysite::Data::Connect;
    my $dbh = Lazysite::Data::Connect::write_handle($d);
    # Occupy the temporary name, so the first step fails.
    $dbh->do('CREATE TABLE "items__rebuild" (x TEXT)');

    redescribe( $d, $WITHOUT );
    my $r = rebuild_table( $d, 'items', confirm_lost => ['colour'] );
    ok( !$r->{ok}, 'the rebuild fails' );
    like( $r->{error}, qr/rolled back/, 'and says it was rolled back' );
    like( $r->{error}, qr/\Q$d\E.*\.json/, 'naming where the rows also are' )
        or diag( 'A failure that does not say where the copy went leaves the '
            . 'operator no better off than no copy.' );

    my $rows = read_rows( $d, 'items', as => 'operator' )->{rows};
    is( scalar @{$rows}, 1, 'the original table is intact' );
    is( $rows->[0]{colour}, 'red', 'with the column that was to be dropped' );

    # THE TRANSACTION IS ASSERTED STRUCTURALLY, and that is a weaker claim
    # stated as one rather than dressed up.
    #
    # The failure above happens at the FIRST step, before anything is dropped -
    # so it passes with or without a transaction. The window a transaction
    # actually protects is between DROP and RENAME, and provoking a failure
    # there needs the rename to fail after the drop has succeeded, which this
    # environment cannot arrange: the name it would collide with has just been
    # removed.
    #
    # So the behavioural test covers the reachable failure, and this covers the
    # unreachable one by reading the code. A structural assertion catches the
    # wrapper being removed, which is the realistic regression; it cannot prove
    # the rollback restores the table.
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Data/Tables.pm"
            or die $!;
        local $/;
        <$fh>;
    };
    my ($fn) = $src =~ /sub rebuild_table \{(.*?)\n\}/s;
    like( $fn, qr/begin_work/, 'the steps run inside a transaction' );
    like( $fn, qr/rollback/,   'and a failure rolls back' )
        or diag( 'Half of "drop the old table, rename the new one into place" '
            . 'is a site with no table at all.' );
};

done_testing();
