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

our @EXPORT_OK = qw(create_table_sql index_sql column_type dsn_for);

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
    return 'INTEGER' if $t eq 'boolean';    # normalised 0/1 on write
    return 'TEXT'    if $t eq 'decimal';    # NEVER REAL - see the header
    return 'TEXT'    if $t eq 'date';       # ISO 8601, validated before write
    return 'TEXT'    if $t eq 'datetime';   # ISO 8601 UTC
    return 'TEXT'    if $t eq 'enum';       # membership enforced before write
    return 'TEXT'    if $t eq 'text';
    die "no column type for '$t'";          # unreachable via a loaded descriptor
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

1;
