#!/usr/bin/perl
# SM725: a named-key descriptor declaring `timestamps: true` could not be
# created. The generated DDL appended created_at/updated_at AFTER the
# table-level PRIMARY KEY (...) clause, and a table constraint must follow every
# column definition - so SQLite refused with `near "created_at": syntax error`.
#
# IT FAILED ONLY ON THE NAMED-KEY PATH, which is why it survived since the
# option shipped: an auto key emits PRIMARY KEY inline on the id COLUMN rather
# than as a table constraint, so appending after it is harmless. The reporting
# site had one table of each shape and only one of them refused.
#
# EXECUTED, NOT MATCHED. The DDL is handed to a real SQLite handle rather than
# compared against expected text: the defect was that valid-looking SQL was
# invalid, and a string comparison written from the same misunderstanding would
# have agreed with it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Data::SQLite qw(create_table_sql);

my $dbh = eval {
    require DBI;
    DBI->connect( 'dbi:SQLite:dbname=:memory:', '', '',
        { RaiseError => 0, PrintError => 0 } );
};
plan skip_all => 'DBD::SQLite not available' unless $dbh;

my %shape = (
    'named key' => {
        ok => 1, table => 't_named', key => 'delivery', timestamps => 1,
        fields => {
            delivery => { type => 'text', required => 1, max => 30 },
            qty      => { type => 'integer' },
        },
    },
    'auto key' => {
        ok => 1, table => 't_auto', auto_key => 1, key => 'id', timestamps => 1,
        fields => { qty => { type => 'integer' } },
    },
    'named key, no timestamps' => {
        ok => 1, table => 't_plain', key => 'delivery',
        fields => { delivery => { type => 'text', required => 1 } },
    },
);

for my $name ( sort keys %shape ) {
    my $sql = create_table_sql( $shape{$name} );
    ok( defined $sql && length $sql, "$name: DDL generated" );
    my $rc = $dbh->do($sql);
    ok( $rc, "$name: SQLite accepts the DDL" )
        or diag( "refused: " . ( $dbh->errstr // '?' ) . "\nSQL:\n$sql" );
}

subtest 'the timestamp columns precede the table constraint' => sub {
    my $sql = create_table_sql( $shape{'named key'} );
    my $ts  = index( $sql, 'created_at' );
    my $pk  = index( $sql, 'PRIMARY KEY (' );
    cmp_ok( $ts, '>', -1, 'created_at is emitted' );
    cmp_ok( $pk, '>', -1, 'the table constraint is emitted' );
    cmp_ok( $ts, '<', $pk,
        'created_at comes BEFORE the PRIMARY KEY clause - the ordering is the fix' );
};

subtest 'the timestamp columns are usable once created' => sub {
    my $ok = $dbh->do(
        q{INSERT INTO t_named (delivery, qty, created_at) VALUES ('d1', 2, '2026-09-01')} );
    ok( $ok, 'a row carrying created_at inserts' )
        or diag( $dbh->errstr // '?' );
    my ($v) = $dbh->selectrow_array(
        q{SELECT created_at FROM t_named WHERE delivery = 'd1'} );
    is( $v, '2026-09-01', 'and reads back' );
};

done_testing();
