package Lazysite::Data::Owned;

# THE COLUMNS THE DATA EXTENSION OWNS, named once.
#
# WHAT THIS REPLACES. `created_at`, `updated_at`, `created_by` and `updated_by`
# are created by `timestamps: true`, stamped by the engine, refused from every
# writer, and skipped by every loop that walks a descriptor's declared fields.
# That set was written out FOURTEEN TIMES across seven modules - twice as a
# %RESERVED hash (Descriptor.pm, Value.pm), once as a qw() list to create
# (Schema.pm), once as a list of column definitions (SQLite.pm), once as export
# headers (Csv.pm), and nine times as the alternation
# /\A(?:created_at|updated_at|created_by|updated_by)\z/.
#
# Nothing had gone wrong yet. What makes it worth fixing NOW is that the set is
# about to grow: SM857's ruling adds a policy column that the engine owns in
# exactly the same way, and a set spelt in fourteen places grows by being spelt
# in fourteen more - which is SM578's rule ("a rule copied into two places is a
# rule that will disagree with itself") applied to a list instead of a rule. A
# column added to twelve of the fourteen would be created by the migration,
# refused from writers, and then treated as an undeclared extra by the loop that
# reports drift: present, protected, and reported as something to remove.
#
# TWO QUESTIONS, NOT ONE, and the difference is why this is a module rather
# than a constant:
#
#   RESERVED is unconditional. A descriptor may never declare a field of its
#   own called `created_at`, whether or not that table sets `timestamps` -
#   because the flag can be turned on afterwards, and a collision found then
#   is found against data already in the store.
#
#   OWNED is per-table. The columns actually present depend on the descriptor's
#   flags, and every loop that walks real columns has to ask about the table in
#   front of it. Asking the unconditional question there would skip a genuinely
#   undeclared `created_at` on a table with no timestamps - a column nothing
#   maintains and nothing reports.
#
# A LEAF, with no dependencies beyond strict/warnings/Exporter, so that
# Descriptor, Value, Schema, SQLite, Query, Csv and Tables can all reach it
# without a cycle. ADR 0001 is untouched: the processor's render path spells
# none of these names, so there is no twin copy to keep in step (unlike the ACL
# decision, which t/lint/36 pins).

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(stamp_columns reserved_column owned_columns is_owned
    stamped_column policy_column POLICIES valid_policy);

# The order is the order they are CREATED in, and the order they appear in a CSV
# export: when it was written out by hand, `created_at, updated_at, created_by,
# updated_by` was what every site said, so it stays the order.
my @STAMPS = qw(created_at updated_at created_by updated_by);

# SM857: the row's own disposition, created by `row_policy: true`. The engine
# owns the COLUMN and the writer owns the VALUE, which is the one place the two
# kinds of owned column differ - see stamped_column below.
my $POLICY = 'row_policy';

my %RESERVED = map { $_ => 1 } ( @STAMPS, $POLICY );
my %STAMPED  = map { $_ => 1 } @STAMPS;

# The policies a row may carry. ABSENT is a third state and means shared, in
# both directions: a row written before this existed carries no value, and a
# writer that names no policy creates a shared row. Absent is deliberately NOT
# spelt 'shared' in the store - see the ruling in SM857.
my @POLICIES = qw(personal shared);

sub policy_column { return $POLICY }
sub POLICIES      { return @POLICIES }

sub valid_policy {
    my ($p) = @_;
    return 0 unless defined $p;
    return ( grep { $_ eq $p } @POLICIES ) ? 1 : 0;
}

# The stamp columns, in creation order. A copy, never the list itself - a caller
# that sorts or splices the return value must not be able to reorder the store.
sub stamp_columns { return @STAMPS }

# May a descriptor declare a field with this name? Unconditional, per above.
sub reserved_column { return ( defined $_[0] && $RESERVED{ $_[0] } ) ? 1 : 0 }

# SM857: RESERVED AND STAMPED ARE NOT THE SAME SET, and the difference is the
# whole of the policy column's design.
#
# A stamped column is one the ENGINE writes and every writer is refused: that is
# what makes created_by the one field in a row a caller cannot forge, and what
# makes ownership testable at all.
#
# row_policy is owned by the engine and SET BY THE WRITER - "the time to set
# policy is at write, so whatever is creating the row gets to say the policy"
# (the ruling). So it is reserved from a DESCRIPTOR (no table may declare a field
# of that name) and permitted from a CALLER, unlike every other owned column.
# Refusing it from writers would leave nothing able to set it.
sub stamped_column { return ( defined $_[0] && $STAMPED{ $_[0] } ) ? 1 : 0 }

# The columns THIS table's flags give it. Empty for a table with no flags set,
# which is the honest answer rather than a special case.
sub owned_columns {
    my ($d) = @_;
    return () unless ref $d eq 'HASH';
    return ( $d->{timestamps} ? @STAMPS : (), $d->{row_policy} ? ($POLICY) : () );
}

# Does this table own this column? The per-table question, and the one every
# walk-the-real-columns loop is asking.
sub is_owned {
    my ( $d, $col ) = @_;
    return 0 unless defined $col;
    return ( grep { $_ eq $col } owned_columns($d) ) ? 1 : 0;
}

1;
