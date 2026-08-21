#!/usr/bin/perl
# SM447: the SQLite adapter - what it generates, and what it refuses to.
#
# THE DIVISION EVERYTHING RESTS ON:
#
#   VALUES are bound, always. No value is interpolated into SQL text - not in
#   a DDL default, not in DML, not in a WHERE clause. A value containing SQL
#   metacharacters is stored and returned verbatim because it never reaches
#   the parser as syntax.
#
#   IDENTIFIERS cannot be bound - SQL has no placeholder for a table or column
#   name - so they ARE interpolated, and the only reason that is safe is that
#   Descriptor.pm has already refused anything outside [a-z][a-z0-9_]*.
#
# So this file tests two different things and must not blur them: that the
# generated DDL is right, and that the generator DIES rather than emits when
# handed an identifier that did not come through validation. The second is the
# one that matters - a generator that quietly quotes bad input is a generator
# whose safety depends on remembering to call it correctly.
#
# It also pins the two type mappings that exist to prevent a specific bug
# rather than to satisfy SQLite.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Data::Descriptor qw(load_descriptor);
use Lazysite::Data::SQLite qw(create_table_sql index_sql column_type);

my $d = load_descriptor( 'tasks', {
        fields => {
            title    => { type => 'text', required => 1, max => 200 },
            done     => { type => 'boolean', default => 0 },
            due      => { type => 'date' },
            cost     => { type => 'decimal', digits => 10, places => 2 },
            rank     => { type => 'integer' },
            priority => { type => 'enum', values => [qw(low high)] },
        },
        indexes    => [ ['done'], [ 'priority', 'due' ] ],
        timestamps => 1,
} );
ok( $d->{ok}, 'fixture descriptor loads' ) or BAIL_OUT('bad fixture');

subtest 'money is never a float, and a boolean is never text' => sub {
    is( column_type( { type => 'decimal', digits => 10, places => 2 } ), 'TEXT',
        'decimal is TEXT, not REAL' )
        or diag( "SQLite's REAL is a double. Money in a double is precisely "
            . 'the bug the decimal type exists to prevent.' );
    is( column_type( { type => 'boolean' } ), 'INTEGER',
        'boolean is INTEGER 0/1, normalised on write' )
        or diag( 'Accepting true/false/1/0 into TEXT makes the round-trip '
            . 'depend on how it happened to be written.' );
    is( column_type( { type => 'integer' } ),  'INTEGER', 'integer' );
    is( column_type( { type => 'date' } ),     'TEXT',    'date is ISO text' );
    is( column_type( { type => 'datetime' } ), 'TEXT',    'datetime is ISO text' );
};

subtest 'the CREATE TABLE says what the descriptor says' => sub {
    my $sql = create_table_sql($d);
    # IDENTIFIERS ARE QUOTED. The module header used to claim the narrow
    # `[a-z][a-z0-9_]*` pattern meant a name needed no quoting in any dialect.
    # That is true of every CHARACTER and false of a class of WORDS - `table`,
    # `key`, `order` all match the pattern and are reserved - so the adapter
    # quotes, and these assertions say so rather than pinning the old claim.
    like( $sql, qr/CREATE TABLE IF NOT EXISTS "tasks"/, 'names the table' );
    like( $sql, qr/^\s*"?id"? INTEGER PRIMARY KEY/m, 'the automatic key' );
    like( $sql, qr/^\s*"title" TEXT NOT NULL/m, 'required means NOT NULL' );
    unlike( $sql, qr/^\s*"due" TEXT NOT NULL/m, 'and optional does not' );
    like( $sql, qr/^\s*created_at TEXT/m, 'timestamps: true adds the columns' );
    like( $sql, qr/^\s*updated_at TEXT/m, '...both of them' );
};

subtest 'NO VALUE APPEARS IN THE DDL, including defaults' => sub {
    # A default is applied by the validation layer when a write omits the
    # field, so one implementation decides it for every engine rather than
    # each engine's DDL dialect deciding it differently. It also keeps values
    # out of generated SQL text entirely, which is the invariant.
    my $sql = create_table_sql($d);
    unlike( $sql, qr/\bDEFAULT\b/i, 'no DEFAULT clause is emitted' )
        or diag( 'A default in the DDL is a VALUE in generated SQL text, and '
            . 'the whole point is that values only ever arrive bound.' );
};

subtest 'a natural key is NOT NULL and the primary key' => sub {
    my $n = load_descriptor( 'pages', {
            key    => 'slug',
            fields => { slug => { type => 'text' }, body => { type => 'text' } },
    } );
    my $sql = create_table_sql($n);
    like( $sql, qr/^\s*"slug" TEXT NOT NULL/m, 'the key cannot be null' )
        or diag( 'A nullable primary key is a table with rows nothing can '
            . 'address.' );
    like( $sql, qr/PRIMARY KEY \("slug"\)/, 'and is declared as the key' );
    unlike( $sql, qr/id INTEGER PRIMARY KEY/, 'with no automatic id beside it' );
};

subtest 'indexes are derived, never carried' => sub {
    my @ix = index_sql($d);
    is( scalar @ix, 2, 'one per declared index' );
    like( $ix[0], qr/CREATE INDEX IF NOT EXISTS "ix_tasks_done" ON "tasks" \("done"\)/,
        'name derived from table and columns' )
        or diag( 'An index name taken from anywhere else is another string '
            . 'reaching SQL without having been validated.' );
    like( $ix[1], qr/"ix_tasks_priority_due" ON "tasks" \("priority", "due"\)/,
        'multi-column too' );
};

subtest 'the generator DIES on an identifier that did not pass validation'
    => sub {
    # This is the assertion that matters. A generator which quietly quoted bad
    # input would be one whose safety depended on every caller remembering to
    # validate first - and the callers are the part most likely to change.
    my $forged = {
        ok       => 1,
        table    => 'tasks; DROP TABLE users; --',
        key      => 'id',
        auto_key => 1,
        fields   => { title => { type => 'text' } },
        indexes  => [],
    };
    eval { create_table_sql($forged); 1 };
    like( $@, qr/unvalidated identifier/, 'a forged table name dies' )
        or diag( 'It must not emit a statement it cannot vouch for.' );

    my $forged_col = {
        ok       => 1,
        table    => 'tasks',
        key      => 'id',
        auto_key => 1,
        fields   => { 'x") --' => { type => 'text' } },
        indexes  => [],
    };
    eval { create_table_sql($forged_col); 1 };
    like( $@, qr/unvalidated identifier/, 'a forged column name dies' );

    my $forged_ix = {
        ok       => 1,
        table    => 'tasks',
        key      => 'id',
        auto_key => 1,
        fields   => { title => { type => 'text' } },
        indexes  => [ ['title); DROP TABLE x; --'] ],
    };
    eval { index_sql($forged_ix); 1 };
    like( $@, qr/unvalidated identifier/, 'and so does a forged index column' );
};

subtest 'a RESERVED WORD is a legal column name' => sub {
    # THE DEFECT THIS CATCHES, found by an integration test written to prove
    # something else. The module header used to argue that the narrow
    # `[a-z][a-z0-9_]*` pattern meant a name needed no quoting "in any dialect
    # we generate for". That is true of every CHARACTER and false of a whole
    # class of WORDS: `table`, `key`, `order`, `group`, `index`, `from` all
    # match the pattern and are reserved.
    #
    # `CREATE TABLE seating (table TEXT)` is a syntax error, and the column was
    # an ordinary one - a seating plan has tables, a parts list has keys, a
    # menu has orders. The author would have got a raw SQL parse error naming
    # their own column, with nothing to tell them the name was the problem.
    #
    # NOT A SECURITY HOLE: the value was still bound and the identifier still
    # restricted to safe characters. A correctness hole, which is why it
    # survived every test that was looking for injection.
    my $r = load_descriptor( 'seating', {
            key    => 'ref',
            fields => {
                ref   => { type => 'text' },
                table => { type => 'text' },
                key   => { type => 'text' },
                order => { type => 'integer' },
            },
    } );
    ok( $r->{ok}, 'the loader accepts them - they are legal names' )
        or diag( 'Refusing them would forbid ordinary column names forever, '
            . 'and the reserved list differs by engine, so the refusal would '
            . 'have to be SQLite\'s list carried into engine-neutral code.' );

    my $sql = create_table_sql($r);
    like( $sql, qr/"table" TEXT/, 'and the generator quotes them' );
    like( $sql, qr/"order" INTEGER/, '...each of them' );

  SKIP: {
        skip 'DBD::SQLite not available', 1
            unless eval { require DBI; require DBD::SQLite; 1 };
        my $dbh = DBI->connect( 'dbi:SQLite:dbname=:memory:', '', '',
            { RaiseError => 1, PrintError => 0 } );
        ok( eval { $dbh->do($sql); 1 }, 'and the engine accepts the statement' )
            or diag( "the DDL was refused: $@" );
    }
};

subtest 'and the loader refuses those names long before the generator sees them'
    => sub {
    # Belt and braces, in that order: the generator dying is the backstop, the
    # loader refusing is the design.
    ok( !load_descriptor( 'tasks; DROP TABLE users; --', { fields => { a => { type => 'text' } } } )->{ok},
        'the loader refuses the forged table name' );
    ok( !load_descriptor( 'tasks', { fields => { 'x") --' => { type => 'text' } } } )->{ok},
        'and the forged column name' );
};

done_testing();
