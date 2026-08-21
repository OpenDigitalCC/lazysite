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
use Lazysite::Data::Connect    qw(read_handle write_handle store_path);
use Lazysite::Data::Schema     qw(plan_migration);
use Lazysite::Data::Value      qw(coerce_row);
use Lazysite::Data::SQLite
    qw(select_sql insert_sql update_sql delete_sql observed_schema);

our @EXPORT_OK = qw(descriptor_dir list_tables load_table read_rows
    apply_schema insert_row update_row delete_row);

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
    my $observed = eval { observed_schema( $dbh, $name ) } || { exists => 0 };
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
    my $key = $d->{auto_key}
        ? $dbh->last_insert_id( undef, undef, $name, undef )
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

1;
