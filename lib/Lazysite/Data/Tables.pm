package Lazysite::Data::Tables;

# SM447: the site's tables - what is declared, and what is in them.
#
# THE LAYER THE SURFACES CALL. Everything below it is engine-shaped
# (Descriptor, SQLite, Value, Schema, Export); everything above it is
# surface-shaped (control API, MCP, page bindings). This is where a DOCROOT
# turns into an answer, and it exists so that the three surfaces call one
# implementation rather than each assembling the same five modules slightly
# differently - which is how two channels come to disagree about the same
# question (SM353, SM442, and the reason t/lint/57 exists).
#
# READS TAKE A READ HANDLE. Connect gives out two, and the render path holds
# the one that cannot write. That is not decoration: a page binding runs in the
# processor, which is the one surface where a bug becomes a write triggered by
# an anonymous visitor. Every read path here goes through read_handle, and the
# only functions that ask for write_handle are the ones whose names say they
# write.
#
# A MISSING TABLE IS NOT AN ERROR CONDITION TO PANIC ABOUT, but it is not
# silence either. A page that scans a table nobody has declared gets an empty
# list AND an error the caller can show, because the alternative - an empty
# list alone - is what SM460 was: a page that rendered fine and listed nothing,
# so the author blamed their pattern.

use strict;
use warnings;
use Exporter                   qw(import);
use Lazysite::Data::Descriptor qw(load_descriptor);
use Lazysite::Data::Connect
    qw(read_handle write_handle store_path store_diagnosis);
use Lazysite::Data::Schema qw(plan_migration plan_rebuild);
use Lazysite::Data::Value  qw(coerce_row);
use Lazysite::Data::SQLite
    qw(select_sql insert_sql update_sql delete_sql observed_schema last_insert_key);

our @EXPORT_OK = qw(descriptor_dir list_tables load_table read_rows
    apply_schema insert_row update_row delete_row export_all_rows
    rebuild_table);

sub _err {
    my ( $error, %extra ) = @_;
    return { ok => 0, kind => 'data', error => $error, %extra };
}

sub descriptor_dir { return "$_[0]/lazysite/db/tables" }

# Table names come from FILENAMES, and the filename is validated before it is
# used for anything. A descriptor's own `table:` is not consulted for the name:
# two files claiming one table would be ambiguous, and the filesystem has
# already made the names unique.
sub list_tables {
    my ($docroot) = @_;
    my $dir = descriptor_dir($docroot);
    return [] unless -d $dir;
    opendir my $dh, $dir or return [];
    my @names = sort map { s/\.ya?ml\z//r }
        grep { /\A[a-z][a-z0-9_]*\.ya?ml\z/ } readdir $dh;
    closedir $dh;
    return \@names;
}

# The descriptor for one table, loaded and validated.
#
# The YAML is read here rather than in Descriptor.pm, which takes a structure:
# that keeps the validator testable without a filesystem, and keeps the parser
# dependency at the edge where the SBOM declaration expects it.
sub load_table {
    my ( $docroot, $name ) = @_;
    return _err('a table name is required')
        unless defined $name && $name =~ /\A[a-z][a-z0-9_]*\z/;

    my $dir = descriptor_dir($docroot);
    my ($file) = grep { -f $_ } ( "$dir/$name.yaml", "$dir/$name.yml" );
    return _err( "no table '$name' is declared", table => $name,
        kind => 'no_such_table' )
        unless $file;

    require YAML::PP;
    my $raw = eval { YAML::PP->new->load_file($file) };
    return _err( "table '$name': the descriptor is not valid YAML - $@",
        table => $name )
        unless defined $raw && !$@;

    my $d = load_descriptor( $name, $raw );
    return $d unless $d->{ok};
    return $d;
}

# Rows, for a surface that may read them.
#
# %opt is passed to select_sql, which is where the ceiling and the ORDER BY
# membership check live - so a caller cannot widen either by coming through
# here.
sub read_rows {
    my ( $docroot, $name, %opt ) = @_;
    my $d = load_table( $docroot, $name );
    return $d unless $d->{ok};

    # NO STORE AT ALL is the same answer as no table, and is checked BEFORE
    # connecting. A read-only handle cannot open a file that does not exist, so
    # going through Connect first turns the ordinary state - a site that has
    # declared tables and not yet migrated - into "the data store cannot be
    # opened", which reads as a broken installation and sends an operator
    # looking for a fault that is not there.
    #
    # The distinction is worth keeping: "not created yet" is a next step, and
    # "exists but will not open" is a problem.
    return { ok => 1, table => $name, rows => [], pending_schema => 1 }
        unless -f store_path($docroot);

    my $dbh = read_handle($docroot);
    return _err( "table '$name': the data store cannot be opened for reading",
        table => $name )
        unless $dbh;

    # A DECLARED TABLE THAT HAS NEVER BEEN CREATED reads as empty, and says so
    # rather than dying. Declaring a table and not yet migrating is an ordinary
    # state - the descriptor is content, and content arrives before the
    # migration that follows it.
    #
    # THE EVAL IS NOT A FALLBACK, and this is where it was one. It used to read
    # `eval { ... } || { exists => 0 }`, so a probe that RAISED - because the
    # store directory is not writable and a WAL reader cannot open its `-shm`
    # file - came back as "the table has not been created yet". SQLite reported
    # the fault accurately and we discarded it, which is worse than the fault:
    # an operator was told their table was empty.
    #
    # Now a failure is diagnosed and named. Read-only deployment may be a
    # legitimate choice; being unable to tell it apart from an empty table is
    # not.
    my $observed = eval { observed_schema( $dbh, $name ) };
    if ( !$observed ) {
        my $why = store_diagnosis($docroot);
        return _err(
            "table '$name': the data store could not be inspected. "
                . $why->{detail},
            table  => $name,
            kind   => 'store_' . $why->{reason},
            detail => $why->{detail},
        );
    }
    return { ok => 1, table => $name, rows => [], pending_schema => 1 }
        unless $observed->{exists};

    my ( $sql, $binds ) = eval { select_sql( $d, %opt ) };
    return _err( "table '$name': $@", table => $name ) if $@;

    my $rows = eval { $dbh->selectall_arrayref( $sql, { Slice => {} }, @{$binds} ) };
    return _err( "table '$name': the query failed - $@", table => $name ) if $@;

    return { ok => 1, table => $name, rows => $rows || [] };
}

# Bring the store into line with the descriptor, as far as is safe.
#
# Returns what it DID and what it REFUSED, both, because the refused list is
# the useful half: it is the operator's account of why their column is not
# there yet, and DP-5 is the flow that resolves it.
sub apply_schema {
    my ( $docroot, $name ) = @_;
    my $d = load_table( $docroot, $name );
    return $d unless $d->{ok};

    my $dbh = write_handle($docroot);
    return _err( "table '$name': the data store cannot be opened for writing",
        table => $name )
        unless $dbh;

    my $plan = plan_migration( $d, $dbh );
    return $plan unless $plan->{ok};

    my @done;
    for my $sql ( @{ $plan->{create} } ) {
        eval { $dbh->do($sql); 1 }
            or return _err( "table '$name': create failed - $@", table => $name );
        push @done, 'create';
    }
    for my $step ( @{ $plan->{additive} } ) {
        eval { $dbh->do( $step->{sql}, undef, @{ $step->{binds} } ); 1 }
            or return _err( "table '$name': $step->{why} failed - $@",
            table => $name );
        push @done, $step->{why};
    }

    return { ok => 1, table => $name, applied => \@done,
        blocked => $plan->{blocked} };
}

sub _write_prep {
    my ( $docroot, $name, $input, %opt ) = @_;
    my $d = load_table( $docroot, $name );
    return ( $d, undef, undef ) unless $d->{ok};
    my $c = coerce_row( $d, $input, %opt );
    return ( $c, undef, undef ) unless $c->{ok};
    my $dbh = write_handle($docroot);
    return (
        _err( "table '$name': the data store cannot be opened for writing",
            table => $name ),
        undef, undef
    ) unless $dbh;
    return ( undef, $d, $dbh, $c->{values} );
}

sub insert_row {
    my ( $docroot, $name, $input ) = @_;
    my ( $bad, $d, $dbh, $values ) = _write_prep( $docroot, $name, $input );
    return $bad if $bad;
    my ( $sql, $binds ) = insert_sql( $d, $values );
    eval { $dbh->do( $sql, undef, @{$binds} ); 1 }
        or return _err( "table '$name': the insert failed - $@", table => $name );
    # The assigned key, for an auto-key table - a caller that has just created a
    # row and cannot address it has to guess.
    my $key
        = $d->{auto_key}
        ? last_insert_key( $dbh, $name )
        : $values->{ $d->{key} };
    return { ok => 1, table => $name, key => $key };
}

sub update_row {
    my ( $docroot, $name, $key_value, $input ) = @_;
    my ( $bad, $d, $dbh, $values )
        = _write_prep( $docroot, $name, $input, partial => 1 );
    return $bad if $bad;
    my ( $sql, $binds ) = eval { update_sql( $d, $key_value, $values ) };
    return _err( "table '$name': $@", table => $name ) if $@;
    my $n = eval { $dbh->do( $sql, undef, @{$binds} ) };
    return _err( "table '$name': the update failed - $@", table => $name ) if $@;
    # 0 rows is NOT an error and NOT a success. The caller asked to change a
    # row that is not there, and reporting "ok" would let a UI say saved.
    return _err( "table '$name': no row with that key", table => $name,
        kind => 'no_such_row' )
        unless $n && $n > 0;
    return { ok => 1, table => $name, key => $key_value, changed => 0 + $n };
}

sub delete_row {
    my ( $docroot, $name, $key_value ) = @_;
    my $d = load_table( $docroot, $name );
    return $d unless $d->{ok};
    my $dbh = write_handle($docroot);
    return _err( "table '$name': the data store cannot be opened for writing",
        table => $name )
        unless $dbh;
    my ( $sql, $binds ) = eval { delete_sql( $d, $key_value ) };
    return _err( "table '$name': $@", table => $name ) if $@;
    my $n = eval { $dbh->do( $sql, undef, @{$binds} ) };
    return _err( "table '$name': the delete failed - $@", table => $name ) if $@;
    return _err( "table '$name': no row with that key", table => $name,
        kind => 'no_such_row' )
        unless $n && $n > 0;
    return { ok => 1, table => $name, key => $key_value, deleted => 0 + $n };
}

# EVERY row, for an export. Not read_rows, which is capped.
#
# The cap on read_rows is deliberate and stays: an unbounded select against a
# table an agent has been filling is how a page comes to render for a minute.
# An EXPORT is the one caller that genuinely wants all of it, so it pages
# through in cap-sized batches rather than asking the cap to be lifted - the
# ceiling keeps protecting every other caller, and this one costs one query per
# thousand rows.
#
# Ordered by the key, so two exports of the same data page identically and the
# batches cannot overlap or skip. Ordering by nothing would let SQLite return
# rows in whatever order it liked BETWEEN queries, which is how a paged export
# silently loses rows.
sub export_all_rows {
    my ( $docroot, $name ) = @_;
    my $d = load_table( $docroot, $name );
    return $d unless $d->{ok};

    my $batch = 1000;
    my @all;
    my $offset = 0;
    while (1) {
        my $r = read_rows( $docroot, $name,
            order_by => $d->{key}, order  => 'asc',
            limit    => $batch,    offset => $offset );
        return $r unless $r->{ok};
        my $rows = $r->{rows} || [];
        push @all, @{$rows};
        last if @{$rows} < $batch;
        $offset += $batch;

        # A table that keeps returning full batches forever means something is
        # wrong with the paging, not that the table is enormous. Stopping with
        # an error beats looping until the process is killed.
        return _err( "table '$name': export exceeded 1,000,000 rows - refusing "
                . 'to continue', table => $name )
            if $offset > 1_000_000;
    }
    return { ok => 1, table => $name, rows => \@all,
        pending_schema => ( $offset == 0 && !@all ) ? 1 : 0 };
}

# DP-5: perform a blocked change, once it has been confirmed by name.
#
# apply_schema applies what is safe and REPORTS what it refuses. This is the
# other side of that: the operator has read the refusal, decided, and named the
# columns whose data they accept losing. Nothing here happens without that
# list, and the list is checked against what the rebuild would actually drop -
# confirming the wrong column name is not confirmation.
#
# A SAFETY EXPORT IS TAKEN FIRST, always, and its path is returned. The
# operation drops a table; if anything about the copy is wrong, the rows exist
# in one other place and the operator is told where. That costs a file and
# removes the only genuinely unrecoverable step.
sub rebuild_table {
    my ( $docroot, $name, %opt ) = @_;
    my $d = load_table( $docroot, $name );
    return $d unless $d->{ok};

    my $dbh = write_handle($docroot);
    return _err( "table '$name': the data store cannot be opened for writing",
        table => $name )
        unless $dbh;

    my $plan = plan_rebuild( $d, $dbh );
    return _err( "table '$name': $plan->{error}", table => $name )
        unless $plan->{ok};

    # THE CONFIRMATION NAMES THE COLUMNS, and must name all of them. A caller
    # that confirms "colour" while the rebuild would also drop "size" has not
    # agreed to lose "size" - and a flag saying "yes, destructive" would have
    # let exactly that through.
    my %confirmed   = map  { $_ => 1 } @{ $opt{confirm_lost} || [] };
    my @unconfirmed = grep { !$confirmed{$_} } @{ $plan->{lost} };
    if (@unconfirmed) {
        return _err(
            "table '$name': this rebuild drops "
                . join( ', ', @unconfirmed )
                . ' and the data in them. Confirm by naming each column.',
            table => $name, kind => 'needs_confirmation',
            lost  => $plan->{lost},
        );
    }
    # THE EXPORT, before anything is dropped.
    my $rows = export_all_rows( $docroot, $name );
    return $rows unless $rows->{ok};
    require Lazysite::Data::Export;
    require JSON::PP;
    my $dir = "$docroot/lazysite/db/rebuilds";
    unless ( -d $dir ) {
        require File::Path;
        eval { File::Path::make_path($dir); 1 }
            or return _err( "table '$name': could not create $dir for the "
                . 'safety export', table => $name );
    }
    my @t     = gmtime;
    my $stamp = sprintf '%04d%02d%02dT%02d%02d%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
    my $safety = "$dir/$name-$stamp.json";
    my $export = Lazysite::Data::Export::export_table( $d, $rows->{rows} );
    if ( open my $fh, '>:utf8', $safety ) {
        my $ok = print {$fh} JSON::PP->new->canonical->pretty->encode($export);
        $ok = 0 unless close $fh;
        unless ($ok) {
            unlink $safety;
            return _err( "table '$name': the safety export could not be "
                    . 'written, so the rebuild was not attempted',
                table => $name );
        }
    }
    else {
        return _err( "table '$name': the safety export could not be opened, "
                . 'so the rebuild was not attempted', table => $name );
    }

    # IN A TRANSACTION. The steps drop a table and rename another into its
    # place; half of that is a site with no table at all.
    my @done;
    my $ok = eval {
        $dbh->begin_work;
        for my $step ( @{ $plan->{steps} } ) {
            $dbh->do( $step->{sql} );
            push @done, $step->{why};
        }
        $dbh->commit;
        1;
    };
    unless ($ok) {
        my $err = $@ || 'unknown error';
        eval { $dbh->rollback; 1 };
        return _err(
            "table '$name': the rebuild failed and was rolled back - $err. "
                . "The rows are also in $safety.",
            table => $name, safety_export => $safety );
    }

    return { ok => 1, table => $name, applied => \@done,
        carried => $plan->{carried},          lost          => $plan->{lost},
        rows    => scalar @{ $rows->{rows} }, safety_export => $safety };
}

1;
