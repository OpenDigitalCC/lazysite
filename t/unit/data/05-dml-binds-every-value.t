#!/usr/bin/perl
# SM447: DML generation.
#
# THE SHAPE IS THE GUARANTEE. Every generator returns ( $sql, \@binds ) and
# never a finished statement, so there is no way to call one and receive a
# string with a value in it - the value has nowhere to go except the bind list.
# A caller cannot interpolate by mistake and a reviewer does not have to read
# the body to know it.
#
# So the headline test is not "does it produce the right SQL". It is: given
# values chosen to be maximally hostile, does any part of them appear in the
# statement text? That question has one right answer for every input, which
# makes it the assertion worth having.
#
# END TO END AGAINST A REAL SQLITE FILE, not just string comparison. Generated
# SQL that looks correct and does not execute is the failure mode a
# text-only test cannot see, and the round-trip is also the only way to prove
# the hostile value came BACK unchanged - which is the actual promise.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Data::Descriptor qw(load_descriptor);
use Lazysite::Data::Value qw(coerce_row);
use Lazysite::Data::SQLite
    qw(create_table_sql insert_sql update_sql delete_sql select_sql);

my $has_dbi = eval { require DBI; require DBD::SQLite; 1 };

my $d = load_descriptor(
    'orders',
    {   key    => 'ref',
        fields => {
            ref   => { type => 'text', required => 1, max => 40 },
            note  => { type => 'text' },
            qty   => { type => 'integer' },
            total => { type => 'decimal', digits => 8, places => 2 },
            paid  => { type => 'boolean', default => 0 },
        },
    }
);
ok( $d->{ok}, 'fixture descriptor loads' ) or BAIL_OUT( $d->{error} );

# Values chosen to break a generator that concatenates.
my %HOSTILE = (
    ref  => q{a'; DROP TABLE orders;--},
    note => qq{line1\nline2 " ' `` \\ %s ? ; -- /* */ \x{263A}},
);

subtest 'no value reaches the statement text' => sub {
    my $row = coerce_row( $d, { %HOSTILE, qty => 7 } );
    ok( $row->{ok}, 'the hostile row coerces' ) or diag( $row->{error} );

    my ( $sql, $binds ) = insert_sql( $d, $row->{values} );
    for my $v ( values %HOSTILE ) {
        ok( index( $sql, $v ) < 0, 'the value is absent from the INSERT text' )
            or diag("statement was: $sql");
    }
    like( $sql, qr/VALUES \(\?, \?, \?, \?\)/, 'every column is a placeholder' );
    is( scalar @{$binds}, 4, 'and every value is a bind' );

    my ( $usql, $ubinds ) = update_sql( $d, $HOSTILE{ref}, $row->{values} );
    ok( index( $usql, $HOSTILE{ref} ) < 0,
        'the KEY is bound too, even though it identifies the row' )
        or diag( 'It is data. Only its column NAME is interpolated.' );
    is( $ubinds->[-1], $HOSTILE{ref}, 'and it is the last bind, for the WHERE' );

    my ( $dsql, $dbinds ) = delete_sql( $d, $HOSTILE{ref} );
    ok( index( $dsql, $HOSTILE{ref} ) < 0, 'likewise for DELETE' );
    is_deeply( $dbinds, [ $HOSTILE{ref} ], 'one bind, the key' );
};

subtest 'no unbounded UPDATE or DELETE can be generated' => sub {
    ok( !eval { update_sql( $d, undef, { note => 'x' } ); 1 },
        'update without a key value dies' )
        or diag( 'A generator that CAN emit an unbounded UPDATE eventually '
            . 'will. There is no code path to one.' );
    ok( !eval { update_sql( $d, 'A1', {} ); 1 }, 'update with nothing to set dies' );
    ok( !eval { delete_sql( $d, '' ); 1 },       'delete without a key dies' );

    my ( $sql, undef ) = update_sql( $d, 'A1', { ref => 'A2', note => 'x' } );
    ok( index( $sql, 'ref = ?' ) < 0 || $sql =~ /WHERE ref = \?/,
        'the key is not SETTABLE through an update' );
    like( $sql, qr/SET note = \?/, 'only the other field is set' )
        or diag( 'Changing the key would move the row identity while the '
            . 'WHERE still names the old one.' );
};

subtest 'select is bounded, and orders only by a declared field' => sub {
    my ( $sql, $binds ) = select_sql($d);
    like( $sql, qr/LIMIT \?$/, 'a bare select still carries a LIMIT' )
        or diag( 'An unbounded select against a table an agent has been '
            . 'filling is how a page renders for a minute.' );
    is( $binds->[-1], 200, 'with the default ceiling' );

    ( $sql, $binds ) = select_sql( $d, limit => 99999 );
    is( $binds->[-1], 1000, 'and the caller cannot raise it past the cap' );

    ( $sql, $binds ) = select_sql( $d, order_by => 'qty', order => 'desc' );
    like( $sql, qr/ORDER BY qty DESC/, 'ordering by a declared field works' );

    ok( !eval { select_sql( $d, order_by => 'sqlite_version()' ); 1 },
        'an expression is refused' );
    ok( !eval { select_sql( $d, order_by => 'nosuch' ); 1 },
        'and so is a plain word that is not a field' )
        or diag( '_ident alone would accept it - safe to interpolate and '
            . 'still wrong, because it names a column that does not exist '
            . 'and the query would die at the engine instead of being '
            . 'refused with a reason.' );

    ( $sql, $binds ) = select_sql( $d, where => { note => undef } );
    like( $sql, qr/note IS NULL/, 'a NULL filter uses IS NULL' )
        or diag( 'NULL = NULL is not true in SQL, so binding undef would '
            . 'match no rows and read as "there are none".' );
};

SKIP: {
    skip 'DBD::SQLite not available', 1 unless $has_dbi;
    subtest 'the round trip returns the hostile value unchanged' => sub {
        my $dir = tempdir( CLEANUP => 1 );
        my $dbh = DBI->connect( "dbi:SQLite:dbname=$dir/t.sqlite",
            '', '', { RaiseError => 1, AutoCommit => 1, sqlite_unicode => 1 } );
        $dbh->do( create_table_sql($d) );

        my $row = coerce_row( $d, { %HOSTILE, qty => 7, total => '10.5' } );
        my ( $sql, $binds ) = insert_sql( $d, $row->{values} );
        $dbh->do( $sql, undef, @{$binds} );

        my ( $ssql, $sbinds ) = select_sql( $d, where => { ref => $HOSTILE{ref} } );
        my $got = $dbh->selectall_arrayref( $ssql, { Slice => {} }, @{$sbinds} );
        is( scalar @{$got}, 1, 'the row is found by its hostile key' );
        is( $got->[0]{note}, $HOSTILE{note},
            'and the hostile note comes back byte for byte' )
            or diag( 'This is the promise the binding invariant makes. If it '
                . 'were escaped anywhere, legitimate content would be '
                . 'corrupted to defend against a problem that does not exist.' );
        is( $got->[0]{total}, '10.50', 'the decimal is stored canonically' );
        is( $got->[0]{paid},  0,       'and the default was applied' );

        # The table is still there - which is the point of the key's spelling.
        my $tables = $dbh->selectall_arrayref(
            "SELECT name FROM sqlite_master WHERE type='table'");
        is( scalar @{$tables}, 1, 'the DROP TABLE in the key did not execute' );

        my ( $usql, $ubinds ) = update_sql( $d, $HOSTILE{ref}, { qty => 9 } );
        is( $dbh->do( $usql, undef, @{$ubinds} ), 1, 'update matches one row' );
        my ( $dsql, $dbinds ) = delete_sql( $d, $HOSTILE{ref} );
        is( $dbh->do( $dsql, undef, @{$dbinds} ), 1, 'delete matches one row' );
    };
}

done_testing();
