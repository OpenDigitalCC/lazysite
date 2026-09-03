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
use JSON::PP                   ();
use Time::HiRes                ();
use Lazysite::Util             qw(log_event);
use Lazysite::Data::Descriptor qw(load_descriptor);
use Lazysite::Data::Connect
    qw(read_handle write_handle store_path store_diagnosis);
use Lazysite::Data::Schema qw(plan_migration plan_rebuild);
use Lazysite::Data::Value  qw(coerce_row);
use Lazysite::Data::SQLite
    qw(select_sql count_sql insert_sql update_sql delete_sql observed_schema last_insert_key
    key_list_sql history_table_sql history_insert_sql history_rows_sql drop_table_sql);

our @EXPORT_OK = qw(descriptor_dir list_tables load_table read_rows
    apply_schema schema_history insert_row update_row delete_row export_all_rows
    resolve_binding import_rows drop_table
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
# MEMOISED ON (path, mtime, size), with the same one-second guard read_settings
# uses (DAO-2). A descriptor is a pure function of its file text, and the YAML
# parse is the most expensive thing on the per-visitor binding path.
#
# HOW STALENESS IS PREVENTED, three ways and all three are needed:
#
#   1. THE KEY IS THE FILE'S IDENTITY, not a clock. A rewrite changes mtime or
#      size, which changes the key, which misses. Correctness never depends on
#      a window being short enough - the same reasoning SM334 wrote down for
#      the settings cache, and for the same reason: this decides what a
#      visitor is served.
#   2. THE ONE-SECOND GUARD covers the case the key cannot. mtime is
#      one-second granular, so an edit landing in the same second as a read,
#      keeping the same size - renaming a field from `aaaa` to `bbbb` does
#      exactly that - would carry an identical key. A file younger than a
#      second is read fresh every time until it settles.
#   3. NOTHING ASSIGNS INTO THE RETURNED DESCRIPTOR, so the shared reference
#      cannot be poisoned by a caller. Verified across Manager/Data.pm,
#      Manager/SitePackage.pm, plugins/data.pl, lazysite-data.pl,
#      lazysite-mcp.pl and this file: the only writes into a descriptor are
#      Descriptor.pm's own normalisation of `required` and `unique`, which
#      happens during the load being cached.
#
# The map is bounded the way the settings cache is - by how many distinct
# versions of one file a process sees, which is one in practice.
{
    my %_descriptor_cache;

    sub _descriptor_cache_clear { %_descriptor_cache = (); return }

    sub load_table {
        my ( $docroot, $name ) = @_;
        return _err('a table name is required')
            unless defined $name && $name =~ /\A[a-z][a-z0-9_]*\z/;

        my $dir = descriptor_dir($docroot);
        my ($file) = grep { -f $_ } ( "$dir/$name.yaml", "$dir/$name.yml" );
        return _err( "no table '$name' is declared", table => $name,
            kind => 'no_such_table' )
            unless $file;

        my @st  = stat $file;
        my $key = @st ? "$file:$st[9]:$st[7]" : '';
        return $_descriptor_cache{$key}
            if length $key && exists $_descriptor_cache{$key};

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
        return _err( "table '$name': the descriptor is not valid YAML - " . _clean_db_error($@),
            table => $name )
            unless defined $raw && !$@;

        my $d = load_descriptor( $name, $raw );
        if ( length $key && @st && $st[9] < time() - 1 ) {
            %_descriptor_cache = () if keys %_descriptor_cache > 8;
            $_descriptor_cache{$key} = $d;
        }
        return $d;
    }
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
    die 'read_rows needs to know who is asking: pass as => "sysop" for a '
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

    return _read_rows_loaded( $docroot, $d, %opt );
}

# DAO-1: THE ROWS, ONCE THE DESCRIPTOR IS IN HAND AND THE GATE HAS ANSWERED.
#
# resolve_binding loaded the descriptor, gated on it, and then called
# read_rows - which loaded the same descriptor from the same file in the same
# process a second time, so every page binding cost TWO YAML parses. The
# gate it repeated was `as => 'operator'`, which may_read answers by
# short-circuit; nothing else was lost by asking once.
#
# THIS SITS BENEATH read_rows, NEVER BESIDE IT. SM476's die is the design:
# a caller cannot read rows without saying who is asking. This helper is
# private, and the only two ways in are read_rows (which dies without `as`)
# and resolve_binding (which has already called may_read). A third caller
# reaching past the gate would be the second door SM476 exists to close.
#
# want_total (DAO-3) is 1 unless the caller says otherwise: read_rows always
# reports a total, because SM502 U-1 made that its contract.
sub _read_rows_loaded {
    my ( $docroot, $d, %opt ) = @_;
    my $name       = $d->{table};
    my $want_total = exists $opt{want_total} ? delete $opt{want_total} : 1;

    # NO STORE AT ALL is the same answer as no table, and is checked BEFORE
    # connecting. A read-only handle cannot open a file that does not exist, so
    # going through Connect first turns the ordinary state - a site that has
    # declared tables and not yet migrated - into "the data store cannot be
    # opened", which reads as a broken installation and sends a sysop
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
    # a sysop was told their table was empty.
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
    return _err( "table '$name': " . _clean_db_error($@), table => $name ) if $@;

    my $rows = eval { $dbh->selectall_arrayref( $sql, { Slice => {} }, @{$binds} ) };
    return _err( "table '$name': the query failed - " . _clean_db_error($@), table => $name ) if $@;

    # SM502 U-1: the listing knows its total. select_sql has ALWAYS capped at
    # 200 rows by default, so a big table silently showed one page with
    # nothing saying so - the reply now carries the count behind the page.
    #
    # DAO-3: BUT NOT WHEN NOBODY IS GOING TO READ IT. `.field(column,key=K)`
    # returns rows[0]{column} and never looks at the total, and it was paying
    # for a second query against the same table on every render.
    return { ok => 1, table => $name, rows => $rows || [] }
        unless $want_total;

    my ( $csql, $cbinds ) = count_sql( $d, where => $opt{where} );
    my ($total) = eval { $dbh->selectrow_array( $csql, undef, @{$cbinds} ) };
    $total = scalar @{ $rows || [] } unless defined $total;

    return { ok => 1, table => $name, rows => $rows || [], total => 0 + $total };
}

# Bring the store into line with the descriptor, as far as is safe.
#
# Returns what it DID and what it REFUSED, both, because the refused list is
# the useful half: it is the sysop's account of why their column is not
# there yet, and DP-5 is the flow that resolves it.
# SM468: what the shape used to be, and who changed it. Derivation answers
# NOW perfectly and BEFORE not at all - so the three operations that change
# a table's shape append one row each to an internal store table. IN THE
# STORE deliberately: it travels with the data through backup/restore by
# construction, where a file beside the database is exactly the desync the
# D2 decision removed. NEVER FATAL: history is a record of the change, and
# a broken record must not block the change it records - failures are
# logged and the operation proceeds.
sub _record_history {
    my ( $dbh, $actor, $table, $op, $detail ) = @_;
    eval {
        $dbh->do( history_table_sql() );
        $dbh->do( history_insert_sql(), undef,
            _now_iso(),
            ( defined $actor && length $actor ? $actor : '(unattributed)' ),
            $table, $op, JSON::PP->new->canonical->encode( $detail || {} ) );
        1;
    } or log_event( 'WARN', $table,
        'schema history write failed - the change itself succeeded',
        op => $op, error => "$@" );
    return;
}

# SM713: what a CALLER is told about a database failure.
#
# Reported from the field: a failed row save returned
#   DBD::SQLite::db do failed: no such table: ... at
#   /home/ispadmin/web/<site>/cgi-bin/../lib/Lazysite/Data/Tables.pm line 453
# - an absolute path carrying the hosting account name and the site's directory
# layout, a source file and line number, and the driver's own vocabulary, of
# which only "no such table" is actionable and it is buried in the middle.
#
# ONE CLEANER, not eight edited call sites: the rule for what a caller may see
# is a rule, and a rule written eight times disagrees with itself (SM578). The
# FULL string still reaches the log, where an operator debugging the engine
# looks for it. This only decides what crosses the wire.
# SM742: a constraint failure reads as OUR sentence, not the driver's.
#
# SM713 stopped these errors naming the server, and did. What survived the
# cleaner was still SQLite's own wording - "UNIQUE constraint failed:
# table.column" - which is not a leak, because the table and column are the
# caller's own, but is a DEPENDENCY talking directly to a caller.
#
# Two reasons that matters, and neither is tidiness. The wording belongs to
# SQLite, so anything built against it - a form highlighting the offending
# field, an importer naming the row that collided - is parsing text we do not
# control, and it breaks silently the day the backend or the phrasing changes.
# And the information is structured: the driver knows which column failed, and
# passing the sentence through as an opaque string throws that away.
#
# FOUR SHAPES ARE RECOGNISED, and everything else falls through to the general
# cleaner untouched. The fallback matters more than the mapping: a translator
# that handles four cases and mangles the fifth is worse than one that handles
# none, because the fifth is the one nobody anticipated and it is now
# unreadable as well as unexpected.
#
# Returns ( $sentence, $column ) - $column undef when the driver did not name
# one (FOREIGN KEY never does), so a caller can highlight a field without
# parsing prose, ours or SQLite's.
sub _constraint_error {
    my ($err) = @_;
    return () unless defined $err && length $err;

    # STRIP THE FILE AND LINE FIRST. The driver appends " at <path> line N." to
    # its message, so a capture that runs to the end of the line swallows it -
    # which is exactly what the first version did: "products.code at
    # /home/.../Tables.pm line 572." parsed as no column at all, every shape
    # fell through, and the cleaner emitted the driver's sentence unchanged
    # while looking like it had translated nothing on purpose.
    $err =~ s/\s+at\s+\S+\s+line\s+\d+\.?//g;

    # "UNIQUE constraint failed: t.a" or, for a composite key, "t.a, t.b".
    if ( $err =~ /UNIQUE constraint failed:\s*([^\n]+)/i ) {
        my @cols = _constraint_columns($1);
        return () unless @cols;
        my $list = _english_list( \@cols );
        return @cols > 1
            ? ( "a row with this combination of $list already exists", $cols[0] )
            : ( "a row with this $list already exists", $cols[0] );
    }

    if ( $err =~ /NOT NULL constraint failed:\s*([^\n]+)/i ) {
        my @cols = _constraint_columns($1);
        return () unless @cols;
        return ( $cols[0] . ' is required', $cols[0] );
    }

    # SQLite names no column for a foreign key. Saying which one would be a
    # guess, and a guess pointed at a field is worse than no field at all.
    if ( $err =~ /FOREIGN KEY constraint failed/i ) {
        return ( 'this refers to a row that does not exist', undef );
    }

    if ( $err =~ /CHECK constraint failed:\s*([^\n]+)/i ) {
        my $what = $1;
        $what =~ s/\s+\z//;
        my @cols = _constraint_columns($what);

        # A CHECK's name is often the constraint's, not a column's - so the
        # sentence names it without claiming it is a field.
        return @cols
            ? ( $cols[0] . ' is outside the values this table allows', $cols[0] )
            : ( "the value breaks the table's '$what' rule", undef );
    }

    return ();
}

# "t.a, t.b" -> ("a", "b"). The table prefix is dropped: the caller asked about
# one table and repeating its name in every field is noise.
#
# THE PREFIX IS REQUIRED, and that is the whole discriminator. SQLite writes
# `table.column` when a constraint is about a column, and a BARE NAME when a
# CHECK is named for itself - so `CHECK constraint failed: positive_total` is a
# rule's name, not a field. Without this rule the two are the same string, and
# the first version reported `positive_total` as a column: a form would then
# have highlighted an input that does not exist, which is worse than showing no
# field at all.
#
# A driver that emitted bare column names would lose them here and fall through
# to the general cleaner. That is the safe direction to be wrong in - the
# caller gets the original sentence rather than a confident mislabelling.
sub _constraint_columns {
    my ($raw) = @_;
    my @out;
    for my $part ( split /\s*,\s*/, $raw ) {
        $part =~ s/\A\s+|\s+\z//g;
        next unless $part =~ /\A[A-Za-z_][A-Za-z0-9_]*\.([A-Za-z_][A-Za-z0-9_]*)\z/;
        push @out, $1;
    }
    return @out;
}

sub _english_list {
    my ($items) = @_;
    return $items->[0] if @$items == 1;
    my @c    = @$items;
    my $last = pop @c;
    return join( ', ', @c ) . " and $last";
}

# The offending column as a key/value PAIR, for splicing into _err's %extra -
# empty when the driver named no column, so nothing has to test for undef at
# the call site and no error grows a `field => undef` that a caller might read
# as "a field, unnamed".
#
# Only the ROW-WRITE sites use it. Those are the ones a form reaches, and a
# form is the thing that can act on knowing which input was refused; a
# migration or a descriptor load has no field to highlight.
sub _constraint_field {
    my ($err) = @_;
    my ( undef, $col ) = _constraint_error($err);
    return () unless defined $col;
    return ( field => $col );
}

sub _clean_db_error {
    my ($err) = @_;
    return 'the database refused the operation' unless defined $err && length $err;

    # SM742: a recognised constraint answers in our words. Anything else falls
    # through to the general cleaning below, unchanged.
    my ($sentence) = _constraint_error($err);
    return $sentence if defined $sentence;

    my $e = "$err";
    $e =~ s/\s+at\s+\S+\s+line\s+\d+\.?//g;                # file and line
    $e =~ s/^\s*DB[DI]::\w+::\w+\s+\w+\s+failed:\s*//i;    # driver vocabulary
    $e =~ s/\s+/ /g;
    $e =~ s/^\s+|\s+$//g;
    $e =~ s/[.\s]+\z//;
    return length $e ? $e : 'the database refused the operation';
}

sub _now_iso {
    my @t = gmtime;
    return sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0];
}

# The reader: newest first, capped by the adapter's query. Answers [] for a
# table with no recorded changes - including every table from before SM468,
# where absence of history is a fact, not an error.
sub schema_history {
    my ( $docroot, $name ) = @_;
    my $dbh  = read_handle($docroot) or return [];
    my $rows = eval {
        $dbh->selectall_arrayref( history_rows_sql(), { Slice => {} }, $name );
    } || [];
    for my $r (@$rows) {
        $r->{detail} = eval { JSON::PP::decode_json( $r->{detail} ) } // {};
    }
    return $rows;
}

# THE SAFETY EXPORT BOTH DESTRUCTIVE VERBS WRITE FIRST (DA-2). drop_table and
# rebuild_table had this block written out twice - make_path, the stamp, the
# encode, the open/print/close and the unlink-on-failure - differing only in
# the name infix and in the clause naming what did not happen. Those two are
# arguments now; nothing else was ever allowed to differ.
#
# The stamp is _now_iso with the punctuation removed, which is what both
# copies were spelling out by hand.
#
# Returns { ok => 1, path => <absolute>, rel => <site-relative> } or an _err
# the caller returns unchanged. SM480: the REL form is the one a caller may
# report - the absolute path names the hosting account and the server layout.
sub _safety_export {
    my ( $docroot, $name, $d, $rows, %opt ) = @_;
    my $infix = $opt{infix} // '';
    my $tail  = $opt{tail}  // '';

    # The create-failure clause is its own option because the two verbs did
    # not agree: drop_table named what did not happen, rebuild_table did not.
    # Folding them onto one $tail would have CHANGED a message.
    my $create_tail = exists $opt{create_tail} ? $opt{create_tail} : $tail;

    require Lazysite::Data::Export;
    my $dir = "$docroot/lazysite/db/rebuilds";
    unless ( -d $dir ) {
        require File::Path;
        eval { File::Path::make_path($dir); 1 }
            or return _err( "table '$name': could not create $dir for the "
                . "safety export$create_tail", table => $name );
    }

    my $stamp = _now_iso();
    $stamp =~ s/[-:]//g;
    my $file   = "$name$infix-$stamp.json";
    my $safety = "$dir/$file";
    my $export = Lazysite::Data::Export::export_table( $d, $rows );
    if ( open my $fh, '>:utf8', $safety ) {
        my $ok = print {$fh} JSON::PP->new->canonical->pretty->encode($export);
        $ok = 0 unless close $fh;
        unless ($ok) {
            unlink $safety;
            return _err( "table '$name': the safety export could not be "
                    . "written$tail", table => $name );
        }
    }
    else {
        return _err( "table '$name': the safety export could not be opened$tail",
            table => $name );
    }

    return { ok => 1, path => $safety, rel => "lazysite/db/rebuilds/$file" };
}

# THE WRITE HANDLE, OR THE REFUSAL THAT NAMES THE TABLE (DA-3). Five verbs
# opened the store and wrote out the same refusal; the message is one string
# in one place now. Returns ( $dbh, undef ) or ( undef, $err ) - the caller
# returns $err unchanged, so every surface keeps the wording it had.
sub _writer {
    my ( $docroot, $name ) = @_;
    my $dbh = write_handle($docroot);
    return ( $dbh, undef ) if $dbh;
    return (
        undef,
        _err( "table '$name': the data store cannot be opened for writing",
            table => $name )
    );
}

sub apply_schema {
    my ( $docroot, $name, %opt ) = @_;
    my $d = load_table( $docroot, $name );
    return $d unless $d->{ok};

    my ( $dbh, $nowrite ) = _writer( $docroot, $name );
    return $nowrite if $nowrite;

    my $plan = plan_migration( $d, $dbh );
    return $plan unless $plan->{ok};

    my @done;
    for my $sql ( @{ $plan->{create} } ) {
        eval { $dbh->do($sql); 1 }
            or return _err( "table '$name': create failed - " . _clean_db_error($@), table => $name );
        push @done, 'create';
    }
    for my $step ( @{ $plan->{additive} } ) {
        eval { $dbh->do( $step->{sql}, undef, @{ $step->{binds} } ); 1 }
            or return _err( "table '$name': $step->{why} failed - " . _clean_db_error($@),
            table => $name );
        push @done, $step->{why};
    }

    _record_history( $dbh, $opt{actor}, $name, 'apply',
        { applied => \@done, blocked => $plan->{blocked} } )
        if @done;
    return { ok => 1, table => $name, applied => \@done,
        blocked => $plan->{blocked} };
}

sub _write_prep {
    my ( $docroot, $name, $input, %opt ) = @_;
    my $d = load_table( $docroot, $name );
    return ( $d, undef, undef ) unless $d->{ok};
    my $c = coerce_row( $d, $input, %opt );
    return ( $c, undef, undef ) unless $c->{ok};
    my ( $dbh, $nowrite ) = _writer( $docroot, $name );
    return ( $nowrite, undef, undef ) if $nowrite;
    return ( undef, $d, $dbh, $c->{values} );
}

sub insert_row {
    my ( $docroot, $name, $input ) = @_;
    my ( $bad, $d, $dbh, $values ) = _write_prep( $docroot, $name, $input );
    return $bad if $bad;
    my ( $sql, $binds ) = insert_sql( $d, $values );
    eval { $dbh->do( $sql, undef, @{$binds} ); 1 }
        or return _err( "table '$name': the insert failed - " . _clean_db_error($@),
        table => $name, _constraint_field($@) );
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
    return _err( "table '$name': " . _clean_db_error($@), table => $name ) if $@;
    my $n = eval { $dbh->do( $sql, undef, @{$binds} ) };
    return _err( "table '$name': the update failed - " . _clean_db_error($@),
        table => $name, _constraint_field($@) )
        if $@;
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
    my ( $dbh, $nowrite ) = _writer( $docroot, $name );
    return $nowrite if $nowrite;
    my ( $sql, $binds ) = eval { delete_sql( $d, $key_value ) };
    return _err( "table '$name': " . _clean_db_error($@), table => $name ) if $@;
    my $n = eval { $dbh->do( $sql, undef, @{$binds} ) };
    return _err( "table '$name': the delete failed - " . _clean_db_error($@),
        table => $name, _constraint_field($@) )
        if $@;
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

    # DAO-1: no `as` here any more. It said 'operator' only to satisfy
    # read_rows' SM476 die, and may_read answers 'sysop' by short-circuit,
    # so the second gate decided nothing. The rows now come from
    # _read_rows_loaded, beneath the gate that ran nine lines above.
    my %opt;
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
        my $r = _read_rows_loaded( $docroot, $d, %opt, want_total => 0 );
        return $r unless $r->{ok};
        my $row = $r->{rows}[0];
        return _timed( $q, $t0,
            { ok => 1, table => $shape->{table}, mode => $q->{mode},
                value => ( $row ? $row->{ $q->{column} } : undef ) } );
    }

    my $r = _read_rows_loaded( $docroot, $d, %opt );
    return $r unless $r->{ok};

    # `.count` is the TRUE count of what the filters select - before any
    # limit. It used to count after the limit, on the reasoning that two
    # numbers on one page that disagree are worse than one capped number;
    # SM511 changed the calculus by giving the page the total (`<var>_total`),
    # so the capped count stopped being the only honest option and started
    # being the wrong one: a gallery of 250 said "250" nowhere at all.
    if ( $scalar eq 'count' ) {
        return _timed( $q, $t0,
            { ok => 1, table => $shape->{table}, mode => $q->{mode},
                value => 0 + ( $r->{total} // scalar @{ $r->{rows} || [] } ) } );
    }

    return _timed( $q, $t0,
        { %{$r}, mode => $q->{mode},
            ( $q->{warnings} ? ( warnings => $q->{warnings} ) : () ),
            ( $q->{writable} ? ( writable => $q->{writable} ) : () ) } );
}

# The threshold, in milliseconds, above which a read is worth a word. A package
# variable rather than a constant so a test can lower it - proving the warning
# by building a table big enough to be slow would make the suite slow instead.
our $SLOW_MS = 25;

sub _now {
    return Time::HiRes::time();
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
    my ( $dbh, $nowrite ) = _writer( $docroot, $name );
    return $nowrite if $nowrite;
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

# SM480: REMOVE A TABLE - the descriptor and the stored rows together.
#
# WHY THIS DID NOT EXIST, AND WHY THAT WAS NOT SURVIVABLE. Declaring a table
# was reachable from three surfaces and removing one was reachable from none:
# no API action, no MCP tool, and the descriptor lives under lazysite/, which
# every write channel refuses on purpose. So a table declared by mistake, or
# renamed, or made for a single test, was PERMANENT - and the field agent found
# it the way anybody would, by trying to tidy up after themselves and
# discovering they could not. Every test table they had made was going to
# outlive the testing.
#
# IT TAKES EVERYTHING, so it asks first. `confirm` must name the table exactly.
# That is the same shape DP-5 uses for a destructive migration, and the reason
# is the same: an operator who confirms by typing the name has read the name,
# where one who clicks yes may not have.
#
# THE SAFETY EXPORT COMES FIRST, and a failure to write it stops the drop. The
# rows are about to stop existing; a copy on disk is the difference between a
# mistake and a loss. It goes beside the rebuild exports, because it is the
# same kind of artefact and an operator looking for "what did I have before"
# should find one place, not two.
#
# THE DESCRIPTOR GOES LAST. If the store drops and the descriptor survives, the
# table reads as declared-but-never-migrated - an ordinary, recoverable state.
# The other order leaves rows in a store nothing describes, which nothing in
# this system can read or clean up.
sub drop_table {
    my ( $docroot, $name, %opt ) = @_;

    my $d = load_table( $docroot, $name );
    return $d unless $d->{ok};

    my $confirm = $opt{confirm} // '';
    unless ( $confirm eq $name ) {
        return _err(
            "dropping '$name' deletes the table, its descriptor and every row "
                . "in it. Confirm by naming it exactly: confirm=$name",
            table => $name, kind => 'needs_confirmation',
        );
    }

    my $rows = export_all_rows( $docroot, $name );
    return $rows unless $rows->{ok};

    my $safe = _safety_export( $docroot, $name, $d, $rows->{rows},
        infix => '-dropped', tail => ', so nothing was dropped' );
    return $safe unless $safe->{ok};

    my $dbh = write_handle($docroot);
    if ($dbh) {
        my $sql = drop_table_sql($d);
        my $ok  = eval { $dbh->do($sql); 1 };
        unless ($ok) {
            my $why = $@ || $dbh->errstr || 'unknown';
            return _err( "table '$name': the stored table could not be "
                    . "dropped, so the descriptor was left in place - $why",
                table => $name );
        }
    }

    # The descriptor last. Both spellings, because load_table accepts either.
    my $removed = 0;
    for my $ext (qw(yaml yml)) {
        my $f = descriptor_dir($docroot) . "/$name.$ext";
        next unless -f $f;
        unless ( unlink $f ) {
            return _err( "table '$name': the rows are gone but the descriptor "
                    . "could not be removed ($!). The table now reads as "
                    . 'declared-but-not-migrated; remove the file or migrate '
                    . 'to recreate it empty.', table => $name );
        }
        $removed++;
    }

    _record_history( $dbh, $opt{actor}, $name, 'drop',
        { rows_dropped => scalar @{ $rows->{rows} || [] },
            safety_export => $safe->{rel} } );
    return { ok => 1, table => $name, dropped => 1,
        rows_dropped  => scalar @{ $rows->{rows} || [] },
        descriptors   => $removed,
        safety_export => $safe->{rel} };
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

    # SM511: the batch is THE ceiling, not a private second number. It was a
    # literal 1000 while select_sql clamped to MAX_ROWS - the moment the two
    # disagreed, "a short page means done" concluded after one page and the
    # export silently lost every row past the cap. The gate caught it; the
    # batch now asks for exactly what the reader can serve.
    my $batch = Lazysite::Data::SQLite::MAX_ROWS();
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

    my ( $dbh, $nowrite ) = _writer( $docroot, $name );
    return $nowrite if $nowrite;

    # SM489: A REBUILD WITH NOTHING TO DO DOES NOTHING - the way data-migrate
    # already does. The field agent pointed data-rebuild at a live table with
    # no pending change, and it dropped and recreated the table anyway: built
    # the copy, copied the rows, dropped the original, renamed into place.
    # Nothing was lost, so nothing was confirmed - which is correct in
    # isolation and wrong here, because a stray or scripted rebuild had just
    # replaced a production table with no prompt and no change to justify it.
    #
    # So the migration plan is consulted first. If it has nothing additive,
    # nothing blocked and nothing to create, the shapes already agree and
    # there is no rebuild to perform. Refusing here closes the no-confirmation
    # gap without adding a confirmation: the thing that would have been
    # confirmed does not happen.
    #
    # THE REBUILD PLAN'S `lost` IS NOT CONSULTED HERE, and the first draft did.
    # A dropped column always arrives from plan_migration as a BLOCKED step -
    # that is what makes it a rebuild rather than a migration - so a `lost`
    # clause could never be the one that refused, and sabotage proved it:
    # deleting that clause changed nothing. A condition no test can reach is
    # one that will be wrong one day without anybody noticing.
    my $mig = plan_migration( $d, $dbh );
    if ( $mig->{ok}
        && !@{ $mig->{additive} || [] }
        && !@{ $mig->{blocked}  || [] }
        && !@{ $mig->{create}   || [] } )
    {
        return { ok => 1, table => $name, rebuilt => 0, noop => 1,
            note => "the stored table already matches the descriptor - "
                . 'nothing to rebuild' };
    }
    # DAO-5: the preflight is three queries per column and the no-op check
    # above never reads $plan, so it is paid for only when there is a rebuild
    # to plan.
    my $plan = plan_rebuild( $d, $dbh );
    return _err( "table '$name': $plan->{error}", table => $name )
        unless $plan->{ok};

    # THE CONFIRMATION NAMES THE COLUMNS, and must name all of them. A caller
    # that confirms "colour" while the rebuild would also drop "size" has not
    # agreed to lose "size" - and a flag saying "yes, destructive" would have
    # let exactly that through.
    # SM487: A BLOCKED REBUILD IS REFUSED BEFORE CONFIRMATION IS ASKED FOR.
    # Asking somebody to confirm losing `note` when the rebuild is going to
    # fail on `when` anyway is a prompt about the wrong thing - and once they
    # have confirmed, the failure arrives as a rollback they did not expect.
    # The data has to be fixed first; nothing here can fix it for them.
    if ( @{ $plan->{blocked} || [] } ) {
        return _err(
            "table '$name': the rebuild would fail on the existing rows - "
                . join( '; ', map { $_->{why} } @{ $plan->{blocked} } ),
            table => $name, kind => 'blocked', blocked => $plan->{blocked},
        );
    }

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
    # SM480: REPORTED AS A SITE-RELATIVE PATH, not the absolute one. The field
    # agent found this handing back /home/<account>/web/<domain>/... - the
    # hosting account name, the layout of the server's filesystem, and the fact
    # that both are guessable for the next site. It is the same disclosure
    # class as the manager edit link, and an operator has no use for the
    # absolute form: they reach the file through Files, which is rooted at the
    # site.
    my $safe = _safety_export( $docroot, $name, $d, $rows->{rows},
        tail => ', so the rebuild was not attempted', create_tail => '' );
    return $safe unless $safe->{ok};
    my $safety     = $safe->{path};
    my $safety_rel = $safe->{rel};

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
        # THE DRIVER'S SENTENCE DOES NOT REACH THE OPERATOR. It names an
        # internal table (`x__rebuild`) and no row, which is the one message
        # in this feature that did not meet the standard the rest sets. The
        # pre-flight above now catches every refusal it can predict; what is
        # left here is the unpredictable - so say that, keep the driver text
        # for the log, and point at the pre-flight's own language.
        my $raw = $@ || 'unknown error';
        log_event( 'ERROR', $name, 'rebuild failed', why => $raw );
        my $err = ( $raw =~ /NOT NULL constraint failed: \S+__rebuild\.(\w+)/ )
            ? "a row has no '$1' and the new descriptor requires one"
            : ( $raw =~ /UNIQUE constraint failed: \S+__rebuild\.(\w+)/ )
            ? "'$1' is declared unique and an existing value is repeated"
            : 'the database refused the new shape for the existing rows';
        eval { $dbh->rollback; 1 };
        return _err(
            "table '$name': the rebuild failed and was rolled back - $err. "
                . "The rows are also in $safety.",
            table => $name, safety_export => $safety_rel );
    }

    _record_history( $dbh, $opt{actor}, $name, 'rebuild',
        { lost => $plan->{lost}, rows => scalar @{ $rows->{rows} },
            safety_export => $safety_rel } );
    return { ok => 1, table => $name, applied => \@done,
        carried => $plan->{carried},          lost          => $plan->{lost},
        rows    => scalar @{ $rows->{rows} }, safety_export => $safety_rel };
}

1;
