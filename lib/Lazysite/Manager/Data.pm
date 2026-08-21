package Lazysite::Manager::Data;

# SM447: the manager/control-API surface over the site's data tables.
#
# A THIN WRAPPER, DELIBERATELY. Every question it answers is answered by
# Lazysite::Data::Tables, which is the single implementation the MCP tools and
# the page bindings also call. What this module adds is the surface's own
# concerns and nothing else: the docroot the request is bound to, and the
# shape a control-API response takes.
#
# Anything reasoned about here that is not surface-shaped is in the wrong file.
# Two surfaces each doing "a little bit of the logic" is how they come to
# disagree about the same question, which is SM353 and SM442 and the reason
# t/lint/57 exists.
#
# THE SCHEMA IS NOT APPLIED ON READ. A read that quietly migrated would make
# every listing a potential writer, and the one surface that reads most is the
# page binding - which holds a handle that cannot write, on purpose. Applying
# the schema is its own action, and an operator asks for it.

use strict;
use warnings;
use Exporter 'import';
use Lazysite::Util             qw(log_event);
use Lazysite::Manager::Plugins ();
use Lazysite::Data::Tables
    qw(list_tables load_table read_rows apply_schema
    insert_row update_row delete_row);

our @EXPORT_OK = qw(action_data_tables action_data_table action_data_rows
    action_data_migrate action_data_row_save action_data_row_delete);

our $DOCROOT;    # set by the caller (manager-api or the CLI)

# SM469: OFF MEANS OFF, on this path too.
#
# ADR 0009's first clause is that every dispatch path consults the enabled
# state. SM409 built that gate and it covers plugin SCRIPT execution - the
# `plugin-action` path. These actions dispatch straight into this module and
# never went near it, so disabling the data plugin changed nothing about them.
#
# A plugin owning control-API actions is a new shape; before this one there was
# no such path for the gate to miss. Which is why the lint matters more than
# these three lines: t/lint/77 asserts the property for any future plugin that
# owns a capability, because the next one would reintroduce this silently.
#
# READS ARE GATED TOO. A disabled plugin executing nothing is the whole rule,
# and a read is execution - it opens the store and runs a query. "Disabled but
# still answering" is the state SM409 exists to remove.
sub _gate {
    local $Lazysite::Manager::Plugins::DOCROOT = $DOCROOT;
    return undef if Lazysite::Manager::Plugins::plugin_enabled('plugins/data.pl');
    return { ok => 0,
        error => 'The data plugin is disabled. An operator can enable it on '
            . 'the Plugin Manager page.' };
}

sub _need_table {
    my ($table) = @_;
    return { ok => 0, error => 'table name required' }
        unless defined $table && length $table;
    return undef;
}

# The tables this site declares, with the title each descriptor carries.
#
# Reports a table whose descriptor is BROKEN rather than omitting it. An
# author who has just mis-typed a descriptor is the most likely reader of this
# list, and a silently shorter list is the least useful thing it could do.
sub action_data_tables {
    if ( my $off = _gate() ) { return $off }
    my @out;
    for my $name ( @{ list_tables($DOCROOT) } ) {
        my $d = load_table( $DOCROOT, $name );
        push @out,
            $d->{ok}
            ? { table => $name, title => $d->{title}, ok => 1 }
            : { table => $name, ok => 0, error => $d->{error} };
    }
    return { ok => 1, tables => \@out };
}

# One table's declared shape, as the manager and an agent both need it: the
# fields, their types, and what is required.
sub action_data_table {
    if ( my $off = _gate() ) { return $off }
    my ($table) = @_;
    if ( my $bad = _need_table($table) ) { return $bad }
    my $d = load_table( $DOCROOT, $table );
    return $d unless $d->{ok};
    return {
        ok         => 1,
        table      => $d->{table},
        title      => $d->{title},
        key        => $d->{key},
        auto_key   => $d->{auto_key},
        fields     => $d->{fields},
        indexes    => $d->{indexes},
        timestamps => $d->{timestamps},
    };
}

sub action_data_rows {
    if ( my $off = _gate() ) { return $off }
    my ( $table, %opt ) = @_;
    if ( my $bad = _need_table($table) ) { return $bad }
    return read_rows( $DOCROOT, $table, %opt );
}

# Bring the store into line with the descriptor, as far as is safe.
#
# Returns `blocked` as well as `applied`, and the caller must show both: the
# blocked list is the operator's account of why their column is not there yet,
# and dropping it would leave them believing the migration succeeded.
sub action_data_migrate {
    if ( my $off = _gate() ) { return $off }
    my ($table) = @_;
    if ( my $bad = _need_table($table) ) { return $bad }
    my $r = apply_schema( $DOCROOT, $table );
    log_event( 'INFO', $table, 'data schema applied',
        applied => scalar @{ $r->{applied} || [] },
        blocked => scalar @{ $r->{blocked} || [] } )
        if $r->{ok};
    return $r;
}

# One entry point for insert AND update, because the caller knows which it
# means by whether it has a key - and a surface that has to choose between two
# action names for "save this row" will eventually choose wrong.
sub action_data_row_save {
    if ( my $off = _gate() ) { return $off }
    my ( $table, $key, $values ) = @_;
    if ( my $bad = _need_table($table) ) { return $bad }
    return { ok => 0, error => 'row values required' }
        unless ref $values eq 'HASH';

    my $r
        = ( defined $key && length $key )
        ? update_row( $DOCROOT, $table, $key, $values )
        : insert_row( $DOCROOT, $table, $values );
    log_event( 'INFO', $table,
        ( defined $key && length $key ) ? 'data row updated' : 'data row inserted' )
        if $r->{ok};
    return $r;
}

sub action_data_row_delete {
    if ( my $off = _gate() ) { return $off }
    my ( $table, $key ) = @_;
    if ( my $bad = _need_table($table) ) { return $bad }
    return { ok => 0, error => 'row key required' }
        unless defined $key && length $key;
    my $r = delete_row( $DOCROOT, $table, $key );
    log_event( 'INFO', $table, 'data row deleted' ) if $r->{ok};
    return $r;
}

1;
