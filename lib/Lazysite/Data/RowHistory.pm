package Lazysite::Data::RowHistory;

# SM1355 (ruling 156): ROW CHANGES ARE RECORDED, AND CAN BE UNDONE.
#
# A page's changes are kept by content history; a table's rows had only the
# audit trail, which names who changed which row and not what it was. So an
# availability switch, a wizard's row and a row saved or deleted through the
# manager, the control API or MCP are each recorded here as ONE change: who,
# when, from where (the door, or `wizard:<name>`), and the row before and after.
# Undo puts the row back as it was before a change and is itself recorded.
#
# IN THE STORE, beside _schema_history and for the same reason: a record kept in
# the database travels with the data through backup and restore, where a file
# beside it is the desync SM410 removed. The table name starts with an
# underscore, which no declared table can (Descriptor's identifier rule), so it
# can never collide with a site's own.
#
# NEVER FATAL, as the schema history is not: a change that could not be
# recorded is logged and the write it describes stands - but then it has no
# change id, and the caller says so rather than offering an Undo it cannot do.
#
# NOT RECORDED: a bulk import, a restore and a form handler's row - each has its
# own record (the import's safety export, the package, the submission), and a
# thousand-row load is not a thousand undoable changes.

use strict;
use warnings;
use Exporter 'import';
use JSON::PP               ();
use Lazysite::Util         qw(log_event);
use Lazysite::Data::SQLite ();              # the engine-specific parts (t/unit/data/12)

our @EXPORT_OK = qw(record_change list_changes get_change mark_undone);

my $TABLE = '_row_changes';

sub _now {
    my @t = gmtime( time() );
    return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, @t[ 3, 2, 1, 0 ];
}

my $JSON = JSON::PP->new->canonical->allow_nonref;

# Record one change. %c: table, key, op (insert|update|delete|switch|undo),
# actor, source, before (hash or undef), after (hash or undef), undoes (id).
# Returns the change id, or undef when it could not be recorded.
sub record_change {
    my ( $dbh, %c ) = @_;
    my $id = eval {
        $dbh->do( Lazysite::Data::SQLite::row_changes_table_sql() );
        $dbh->do(
            qq{INSERT INTO "$TABLE" ("at","actor","tbl","row_key","op","source","before","after","undoes") }
                . 'VALUES (?,?,?,?,?,?,?,?,?)', undef,
            _now(),
            ( defined $c{actor} && length $c{actor} ? $c{actor} : '(unattributed)' ),
            $c{table}, "$c{key}", $c{op}, ( $c{source} // 'unknown' ),
            ( defined $c{before} ? $JSON->encode( $c{before} ) : undef ),
            ( defined $c{after}  ? $JSON->encode( $c{after} )  : undef ),
            $c{undoes} );
        Lazysite::Data::SQLite::row_changes_last_id($dbh);
    };
    unless ( defined $id ) {
        log_event( 'WARN', $c{table} // 'data', 'row change not recorded - the write itself succeeded',
            op => $c{op}, error => ( $@ || 'unknown' ) );
        return undef;
    }
    return 0 + $id;
}

sub _row {
    my ($h) = @_;
    return undef unless ref $h eq 'HASH';
    my %r = %$h;
    $r{before} = defined $r{before} ? eval { $JSON->decode( $r{before} ) } : undef;
    $r{after}  = defined $r{after}  ? eval { $JSON->decode( $r{after} ) }  : undef;
    $r{id}     = 0 + $r{id};
    $r{key}    = delete $r{row_key};
    $r{table}  = delete $r{tbl};
    return \%r;
}

# The newest changes to a table (or to one row of it), newest first.
sub list_changes {
    my ( $dbh, $table, %opt ) = @_;
    my $limit = ( ( $opt{limit} // '' ) =~ /\A[1-9][0-9]{0,2}\z/ ) ? 0 + $opt{limit} : 50;
    $limit = 200 if $limit > 200;
    my $rows = eval {
        return [] unless Lazysite::Data::SQLite::row_changes_exist($dbh);
        my ( $sql, @b ) = ( qq{SELECT * FROM "$TABLE" WHERE "tbl" = ?}, $table );
        if ( defined $opt{key} && length $opt{key} ) { $sql .= ' AND "row_key" = ?'; push @b, "$opt{key}" }
        $sql .= ' ORDER BY "id" DESC LIMIT ' . $limit;
        $dbh->selectall_arrayref( $sql, { Slice => {} }, @b );
    };
    return [ map { _row($_) } @{ $rows || [] } ];
}

sub get_change {
    my ( $dbh, $table, $id ) = @_;
    return undef unless defined $id && $id =~ /\A[1-9][0-9]{0,17}\z/;
    my $h = eval {
        return undef unless Lazysite::Data::SQLite::row_changes_exist($dbh);
        $dbh->selectrow_hashref( qq{SELECT * FROM "$TABLE" WHERE "id" = ? AND "tbl" = ?}, undef, $id, $table );
    };
    return _row($h);
}

sub mark_undone {
    my ( $dbh, $id, $by ) = @_;
    eval { $dbh->do( qq{UPDATE "$TABLE" SET "undone_by" = ? WHERE "id" = ?}, undef, $by, $id ); 1 }
        or log_event( 'WARN', 'data', 'row change not marked undone', id => $id, error => "$@" );
    return;
}

1;
