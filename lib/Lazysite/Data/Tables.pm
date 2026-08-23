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
    qw(select_sql insert_sql update_sql delete_sql observed_schema last_insert_key
    key_list_sql);

our @EXPORT_OK = qw(descriptor_dir list_tables load_table read_rows
    apply_schema insert_row update_row delete_row export_all_rows
    resolve_binding import_rows
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

    # SM472: A MISSING MODULE IS A DIAGNOSIS, NOT A 500.
    #
    # This was a bare `require`, so on a host without YAML::PP it DIED - and a
    # die in a CGI is an HTTP 500 with an HTML body. The field bisected it
    # carefully and correctly and still could not see the cause, because
    # nothing anywhere said the word "YAML::PP": every descriptor 500'd, an
    # empty listing succeeded (it globs filenames and never parses), and a call
    # with no descriptor answered properly (the parameter check runs first).
    # Three consistent, honest signals that pointed nowhere.
    #
    # The dependency is declared - in sbom-deps.json, in the deb, in the
    # plugin's `owns` - so this is not about whether it SHOULD be there. It is
    # about what happens on the host where it is not, and "500" is the one
    # answer that cannot be acted on.
    unless ( eval { require YAML::PP; 1 } ) {
        return _err(
            "table '$name': the YAML::PP module is not installed, so a "
                . 'descriptor cannot be read. Install it (Debian: '
                . 'libyaml-pp-perl) and try again.',
            table  => $name,
            kind   => 'missing_module',
            module => 'YAML::PP',
        );
    }
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
#
# SM476: `as` IS REQUIRED, AND IT DIES WITHOUT ONE.
#
# The obvious shape was a may_read() the read surfaces remember to call first,
# and "remember to" is exactly how this went wrong in the first place: the
# endpoint was a second door built without the gate the first door had, and no
# reviewer noticed because nothing in the signature asked. So the question
# moves into the call itself - a caller CANNOT read rows without saying who is
# asking, and there is nothing to forget.
#
# It DIES rather than returning an error, because a missing `as` is a
# programming fault and no visitor input can produce one. Dying is loud in the
# suite and unreachable in the field; returning an error would be a surface
# that silently renders nothing, which is the failure this whole filing is
# about.
sub read_rows {
    my ( $docroot, $name, %opt ) = @_;
    my $as = delete $opt{as};
    die 'read_rows needs to know who is asking: pass as => "operator" for a '
        . 'manage_data-gated surface, or as => { user, groups } for a visitor'
        unless defined $as;

    my $d = load_table( $docroot, $name );
    return $d unless $d->{ok};

    # THE SAME ANSWER AS A TABLE THAT DOES NOT EXIST. Distinguishing "you may
    # not read this" from "there is no such table" tells an anonymous caller
    # which tables a site has, which is most of what an attacker wants from a
    # store they cannot read.
    require Lazysite::Data::Access;
    return _err( "no table '$name' is declared", table => $name,
        kind => 'no_such_table' )
        unless Lazysite::Data::Access::may_read( $docroot, $d, $as );

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

# DP-2: a binding, resolved. One entry point for `db:` on a page and for the
# endpoint, so the two cannot answer the same binding differently.
#
# IT RETURNS WHAT THE BINDING ASKED FOR, not always a list: `.count` gives a
# number and `.field` gives one value, because a page that has to write
# `[% total.0.n %]` to show a count has been given the query engine's internal
# shape instead of an answer.
sub resolve_binding {
    my ( $docroot, $spec, $as ) = @_;
    require Lazysite::Data::Query;

    # The table name has to come out before the descriptor can be loaded, so
    # the binding is parsed twice: once for shape, once - inside the same
    # function - with the descriptor to validate against. Parsing is pure and
    # cheap, and the alternative is a half-parsed thing passed around.
    my $shape = Lazysite::Data::Query::parse_binding($spec);
    return $shape unless $shape->{ok};

    my $d = load_table( $docroot, $shape->{table} );
    return $d unless $d->{ok};

    require Lazysite::Data::Access;
    return _err( "no table '$shape->{table}' is declared",
        table => $shape->{table}, kind => 'no_such_table' )
        unless Lazysite::Data::Access::may_read( $docroot, $d, $as );

    my $q = Lazysite::Data::Query::parse_binding( $spec, $d );
    return $q unless $q->{ok};

    my %opt = ( as => 'operator' );    # already gated, three lines above
    $opt{where}    = $q->{filters}  if %{ $q->{filters} };
    $opt{order_by} = $q->{order_by} if defined $q->{order_by};
    $opt{order}    = $q->{order}    if defined $q->{order};
    $opt{limit}    = $q->{limit}    if defined $q->{limit};
    $opt{offset}   = $q->{offset}   if defined $q->{offset};

    my $scalar = $q->{scalar} // '';

    # TIMED, so the diagnosis is about what happened rather than about what
    # might. SLOW_MS is deliberately well above the measured worst case for a
    # table of any size these are meant to hold - about 5 ms at 100,000 rows -
    # so it fires on something genuinely abnormal rather than on a busy host. A
    # warning that cries wolf gets filtered out, and then the one time it
    # matters nobody is listening.
    my $t0 = _now();

    # `.field(column,key=K)` reads ONE row by its key, so the key travels as a
    # filter and the limit is 1 whatever the binding said.
    if ( $scalar eq 'field' ) {
        $opt{limit} = 1;
        my $r = read_rows( $docroot, $shape->{table}, %opt );
        return $r unless $r->{ok};
        my $row = $r->{rows}[0];
        return _timed( $q, $t0,
            { ok => 1, table => $shape->{table}, mode => $q->{mode},
                value => ( $row ? $row->{ $q->{column} } : undef ) } );
    }

    my $r = read_rows( $docroot, $shape->{table}, %opt );
    return $r unless $r->{ok};

    # `.count` counts what the filters SELECT, and it counts them after the
    # limit rather than before - which is worth saying because it is the
    # surprising choice. A count that ignored the limit would disagree with the
    # list beside it on the same page, and two numbers on one page that
    # disagree is worse than one number that is capped.
    if ( $scalar eq 'count' ) {
        return _timed( $q, $t0,
            { ok => 1, table => $shape->{table}, mode => $q->{mode},
                value => scalar @{ $r->{rows} || [] } } );
    }

    return _timed( $q, $t0,
        { %{$r}, mode => $q->{mode},
            ( $q->{writable} ? ( writable => $q->{writable} ) : () ) } );
}

# The threshold, in milliseconds, above which a read is worth a word. A package
# variable rather than a constant so a test can lower it - proving the warning
# by building a table big enough to be slow would make the suite slow instead.
our $SLOW_MS = 25;

sub _now {
    return eval { require Time::HiRes; Time::HiRes::time() } || 0;
}

# WHAT THE WARNING SAYS AND WHY IT SAYS IT. An author who sees "this page is
# slow" cannot act; one who is told which binding, how long it took, and which
# field to index can. And when the table has simply outgrown SQLite, the honest
# advice is a different engine rather than a smaller query - so it says that
# too, because an index on a table that large only moves the problem.
sub _timed {
    my ( $q, $t0, $out ) = @_;
    return $out unless $t0;
    my $ms = ( _now() - $t0 ) * 1000;
    $out->{elapsed_ms} = sprintf '%.1f', $ms;
    return $out unless $ms > $SLOW_MS;

    my @scans = @{ $q->{scans} || [] };
    $out->{slow}
        = "reading '$q->{table}' took "
        . sprintf( '%.0f', $ms )
        . 'ms'
        . ( @scans
        ? ". Nothing indexes " . join( ' or ', map { "'$_'" } @scans )
            . ', so the whole table is examined - add an index for it in the'
            . ' descriptor. If the table is large enough that an index does not'
            . ' settle it, it has outgrown SQLite rather than outgrown the query'
        : '' );
    return $out;
}

# DM-4: A STAGED IMPORT - validate everything, show the diff, then commit.
#
# The brief's rule, and this layer's: "a reject in any row aborts the whole
# import". So this runs in two halves that share one function, selected by
# `apply`:
#
#   apply => 0   PLAN. Every row is coerced through the descriptor exactly as
#                a live write would be, every key is classified insert-or-
#                update against the store, and NOTHING is written. The plan
#                says what would happen. A row that fails names its ROW NUMBER
#                and field, and the whole import is refused - a partial import
#                that stopped at row 40 of 200 leaves an operator with a table
#                that is half one thing and half another, and no way to tell
#                which rows landed.
#   apply => 1   COMMIT, in one transaction. The same validation runs again -
#                the store may have moved since the plan was shown - and if
#                every row still passes, they are written together or not at
#                all.
#
# KEYS ARE READ ONCE. Classifying 200 rows as insert-or-update with one query
# each would be 200 round trips to learn one fact; the existing keys come back
# in a single select and the classification is a hash lookup.
#
# THE CSV HEADER IS MATCHED TO THE DESCRIPTOR BY NAME, EXACTLY. A column the
# table does not have is refused - a spreadsheet that grew a column is telling
# you something, and importing around it would lose that column's values in
# silence. A declared field the CSV omits is fine: a partial column set is a
# partial write, and the missing fields keep their stored values on update or
# take their defaults on insert, exactly as a row save does.
#
# AN EMPTY CELL MEANS "NOT SENT". CSV cannot say unset, so an empty field is
# left out of the row - the same rule the row editor's collectRow() applies,
# and for the same reason: sending '' for every blank cell would overwrite
# every default with an empty string on every import.
sub import_rows {
    my ( $docroot, $name, $header, $rows, %opt ) = @_;
    my $apply = $opt{apply} ? 1 : 0;

    my $d = load_table( $docroot, $name );
    return $d unless $d->{ok};

    return _err( "table '$name': the CSV has no header row", table => $name,
        kind => 'validation' )
        unless ref $header eq 'ARRAY' && @{$header};

    # The header, checked against the declared fields. The key counts as a
    # field here even when it is automatic - an export includes it, so an
    # edited export will too, and it is how an update knows which row it is.
    my %known = map { $_ => 1 } keys %{ $d->{fields} };
    $known{ $d->{key} } = 1;
    $known{$_} = 1 for ( $d->{timestamps} ? qw(created_at updated_at) : () );
    my %seen;
    for my $col ( @{$header} ) {
        return _err( "table '$name': the CSV has a column '$col' that the "
                . 'table does not have. Remove it, or add the field to the '
                . 'descriptor first', table => $name, kind => 'validation',
            field => $col, rule => 'unknown_column' )
            unless $known{$col};
        return _err( "table '$name': the CSV names column '$col' twice",
            table => $name, kind => 'validation', field => $col,
            rule  => 'duplicate_column' )
            if $seen{$col}++;
    }
    my $key = $d->{key};
    my ($key_col) = grep { $header->[$_] eq $key } 0 .. $#{$header};

    # THE EXISTING KEYS, ONCE.
    my %exists;
    if ( -f store_path($docroot) ) {
        my $dbh = read_handle($docroot);
        return _err( "table '$name': the data store cannot be opened",
            table => $name )
            unless $dbh;
        my $keys = eval { $dbh->selectcol_arrayref( key_list_sql($d) ) } || [];
        %exists = map { $_ => 1 } grep { defined } @{$keys};
    }

    # VALIDATE EVERY ROW BEFORE TOUCHING ANY.
    my ( @inserts, @updates );
    my $n = 1;    # the header is line 1; the operator's spreadsheet agrees
    for my $r ( @{$rows} ) {
        $n++;
        my %in;
        for my $i ( 0 .. $#{$header} ) {
            my $v = $r->[$i];
            next unless defined $v && length $v;    # empty cell: not sent
            $in{ $header->[$i] } = $v;
        }
        # Timestamps are the plugin's; an export carries them, an import must
        # not try to write them back.
        delete @in{qw(created_at updated_at)};

        my $kv        = defined $key_col ? $r->[$key_col] : undef;
        my $is_update = defined $kv && length $kv && $exists{$kv};

        my $c;
        if ($is_update) {
            my %partial = %in;
            delete $partial{$key};    # the key is the address, never a value
            $c = coerce_row( $d, \%partial, partial => 1 );
        }
        else {
            # An auto key cannot be supplied on insert; an export carries it,
            # so strip it rather than refuse a file the system itself wrote.
            delete $in{$key} if $d->{auto_key};
            $c = coerce_row( $d, \%in );
        }
        unless ( $c->{ok} ) {
            return _err( "row $n: $c->{error}", table => $name,
                kind => 'validation', row => $n,
                ( $c->{field} ? ( field => $c->{field} ) : () ),
                ( $c->{rule}  ? ( rule  => $c->{rule} )  : () ) );
        }
        if ($is_update) { push @updates, [ $kv, $c->{values}, $n ] }
        else            { push @inserts, [ $c->{values}, $n ] }
    }

    my $plan = { ok => 1, table => $name, rows => scalar @{$rows},
        inserts => scalar @inserts, updates => scalar @updates,
        applied => 0 };
    return $plan unless $apply;

    # COMMIT, ALL OR NOTHING.
    my $dbh = write_handle($docroot);
    return _err( "table '$name': the data store cannot be opened for writing",
        table => $name )
        unless $dbh;
    my $ok = eval {
        $dbh->begin_work;
        for my $u (@updates) {
            my ( $sql, $binds )
                = update_sql( $d, $u->[0], $u->[1] );
            $dbh->do( $sql, undef, @{$binds} );
        }
        for my $ins (@inserts) {
            my ( $sql, $binds )
                = insert_sql( $d, $ins->[0] );
            $dbh->do( $sql, undef, @{$binds} );
        }
        $dbh->commit;
        1;
    };
    unless ($ok) {
        my $why = $@ || $dbh->errstr || 'unknown';
        eval { $dbh->rollback; 1 };
        return _err( "table '$name': the import failed and was rolled back - "
                . "nothing was written. $why", table => $name );
    }
    $plan->{applied} = 1;
    return $plan;
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
        my $r = read_rows( $docroot, $name, as => 'operator',
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
