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
    insert_row update_row delete_row descriptor_dir rebuild_table export_all_rows
    import_rows drop_table);
use Lazysite::Data::Descriptor qw(load_descriptor);

our @EXPORT_OK = qw(action_data_tables action_data_table action_data_rows
    action_data_migrate action_data_row_save action_data_row_delete
    action_data_table_save action_data_rebuild action_data_export
    action_data_import action_data_table_source action_data_migrate_plan
    action_data_table_drop);

our $DOCROOT;    # set by the caller (manager-api or the CLI)

use Lazysite::Data::Connect ();
use JSON::PP                ();

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
# SM470: WRITE A TABLE DESCRIPTOR. Without this there is no way to create one.
#
# The descriptor lives at lazysite/db/tables/<name>.yaml, and `lazysite` is a
# RESERVED ROOT: the manager's content paths refuse it, and WebDAV allows only
# lazysite/layouts/ ("the rest of lazysite/ is protected"). So before this, a
# table could be declared only by somebody with shell access to the docroot -
# which is nobody the feature is for.
#
# THE RESERVED ROOT IS NOT THE PROBLEM AND IS NOT LOOSENED. lazysite/ holds the
# account store, the session secret and the ACLs; the guard that keeps a
# generic write channel out of it is doing exactly its job. What was missing is
# a NAMED door: one action, capability-gated, that writes one kind of file to
# one place.
#
# IT VALIDATES BEFORE IT WRITES, which is the part a generic file write could
# never have given. A descriptor that does not load is refused with the
# loader's own reason - the field, the rule, the value - rather than being
# stored and failing later at first use, when the author has moved on and the
# error surfaces as "the table does not work".
sub action_data_table_save {
    my ( $table, $yaml ) = @_;
    if ( my $bad = _gate() )             { return $bad }
    if ( my $bad = _need_table($table) ) { return $bad }

    # The NAME is the filename, so it is validated here rather than trusted -
    # this is the one place a caller chooses a path under a reserved root.
    return { ok => 0, error => "'$table' must be lower-case letters, digits "
            . 'and underscores, starting with a letter', field => 'table' }
        unless $table =~ /\A[a-z][a-z0-9_]*\z/;
    return { ok => 0, error => 'descriptor text required' }
        unless defined $yaml && length $yaml;

    # SM472: the same on the WRITE path, and this is the one the field met.
    unless ( eval { require YAML::PP; 1 } ) {
        return { ok => 0, kind => 'missing_module', module => 'YAML::PP',
            error => 'the YAML::PP module is not installed, so a descriptor '
                . 'cannot be read. Install it (Debian: libyaml-pp-perl) and '
                . 'try again.' };
    }
    my $raw = eval { YAML::PP->new->load_string($yaml) };
    return { ok => 0, kind => 'descriptor',
        error => "the descriptor is not valid YAML - $@" }
        if $@ || !defined $raw;

    # The SAME loader the render path uses. A descriptor accepted here and
    # refused at read time would be the worst of both.
    my $d = load_descriptor( $table, $raw );
    return $d unless $d->{ok};

    my $dir = descriptor_dir($DOCROOT);
    unless ( -d $dir ) {
        require File::Path;
        eval { File::Path::make_path($dir); 1 }
            or return { ok => 0,
            error => "could not create $dir - check that lazysite/ is "
                . 'writable by the site' };
    }

    # Written through a temp file and renamed, checked at every step. The
    # SM404 shape: a print or close that fails must not leave a truncated
    # descriptor renamed over a good one - and a torn descriptor is worse than
    # most, because the table it describes still holds rows.
    my $path = "$dir/$table.yaml";
    my $tmp  = "$path.$$";
    open my $fh, '>:utf8', $tmp
        or return { ok => 0, error => "could not write $path: $!" };
    my $ok = print {$fh} $yaml;
    $ok = 0 unless close $fh;
    unless ($ok) {
        unlink $tmp;
        return { ok => 0, error => "could not write $path (disk full?)" };
    }
    unless ( rename $tmp, $path ) {
        unlink $tmp;
        return { ok => 0, error => "could not replace $path: $!" };
    }

    log_event( 'INFO', $table, 'data descriptor saved' );

    # Deliberately NOT migrated here. Writing a descriptor and changing the
    # stored table are two decisions, and the second can be refused in part -
    # an operator needs to see what the migration would do before it happens.
    #
    # BUT WHETHER ONE IS NEEDED IS DERIVED, not asserted. This was a hardcoded
    # `1`, so every descriptor save reported "migration required" whether or
    # not the stored table already matched - and SM476 made that visible,
    # because PUBLISHING a table is a descriptor save that changes no field at
    # all. Being told to run a migration to change a privacy setting puts a
    # destructive-change confirmation in front of an operator for no reason,
    # and an operator who is told that every time stops reading it.
    #
    # Derived the same way D2 derives schema state: the database IS the state,
    # so plan_migration answers by looking rather than by remembering.
    my $needed = 1;
    my $dbh    = Lazysite::Data::Connect::read_handle($DOCROOT);
    if ($dbh) {
        require Lazysite::Data::Schema;
        my $plan = Lazysite::Data::Schema::plan_migration( $d, $dbh );
        $needed = ( $plan->{ok}
                && !@{ $plan->{create}   // [] }
                && !@{ $plan->{additive} // [] }
                && !@{ $plan->{blocked}  // [] } ) ? 0 : 1;
    }

    return { ok => 1, table => $table, title => $d->{title},
        fields => $d->{fields}, migrate_required => $needed };
}

sub action_data_tables {
    if ( my $off = _gate() ) { return $off }
    my @out;
    # WHETHER IT IS PUBLISHED, AND WHETHER IT EXISTS YET, both travel with the
    # listing (DM-1). An operator looking at a list of tables has exactly two
    # questions about each one - can anybody see it, and is it real yet - and
    # answering them per-table would mean a request per row.
    #
    # Both are DERIVED rather than remembered: `public` off the descriptor,
    # existence off the database, per D2. The database is the state.
    my $dbh = Lazysite::Data::Connect::read_handle($DOCROOT);
    for my $name ( @{ list_tables($DOCROOT) } ) {
        my $d = load_table( $DOCROOT, $name );
        unless ( $d->{ok} ) {
            push @out, { table => $name, ok => 0, error => $d->{error} };
            next;
        }

        my $pending = 1;
        if ($dbh) {
            require Lazysite::Data::Schema;
            my $obs = eval {
                Lazysite::Data::Schema::observed_schema( $dbh, $name );
            };
            $pending = ( $obs && $obs->{exists} ) ? 0 : 1;
        }

        push @out,
            { table => $name,
            title => $d->{title},
            public => ( $d->{public} ? JSON::PP::true : JSON::PP::false ),
            ( $pending ? ( pending_schema => JSON::PP::true ) : () ),
            ok => 1,
            };
    }
    return { ok => 1, tables => \@out };
}

# One table's declared shape, as the manager and an agent both need it: the
# fields, their types, and what is required.
# DM-5: the descriptor's SOURCE, for an editor. data-table returns the parsed
# shape, which is right for an agent and wrong for a person editing a file -
# their comments, their key order and their spacing are part of what they
# wrote, and a round trip through the parser would throw all three away.
sub action_data_table_source {
    if ( my $off = _gate() ) { return $off }
    my ($table) = @_;
    if ( my $bad = _need_table($table) ) { return $bad }
    return { ok => 0, error => "'$table' must be lower-case letters, digits "
            . 'and underscores, starting with a letter', field => 'table' }
        unless $table =~ /\A[a-z][a-z0-9_]*\z/;
    my $dir = descriptor_dir($DOCROOT);
    my ($file) = grep { -f $_ } ( "$dir/$table.yaml", "$dir/$table.yml" );
    return { ok => 0, error => "no table '$table' is declared",
        kind => 'no_such_table' }
        unless $file;
    open my $fh, '<:utf8', $file or return { ok => 0,
        error => "table '$table': the descriptor cannot be read" };
    my $text = do { local $/; <$fh> };
    close $fh;
    return { ok => 1, table => $table, descriptor => $text };
}

sub action_data_table {
    if ( my $off = _gate() ) { return $off }
    my ($table) = @_;
    if ( my $bad = _need_table($table) ) { return $bad }
    my $d = load_table( $DOCROOT, $table );
    return $d unless $d->{ok};
    # SM489 (minor): the SAME two facts the listing carries. data-tables said
    # public and pending_schema per table and data-table said neither, so the
    # reply for a published and an unpublished table was identical - and
    # data-table is what somebody inspecting ONE table reaches for when asking
    # why a page is empty. Derived the same way, per D2.
    my $pending = 1;
    if ( my $dbh = Lazysite::Data::Connect::read_handle($DOCROOT) ) {
        require Lazysite::Data::Schema;
        my $obs = eval { Lazysite::Data::Schema::observed_schema( $dbh, $table ) };
        $pending = ( $obs && $obs->{exists} ) ? 0 : 1;
    }
    return {
        ok         => 1,
        table      => $d->{table},
        title      => $d->{title},
        key        => $d->{key},
        auto_key   => $d->{auto_key},
        fields     => $d->{fields},
        indexes    => $d->{indexes},
        timestamps => $d->{timestamps},
        public     => ( $d->{public} ? JSON::PP::true : JSON::PP::false ),
        ( $pending ? ( pending_schema => JSON::PP::true ) : () ),
    };
}

sub action_data_rows {
    if ( my $off = _gate() ) { return $off }
    my ( $table, %opt ) = @_;
    if ( my $bad = _need_table($table) ) { return $bad }
    # `as => 'operator'`: every action in this module has already passed the
    # manage_data gate in _gate, so the SM476 read check would be asking a
    # question that is already answered.
    return read_rows( $DOCROOT, $table, as => 'operator', %opt );
}

# Bring the store into line with the descriptor, as far as is safe.
#
# Returns `blocked` as well as `applied`, and the caller must show both: the
# blocked list is the operator's account of why their column is not there yet,
# and dropping it would leave them believing the migration succeeded.
# DM-2: the table as a file.
#
# TWO FORMATS, FOR TWO DIFFERENT JOBS, and the difference is worth stating
# rather than leaving somebody to discover:
#
#   json  exact. Types survive, NULL and empty stay distinct, a decimal keeps
#         its trailing zeros. This is the one that goes back in.
#   csv   for the spreadsheet a person actually works in. No types, no null,
#         and cells that could be read as formulas are altered to make them
#         safe. Useful, and not an interchange format.
#
# STREAMED AS AN ATTACHMENT rather than returned as JSON-in-JSON: a download an
# operator has to copy out of a response body is not a download.
sub action_data_export {
    if ( my $off = _gate() ) { return $off }
    my ( $table, $format ) = @_;
    if ( my $bad = _need_table($table) ) { return $bad }

    my $d = load_table( $DOCROOT, $table );
    return $d unless $d->{ok};

    # EVERY row, not read_rows' capped page. A download that silently stopped
    # at the read ceiling would be a backup missing rows nobody was told about.
    my $all = export_all_rows( $DOCROOT, $table );
    return $all unless $all->{ok};

    $format = lc( $format // 'json' );
    my ( $body, $type, $ext, $note );

    if ( $format eq 'csv' ) {
        require Lazysite::Data::Csv;
        my $guarded;
        ( $body, $guarded ) = Lazysite::Data::Csv::to_csv( $d, $all->{rows} );
        $type = 'text/csv; charset=utf-8';
        $ext  = 'csv';
        $note = $guarded ? "$guarded cell(s) prefixed to disarm formulas" : '';
    }
    elsif ( $format eq 'json' ) {
        require Lazysite::Data::Export;
        my $export = Lazysite::Data::Export::export_table( $d, $all->{rows} );
        $body = Lazysite::Data::Export::to_json($export);
        $type = 'application/json; charset=utf-8';
        $ext  = 'json';
    }
    else {
        return { ok => 0,
            error => "'$format' is not a format - they are json and csv" };
    }

    log_event( 'INFO', $table, 'data table downloaded',
        format => $format,
        rows   => scalar @{ $all->{rows} || [] },
        ( $note ? ( note => $note ) : () ) );

    return { ok => 1, streamed_body => $body, content_type => $type,
        filename => "$table.$ext", ( $note ? ( note => $note ) : () ) };
}

# DM-5: what a migration WOULD do, with nothing done. The same plan_migration
# apply_schema runs, so the preview and the action cannot disagree - and the
# UI can show "this will add a column and refuse a type change" before an
# operator commits to either.
sub action_data_migrate_plan {
    if ( my $off = _gate() ) { return $off }
    my ($table) = @_;
    if ( my $bad = _need_table($table) ) { return $bad }
    my $d = load_table( $DOCROOT, $table );
    return $d unless $d->{ok};

    my $dbh = Lazysite::Data::Connect::read_handle($DOCROOT);
    return { ok => 1, table => $table, create => 1, additive => [],
        blocked => [], note => 'no store yet - the migration creates it' }
        unless $dbh;

    require Lazysite::Data::Schema;
    my $plan = Lazysite::Data::Schema::plan_migration( $d, $dbh );
    return $plan unless $plan->{ok};

    # A plan that has blocked steps is a rebuild in waiting. Ask the rebuild
    # pre-flight too, so the operator sees SM487's data checks - "2 rows have
    # no when" - at the moment they are deciding, not after confirming.
    my $rebuild;
    if ( @{ $plan->{blocked} || [] } ) {
        $rebuild = eval { Lazysite::Data::Schema::plan_rebuild( $d, $dbh ) };
    }
    return {
        ok       => 1,
        table    => $table,
        create   => ( @{ $plan->{create}                     || [] } ? 1 : 0 ),
        additive => [ map { $_->{why} } @{ $plan->{additive} || [] } ],
        blocked  => $plan->{blocked} || [],
        ( $rebuild && $rebuild->{ok}
            ? ( rebuild => { lost => $rebuild->{lost} || [],
                    data_blocked => $rebuild->{blocked} || [] } )
            : () ),
    };
}

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
# DP-5: perform a change apply_schema refuses, once it is confirmed by name.
#
# A SEPARATE ACTION rather than a flag on data-migrate, deliberately. Migrating
# is a routine act an agent performs after editing a descriptor; rewriting a
# table is not, and giving them one name would mean the routine call carried
# the dangerous capability every time it was made.
sub action_data_rebuild {
    if ( my $off = _gate() ) { return $off }
    my ( $table, $confirm_lost ) = @_;
    if ( my $bad = _need_table($table) ) { return $bad }
    my $r = rebuild_table( $DOCROOT, $table,
        confirm_lost => ( ref $confirm_lost eq 'ARRAY' ? $confirm_lost : [] ) );
    log_event( 'INFO', $table, 'data table rebuilt',
        lost => join( ',', @{ $r->{lost} || [] } ) )
        if $r->{ok};
    return $r;
}

# DM-4: a CSV import, staged. `apply` false plans and writes nothing; true
# commits in one transaction. Both parse the same file the same way, so what
# the operator was shown is what is applied - or refused again, if the store
# moved in between.
sub action_data_import {
    if ( my $off = _gate() ) { return $off }
    my ( $table, $body, $content_type, $apply ) = @_;
    if ( my $bad = _need_table($table) ) { return $bad }

    # The CSV is the multipart part named `file`, as site-backup-upload takes
    # its tarball. Parsed HERE, after the gate: a disabled plugin must not
    # read the upload at all, and the parser is the plugin's to call.
    require Lazysite::Manager::Upload;
    my @parts = Lazysite::Manager::Upload::parse_multipart_body( $body // '',
        $content_type // '' );
    my ($file) = grep { ( $_->{name} // '' ) eq 'file' } @parts;
    my $csv_text = $file ? $file->{data} : undef;
    return { ok => 0, error => 'a CSV file is required, as the multipart part '
            . 'named "file"', kind => 'validation' }
        unless defined $csv_text && length $csv_text;

    require Lazysite::Data::Csv;
    my ( $header, $rows, $why ) = Lazysite::Data::Csv::from_csv($csv_text);
    return { ok => 0, error => "the file is not valid CSV: $why",
        kind => 'validation' }
        if defined $why;

    my $r = import_rows( $DOCROOT, $table, $header, $rows,
        apply => ( $apply ? 1 : 0 ) );

    # AN IMPORT AUDITS AS ONE EVENT, with the counts - the brief's rule. Two
    # hundred row-level entries would bury the one fact the trail is asked
    # for, which is that an import happened, by whom, and how big it was.
    log_event( 'INFO', $table, 'data table imported',
        inserts => $r->{inserts}, updates => $r->{updates} )
        if $r->{ok} && $r->{applied};
    return $r;
}

# SM480: remove a table entirely. Destructive by definition, so `confirm` must
# name it - the same shape a destructive migration uses.
sub action_data_table_drop {
    if ( my $off = _gate() ) { return $off }
    my ( $table, $confirm ) = @_;
    if ( my $bad = _need_table($table) ) { return $bad }

    my $r = drop_table( $DOCROOT, $table, confirm => $confirm );
    log_event( 'INFO', $table, 'data table dropped',
        rows   => ( $r->{rows_dropped}  // 0 ),
        export => ( $r->{safety_export} // '' ) )
        if $r->{ok};
    return $r;
}

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
