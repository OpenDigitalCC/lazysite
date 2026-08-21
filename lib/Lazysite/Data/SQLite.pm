package Lazysite::Data::SQLite;

# SM447: the SQLite adapter - DDL generation and typed column mapping.
#
# Tier zero and the default: a single file at lazysite/db/data.sqlite, no
# provisioning, and a store that is trivial to back up because it is one file.
#
# THE DIVISION THIS FILE RESTS ON, and the reason it can interpolate at all:
#
#   VALUES are bound. Always, without exception, everywhere. No value is ever
#   interpolated into SQL text - not in DDL defaults, not in DML, not in a
#   WHERE clause. A value containing SQL metacharacters is stored and returned
#   verbatim because it never reaches the parser as syntax.
#
#   IDENTIFIERS cannot be bound. SQL has no placeholder for a table or column
#   name, so they must be interpolated - and the only reason that is safe is
#   that Descriptor.pm has already refused anything outside [a-z][a-z0-9_]*.
#   That check runs once at load; this file is entitled to assume it, and
#   _ident() below re-asserts it anyway, because an assumption that is free to
#   check is not worth carrying.
#
# Types map to SQLite's affinities, with two deliberate refusals to be clever:
#
#   decimal  -> TEXT, not REAL. SQLite's REAL is a double, and money in a
#              double is the bug the type exists to prevent. Stored as a
#              canonical decimal string; the caller does the arithmetic in
#              something that can hold it.
#   boolean  -> INTEGER 0/1, normalised on write. SQLite has no boolean, and
#              accepting 'true'/'false'/1/0 into a TEXT column would make the
#              round-trip depend on how it was written.
#
# No CREATE ... AS SELECT, no dynamic table names from user input, no string
# concatenation of clauses from anything but a validated descriptor.

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(create_table_sql index_sql column_type dsn_for
    insert_sql update_sql delete_sql select_sql
    observed_schema add_column_sql backfill_sql table_has_rows);

# Re-assert the identifier rule at the point of interpolation.
#
# Descriptor.pm already guarantees this and nothing should reach here without
# passing through it. The check stays because it costs nothing, and because a
# future caller that forgets the guarantee gets a die() rather than a
# generated statement - which is the correct direction to fail in.
sub _ident {
    my ($n) = @_;
    die "refusing to build SQL with an unvalidated identifier: '"
        . ( defined $n ? $n : '(undef)' ) . "'"
        unless defined $n && $n =~ /\A[a-z][a-z0-9_]*\z/;
    return $n;
}

# The column type for a field descriptor, as SQLite should hold it.
sub column_type {
    my ($spec) = @_;
    my $t = ref $spec eq 'HASH' ? ( $spec->{type} // '' ) : '';
    return 'INTEGER' if $t eq 'integer';
    return 'INTEGER' if $t eq 'boolean';     # normalised 0/1 on write
    return 'TEXT'    if $t eq 'decimal';     # NEVER REAL - see the header
    return 'TEXT'    if $t eq 'date';        # ISO 8601, validated before write
    return 'TEXT'    if $t eq 'datetime';    # ISO 8601 UTC
    return 'TEXT'    if $t eq 'enum';        # membership enforced before write
    return 'TEXT'    if $t eq 'text';
    die "no column type for '$t'";           # unreachable via a loaded descriptor
}

# CREATE TABLE for a loaded descriptor. Returns the statement text.
#
# NOT NULL is emitted for required fields and for the key. DEFAULTS ARE NOT
# EMITTED INTO THE DDL: a default is a validation-layer concept here, applied
# when a write omits the field, so that one implementation decides it for every
# engine rather than each engine's DDL dialect deciding it differently. It also
# keeps values out of generated SQL text entirely, which is the invariant above.
sub create_table_sql {
    my ($d) = @_;
    die 'create_table_sql needs a loaded descriptor' unless ref $d eq 'HASH' && $d->{ok};

    my $table = _ident( $d->{table} );
    my @cols;

    if ( $d->{auto_key} ) {
        # SQLite gives INTEGER PRIMARY KEY rowid semantics, which is what an
        # auto key wants; AUTOINCREMENT is deliberately omitted - it adds a
        # monotonicity guarantee nothing here needs and a table to maintain.
        push @cols, '  id INTEGER PRIMARY KEY';
    }

    my $fields = $d->{fields};
    for my $f ( sort keys %{$fields} ) {
        my $spec = $fields->{$f};
        my $col  = '  ' . _ident($f) . ' ' . column_type($spec);
        $col .= ' NOT NULL'
            if $spec->{required} || ( !$d->{auto_key} && $f eq $d->{key} );
        push @cols, $col;
    }

    if ( !$d->{auto_key} ) {
        push @cols, '  PRIMARY KEY (' . _ident( $d->{key} ) . ')';
    }

    if ( $d->{timestamps} ) {
        # Maintained by the plugin, which is why a descriptor declaring them
        # is refused at load.
        push @cols, '  created_at TEXT', '  updated_at TEXT';
    }

    return "CREATE TABLE IF NOT EXISTS $table (\n" . join( ",\n", @cols ) . "\n)";
}

# CREATE INDEX statements for a loaded descriptor.
#
# The index name is derived from the table and its columns rather than taken
# from anywhere, so it cannot carry anything that was not already validated.
sub index_sql {
    my ($d) = @_;
    die 'index_sql needs a loaded descriptor' unless ref $d eq 'HASH' && $d->{ok};
    my $table = _ident( $d->{table} );
    my @out;
    for my $ix ( @{ $d->{indexes} || [] } ) {
        my @cols = map { _ident($_) } @{$ix};
        my $name = join '_', 'ix', $table, @cols;
        push @out,
            "CREATE INDEX IF NOT EXISTS " . _ident($name) . " ON $table ("
            . join( ', ', @cols ) . ')';
    }
    return @out;
}

# The DSN for a docroot's store. One file, so a backup is a copy.
sub dsn_for {
    my ($docroot) = @_;
    return "dbi:SQLite:dbname=$docroot/lazysite/db/data.sqlite";
}

# --- DML -------------------------------------------------------------------
#
# EVERY GENERATOR RETURNS ( $sql, \@binds ), never a finished statement, and
# that shape is the invariant made structural rather than promised. There is no
# way to call these and get a string with a value in it - the value has nowhere
# to go except the bind list, so a caller cannot interpolate one by mistake and
# a reviewer does not have to read the body to know that.
#
# The column ORDER is sorted, not hash order, everywhere. Two callers building
# the same statement must produce the same text, or the statement cache is a
# cache of one and a test comparing generated SQL becomes flaky in a way that
# looks like a real difference.
#
# WHAT THESE DO NOT DO: they do not validate. Value.pm has already coerced and
# refused; passing raw input here would generate a statement that binds
# whatever it was given. Callers go through Value::coerce_row first, and the
# tests assert the pairing rather than leaving it to habit.

sub _cols_and_binds {
    my ($values) = @_;
    my @cols = sort keys %{$values};
    return ( \@cols, [ map { $values->{$_} } @cols ] );
}

# INSERT for one coerced row.
#
# Timestamps are supplied by the CALLER when the descriptor declares them,
# rather than generated here with an SQL function: CURRENT_TIMESTAMP has a
# different spelling and a different format in each engine, and the whole point
# of the value layer is that one implementation decides what a datetime looks
# like. Passing them in also keeps the generator free of anything that is not
# a bind.
sub insert_sql {
    my ( $d, $values ) = @_;
    die 'insert_sql needs a loaded descriptor' unless ref $d eq 'HASH'      && $d->{ok};
    die 'insert_sql needs values'              unless ref $values eq 'HASH' && %{$values};

    my ( $cols, $binds ) = _cols_and_binds($values);
    my $table = _ident( $d->{table} );
    my $names = join ', ', map { _ident($_) } @{$cols};
    my $marks = join ', ', ('?') x scalar @{$cols};
    return ( "INSERT INTO $table ($names) VALUES ($marks)", $binds );
}

# UPDATE one row, identified by its key.
#
# The key is BOUND like any other value even though it identifies the row; it
# is data, and the only thing interpolated is its column name. An update with
# no WHERE is not reachable from here: the key is required and refused if
# absent, because a generator that can emit an unbounded UPDATE will eventually
# emit one.
sub update_sql {
    my ( $d, $key_value, $values ) = @_;
    die 'update_sql needs a loaded descriptor' unless ref $d eq 'HASH'      && $d->{ok};
    die 'update_sql needs values'              unless ref $values eq 'HASH' && %{$values};
    die 'update_sql needs a key value'
        unless defined $key_value && length $key_value;

    my $key = $d->{key};
    my %set = %{$values};
    # The key is not settable through an update. Changing it would move the
    # row's identity while the WHERE clause still names the old one, so the
    # statement would either match nothing or rename something silently.
    delete $set{$key};
    die 'update_sql needs at least one field to set' unless %set;

    my ( $cols, $binds ) = _cols_and_binds( \%set );
    my $table  = _ident( $d->{table} );
    my $assign = join ', ', map { _ident($_) . ' = ?' } @{$cols};
    push @{$binds}, $key_value;
    return ( "UPDATE $table SET $assign WHERE " . _ident($key) . ' = ?', $binds );
}

# DELETE one row, identified by its key. Same reasoning as update: no
# unbounded form exists.
sub delete_sql {
    my ( $d, $key_value ) = @_;
    die 'delete_sql needs a loaded descriptor' unless ref $d eq 'HASH' && $d->{ok};
    die 'delete_sql needs a key value'
        unless defined $key_value && length $key_value;
    my $table = _ident( $d->{table} );
    return ( "DELETE FROM $table WHERE " . _ident( $d->{key} ) . ' = ?',
        [$key_value] );
}

# SELECT, with the shape a page binding needs: equality filters, ordering by a
# declared field, and a bounded row count.
#
# ORDER BY TAKES A FIELD NAME, NOT AN EXPRESSION, and the name must be one the
# descriptor declares. `_ident` alone would accept any lower-case word, which
# is safe to interpolate and still wrong - it would name a column that does not
# exist and the query would die at the engine rather than being refused with a
# reason. Membership is the check that produces a usable message.
#
# LIMIT IS BOUND rather than interpolated, and always present. An unbounded
# select against a table an agent has been filling is how a page renders for a
# minute; the caller may raise the ceiling but cannot remove it.
sub select_sql {
    my ( $d, %opt ) = @_;
    die 'select_sql needs a loaded descriptor' unless ref $d eq 'HASH' && $d->{ok};
    my $table  = _ident( $d->{table} );
    my $fields = $d->{fields};

    my @where;
    my @binds;
    my $filter = $opt{where} || {};
    for my $f ( sort keys %{$filter} ) {
        die "select_sql: '$f' is not a field of '$d->{table}'"
            unless exists $fields->{$f} || $f eq $d->{key};
        if ( defined $filter->{$f} ) {
            push @where, _ident($f) . ' = ?';
            push @binds, $filter->{$f};
        }
        else {
            # IS NULL, not `= ?` with undef: in SQL, NULL = NULL is not true,
            # so binding undef would silently match no rows and read as "there
            # are none" rather than "that is not how you ask".
            push @where, _ident($f) . ' IS NULL';
        }
    }

    my $sql = "SELECT * FROM $table";
    $sql .= ' WHERE ' . join( ' AND ', @where ) if @where;

    if ( defined $opt{order_by} && length $opt{order_by} ) {
        my $ob = $opt{order_by};
        die "select_sql: cannot order by '$ob' - not a field of '$d->{table}'"
            unless exists $fields->{$ob}
            || $ob eq $d->{key}
            || ( $d->{timestamps} && $ob =~ /\A(?:created_at|updated_at)\z/ );
        my $dir = ( $opt{order} // 'asc' ) =~ /\Adesc\z/i ? 'DESC' : 'ASC';
        $sql .= ' ORDER BY ' . _ident($ob) . " $dir";
    }

    my $limit = $opt{limit};
    $limit = 200 unless defined $limit && $limit =~ /\A\d+\z/ && $limit > 0;
    $limit = 1000 if $limit > 1000;
    $sql .= ' LIMIT ?';
    push @binds, $limit;

    if ( defined $opt{offset} && $opt{offset} =~ /\A\d+\z/ && $opt{offset} > 0 ) {
        $sql .= ' OFFSET ?';
        push @binds, $opt{offset};
    }

    return ( $sql, \@binds );
}

# --- introspection ---------------------------------------------------------
#
# THE DATABASE IS THE SCHEMA STATE. There is no state file, deliberately - see
# Lazysite::Data::Schema for the reasoning. This is the engine-specific half of
# that: PRAGMA is SQLite's dialect, and dialect belongs in the adapter.
sub observed_schema {
    my ( $dbh, $table ) = @_;
    my $t = _ident($table);

    # PRAGMA takes an identifier, not a bind, which is why _ident guards it -
    # the same rule as everywhere else in this file.
    my $cols = $dbh->selectall_arrayref( "PRAGMA table_info($t)", { Slice => {} } );
    return { exists => 0, columns => {}, indexes => {} } unless @{$cols};

    my %columns;
    for my $c ( @{$cols} ) {
        $columns{ $c->{name} } = {
            # SQLite reports the declared type verbatim, which is what we
            # generated, so comparing it to column_type() compares like with
            # like. Upper-cased because a hand-created table may differ in
            # case and that is not a schema difference.
            type    => uc( $c->{type} // '' ),
            notnull => ( $c->{notnull} ? 1 : 0 ),
            pk      => ( $c->{pk}      ? 1 : 0 ),
        };
    }

    my %indexes;
    for my $ix ( @{ $dbh->selectall_arrayref( "PRAGMA index_list($t)", { Slice => {} } ) } ) {
        # origin 'c' means CREATE INDEX - ours. 'pk' and 'u' are constraint
        # indexes the engine maintains, and reporting them as ours would make
        # every plan want to drop something it did not create.
        next unless ( $ix->{origin} // '' ) eq 'c';
        my $n    = $ix->{name};
        my $info = $dbh->selectall_arrayref(
            'PRAGMA index_info(' . _ident($n) . ')', { Slice => {} } );
        $indexes{$n} = [ map { $_->{name} } sort { $a->{seqno} <=> $b->{seqno} } @{$info} ];
    }

    return { exists => 1, columns => \%columns, indexes => \%indexes };
}

# Does this table hold anything? The answer changes what a migration MAY do,
# so it is measured rather than assumed.
sub table_has_rows {
    my ( $dbh, $table ) = @_;
    my $t = _ident($table);
    my ($n) = $dbh->selectrow_array("SELECT EXISTS (SELECT 1 FROM $t LIMIT 1)");
    return $n ? 1 : 0;
}

# ADD COLUMN, and it is NEVER `NOT NULL` and NEVER carries a DEFAULT.
#
# Both restrictions are forced, and measured rather than assumed:
#
#   * `ADD COLUMN ... NOT NULL` without a default is REFUSED by SQLite once the
#     table holds rows ("Cannot add a NOT NULL column with default value
#     NULL"). It succeeds on an empty table, which is worse than failing - the
#     same migration would behave differently depending on whether anyone had
#     used the site yet.
#   * `DEFAULT ?` is a SYNTAX ERROR. A DDL default cannot be bound, so emitting
#     one means interpolating a value into SQL text, which is the one thing
#     this file does not do.
#
# So a new required field is applied as a NULLABLE column plus a BOUND backfill
# (see backfill_sql), and its required-ness is enforced where every other rule
# is enforced - in Value.pm, on write. That is not a workaround: it is the
# existing decision that validation does not live in DDL, arriving at the same
# answer from the other direction.
sub add_column_sql {
    my ( $d, $field ) = @_;
    die 'add_column_sql needs a loaded descriptor' unless ref $d eq 'HASH' && $d->{ok};
    my $spec = $d->{fields}{$field} or die "add_column_sql: no field '$field'";
    return 'ALTER TABLE ' . _ident( $d->{table} ) . ' ADD COLUMN '
        . _ident($field) . ' ' . column_type($spec);
}

# Fill a freshly added column in the rows that predate it. Bound, like every
# other value. Scoped to IS NULL so re-running it cannot overwrite a value
# somebody has since set - a migration that is not safe to repeat is a
# migration that fails badly the one time it is interrupted.
sub backfill_sql {
    my ( $d, $field, $value ) = @_;
    die 'backfill_sql needs a loaded descriptor' unless ref $d eq 'HASH' && $d->{ok};
    die "backfill_sql: no field '$field'"        unless exists $d->{fields}{$field};
    return ( 'UPDATE ' . _ident( $d->{table} ) . ' SET ' . _ident($field)
            . ' = ? WHERE ' . _ident($field) . ' IS NULL',
        [$value] );
}

1;
