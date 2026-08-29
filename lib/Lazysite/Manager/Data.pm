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
use Lazysite::Data::Connect    ();
use Lazysite::Data::Access     ();
use Lazysite::Auth::Acl        qw(load_acls save_acls _acl_norm _to_list
    _acl_allows _is_operator);
use File::Path ();
use JSON::PP   ();

our @EXPORT_OK = qw(row_write_refusal groups_for
    action_table_acl_get action_table_acl_set
    action_table_acl_remove
    action_data_tables action_data_table action_data_rows
    action_data_migrate action_data_row_save action_data_row_delete
    action_data_table_save action_data_rebuild action_data_export
    action_data_import action_data_table_source action_data_migrate_plan
    action_data_table_drop action_data_safety_exports
    action_data_safety_export_delete action_data_safety_export_read
    action_data_safety_export_restore);

our $DOCROOT;    # set by the caller (manager-api or the CLI)

# SM593: the caller's own dav_scopes, set by whichever surface is answering.
# EMPTY MEANS UNCONFINED, which is the sysop - never "no domains". The CLI
# and the processor's render path leave it empty and are unaffected.
our @CALLER_SCOPES;

# SM648: THE THIRD STATE. Empty @CALLER_SCOPES meant two opposite things - "no
# confinement applies" for the CLI and the render path, and "confined to
# nothing" for a grant with no domain access - and the second was reading every
# table on the instance because it presented as the first.
#
# Flipping the default was never available: failing closed on empty would have
# confined the CLI and the render path too, and a render path that reaches no
# table serves a page with its data missing, on every site rather than only
# multi-domain ones. That is very likely why packages could fail closed under
# SM578 and tables could not - packages have no render path and no CLI reading
# them through the same predicate.
#
# So the fix is a flag, not a different default. Set by the two surfaces that
# serve a principal whose scopes were RESOLVED; the CLI, the render path and a
# cookie operator (who skips resolution entirely, by !_operator()) leave it
# alone and stay unconfined, which they genuinely are rather than accidentally.
our $CALLER_CONFINED = 0;
our $auth_user       = ''; # SM468: the actor for schema-history rows; set by each surface

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

# ---------------------------------------------------------------------------
# SM687: a table's access rule, reachable.
#
# A table's access IS an ACL - Lazysite::Data::Access keys it
# `lazysite/db/tables/<table>` and `may_read` consults it through the shared
# `_acl_allows`. The obvious way to read and write it was the generic acl-get /
# acl-set, and that NEVER WORKED: those verbs run `is_blocked_path`, which
# refuses everything under `lazysite/` outside two carve-outs, so every call
# came back "Path is blocked". The rule was enforced and unreachable at the same
# time - the enforcement side reads the store directly and never consults the
# blocklist.
#
# The blocklist is right and stays. It guards the generic FILE EDITOR from the
# management tree, and a descriptor is exactly the sort of file it should keep
# out of reach: writing one through the file editor would bypass the data
# plugin's own gates, including SM682's authority check on `writable_by`.
#
# So the fix is a verb that knows it is addressing a TABLE, not a path. The key
# is synthesised from a validated table name through Data::Access::acl_key -
# the same function the enforcement side calls - so the surface that sets the
# rule and the surface that applies it cannot key it differently.
#
# WHAT IS PORTED FROM THE FILE WRITER, AND WHAT IS NOT.
#   Ported:     the owner rule (only the owner may change an existing rule,
#               operators excepted), the read-any-rule split (SM464), and
#               owner assignment.
#   Not ported: `draft`, which is a property of a published section and means
#               nothing for a table; the private-store move, because there is
#               no file content to move - a table's rows live in the database
#               and moving them is SM611's problem, not this verb's; and path
#               validation, because the caller supplies a name, not a path.

# A table name is one opaque segment. Same shape SM657 requires of a brief's
# `table`, and for the same reason: it becomes part of a key, and a name
# carrying a slash would put the rule somewhere the name does not describe.
sub _acl_table_key {
    my ($table) = @_;
    return ( undef, { ok => 0, error => 'table name required' } )
        unless defined $table && length $table;
    return ( undef, { ok => 0, error => 'invalid table name' } )
        unless $table =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;
    return ( Lazysite::Data::Access::acl_key($table), undef );
}

sub action_table_acl_get {
    my ( $table, $user ) = @_;
    if ( my $off = _gate() ) { return $off }
    my ( $key, $err ) = _acl_table_key($table);
    return $err if $err;

    my $a = load_acls()->{ _acl_norm($key) };

    # SM464: reading a rule is the audit half - manage_users, a sysop, or a
    # token carrying manage_users may read ANY rule. Changing one stays
    # owner-only. Same split as a file's rule, deliberately.
    unless ( Lazysite::Manager::Files::may_read_any_rule() ) {
        return { ok => 0, error => 'Not the owner of this rule' }
            if $a && ( $a->{owner} // '' ) ne ( $user // '' );
    }
    return { ok => 1, table => $table, path => $key, acl => $a };
}

sub action_table_acl_set {
    my ( $table, $user, %o ) = @_;
    if ( my $off = _gate() ) { return $off }
    my ( $key, $err ) = _acl_table_key($table);
    return $err if $err;

    my $acls     = load_acls();
    my $norm     = _acl_norm($key);
    my $existing = $acls->{$norm};

    unless ( _is_operator() ) {
        if ($existing) {
            return { ok => 0, error => 'Only the owner may change who can read this table' }
                unless ( $existing->{owner} // '' ) eq ( $user // '' );
        }
        else {
            # Creating the FIRST rule on a table. The file writer asks for write
            # access to the file; the equivalent here is authority over the
            # table, and reaching this verb at all requires manage_data.
            return { ok => 0, error => 'You cannot set who can read this table' }
                unless defined $user && length $user;
        }
    }

    my $owner =
        $existing                                                     ? $existing->{owner}
        : ( _is_operator() && defined $o{owner} && length $o{owner} ) ? $o{owner}
        :                                                               $user;

    my %rec = ( owner => $owner );
    my $rl  = _to_list( $o{read} );  $rec{read}  = $rl if defined $rl;
    my $wl  = _to_list( $o{write} ); $rec{write} = $wl if defined $wl;

    $acls->{$norm} = \%rec;
    save_acls($acls);
    log_event( 'INFO', 'table-acl-set', 'table access rule set',
        table => $table, user => $user );
    return { ok => 1, table => $table, path => $key, acl => \%rec };
}

sub action_table_acl_remove {
    my ( $table, $user ) = @_;
    if ( my $off = _gate() ) { return $off }
    my ( $key, $err ) = _acl_table_key($table);
    return $err if $err;

    my $acls     = load_acls();
    my $norm     = _acl_norm($key);
    my $existing = $acls->{$norm};
    return { ok => 1, table => $table, path => $key, removed => 0 }
        unless $existing;

    unless ( _is_operator() ) {
        return { ok => 0, error => 'Only the owner may change who can read this table' }
            unless ( $existing->{owner} // '' ) eq ( $user // '' );
    }

    delete $acls->{$norm};
    save_acls($acls);
    log_event( 'INFO', 'table-acl-remove', 'table access rule cleared',
        table => $table, user => $user );
    return { ok => 1, table => $table, path => $key, removed => 1 };
}

sub _need_table {
    my ($table) = @_;
    return { ok => 0, error => 'table name required' }
        unless defined $table && length $table;
    return undef;
}

# Every action over a named table asks the same two questions in the same
# order - is the plugin on, and was a table named - and answers with the same
# two refusals. Written out twelve times before this; one name now.
sub _table_action {
    my ($table) = @_;
    return _gate() // _need_table($table) // _outside_scope($table);
}

# SM593: WHICH DOMAINS THIS CALLER MAY REACH, derived from its grant.
#
# `manage_data` is an INSTANCE capability and a table's ACL path carries no
# domain component, so on a multi-domain instance one client's grant reached
# every other client's tables - and the table NAMES are their own disclosure,
# which is why an unpublished table is invisible to a visitor in the first
# place.
#
# Memoised per request because every action asks, and the answer cannot change
# inside one.
my @_CALLER_DOMAINS;
my $_CALLER_DOMAINS_FOR = "\0";

sub _caller_domains {
    my $key = join( "\0", @CALLER_SCOPES );
    return @_CALLER_DOMAINS if $key eq $_CALLER_DOMAINS_FOR;
    require Lazysite::Manager::Domains;
    @_CALLER_DOMAINS     = Lazysite::Manager::Domains::domains_for_scopes(@CALLER_SCOPES);
    $_CALLER_DOMAINS_FOR = $key;
    return @_CALLER_DOMAINS;
}

# May this caller act on this table at all?
#
# A table that names no domain behaves EXACTLY as it did before this existed.
# That is deliberate and is the whole migration story: an instance carrying
# live tables upgrades to this release and nothing changes for them, and a
# table becomes confined the moment somebody writes `domain:` on it. The
# alternative - unscoped means nobody's - would have emptied every existing
# table out from under its own application on upgrade day.
sub _table_domain {
    my ($table) = @_;
    my $d = Lazysite::Data::Tables::load_table( $DOCROOT, $table );
    return '' unless ref $d eq 'HASH' && $d->{ok};
    my $dom = $d->{domain};
    return ( defined $dom && !ref $dom ) ? $dom : '';
}

sub _may_reach {
    my ($table) = @_;
    # SM648: a caller whose scopes were resolved is CONFINED, even when the
    # resolution came back empty - that is "no domains", not "no confinement".
    # SM659: the unconfined caller here is the SYSOP (or the CLI / render path),
    # never "the operator" - which meant both and so meant neither.
    return 1 unless $CALLER_CONFINED || @CALLER_SCOPES;
    my $dom = _table_domain($table);
    return 1 unless length $dom;    # unscoped - as it always was
    return ( grep { $_ eq $dom } _caller_domains() ) ? 1 : 0;
}

# THE REFUSAL IS THE ONE A MISSING TABLE GETS, word for word and kind for kind.
# A caller that could tell "not yours" from "no such table" would learn the
# names of the tables it may not reach, which is the disclosure this exists to
# stop - the filing's own point, since an unpublished table is hidden from a
# visitor precisely so its name cannot be guessed.
sub _outside_scope {
    my ($table) = @_;
    return undef if _may_reach($table);
    return { ok => 0, error => "no table '$table' is declared",
        table => $table, kind => 'no_such_table' };
}

# SM470: the table NAME is a filename under a reserved root, so it is
# validated here rather than trusted. The refusal, or undef.
sub _valid_table_name {
    my ($table) = @_;
    return undef if $table =~ /\A[a-z][a-z0-9_]*\z/;
    return { ok => 0, error => "'$table' must be lower-case letters, digits "
            . 'and underscores, starting with a letter', field => 'table' };
}

# Is the stored table behind its descriptor? Derived, per D2 - the database
# IS the state - and derived the same way wherever the question is asked.
sub _schema_pending {
    my ( $dbh, $table ) = @_;
    return 1 unless $dbh;
    require Lazysite::Data::Schema;
    my $obs = eval { Lazysite::Data::Schema::observed_schema( $dbh, $table ) };
    return ( $obs && $obs->{exists} ) ? 0 : 1;
}

# SM679: how many rows, for the listing.
#
# A count is the first thing anybody wants from a list of tables - which of
# these has anything in it, which is the big one, did the import land - and the
# listing could not answer it.
#
# UNKNOWN IS NOT ZERO. A table whose schema has not been applied yet, or whose
# query fails, returns undef and the listing omits the field. Reporting 0 for a
# table nobody could count would be a confident wrong answer, and "empty" and
# "could not tell" are different things to an operator deciding whether an
# import worked.
#
# Counted in the pass that already opened the handle and read the descriptor,
# not in a second loop over the tables.
sub _row_count {
    my ( $dbh, $desc, $pending ) = @_;
    return undef unless $dbh && !$pending && ref $desc eq 'HASH';
    # SQLite::count_sql, not a hand-built statement: it owns identifier quoting
    # for a table name, and writing `SELECT COUNT(*) FROM $table` here would be
    # a second place that has to get that right.
    my $n = eval {
        require Lazysite::Data::SQLite;
        my ($sql) = Lazysite::Data::SQLite::count_sql($desc);
        my $q = $dbh->prepare($sql);
        $q->execute;
        my ($c) = $q->fetchrow_array;
        $c;
    };
    return ( defined $n ) ? $n + 0 : undef;
}

# SM677: the descriptor, for the audit decision only. A thin named wrapper so
# the manager API asks a question rather than reaching into this module's
# internals - and so the audit path has one obvious place to look when somebody
# asks why a row write was or was not recorded.
sub load_table_for_audit {
    my ($table) = @_;
    return undef unless defined $table && length $table;
    return eval { load_table( $DOCROOT, $table ) };
}

# SM682 FOLLOW-UP (round 2, measured on 0.11.5): THE ALLOW-LIST DECISION, IN
# ONE PLACE, BECAUSE IT WAS IN ONLY ONE OF TWO.
#
# `writable_by` was enforced in lazysite-data.pl - the app-user data endpoint -
# and NOT on the control-API `data-row-save`, which carried the capability gate
# (manage_data OR write_data) and nothing else. The edge agent measured the
# consequence with a write_data-only partner token: it wrote a table naming a
# group it was not in, a table with an explicitly empty list, and a table with
# no list at all. Three cases that must refuse, all wrote.
#
# That makes write_data an instance-wide table write on that surface, which is
# exactly the grant it exists to avoid - the comment in lazysite-data.pl says so
# in those words, on the branch that was never reached.
#
# SM578 is the standing warning and it applies verbatim: four package verbs each
# carried their own copy of one rule and two were missed. So the rule lives HERE
# and both surfaces ask it, rather than each holding its own copy of a table
# that must agree.
#
#   manage_data + empty list -> writes (historic behaviour, unchanged)
#   manage_data + named list -> writes only if named (narrowing)
#   write_data  + empty list -> REFUSED (an allow-list naming nobody is closed)
#   write_data  + named list -> writes only if named
# The account's REAL groups, for a write-authority decision.
#
# Wrapped here rather than called from the dispatch branch because t/lint/77
# reads each plugin-owned action's branch and requires every module it names to
# consult the plugin's enabled state. Naming Lazysite::Auth::Acl there pulled a
# core module into that set - correctly refused, since Acl has no business
# knowing about the data plugin. The dependency belongs on this side of the
# boundary.
#
# Resolved from the ACCOUNT, not from X-Remote-Groups: that header is the stale
# source (SM268 - ask the store first), and a write-authority decision must not
# be answerable by a header the account no longer justifies.
sub groups_for {
    my ($user) = @_;
    return [] unless defined $user && length $user;
    require Lazysite::Auth::Acl;
    return [ Lazysite::Auth::Acl::groups_for_user($user) ];
}

# Whether a table carries an access rule at all. Keyed through the same
# function the enforcement side uses, so a listing cannot disagree with the
# panel about whether a rule is there.
sub _table_has_acl {
    my ($table) = @_;
    return 0 unless defined $table && length $table;
    my $key = Lazysite::Data::Access::acl_key($table);
    my $a   = eval { load_acls()->{ _acl_norm($key) } };
    return 0 unless ref $a eq 'HASH';

    # An owner, or a named principal. An entry holding neither is not a rule
    # governing anything - and SM635's three states apply here too: no rule at
    # all and a rule naming nobody must not read the same.
    return 1 if length( $a->{owner} // '' );
    return 1 if ref $a->{read} eq 'ARRAY'  && @{ $a->{read} };
    return 1 if ref $a->{write} eq 'ARRAY' && @{ $a->{write} };
    return 0;
}

sub row_write_refusal {
    my ( $table, $caps, $groups ) = @_;
    $caps   = {} unless ref $caps eq 'HASH';
    $groups = [] unless ref $groups eq 'ARRAY';

    my $d = eval { load_table( $DOCROOT, $table ) };
    my $wb
        = ( ref $d eq 'HASH' && $d->{ok} && ref $d->{writable_by} eq 'ARRAY' )
        ? $d->{writable_by}
        : [];

    my %in    = map { $_ => 1 } @{$groups};
    my $named = ( @{$wb} && grep { $in{$_} } @{$wb} ) ? 1 : 0;

    # WHOSE RULE IS THIS? The allow-list is a property of the `write_data`
    # GRANT, so it binds a caller who holds write_data and does not hold
    # manage_data. A caller holding NEITHER reached this action by some other
    # authorisation - the trusted-header path, where _user_caps returns an
    # empty set because there is no account to read - and inventing a
    # restriction for them would refuse callers this rule was never about.
    #
    # My first version tested `!$caps->{manage_data}` alone and did exactly
    # that: three integration suites failed because a trusted-header caller
    # with an empty capability hash was refused as though it were a
    # write_data-only partner.
    if ( !$caps->{manage_data} && $caps->{write_data} ) {
        return undef if $named;
        return {
            ok    => 0,
            kind  => 'forbidden',
            error => @{$wb}
            ? ( "table '$table' is writable by: "
                    . join( ', ', @{$wb} )
                    . ' - this account is in none of them' )
            : ( "table '$table' names no writable_by groups, so a write_data "
                    . 'grant reaches no rows in it. A sysop can add your group '
                    . "to the table's writable_by." ),
        };
    }

    return undef unless @{$wb} && !$named;
    return {
        ok    => 0,
        kind  => 'forbidden',
        error => "table '$table' is writable by: "
            . join( ', ', @{$wb} )
            . ' - this account is in none of them',
    };
}

# SM682: the two halves of "did this save change who may write the rows".
#
# Compared as a normalised STRING rather than as a list, so a reorder is not a
# change - an author moving a name up the list has not altered who may write,
# and refusing that would teach people the check is noise.
sub _wb_key {
    my ($list) = @_;
    return '' unless ref $list eq 'ARRAY';
    return join ',', sort grep { defined && length } @{$list};
}

# What the STORED descriptor says today. undef when there is no such table yet,
# which makes a first save unconstrained - there is nothing to widen.
sub writable_by_of {
    my ($table) = @_;
    return undef unless defined $table && length $table;
    my $d = eval { load_table( $DOCROOT, $table ) };
    return undef unless ref $d eq 'HASH' && $d->{ok};
    return _wb_key( $d->{writable_by} );
}

# What the INCOMING descriptor text says. Parsed with the SAME loader the save
# itself uses - YAML::PP->load_string - so this cannot disagree with what gets
# stored. A hand-rolled scan of the YAML could, and any difference between the
# two readings would be a way past the check.
#
# undef when the text is absent or unparseable: there is then no change to
# assess, and the save's own parser will reject it a moment later with a better
# message than this could give.
sub writable_by_in {
    my ($text) = @_;
    return undef unless defined $text && length $text;
    return undef unless eval { require YAML::PP; 1 };
    my $raw = eval { YAML::PP->new->load_string($text) };
    return undef unless ref $raw eq 'HASH';
    return _wb_key( $raw->{writable_by} );
}

# The tables this site declares, with the title each descriptor carries.
#
# Reports a table whose descriptor is BROKEN rather than omitting it. An
# author who has just mis-typed a descriptor is the most likely reader of this
# list, and a silently shorter list is the least useful thing it could do.
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
        # SM593: a confined caller is not told the names of another domain's
        # tables. Filtered rather than refused, because a listing that refused
        # would still say how many there are.
        next unless _may_reach($name);
        my $d = load_table( $DOCROOT, $name );
        unless ( $d->{ok} ) {
            push @out, { table => $name, ok => 0, error => $d->{error} };
            next;
        }

        my $pending = _schema_pending( $dbh, $name );
        my $rows    = _row_count( $dbh, $d->{desc} // $d, $pending );

        push @out,
            { table => $name,
            title => $d->{title},
            # SM679: absent rather than 0 when it could not be counted.
            ( defined $rows ? ( row_count => $rows ) : () ),
            # SM593 follow-up: part-way through the migration, "which of my
            # tables are bound, and to what" was answerable only by fetching
            # every descriptor's source one at a time.
            ( length( $d->{domain} // '' ) ? ( domain => $d->{domain} ) : () ),
            public => ( $d->{public} ? JSON::PP::true : JSON::PP::false ),

            # SM678 remainder: DOES THIS TABLE HAVE AN ACCESS RULE?
            #
            # The rule was settable and invisible until SM687 gave it a panel,
            # and the panel answers only once opened - so an operator with a
            # dozen tables opened a dozen panels to learn which were governed.
            # SM635 made the same argument for a protected file row: say it
            # where the operator is looking.
            #
            # A BOOLEAN, not the rule. Who may read a table is the rule's own
            # business and reading it is gated on manage_content; whether one
            # EXISTS is what a listing needs to answer, and it discloses
            # nothing a manage_data holder could not learn by opening the
            # panel they can already open.
            has_acl => ( _table_has_acl($name) ? JSON::PP::true : JSON::PP::false ),
            ( $pending ? ( pending_schema => JSON::PP::true ) : () ),
            ok => 1,
            };
    }
    return { ok => 1, tables => \@out };
}

# One table's declared shape, as the manager and an agent both need it: the
# fields, their types, and what is required.
sub action_data_table {
    my ($table) = @_;
    if ( my $bad = _table_action($table) ) { return $bad }
    my $d = load_table( $DOCROOT, $table );
    return $d unless $d->{ok};
    # SM489 (minor): the SAME two facts the listing carries. data-tables said
    # public and pending_schema per table and data-table said neither, so the
    # reply for a published and an unpublished table was identical - and
    # data-table is what somebody inspecting ONE table reaches for when asking
    # why a page is empty. Derived the same way, per D2.
    my $pending =
        _schema_pending( Lazysite::Data::Connect::read_handle($DOCROOT), $table );
    return {
        # SM468: the shape's own history - who changed it, when, and what
        # happened - read from the store table that travels with the data.
        history =>
            Lazysite::Data::Tables::schema_history( $DOCROOT, $table ),
        ok         => 1,
        table      => $d->{table},
        title      => $d->{title},
        key        => $d->{key},
        auto_key   => $d->{auto_key},
        fields     => $d->{fields},
        indexes    => $d->{indexes},
        timestamps => $d->{timestamps},
        public     => ( $d->{public} ? JSON::PP::true : JSON::PP::false ),
        ( length( $d->{domain} // '' ) ? ( domain         => $d->{domain} )   : () ),
        ( $pending                     ? ( pending_schema => JSON::PP::true ) : () ),
    };
}

# DM-5: the descriptor's SOURCE, for an editor. data-table returns the parsed
# shape, which is right for an agent and wrong for a person editing a file -
# their comments, their key order and their spacing are part of what they
# wrote, and a round trip through the parser would throw all three away.
sub action_data_table_source {
    my ($table) = @_;
    if ( my $bad = _table_action($table) )     { return $bad }
    if ( my $bad = _valid_table_name($table) ) { return $bad }
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
    if ( my $bad = _table_action($table) ) { return $bad }

    # The NAME is the filename, so it is validated here rather than trusted -
    # this is the one place a caller chooses a path under a reserved root.
    if ( my $bad = _valid_table_name($table) ) { return $bad }
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

    # SM593 follow-up: A DOMAIN IS CHECKED AGAINST THE ONES THIS INSTANCE
    # SERVES, at save time.
    #
    # The migration asks a sysop to hand-write `domain:` onto every table
    # that names none - a hostname typed by a person, once per descriptor. The
    # parser validates the SHAPE of that string and nothing checked the value,
    # so `shop.exmaple.com` stored with ok:true and produced a table bound to a
    # domain that does not exist: reachable by no confined grant, and
    # indistinguishable from a table that is fine. `domain-add` already checks
    # what it is given; a descriptor naming a domain deserves the same.
    #
    # The refusal NAMES the configured hosts, because the whole failure is a
    # typo and the answer to a typo is the correct spelling.
    if ( length( $d->{domain} // '' ) ) {
        require Lazysite::Manager::Domains;
        # `used only once` otherwise: this file sets that package's docroot and
        # never reads it, which is exactly the shape the warning exists to
        # catch and exactly what is intended here.
        no warnings 'once';    ## no critic (ProhibitNoWarnings)
        local $Lazysite::Manager::Domains::DOCROOT = $DOCROOT;
        my $dl    = eval { Lazysite::Manager::Domains::domains_list() } || {};
        my @hosts = grep { length }
            map { lc( $_->{host} // '' ) } @{ $dl->{domains} || [] };
        unless ( grep { $_ eq lc( $d->{domain} ) } @hosts ) {
            return { ok => 0, kind => 'descriptor', field => 'domain',
                error => "domain '$d->{domain}' is not a domain this instance "
                    . 'serves'
                    . ( @hosts ? ' - configured: ' . join( ', ', sort @hosts ) : '' ) };
        }
    }

    my $dir = descriptor_dir($DOCROOT);
    unless ( -d $dir ) {
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

sub action_data_rows {
    my ( $table, %opt ) = @_;
    if ( my $bad = _table_action($table) ) { return $bad }
    # `as => 'operator'`: every action in this module has already passed the
    # manage_data gate in _gate, so the SM476 read check would be asking a
    # question that is already answered.
    return read_rows( $DOCROOT, $table, as => 'operator', %opt );
}

# DM-5: what a migration WOULD do, with nothing done. The same plan_migration
# apply_schema runs, so the preview and the action cannot disagree - and the
# UI can show "this will add a column and refuse a type change" before an
# operator commits to either.
sub action_data_migrate_plan {
    my ($table) = @_;
    if ( my $bad = _table_action($table) ) { return $bad }
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

# Bring the store into line with the descriptor, as far as is safe.
#
# Returns `blocked` as well as `applied`, and the caller must show both: the
# blocked list is the sysop's account of why their column is not there yet,
# and dropping it would leave them believing the migration succeeded.
sub action_data_migrate {
    my ($table) = @_;
    if ( my $bad = _table_action($table) ) { return $bad }
    my $r = apply_schema( $DOCROOT, $table, actor => $auth_user );
    log_event( 'INFO', $table, 'data schema applied',
        applied => scalar @{ $r->{applied} || [] },
        blocked => scalar @{ $r->{blocked} || [] } )
        if $r->{ok};
    return $r;
}

# DP-5: perform a change apply_schema refuses, once it is confirmed by name.
#
# A SEPARATE ACTION rather than a flag on data-migrate, deliberately. Migrating
# is a routine act an agent performs after editing a descriptor; rewriting a
# table is not, and giving them one name would mean the routine call carried
# the dangerous capability every time it was made.
sub action_data_rebuild {
    my ( $table, $confirm_lost ) = @_;
    if ( my $bad = _table_action($table) ) { return $bad }
    my $r = rebuild_table( $DOCROOT, $table, actor => $auth_user,
        confirm_lost => ( ref $confirm_lost eq 'ARRAY' ? $confirm_lost : [] ) );
    log_event( 'INFO', $table, 'data table rebuilt',
        lost => join( ',', @{ $r->{lost} || [] } ) )
        if $r->{ok};
    return $r;
}

# One entry point for insert AND update, because the caller knows which it
# means by whether it has a key - and a surface that has to choose between two
# action names for "save this row" will eventually choose wrong.
sub action_data_row_save {
    my ( $table, $key, $values ) = @_;
    if ( my $bad = _table_action($table) ) { return $bad }
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
    my ( $table, $key ) = @_;
    if ( my $bad = _table_action($table) ) { return $bad }
    return { ok => 0, error => 'row key required' }
        unless defined $key && length $key;
    my $r = delete_row( $DOCROOT, $table, $key );
    log_event( 'INFO', $table, 'data row deleted' ) if $r->{ok};
    return $r;
}

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
    my ( $table, $format ) = @_;
    if ( my $bad = _table_action($table) ) { return $bad }

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

# DM-4: a CSV import, staged. `apply` false plans and writes nothing; true
# commits in one transaction. Both parse the same file the same way, so what
# the sysop was shown is what is applied - or refused again, if the store
# moved in between.
sub action_data_import {
    my ( $table, $body, $content_type, $apply ) = @_;
    if ( my $bad = _table_action($table) ) { return $bad }

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
    my ( $table, $confirm ) = @_;
    if ( my $bad = _table_action($table) ) { return $bad }

    my $r = drop_table( $DOCROOT, $table, actor => $auth_user, confirm => $confirm );
    log_event( 'INFO', $table, 'data table dropped',
        rows   => ( $r->{rows_dropped}  // 0 ),
        export => ( $r->{safety_export} // '' ) )
        if $r->{ok};
    return $r;
}

# SM512: the safety exports a drop or a rebuild writes, listed and cleared.
# They live under lazysite/db/rebuilds/, denied to every write channel -
# correctly - which made each one permanent until a sysop's filesystem
# trip. The name is validated to the EXACT shape the engine mints, so no
# path separator can reach the unlink.
my $EXPORT_NAME = qr/\A([a-z][a-z0-9_]*)-(dropped-)?(\d{8}T\d{6}Z)\.json\z/;

# The name, checked and taken apart: ( $entry, undef ) or ( undef, $refusal ).
# The parts are NAMED here rather than read from $1..$3 at the point of use,
# where a -f test and an unlink sit between the match and the read.
sub _export_path {
    my ($file) = @_;
    return ( undef, { ok => 0, error => 'file required - the export name as '
                . 'data-safety-exports reports it' } )
        unless defined $file && length $file;
    return ( undef,
        { ok => 0, error => "'$file' is not a safety export name", kind => 'name' } )
        unless $file =~ $EXPORT_NAME;
    my ( $table, $dropped, $stamp ) = ( $1, $2, $3 );
    my $abs = "$DOCROOT/lazysite/db/rebuilds/$file";
    return ( undef, { ok => 0, error => 'no such safety export', kind => 'not-found' } )
        unless -f $abs;
    return ( { abs => $abs, table => $table, dropped => $dropped, stamp => $stamp },
        undef );
}

sub action_data_safety_exports {
    if ( my $off = _gate() ) { return $off }
    my $dir = "$DOCROOT/lazysite/db/rebuilds";
    my @out;
    if ( opendir my $dh, $dir ) {
        for my $f ( readdir $dh ) {
            next unless $f =~ $EXPORT_NAME;
            my ( $table, $dropped, $stamp ) = ( $1, $2, $3 );
            my @st = stat "$dir/$f";

            # SM514: a summary, so an export can be judged without opening
            # it - the row count and a sample of keys.
            my ( $rows, $keys ) = ( undef, [] );
            if ( my $data = _read_export_file("$dir/$f") ) {
                my $k = $data->{key} // '';
                my @r = @{ $data->{rows} || [] };
                $rows = scalar @r;
                my @ks = map { $_->{$k} } grep { ref $_ eq 'HASH' && defined $_->{$k} } @r;
                $keys = @ks > 4 ? [ @ks[ 0 .. 2 ], '...', $ks[-1] ] : \@ks;
            }
            push @out,
                { file => $f,
                table => $table,
                kind  => ( $dropped ? 'dropped' : 'rebuild' ),
                stamp => $stamp,
                size  => $st[7] // 0,
                mtime => $st[9] // 0,
                ( defined $rows ? ( rows => $rows, keys => $keys ) : () ),
                };
        }
        closedir $dh;
    }
    @out = sort { $b->{mtime} <=> $a->{mtime} || $a->{file} cmp $b->{file} } @out;
    return { ok => 1, dir => 'lazysite/db/rebuilds', exports => \@out,
        count => scalar @out };
}

sub action_data_safety_export_delete {
    my ($file) = @_;
    if ( my $off = _gate() ) { return $off }
    my ( $e, $bad ) = _export_path($file);
    return $bad if $bad;
    unlink $e->{abs}
        or return { ok => 0, error => "could not remove the export: $!" };
    log_event( 'INFO', $e->{table}, 'safety export removed', file => $file,
        actor => $auth_user );
    return { ok => 1, file => $file, deleted => 1 };
}

sub _read_export_file {
    my ($abs) = @_;
    open my $fh, '<:utf8', $abs or return undef;
    my $text = do { local $/; <$fh> };
    close $fh;
    my $data = eval { JSON::PP->new->decode($text) };
    return ( ref $data eq 'HASH' && defined $data->{lazysite_data} ) ? $data : undef;
}

# SM514: the read. "When a store gains a delete, check it has a read" - the
# briefs store had one before its delete, and that third verb is why an
# orphaned brief could be read and copied before it was cleared; an export
# could only be listed and destroyed.
sub action_data_safety_export_read {
    my ($file) = @_;
    if ( my $off = _gate() ) { return $off }
    my ( $e, $bad ) = _export_path($file);
    return $bad if $bad;
    my $data = _read_export_file( $e->{abs} )
        or return { ok => 0, error => 'the export is not a readable lazysite data export' };
    return { ok => 1, file => $file, table => $e->{table},
        kind      => ( $e->{dropped} ? 'dropped' : 'rebuild' ),
        stamp     => $e->{stamp},
        key       => $data->{key},
        fields    => $data->{fields},
        rows      => $data->{rows} || [],
        row_count => scalar @{ $data->{rows} || [] },
    };
}

# SM514: the offer-back. The rows go back to the table they came from
# through import_rows - the same plan-then-apply, the same coercion as a
# live write. Columns the table still has are restored; columns it no
# longer has are REPORTED, not refused: a lossy rebuild export is lossy by
# definition, and the way to recover those columns is to re-declare them
# and restore again. A drop export needs its table re-declared first.
sub action_data_safety_export_restore {
    my ( $file, $apply ) = @_;
    # BPO-3: gated once. Reading through action_data_safety_export_read asked
    # the same gate a second time; the checks and their order are unchanged.
    if ( my $off = _gate() ) { return $off }
    my ( $e, $bad ) = _export_path($file);
    return $bad if $bad;
    my $data = _read_export_file( $e->{abs} )
        or return { ok => 0, error => 'the export is not a readable lazysite data export' };
    my $d = load_table( $DOCROOT, $e->{table} );
    return { ok => 0, kind => 'no_such_table',
        error => "table '$e->{table}' is not declared - re-declare it (and "
            . 'migrate) before restoring its export into it' }
        unless $d->{ok};
    my %known = map { $_ => 1 } keys %{ $d->{fields} };
    $known{ $d->{key} } = 1;
    my @export_cols = sort keys %{ $data->{fields} || {} };
    push @export_cols, $data->{key}
        if defined $data->{key} && !grep { $_ eq $data->{key} } @export_cols;
    my @header = grep { $known{$_} } @export_cols;
    my @gone   = grep { !$known{$_} } @export_cols;
    return { ok => 0, error => "none of the export's columns exist in the "
            . "table '$e->{table}' any more; re-declare them first",
        not_restored_columns => \@gone }
        unless @header;
    my @rows = map {
        my $row = $_;
        [ map { ref $row->{$_} ? ( $row->{$_} ? 1 : 0 ) : $row->{$_} } @header ]
    } grep { ref $_ eq 'HASH' } @{ $data->{rows} || [] };
    my $res = import_rows( $DOCROOT, $e->{table}, \@header, \@rows,
        apply => ( $apply ? 1 : 0 ) );
    $res->{file}                 = $file;
    $res->{restored_columns}     = \@header;
    $res->{not_restored_columns} = \@gone if @gone;
    log_event( 'INFO', $e->{table}, 'safety export restored',
        file  => $file, inserts => $res->{inserts}, updates => $res->{updates},
        actor => $auth_user )
        if $res->{ok} && $res->{applied};
    return $res;
}

1;
