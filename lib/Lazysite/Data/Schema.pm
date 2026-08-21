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
    observed_schema table_has_rows);
use Lazysite::Data::Value qw(coerce_field);

our @EXPORT_OK = qw(plan_migration);

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
    my %want_index;
    for my $ix ( @{ $d->{indexes} || [] } ) {
        $want_index{ _index_name( $d->{table}, @{$ix} ) } = 1;
    }
    my @index_sql = index_sql($d);
    my $i         = 0;
    for my $ix ( @{ $d->{indexes} || [] } ) {
        my $name = _index_name( $d->{table}, @{$ix} );
        push @additive, { sql => $index_sql[$i], binds => [], why => "index $name" }
            unless $observed->{indexes}{$name};
        $i++;
    }

    # An index the descriptor no longer asks for is left in place and not
    # reported as a problem: it costs a little space, it loses nothing, and
    # dropping it is not this function's decision to make.

    return { ok => 1, create => [], additive => \@additive, blocked => \@blocked };
}

1;
