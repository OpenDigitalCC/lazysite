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
#
# KEPT FOR A PERIOD (ruling 170): 90 days by default, or the table's own
# `row_history_days` (Descriptor checks it is a positive whole number). A change
# older than its table's period is removed - a deleted row's changes too, the
# delete among them, so a row that is gone leaves no history behind it once the
# period has passed - and one still listed past it (no write has pruned yet) is
# not undoable. PRUNING RUNS IN TWO PLACES, never on a read (a list or a look at
# one change only compares ages): where the store is written, after a change is
# recorded, and once a day in the daemon's `row-history-prune` job, so a store
# nobody writes to does not keep expired changes - old values of people's rows -
# for as long as nobody writes. Both call prune with period_for, so the two
# cannot disagree about a table's period.

use strict;
use warnings;
use Exporter 'import';
use JSON::PP               ();
use Lazysite::Util         qw(log_event);
use Lazysite::Data::SQLite ();              # the engine-specific parts (t/unit/data/12)

our @EXPORT_OK = qw(record_change list_changes get_change mark_undone prune keep_days
    within_period period_for);

my $TABLE = '_row_changes';

# Ruling 170: the period a table's changes are kept, when it names none.
our $DEFAULT_KEEP_DAYS = 90;

sub _stamp {
    my @t = gmtime( $_[0] );
    return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, @t[ 3, 2, 1, 0 ];
}

sub _now { return _stamp( time() ) }

# The days a table's changes are kept: its descriptor's row_history_days, else
# the default. Takes a loaded descriptor (or undef, for a table that is gone).
sub keep_days {
    my ($d) = @_;
    my $n   = ref $d eq 'HASH' ? $d->{row_history_days} : undef;
    return ( defined $n && $n =~ /\A[1-9][0-9]*\z/ ) ? 0 + $n : $DEFAULT_KEEP_DAYS;
}

# The oldest `at` still inside a period of $days. The stamps are fixed-width
# UTC, so they compare as strings.
sub _cutoff { return _stamp( time() - $_[0] * 86400 ) }

# Is a change (as get_change/list_changes return it) inside a period of $days?
sub within_period {
    my ( $c, $days ) = @_;
    return 0 unless ref $c eq 'HASH' && defined $c->{at};
    return $c->{at} ge _cutoff( $days // $DEFAULT_KEEP_DAYS ) ? 1 : 0;
}

# The period lookup both callers pass to prune: a table's days are keep_days of
# its descriptor as the docroot declares it now, read once per table; a table
# no longer declared (or whose descriptor does not load) is held to the default.
sub period_for {
    my ($docroot) = @_;
    require Lazysite::Data::Tables;
    my %days;
    return sub {
        my ($t) = @_;
        return $days{$t} //= do {
            my $d = eval { Lazysite::Data::Tables::load_table( $docroot, $t ) };
            keep_days( ref $d eq 'HASH' && $d->{ok} ? $d : undef );
        };
    };
}

# Remove every change older than its table's period. $period_for is called with
# each table the history names and answers its days (period_for above). Called
# after a recorded write and by the daemon's row-history-prune job, never on a
# read. Never fatal: a prune that fails is logged and the write that called it
# stands. Returns how many were removed, or undef when the prune failed (the
# job reports that; a write ignores it).
sub prune {
    my ( $dbh, $period_for ) = @_;
    my $gone = eval {
        return 0 unless Lazysite::Data::SQLite::row_changes_exist($dbh);
        my $tables = $dbh->selectcol_arrayref(qq{SELECT DISTINCT "tbl" FROM "$TABLE"}) || [];
        my $n      = 0;
        for my $t (@$tables) {
            my $days = $period_for ? $period_for->($t) : undef;
            $days = $DEFAULT_KEEP_DAYS unless defined $days && $days =~ /\A[1-9][0-9]*\z/;
            my $r = $dbh->do( qq{DELETE FROM "$TABLE" WHERE "tbl" = ? AND "at" < ?}, undef, $t,
                _cutoff($days) );
            $n += $r if $r && $r > 0;
        }
        $n;
    };
    unless ( defined $gone ) {
        log_event( 'WARN', 'data', 'row history not pruned - nothing else was changed',
            error => ( $@ || 'unknown' ) );
        return undef;
    }
    log_event( 'INFO', 'data', 'row history pruned', removed => $gone ) if $gone;
    return $gone;
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

# The newest changes to a table (or to one row of it), newest first, each with
# `undoable`: not undone yet and inside the period ($opt{days}, the table's).
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
    # Ruling 170: Undo is offered only inside the period (and only once).
    my $days = $opt{days} // $DEFAULT_KEEP_DAYS;
    return [
        map {
            my $r = _row($_);
            $r->{undoable} = ( !$r->{undone_by} && within_period( $r, $days ) )
                ? JSON::PP::true() : JSON::PP::false();
            $r
        } @{ $rows || [] }
    ];
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
