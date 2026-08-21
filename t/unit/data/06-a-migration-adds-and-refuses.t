#!/usr/bin/perl
# SM447: schema comparison and additive migration.
#
# NO SCHEMA-STATE FILE, which departs from the SM410 map's "schema-state via
# the SM404 checked writer" and is asserted here so the departure is visible
# rather than implicit. A state file is a THIRD copy of the truth after the
# descriptor and the database, and the failure is concrete: DP-6 restores rows
# into a FRESH database, possibly on another engine, so a state file arrives
# describing something that is not there. Derivation costs one PRAGMA and
# cannot desync, because the actual state IS the database.
#
# TWO MEASURED ENGINE FACTS drive the whole design, probed rather than assumed:
#
#   ALTER TABLE ... ADD COLUMN ... NOT NULL is REFUSED by SQLite once the table
#   holds rows, and ACCEPTED while it is empty - so the same migration would
#   behave differently depending on whether anyone had used the site yet.
#
#   DEFAULT ? is a SYNTAX ERROR. A DDL default cannot be bound, so emitting one
#   means putting a value into SQL text, which the adapter does not do.
#
# Both are asserted below against a real database, because a comment recording
# a measurement is worth nothing once somebody changes the code around it.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; 1 }
        or plan skip_all => 'DBD::SQLite not available';
}

use Lazysite::Data::Descriptor qw(load_descriptor);
use Lazysite::Data::Schema qw(plan_migration);
use Lazysite::Data::SQLite qw(create_table_sql insert_sql);
use Lazysite::Data::Value qw(coerce_row);

my $dir = tempdir( CLEANUP => 1 );
sub fresh_dbh {
    my $n = shift;
    # PrintError off: two subtests below deliberately provoke a refusal and
    # catch it, and DBI would print each to STDERR - noise that reads like a
    # failing suite.
    return DBI->connect( "dbi:SQLite:dbname=$dir/$n.sqlite",
        '', '', { RaiseError => 1, PrintError => 0, AutoCommit => 1 } );
}

sub desc {
    my (%fields) = @_;
    my $d = load_descriptor( 'items',
        { key => 'code', fields => { code => { type => 'text' }, %fields },
          ( $fields{__ix} ? () : () ) } );
    return $d;
}

sub apply {
    my ( $dbh, $plan ) = @_;
    $dbh->do($_) for @{ $plan->{create} };
    $dbh->do( $_->{sql}, undef, @{ $_->{binds} } ) for @{ $plan->{additive} };
    return;
}

# --- a table that does not exist yet ---------------------------------------
subtest 'an absent table is created, not migrated' => sub {
    my $dbh = fresh_dbh('a');
    my $d   = desc( name => { type => 'text' } );
    my $p   = plan_migration( $d, $dbh );
    ok( $p->{ok}, 'the plan is produced' );
    ok( scalar @{ $p->{create} },   'it creates' );
    ok( !scalar @{ $p->{blocked} }, 'and blocks nothing' );
    apply( $dbh, $p );

    my $again = plan_migration( $d, $dbh );
    is_deeply( $again->{create},   [], 'a second run creates nothing' );
    is_deeply( $again->{additive}, [], 'and has nothing left to add' )
        or diag( 'A plan that is not idempotent fails badly the one time it '
            . 'is interrupted.' );
};

# --- the measured engine facts ---------------------------------------------
subtest 'the two engine limits this design is built around' => sub {
    my $dbh = fresh_dbh('b');
    $dbh->do('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT)');
    $dbh->do( 'INSERT INTO t (a) VALUES (?)', undef, 'row' );

    ok( !eval { $dbh->do('ALTER TABLE t ADD COLUMN c TEXT NOT NULL'); 1 },
        'ADD COLUMN NOT NULL is refused once the table holds rows' )
        or diag( 'If this ever starts succeeding, the migration planner can '
            . 'be simplified - but silently emitting it would produce a '
            . 'migration that works on an unused site and fails on a used one.' );

    ok( !eval { $dbh->do('ALTER TABLE t ADD COLUMN e TEXT DEFAULT ?'); 1 },
        'a DDL default cannot be bound - DEFAULT ? is a syntax error' )
        or diag( 'This is why defaults are applied by a bound UPDATE: the '
            . 'alternative is a value in SQL text.' );
};

# --- adding a field to a populated table -----------------------------------
subtest 'a new field is added, and its default is BACKFILLED by a bound update' => sub {
    my $dbh = fresh_dbh('c');
    my $d1  = desc( name => { type => 'text' } );
    apply( $dbh, plan_migration( $d1, $dbh ) );
    my $row = coerce_row( $d1, { code => 'A1', name => 'first' } );
    my ( $sql, $binds ) = insert_sql( $d1, $row->{values} );
    $dbh->do( $sql, undef, @{$binds} );

    my $d2 = desc(
        name  => { type => 'text' },
        state => { type => 'enum', values => [qw(new done)], default => 'new' },
    );
    my $p = plan_migration( $d2, $dbh );
    is( scalar @{ $p->{additive} }, 2, 'two steps: the column, then the backfill' );
    ok( ( grep { $_->{sql} =~ /ADD COLUMN state TEXT$/ } @{ $p->{additive} } ),
        'the column is added WITHOUT NOT NULL and WITHOUT a DEFAULT' );
    my ($fill) = grep { $_->{sql} =~ /^UPDATE/ } @{ $p->{additive} };
    ok( $fill, 'and the default arrives as an UPDATE' );
    is_deeply( $fill->{binds}, ['new'], 'with the value BOUND, not in the text' );
    like( $fill->{sql}, qr/WHERE state IS NULL/,
        'scoped to IS NULL, so re-running cannot overwrite a set value' );

    apply( $dbh, $p );
    my $got = $dbh->selectall_arrayref( 'SELECT code, state FROM items',
        { Slice => {} } );
    is( $got->[0]{state}, 'new', 'the pre-existing row is filled' );
    is_deeply( plan_migration( $d2, $dbh )->{additive}, [],
        'and the migration is now a no-op' );
};

# --- what must never be done silently --------------------------------------
subtest 'a type change is refused and named, never performed' => sub {
    my $dbh = fresh_dbh('d');
    apply( $dbh, plan_migration( desc( n => { type => 'text' } ), $dbh ) );

    my $changed = desc( n => { type => 'integer' } );
    my $p       = plan_migration( $changed, $dbh );
    my ($b) = grep { $_->{kind} eq 'type' } @{ $p->{blocked} };
    ok( $b, 'the type change is blocked' )
        or diag( 'SQLite would accept writes of the new shape into the old '
            . 'affinity and the rows would disagree with each other.' );
    like( $b->{why}, qr/rewrites the table/, 'and says what it would take' );
    is_deeply( $p->{additive}, [], 'nothing is applied for it' );
};

subtest 'a dropped field keeps its DATA, not just a mention' => sub {
    my $dbh = fresh_dbh('e');
    my $d1  = desc( keepme => { type => 'text' } );
    apply( $dbh, plan_migration( $d1, $dbh ) );
    my $row = coerce_row( $d1, { code => 'A1', keepme => 'precious' } );
    my ( $isql, $ibinds ) = insert_sql( $d1, $row->{values} );
    $dbh->do( $isql, undef, @{$ibinds} );

    my $p = plan_migration( desc(), $dbh );
    my ($b) = grep { $_->{kind} eq 'extra' } @{ $p->{blocked} };
    ok( $b && $b->{field} eq 'keepme', 'the removed column is reported' );
    like( $b->{why}, qr/left alone/, 'and says it is left alone' );

    # REPORTING IT AND NOT DOING IT ARE TWO DIFFERENT GUARANTEES, and asserting
    # only the first is what an earlier version of this file did - a sabotage
    # that ADDED a DROP COLUMN step alongside the existing report passed the
    # whole suite. The guarantee worth having is that the data survives.
    ok( !( grep { $_->{sql} =~ /DROP\s+COLUMN/i } @{ $p->{additive} } ),
        'and NO step drops it' )
        or diag( 'A plan that quietly discards a column holding data is the '
            . 'one mistake a migration must not make.' );

    apply( $dbh, $p );
    my $still = $dbh->selectall_arrayref( 'SELECT keepme FROM items',
        { Slice => {} } );
    is( $still->[0]{keepme}, 'precious',
        'after applying the plan, the value is still there' );
};

subtest 'blocked items do not freeze the safe ones' => sub {
    my $dbh = fresh_dbh('f');
    apply( $dbh, plan_migration( desc( n => { type => 'text' } ), $dbh ) );
    my $p = plan_migration(
        desc( n => { type => 'integer' }, extra => { type => 'text' } ), $dbh );
    ok( scalar @{ $p->{blocked} },  'the type change is still blocked' );
    ok( scalar @{ $p->{additive} }, 'and the new column is still offered' )
        or diag( 'All-or-nothing makes one awkward column freeze every other '
            . 'change, and the usual response to that is to edit the store '
            . 'by hand.' );
};

subtest 'a required field added to a populated table is reported, not forced' => sub {
    my $dbh = fresh_dbh('g');
    my $d1  = desc();
    apply( $dbh, plan_migration( $d1, $dbh ) );
    my $row = coerce_row( $d1, { code => 'A1' } );
    my ( $sql, $binds ) = insert_sql( $d1, $row->{values} );
    $dbh->do( $sql, undef, @{$binds} );

    my $p = plan_migration( desc( must => { type => 'text', required => 1 } ), $dbh );
    my ($b) = grep { $_->{kind} eq 'incomplete' } @{ $p->{blocked} };
    ok( $b, 'the operator is told the old rows have no value for it' )
        or diag( 'Otherwise they discover it from a report.' );
    ok( ( grep { $_->{sql} =~ /ADD COLUMN must/ } @{ $p->{additive} } ),
        'the column is still added - NULL is the honest record for rows '
            . 'written before it was asked for' );
    apply( $dbh, $p );
    pass('and applying it does not die');
};

done_testing();
