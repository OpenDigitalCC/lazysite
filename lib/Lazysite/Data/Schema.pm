package Lazysite::Data::Schema;

# SM447: what the store HAS versus what the descriptor DECLARES, and what may
# safely be done about the difference.
#
# NO SCHEMA-STATE FILE. THIS IS A DELIBERATE DEPARTURE FROM THE SM410 MAP,
# which listed "schema-state via the SM404 checked writer", and it is flagged
# here rather than buried because the plan is the release manager's.
#
# The reasoning: a state file is a THIRD copy of the truth, after the
# descriptor (what is wanted) and the database (what exists). Three copies of
# one fact is the defect this programme has met repeatedly - a control
# reporting a conclusion it did not measure - and here the failure is concrete
# rather than theoretical:
#
#   * DP-6 restores rows into a FRESH database, possibly on another engine. A
#     state file describing the old one arrives describing something that is
#     not there.
#   * Restoring `data.sqlite` alone, or restoring the state file alone, leaves
#     two files disagreeing with no way to tell which is right.
#   * A hand-edited store is then described by a stale note rather than by
#     itself.
#
# Deriving it costs one PRAGMA and cannot desync, because the actual state IS
# the database. What a state file would have added - WHEN a migration ran and
# WHO ran it - is audit-trail material and belongs in the audit trail, which
# already exists and is already read for exactly that question.
#
# SM404's checked writer is therefore not needed for this. It remains the right
# tool for anything that does write a file.
#
# CONFIRMED BY THE RELEASE MANAGER, 2026-08-21, with one thing carried forward:
# derivation is a perfect account of NOW and no account at all of BEFORE. It
# cannot say what the shape was last week, when a column appeared, or who
# applied the migration. Nobody has asked for that yet and it becomes a real
# question the first time a migration is blamed for something. SM468 records
# it, and records that the answer - if it is ever wanted - is a TABLE IN THE
# STORE and not a file beside it: a table travels with the rows it describes
# through backup and through the DP-6 export, because it IS rows.
#
# ADDITIVE MEANS ADDITIVE. A plan either applies without touching data that is
# already there, or it is not applied at all and says why. SQLite can rewrite a
# table to change a column's type, and doing that silently on a store somebody
# is relying on is exactly the operation that deserves the confirmation flow
# DP-5 builds. So this module REFUSES those and names them; it does not perform
# them behind a flag.

use strict;
use warnings;
use Exporter qw(import);
use Lazysite::Data::SQLite
    qw(create_table_sql index_sql column_type add_column_sql backfill_sql
    unique_index_sql unique_index_name duplicate_value_sql
    null_count_sql column_values_sql
    observed_schema table_has_rows);
use Lazysite::Data::Value qw(coerce_field);

our @EXPORT_OK = qw(plan_migration plan_rebuild);

# Index names are DERIVED from the table and its columns, exactly as
# index_sql() derives them, so the two agree by construction rather than by a
# convention somebody has to remember.
sub _index_name {
    my ( $table, @cols ) = @_;
    return join '_', 'ix', $table, @cols;
}

# What has to happen to make the store match the descriptor.
#
# Returns:
#   ok        1
#   create    [ sql, ... ]              the table does not exist yet
#   additive  [ { sql, binds, why }, ]  safe on a populated table
#   blocked   [ { field, why }, ... ]   needs the DP-5 destructive flow
#
# `blocked` being non-empty does NOT invalidate the additive list: an operator
# can apply what is safe now and decide about the rest. Returning all-or-
# nothing would make one awkward column freeze every other change, and the
# usual response to that is to edit the store by hand.
# THE DUPLICATE PROBE BOTH PLANNERS RUN (DA-14): the first value that appears
# in more than one row, or undef. eval'd because the column may not exist yet -
# the probe is asked BEFORE the migration that would create it.
sub _first_duplicate {
    my ( $dbh, $d, $f ) = @_;
    return eval {
        my $row = $dbh->selectrow_arrayref( duplicate_value_sql( $d, $f ) );
        $row ? $row->[0] : undef;
    };
}

sub plan_migration {
    my ( $d, $dbh ) = @_;
    return { ok => 0, error => 'a loaded descriptor is required' }
        unless ref $d eq 'HASH' && $d->{ok};

    my $observed = observed_schema( $dbh, $d->{table} );

    if ( !$observed->{exists} ) {
        return {
            ok       => 1,
            create   => [ create_table_sql($d), index_sql($d) ],
            additive => [],
            blocked  => [],
        };
    }

    my $has_rows = table_has_rows( $dbh, $d->{table} );
    my ( @additive, @blocked );

    my $fields = $d->{fields};
    for my $f ( sort keys %{$fields} ) {
        my $spec = $fields->{$f};
        my $want = column_type($spec);
        my $have = $observed->{columns}{$f};

        if ( !$have ) {
            push @additive,
                { sql => add_column_sql( $d, $f ), binds => [],
                why => "add '$f'" };

            # A default is applied to the rows that predate the column, by a
            # BOUND update - never a DDL default, which cannot be bound. It
            # goes through the same coercion as any other write, because a
            # descriptor default is author-written text with no more claim to
            # being well-formed than a form field.
            if ( defined $spec->{default} ) {
                my ( $why, $value ) = coerce_field( $f, $spec, $spec->{default} );
                if ( defined $why ) {
                    push @blocked, { field => $f, why => "default for $why" };
                }
                elsif ($has_rows) {
                    my ( $sql, $binds ) = backfill_sql( $d, $f, $value );
                    push @additive,
                        { sql => $sql, binds => $binds,
                        why => "fill '$f' in rows that predate it" };
                }
            }
            elsif ( $spec->{required} && $has_rows ) {
                # Not blocked - the column is added and every EXISTING row is
                # left NULL, which is the honest record of "this was not asked
                # for when that row was written". Writes from here on are
                # refused without it by Value.pm. Reported so the operator
                # knows the old rows are incomplete rather than discovering it
                # from a report.
                push @blocked,
                    { field => $f, kind => 'incomplete',
                    why => "'$f' is required and existing rows have no value "
                        . 'for it; they stay NULL until edited, and new '
                        . 'writes must supply it' };
            }
            next;
        }

        # A TYPE CHANGE IS NOT ADDITIVE. SQLite would accept writes of the new
        # shape into the old affinity and the rows would disagree with each
        # other, which is worse than refusing.
        if ( $have->{type} ne $want ) {
            push @blocked,
                { field => $f, kind => 'type',
                why => "'$f' is $have->{type} in the store and $want in the "
                    . 'descriptor; changing it rewrites the table' };
            next;
        }

        # Adding NOT NULL to an existing column needs a table rebuild too, and
        # required-ness is enforced on write regardless, so this is reported
        # rather than attempted.
        if ( $spec->{required} && !$have->{notnull} && $f ne $d->{key} ) {
            push @blocked,
                { field => $f, kind => 'constraint',
                why => "'$f' became required; the column stays nullable "
                    . '(enforced on write), and tightening it rewrites the table' };
        }
    }

    # A column in the store that the descriptor no longer declares. NEVER
    # dropped here: the column holds data, and a plan that quietly discards it
    # is the one mistake a migration must not make.
    for my $c ( sort keys %{ $observed->{columns} } ) {
        next if exists $fields->{$c};
        next if $c eq $d->{key};
        next if $d->{timestamps} && $c =~ /\A(?:created_at|updated_at)\z/;
        next if $d->{auto_key}   && $c eq 'id';
        push @blocked,
            { field => $c, kind => 'extra',
            why => "'$c' is in the store and not in the descriptor; it still "
                . 'holds data and is left alone' };
    }

    # Missing indexes ARE additive - an index holds no data of its own.
    my @index_sql = index_sql($d);
    my $i         = 0;
    for my $ix ( @{ $d->{indexes} || [] } ) {
        my $name = _index_name( $d->{table}, @{$ix} );
        push @additive, { sql => $index_sql[$i], binds => [], why => "index $name" }
            unless $observed->{indexes}{$name};
        $i++;
    }

    # F-5: A UNIQUE INDEX IS ONLY ADDITIVE IF THE DATA ALREADY AGREES.
    #
    # A plain index holds no data of its own and always applies. A UNIQUE one
    # asserts something about every row already stored, so on a table with
    # duplicates the DDL fails - and a migration that stops half way with a raw
    # engine message about a constraint is what D5 exists to prevent. So it is
    # CHECKED and REPORTED, naming the value that blocks it, and the operator
    # fixes the data before migrating again.
    # The generator returns one statement per unique field, in the descriptor's
    # own order, so position pairs them - the same arrangement the plain-index
    # loop above uses.
    my @unique_sql = unique_index_sql($d);
    my $u          = -1;
    for my $f ( @{ $d->{unique} || [] } ) {
        $u++;
        my $name = unique_index_name( $d->{table}, $f );
        next if $observed->{indexes}{$name};

        if ($has_rows) {
            my $dup = _first_duplicate( $dbh, $d, $f );
            if ( defined $dup ) {
                push @blocked,
                    { field => $f,
                    why => "'$f' cannot be made unique: the value '$dup' "
                        . 'is in more than one row already. Make the '
                        . 'existing values distinct, then migrate again' };
                next;
            }
        }

        push @additive,
            { sql => $unique_sql[$u], binds => [], why => "unique index $name" }
            if defined $unique_sql[$u];
    }

    # An index the descriptor no longer asks for is left in place and not
    # reported as a problem: it costs a little space, it loses nothing, and
    # dropping it is not this function's decision to make.

    return { ok => 1, create => [], additive => \@additive, blocked => \@blocked };
}

# DP-5: the steps that make a BLOCKED change happen.
#
# plan_migration refuses a type change, a tightening to NOT NULL, and a dropped
# column, and reports each. That is right as a default and wrong as a permanent
# state: a refusal with no path through is a dead end, and an operator meeting
# one edits the store by hand - which is the outcome the refusal was protecting
# them from.
#
# SQLITE CANNOT ALTER A COLUMN, so every one of these is the same operation:
# build a new table with the wanted shape, copy what carries over, drop the old
# one, rename. That is a rewrite of the whole table, which is exactly why it is
# not something a migration does because a descriptor changed.
#
# WHAT IS COPIED AND WHAT IS NOT. Columns present in BOTH shapes carry over.
# A column the descriptor no longer declares does not, and its data is gone -
# which is the whole reason confirming names the columns rather than saying
# "yes". A new column arrives empty, or filled by the additive pass afterwards.
sub plan_rebuild {
    my ( $d, $dbh ) = @_;
    return { ok => 0, error => 'a loaded descriptor is required' }
        unless ref $d eq 'HASH' && $d->{ok};

    my $observed = observed_schema( $dbh, $d->{table} );
    return { ok => 0, error => "table '$d->{table}' does not exist" }
        unless $observed->{exists};

    my $table = $d->{table};
    my $tmp   = "${table}__rebuild";

    # The columns the new table will have, and which of them exist now.
    my @want = sort keys %{ $d->{fields} };
    push @want, 'created_at', 'updated_at' if $d->{timestamps};
    my @carry = grep { $observed->{columns}{$_} } @want;

    my @lost = sort grep {
        !$d->{fields}{$_}
            && $_ ne $d->{key}
            && !( $d->{auto_key}   && $_ eq 'id' )
            && !( $d->{timestamps} && /\A(?:created_at|updated_at)\z/ )
    } keys %{ $observed->{columns} };

    # The new table is built under a temporary name, so a failure part-way
    # leaves the original standing. The rename is the only moment the table is
    # not there, and it is atomic.
    # Rename the QUOTED identifier only. A bare substitution would also hit the
    # table's name wherever it appeared as part of something else - an index
    # name, a column that happens to share the word - and the adapter quotes
    # every identifier, so the quoted form is both precise and complete.
    my $create = create_table_sql($d);
    $create =~ s/"\Q$table\E"/"$tmp"/;

    my $cols  = join ', ', map { qq{"$_"} } @carry;
    my @steps = (
        { sql => $create, why => "build $tmp with the new shape" },
        ( @carry
            ? { sql => qq{INSERT INTO "$tmp" ($cols) SELECT $cols FROM "$table"},
                why => 'copy the columns both shapes have' }
            : ()
        ),
        { sql => qq{DROP TABLE "$table"}, why => "drop the old $table" },
        { sql => qq{ALTER TABLE "$tmp" RENAME TO "$table"}, why => "rename $tmp into place" },
    );

    # SM487: THE PRE-FLIGHT CHECKS THE DATA, NOT JUST THE COLUMNS.
    #
    # This used to report only @lost - the columns that would be dropped - and
    # the field agent watched it name the wrong risk: the prompt warned about
    # losing `note`, they confirmed `note`, and the rebuild FAILED on a null
    # `when` that the new descriptor had made required. The copy is one INSERT
    # ... SELECT; the first row that cannot satisfy a tightened constraint
    # fails the whole statement, and the error named an internal table and no
    # row. A confirmation that names a risk which is not the one that will
    # bite trains an operator to confirm without reading.
    #
    # So for every carried column, ask what the EXISTING rows would do against
    # the NEW constraint, and report it with a count - "2 rows have no `when`"
    # is the useful sentence. Three ways a carried column can refuse:
    #
    #   required   rows where it is NULL
    #   unique     a value already in more than one row
    #   narrowed   a stored value the new type will not coerce - which only
    #              Value.pm can judge, so the distinct values come out and go
    #              through coerce_field one at a time
    my @blocked;
    for my $f (@carry) {
        my $spec = $d->{fields}{$f} or next;    # timestamps carry no spec
        my $have = $observed->{columns}{$f};

        if ( $spec->{required} && !$have->{notnull} ) {
            my ($n) = eval { $dbh->selectrow_array( null_count_sql( $d, $f ) ) };
            push @blocked, { field => $f, rule => 'required', rows => 0 + ( $n // 0 ),
                why => "$n row" . ( $n == 1 ? ' has' : 's have' )
                    . " no '$f', and the new descriptor makes it required. "
                    . 'Fill them in, or leave the field optional' }
                if $n;
        }

        if ( grep { $_ eq $f } @{ $d->{unique} || [] } ) {
            my $dup = _first_duplicate( $dbh, $d, $f );
            push @blocked, { field => $f, rule => 'unique',
                why => "'$f' cannot be made unique: the value '$dup' is in "
                    . 'more than one row already' }
                if defined $dup;
        }

        my $want_type = column_type($spec);
        if ( uc( $have->{type} // '' ) ne uc($want_type) ) {
            my $vals = eval { $dbh->selectcol_arrayref( column_values_sql( $d, $f ) ) } || [];
            my @bad;
            for my $v ( @{$vals} ) {
                my ($why) = coerce_field( $f, $spec, $v );
                push @bad, $v if defined $why;
                last if @bad >= 3;
            }
            push @blocked, { field => $f, rule => 'type', examples => \@bad,
                why => "'$f' is becoming $spec->{type}, and stored values "
                    . 'will not convert: ' . join( ', ', map { "'$_'" } @bad )
                    . ( @{$vals} > 3 ? ' ...' : '' )
                    . '. Fix those rows first' }
                if @bad;
        }
    }

    return { ok => 1, table => $table, steps => \@steps,
        carried => \@carry, lost => \@lost, blocked => \@blocked };
}

1;
