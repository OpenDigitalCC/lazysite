package Lazysite::Handlers;

# SM842: ONE WAY TO DELIVER.
#
# A handler is a named, reusable function that takes a flat set of fields and
# delivers it somewhere: an email, a file, a row in a data table, or a call
# through a connector. A form calls handlers by name; the timer calls handlers
# by name. There is no second way to say where data goes.
#
# WHAT THIS REPLACES, and why it was debt rather than variety:
#
#   * THREE PARSERS of lazysite/forms/handlers.conf - the submission path, the
#     manager module and the MCP server - and they disagreed. The MCP one read
#     an absent `enabled` as FALSE while delivery read it as TRUE, so a handler
#     an agent was told was off took every submission.
#   * INLINE TARGETS in a form's own config (`- type: webhook` with a url), a
#     second way to name a destination that no operator vetted and no listing
#     showed. Converted into named handlers once, on upgrade, and not read
#     after that.
#   * WEBHOOK AND API HANDLERS, an outbound HTTP path with no credential, no
#     modes, no rate cap and no call record, beside connectors, which have all
#     four (SM579). Outbound HTTP now goes through a connector and nowhere
#     else; a connector with only a URL is the simple case.
#   * THE CONNECTOR'S OWN TIMER (schedule_every), a schedule that could call one
#     kind of thing. The schedule below calls any handler.
#   * `db` BESIDE `table`, two types for one destination that differed by
#     whether a copy was kept. One type, `table`, with keep_copy.
#
# THE DESTINATION DECIDES WHO MAY CONFIGURE IT (the release manager,
# 2026-09-11). Creating or editing a handler needs the capability that governs
# where it sends: a table handler writes rows, so it needs manage_data; a
# connector handler sends data off the site, so manage_connectors; email and
# file delivery are the form owner's own business, so manage_forms. Binding a
# form to a handler that already exists needs manage_forms and nothing else -
# the vetting happened when the handler was made. Delivery itself checks
# nothing: a visitor submitting a form, or the timer at 03:00, runs a function
# somebody with the right grant already wrote.
#
# THE STORE. handlers.conf and schedule.conf live beside the forms they serve
# in lazysite/forms/, and the SM766 rule applies to both: a file that exists
# and cannot be opened is not an empty file. Every reader answers undef for
# "cannot tell", and every write refuses to land on something it could not
# read - SM785 lost every account's settings to exactly that shape, and a
# handler save over an unreadable handlers.conf would have replaced every
# handler with one.
use strict;
use warnings;
use JSON::PP        ();
use File::Path      qw(make_path);
use File::Basename  qw(dirname);
use POSIX           qw(strftime);
use Fcntl           qw(:flock);
use Lazysite::Util  qw(log_event cannot_read);
use Lazysite::Paths ();

our $VERSION = '1.0';
our $DOCROOT = '';

# --- the catalogue -----------------------------------------------------------
#
# Every handler carries id, type, name and enabled. What else it carries is its
# type's schema, and nothing else: a key the schema does not declare is refused
# at save by name, never kept and ignored (SM772 found a required key dropped
# with ok:true; the converse, a key accepted and never read, is the same fault).
#
# `cap` is the destination's capability - the one gate for creating, editing,
# deleting and scheduling a handler of the type, and the one the timer's job
# account must hold to run it.
#
# Field types: text, email, boolean, and two that name something the engine
# already knows - `table` (a declared data table) and `connector` (a configured
# connector). Those are chosen from a list on every surface that draws a form,
# never typed (SM806).
our @TYPE_ORDER = qw(smtp file table connector);
our %TYPES      = (
    smtp => {
        label  => 'Send email',
        cap    => 'manage_forms',
        schema => [
            { key => 'from', label => 'From address', type => 'email', required => 1 },
            { key => 'to',   label => 'To address',   type => 'email', required => 1 },
            { key => 'subject_prefix', label => 'Subject prefix', type => 'text',
                default => '[Contact] ' },
            { key => 'attach_files', label => 'Attach uploaded files', type => 'boolean',
                default => 'false',
                note => 'Files uploaded with a form are attached and listed (name and size) '
                    . 'below the message. Mind the mail server\'s attachment limits.' },
        ],
        note => 'How mail leaves the site - sendmail or an SMTP server - is the Form SMTP '
            . 'extension\'s configuration, shared by every email handler.',
    },
    file => {
        label  => 'Save to file',
        cap    => 'manage_forms',
        schema => [
            { key => 'path', label => 'Storage directory', type => 'text',
                default => 'lazysite/forms/submissions',
                note    => 'Relative to the site. Each form (or schedule entry) writes '
                    . '<name>.jsonl inside it; the Submissions page reads it.' },
        ],
    },
    table => {
        label  => 'Store in a data table',
        cap    => 'manage_data',
        schema => [
            { key => 'table', label => 'Table', type => 'table', required => 1 },
            { key => 'fields', label => 'Field mapping', type => 'text', required => 1,
                note => 'field=column, comma separated. It is what keeps a visitor from '
                    . 'choosing where their data goes: a field nobody maps is dropped, so a '
                    . 'form gaining a field cannot start writing a column.' },
            { key => 'keep_copy', label => 'Keep a submissions copy', type => 'boolean',
                default => 'true',
                note => 'Also keep each submission in lazysite/forms/submissions, so the '
                    . 'Submissions page, exports and bulk delete work. A row the table '
                    . 'refuses is kept there and marked as refused.' },
        ],
        note => 'Needs the Data tables extension to be enabled. Values are checked against '
            . 'the table\'s declared types: a submission that does not fit is refused, and '
            . 'the visitor is told, rather than stored wrong.',
    },
    connector => {
        label  => 'Send through a connector',
        cap    => 'manage_connectors',
        schema => [
            { key => 'connector', label => 'Connector', type => 'connector', required => 1,
                note => 'A form can use it only if the connector permits public '
                    . 'invocation; the schedule only if it permits scheduled invocation.' },
        ],
        note => 'Everything that leaves the site over HTTP goes through a connector. A '
            . 'connector with only a URL is the simple case.',
    },
);

# Form names a form may not take, because the file beside it is not a form.
our %RESERVED_FORM = map { $_ => 1 } qw(handlers smtp schedule);

# The schedule's floor, in seconds: the scheduler ticks its job every 300s, and
# an entry asking for less would be told it ran every minute while it did not.
our $SCHEDULE_FLOOR = 300;

sub is_reserved_form { return $RESERVED_FORM{ $_[0] // '' } ? 1 : 0 }

sub types { return [ map { { type => $_, %{ $TYPES{$_} } } } @TYPE_ORDER ] }

sub cap_for_type {
    my ($type) = @_;
    return undef unless defined $type && $TYPES{$type};
    return $TYPES{$type}{cap};
}

# The capabilities that admit a caller to the handler actions at all. The
# destination then decides; this is only the door.
sub door_caps { my %s; return [ grep { !$s{$_}++ } map { $TYPES{$_}{cap} } @TYPE_ORDER ] }

sub valid_id { return defined $_[0] && $_[0] =~ /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/ }

sub enabled {
    my ($h) = @_;
    return ( ( $h->{enabled} // 'true' ) =~ /\A\s*(?:false|no|off|0)\s*\z/i ) ? 0 : 1;
}

# --- where things are --------------------------------------------------------

sub _lz {
    my $lz = Lazysite::Paths::lazysite_dir($DOCROOT);
    return ( defined $lz && length $lz ) ? $lz : undef;
}
sub forms_dir     { my $lz = _lz();       return defined $lz ? "$lz/forms"       : undef }
sub handlers_file { my $d  = forms_dir(); return defined $d ? "$d/handlers.conf" : undef }
sub schedule_file { my $d  = forms_dir(); return defined $d ? "$d/schedule.conf" : undef }
sub form_file     { my $d  = forms_dir(); return defined $d ? "$d/$_[0].conf"    : undef }

# Where a file handler's store is. A path under lazysite/ is in the ENGINE tree,
# which is not always inside the docroot (SM293 moves it beside it); an absolute
# path is an operator's own choice on a shell and is taken as written.
#
# Anything else is in the SITE's tree, and is resolved as every other write to
# that tree is (SM852): a store inside a protected section is in the private
# store, with its section. Built as "$DOCROOT/$r", the next submission made a
# public copy of the gated folder and appended the visitor's data there - and a
# public folder at a gated path then pulled every later write under it out of
# the store too. The readers call this as well, so they find what was written.
sub store_path {
    my ($rel) = @_;
    $rel = 'lazysite/forms/submissions' unless defined $rel && length $rel;
    return $rel if $rel =~ m{\A/};
    ( my $r = $rel ) =~ s{/+\z}{};
    if ( $r =~ m{\Alazysite(?:/(.*))?\z} ) {
        my $tail = $1;
        my $lz   = _lz() // return undef;    # no docroot: nowhere to put it
        return defined $tail && length $tail ? "$lz/$tail" : $lz;
    }
    require Lazysite::Private;
    my ($abs) = Lazysite::Private::resolve_for_write( $DOCROOT, $r );
    return $abs // "$DOCROOT/$r";
}

# SM855: WHERE THIS FORM'S SUBMISSIONS ARE - one answer, for every reader.
#
# A form's store is not "the default directory": it is the path of the file
# handler the form is bound to, and that handler may name its own (`path:`). The
# control API's form-list worked this out inline, and MCP's read_form_submissions
# did not - it built "lazysite/forms/submissions/<form>.jsonl" and answered
# `ok: true, total: 0` for a store it had not looked at, naming a file that was
# not the store. The site agent found it with a row sitting in the real one.
#
# Returns the absolute .jsonl path, or undef when there is no docroot to resolve
# against. A form with no file handler has no store, and that is said by
# returning the DEFAULT location, which the caller then finds absent - the same
# answer as a form that has simply had no submissions.
# The store DIRECTORY as configured - relative, as handlers.conf writes it.
# Readers that confine a path (the submissions readers check it against the
# configured stores) need the relative form; form_store_file below resolves it.
sub form_store_dir {
    my ($form) = @_;
    my $dir = 'lazysite/forms/submissions';
    return $dir unless defined $form && length $form;
    my $fc = form_file($form);
    if ( defined $fc && -f $fc ) {
        my $text = _slurp( $fc, "form $form" );
        if ( defined $text ) {
            my ($ids) = parse_form_conf($text);
            my $list = read_handlers() || [];
            for my $id ( @{ $ids || [] } ) {
                my $h = find_handler( $list, $id ) or next;
                next unless ( $h->{type} // 'file' ) eq 'file';
                $dir = $h->{path} if defined $h->{path} && length $h->{path};
                last;
            }
        }
    }
    return $dir;
}

sub form_store_file {
    my ($form) = @_;
    return undef unless defined $form && length $form;
    my $abs = store_path( form_store_dir($form) ) // return undef;
    return "$abs/$form.jsonl";
}

# --- the one parser ----------------------------------------------------------
#
# The file shape is the one sysops have always hand-written, so it is read
# leniently about indentation and strictly about everything else:
#
#   handlers:
#     - id: enquiries
#       type: table
#       table: enquiries
#
# A record starts at a list item naming `id:`; every indented `key: value` after
# it belongs to it. An empty value is an absent key. Comments are skipped.
sub parse_records {
    my ($text) = @_;
    my ( @out, $cur );
    for my $line ( split /\r?\n/, ( $text // '' ) ) {
        next if $line =~ /\A\s*(?:#|\z)/;
        if ( $line =~ /\A[ \t]*-[ \t]+id[ \t]*:[ \t]*(\S+)[ \t]*\z/ ) {
            $cur = { id => $1 };
            push @out, $cur;
            next;
        }
        if ( $cur && $line =~ /\A[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*:[ \t]*(.*?)[ \t]*\z/ ) {
            $cur->{$1} = $2 if length $2;
            next;
        }
        undef $cur if $line =~ /\A\S/;    # a new top-level key ends the list
    }
    return \@out;
}

sub render_records {
    my ( $top, $records, $head ) = @_;
    my $out = $head // '';
    $out .= "$top:\n";
    for my $r (@$records) {
        $out .= "  - id: $r->{id}\n";
        for my $k ( _key_order($r) ) {
            my $v = $r->{$k};
            next unless defined $v && length $v;
            $out .= "    $k: $v\n";
        }
    }
    return $out;
}

sub _key_order {
    my ($r)   = @_;
    my @first = grep { exists $r->{$_} } qw(type name enabled handler every);
    my %f     = map  { $_ => 1 } @first, 'id';
    return ( @first, sort grep { !$f{$_} } keys %$r );
}

# Read a file the SM766 way: absent is empty (''), unopenable is undef.
sub _slurp {
    my ( $path, $what ) = @_;
    return undef unless defined $path;
    open my $fh, '<:utf8', $path or return $!{ENOENT} ? '' : cannot_read( $what, $path );
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t // '';
}

# Temp and rename, the existing mode carried across; a new file is group
# writable, because the manager (the web server's user) and the CLI (the site
# owner) both write it.
sub _write_text {
    my ( $path, $text ) = @_;
    return ( 0, 'no docroot: nowhere to write' ) unless defined $path;
    my $dir = dirname($path);
    make_path($dir) unless -d $dir;
    my $tmp = "$path.tmp.$$";
    open my $fh, '>:utf8', $tmp or return ( 0, _cannot_write($path) );
    my $ok = print {$fh} $text;
    unless ( close($fh) && $ok ) { unlink $tmp; return ( 0, _cannot_write($path) ) }
    my @st = stat $path;
    chmod( ( @st ? $st[2] & 07777 : 0664 ), $tmp );
    unless ( rename $tmp, $path ) { unlink $tmp; return ( 0, _cannot_write($path) ) }
    return ( 1, '' );
}

sub _cannot_write {
    my ($path) = @_;
    my $err    = "$!";
    my ($who)  = getpwuid($>);
    ( my $leaf = $path ) =~ s{.*/}{};
    return "cannot write forms/$leaf: $err (unix user " . ( $who // $> ) . ')';
}

sub _unreadable {
    my ($leaf) = @_;
    my ($who)  = getpwuid($>);
    return "forms/$leaf exists but cannot be opened by this process (unix user "
        . ( $who // $> ) . ') - see the event log';
}

# --- handlers ----------------------------------------------------------------

# Every handler, in file order. undef when the file exists and cannot be read.
sub read_handlers {
    my $path = handlers_file();
    unless ( defined $path ) {
        log_event( 'WARN', 'handlers', 'no docroot: cannot locate handlers.conf' );
        return undef;
    }
    my $text = _slurp( $path, 'handlers.conf' );
    return undef unless defined $text;
    return parse_records($text);
}

sub write_handlers {
    my ($list) = @_;
    return _write_text( handlers_file(),
        render_records( 'handlers', $list,
            "# Delivery handlers - named functions a form or the schedule calls.\n"
                . "# Written by the manager, the control API, MCP and lazysite-handlers.pl.\n\n" ) );
}

sub find_handler {
    my ( $list, $id ) = @_;
    my ($h) = grep { defined $_->{id} && $_->{id} eq $id } @{ $list || [] };
    return $h;
}

# --- form bindings -----------------------------------------------------------
#
# A form's config is lazysite/forms/<form>.conf. Its `targets:` list names
# handlers and nothing else:
#
#   targets:
#     - handler: enquiries
#
# The other keys in the file (upload limits, rate_limit, quarantine and the
# rest) belong to the submission path and are carried through a rewrite
# untouched - bind_form used to rewrite the whole file with one target and
# dropped them.

sub valid_form_name {
    my ($f) = @_;
    return defined $f && $f =~ /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/ && !$RESERVED_FORM{$f};
}

# ( \@handler_ids, \@inline_entries, \@other_lines ). An inline entry is any
# list item under targets: that is not `handler: <id>` - read so a check can
# report it and the conversion can convert it, and never delivered.
sub parse_form_conf {
    my ($text) = @_;
    my ( @ids, @inline, @other );
    my ( $in_targets, $cur ) = ( 0, undef );
    for my $line ( split /\r?\n/, ( $text // '' ) ) {
        if ( $line =~ /\Atargets[ \t]*:[ \t]*\z/ ) { $in_targets = 1; undef $cur; next }
        if ($in_targets) {
            if ( $line =~ /\A[ \t]*-[ \t]+handler[ \t]*:[ \t]*(\S+)[ \t]*\z/ ) {
                push @ids, $1;
                undef $cur;
                next;
            }
            if ( $line =~ /\A[ \t]*-[ \t]+([A-Za-z_]\w*)[ \t]*:[ \t]*(.*?)[ \t]*\z/ ) {
                $cur = { $1 => $2 };
                push @inline, $cur;
                next;
            }
            if ( $line =~ /\A[ \t]+([A-Za-z_]\w*)[ \t]*:[ \t]*(.*?)[ \t]*\z/ && $cur ) {
                $cur->{$1} = $2;
                next;
            }
            next            if $line =~ /\A\s*\z/;
            $in_targets = 0 if $line =~ /\A\S/;
            next            if $in_targets;
        }
        push @other, $line;
    }
    return ( \@ids, \@inline, \@other );
}

sub render_form_conf {
    my ( $ids, $other ) = @_;
    my $out = "targets:\n";
    $out .= "  - handler: $_\n" for @$ids;
    my @rest = @{ $other || [] };
    shift @rest while @rest && $rest[0] =~ /\A\s*\z/;
    $out .= join( "\n", @rest ) . "\n" if @rest;
    return $out;
}

# The names of every configured form. undef when the directory cannot be read.
sub form_names {
    my $dir = forms_dir() // return undef;
    opendir my $dh, $dir or return $!{ENOENT} ? [] : cannot_read( 'the forms directory', $dir );
    my @n = sort grep { valid_form_name($_) } map { /\A(.+)\.conf\z/ ? $1 : () } readdir $dh;
    closedir $dh;
    return \@n;
}

# { form => [handler ids] } for every form, or undef when unreadable.
sub bindings {
    my $names = form_names() // return undef;
    my %b;
    for my $f (@$names) {
        my $t = _slurp( form_file($f), "forms/$f.conf" );
        return undef unless defined $t;
        my ($ids) = parse_form_conf($t);
        $b{$f} = $ids;
    }
    return \%b;
}

# What is wrong with a form config's text, as sentences - [] when nothing is.
# The WebDAV surface refuses a PUT that has any, so a hand-written config meets
# the same rules as one the binding actions write.
sub form_conf_problems {
    my ($text) = @_;
    my ( $ids, $inline ) = parse_form_conf($text);
    my @p;
    for my $e (@$inline) {
        my ($k) = keys %$e;
        push @p, "targets: '- $k: ...' is not a handler reference - a form's targets name "
            . 'handlers only (- handler: <id>); create the handler first';
    }
    my $all = read_handlers();
    if ( defined $all ) {
        for my $id (@$ids) {
            push @p, "targets: no handler '$id' - the configured handlers are: "
                . ( join( ', ', map { $_->{id} } @$all ) || 'none' )
                unless find_handler( $all, $id );
        }
    }
    return \@p;
}

# --- the schedule ------------------------------------------------------------
#
#   schedule:
#     - id: nightly-export
#       handler: crm
#       every: 86400
#       enabled: true
#       payload: {"source":"timer"}
#
# `payload` is a flat JSON object on one line: the fields the handler is
# called with, fixed in configuration, so nothing a visitor sends ever reaches
# a scheduled call.

sub read_schedule {
    my $path = schedule_file();
    unless ( defined $path ) {
        log_event( 'WARN', 'handlers', 'no docroot: cannot locate schedule.conf' );
        return undef;
    }
    my $text = _slurp( $path, 'schedule.conf' );
    return undef unless defined $text;
    my $list = parse_records($text);
    for my $e (@$list) {
        my $raw = $e->{payload};
        my $p = ( defined $raw && length $raw ) ? eval { JSON::PP::decode_json($raw) } : {};
        if ( ref $p eq 'HASH' ) { $e->{payload} = $p }
        else {
            $e->{payload} = {};
            $e->{invalid} = 'payload is not a JSON object';
        }
    }
    return $list;
}

sub write_schedule {
    my ($list) = @_;
    my @rows = map {
        my %r = %$_;
        delete $r{invalid};
        $r{payload} = JSON::PP->new->canonical->encode( $r{payload} || {} );
        \%r;
    } @$list;
    return _write_text( schedule_file(),
        render_records( 'schedule', \@rows,
            "# The schedule - which handler the timer calls, how often, with what.\n\n" ) );
}

# --- who uses what -----------------------------------------------------------

sub used_by {
    my ( $id, $bindings, $schedule ) = @_;
    return {
        forms => [ sort grep { grep { $_ eq $id } @{ $bindings->{$_} } } keys %{ $bindings || {} } ],
        schedule => [ map { $_->{id} } grep { ( $_->{handler} // '' ) eq $id } @{ $schedule || [] } ],
    };
}

# --- authority ---------------------------------------------------------------
#
# $who is { caps => {...} } for a caller the capability model governs, or
# { unconstrained => 1 } for the shell, which is the operator (the users tool
# and the ACL tool act the same way). Returns '' when allowed, else the sentence.
sub _may {
    my ( $who, $cap, $what ) = @_;
    return '' if $who->{unconstrained};
    return '' if defined $cap && ( $who->{caps} || {} )->{$cap};
    return "$what needs the '$cap' permission - the destination decides who may configure "
        . 'it. An administrator can grant it on the Groups page.';
}

# --- validation --------------------------------------------------------------

sub _declared_tables {
    my @t = eval {
        require Lazysite::Data::Tables;
        @{ Lazysite::Data::Tables::list_tables($DOCROOT) || [] };
    };
    return \@t;
}

sub _connector_store {
    my $all = eval {
        require Lazysite::Manager::Connectors;
        no warnings 'once';
        local $Lazysite::Manager::Connectors::DOCROOT = $DOCROOT;
        Lazysite::Manager::Connectors::connectors();
    };
    return $all;    # undef: cannot tell
}

sub _check_path {
    my ($p) = @_;
    return 'path must be relative to the site'        if $p =~ m{\A/};
    return 'path must not step outside the site (..)' if $p =~ m{(?:\A|/)\.\.(?:/|\z)};
    return 'path must not contain a newline'          if $p =~ /[\r\n]/;
    require Lazysite::Manager::Common;
    ( my $n = $p ) =~ s{/+\z}{};
    return "path '$p' is in an engine-owned area - a store may be under lazysite/forms/ or "
        . 'in the site\'s own tree'
        if Lazysite::Manager::Common::path_is_reserved($n)
        && $n !~ m{\Alazysite/forms(?:/|\z)};
    return '';
}

# The field mapping, parsed. ( \%form_to_column, '' ) or ( undef, why ).
sub parse_fields {
    my ($map) = @_;
    my %m;
    for my $pair ( split /\s*,\s*/, ( $map // '' ) ) {
        next unless length $pair;
        my ( $from, $to ) = split /\s*=\s*/, $pair, 2;
        return ( undef, "fields: '$pair' is not field=column" )
            unless defined $to && length $from && length $to;
        return ( undef, "fields: '$to' is not a column name" )
            unless $to =~ /\A[a-z][a-z0-9_]{0,63}\z/;
        return ( undef, "fields: '$from' is not a form field name" )
            unless $from =~ /\A[A-Za-z][A-Za-z0-9_.~-]{0,127}\z/;
        $m{$from} = $to;
    }
    return ( undef, 'fields must map at least one form field to a column' ) unless %m;
    return ( \%m,   '' );
}

# A record, validated against its type. ( \%clean, '' ) or ( undef, why ).
# `field` travels with a refusal so a surface can put the message beside the
# input it is about.
sub validate_handler {
    my ($in) = @_;
    return ( undef, 'a handler is required', 'id' ) unless ref $in eq 'HASH';
    my $id = $in->{id};
    return ( undef, 'id is required', 'id' ) unless defined $id && length $id;
    return ( undef, "id '$id' must be letters, digits, - or _ (at most 64)", 'id' )
        unless valid_id($id);
    my $type = $in->{type};
    return ( undef, 'type is required - one of: ' . join( ', ', @TYPE_ORDER ), 'type' )
        unless defined $type && length $type;
    return ( undef,
        "there is no '$type' handler any more: outbound HTTP goes through a connector (SM842). "
            . 'Create the connector with the URL on the Connectors page, then a handler of type '
            . "'connector' naming it.", 'type' )
        if $type eq 'webhook' || $type eq 'api';
    return ( undef, "there is no 'db' handler any more: use type 'table' with keep_copy: false (SM842)",
        'type' )
        if $type eq 'db';
    my $def = $TYPES{$type}
        or return ( undef, "no handler type '$type' - the types are: " . join( ', ', @TYPE_ORDER ),
        'type' );

    my %declared = map { $_->{key} => $_ } @{ $def->{schema} };
    my @unknown  = sort grep {
        !$declared{$_} && !/\A(?:id|type|name|enabled|csrf_token)\z/
    } keys %$in;
    return ( undef,
        "a $type handler does not take: " . join( ', ', @unknown )
            . '. It takes: name, enabled, ' . join( ', ', map { $_->{key} } @{ $def->{schema} } ),
        $unknown[0] )
        if @unknown;

    my %out  = ( id => $id, type => $type );
    my $name = $in->{name} // '';
    return ( undef, 'name is required', 'name' ) unless length $name;
    return ( undef, 'name must be one line of at most 80 characters', 'name' )
        if $name =~ /[\r\n]/ || length $name > 80;
    $out{name}    = $name;
    $out{enabled} = _bool( $in->{enabled} // 'true' );

    for my $f ( @{ $def->{schema} } ) {
        my $k = $f->{key};
        my $v = $in->{$k};
        $v = "$v" if defined $v && !ref $v;
        return ( undef, "$k must be a single value", $k ) if ref $v;
        if ( !defined $v || !length $v ) {
            if ( defined $f->{default} && length $f->{default} ) { $v = $f->{default} }
            elsif ( $f->{required} ) { return ( undef, "$k is required for a $type handler", $k ) }
            else                     { next }
        }
        return ( undef, "$k must be one line",              $k ) if $v =~ /[\r\n]/;
        return ( undef, "$k is longer than 500 characters", $k ) if length $v > 500;
        if    ( $f->{type} eq 'boolean' ) { $v = _bool($v) }
        elsif ( $f->{type} eq 'email' ) {
            return ( undef, "$k must be an email address", $k ) unless $v =~ /\A[^\s@]+@[^\s@]+\z/;
        }
        elsif ( $f->{type} eq 'table' ) {
            return ( undef, "$k must be a table name", $k ) unless $v =~ /\A[a-z][a-z0-9_]{0,63}\z/;
        }
        elsif ( $f->{type} eq 'connector' ) {
            return ( undef, "$k must be a connector id", $k )
                unless $v =~ /\A[a-z0-9][a-z0-9_-]{0,63}\z/;
        }
        $out{$k} = $v;
    }

    if ( $type eq 'file' ) {
        my $why = _check_path( $out{path} );
        return ( undef, $why, 'path' ) if length $why;
    }
    if ( $type eq 'table' ) {
        my ( $m, $why ) = parse_fields( $out{fields} );
        return ( undef, $why, 'fields' ) unless $m;
    }
    return ( \%out, '' );
}

sub _bool { return ( defined $_[0] && $_[0] =~ /\A\s*(?:false|no|off|0)\s*\z/i ) ? 'false' : 'true' }

# What the destination itself says about the record - checked against the
# live site at save, because saving a mapping that cannot work and failing at
# a visitor's submission is the worst arrangement of the two (SM807). A store
# that cannot be read is NOT a refusal: unvalidated is not invalid.
sub _destination_problem {
    my ($h) = @_;
    if ( $h->{type} eq 'table' ) {
        my $tables = _declared_tables();
        return "table: no table '$h->{table}' is declared - the declared tables are: "
            . ( join( ', ', @$tables ) || 'none' )
            if @$tables && !grep { $_ eq $h->{table} } @$tables;
        my $d = eval {
            require Lazysite::Data::Tables;
            Lazysite::Data::Tables::load_table( $DOCROOT, $h->{table} );
        };
        if ( ref $d eq 'HASH' && $d->{ok} && ref $d->{fields} eq 'HASH' ) {
            my ($m) = parse_fields( $h->{fields} );
            my $key = $d->{key} // 'id';
            my @bad = sort grep { !exists $d->{fields}{$_} && $_ ne $key } values %{ $m || {} };
            return "fields: '$h->{table}' has no "
                . ( @bad > 1 ? 'columns ' : 'column ' )
                . join( ', ', @bad )
                . ' - its columns are: '
                . join( ', ', sort( keys %{ $d->{fields} } ) )
                if @bad;
        }
    }
    if ( $h->{type} eq 'connector' ) {
        my $all = _connector_store();
        return "connector: no connector '$h->{connector}' - the configured connectors are: "
            . ( join( ', ', sort keys %$all ) || 'none' )
            if defined $all && !exists $all->{ $h->{connector} };
    }
    return '';
}

# --- the actions (every surface calls these) ---------------------------------

sub action_handler_list {
    my $all = read_handlers();
    return { ok => 0, error => _unreadable('handlers.conf') } unless defined $all;
    my $b   = bindings()      // {};
    my $s   = read_schedule() // [];
    my @out = map {
        my %h = %$_;
        $h{enabled} = enabled($_) ? JSON::PP::true : JSON::PP::false;
        $h{cap}     = cap_for_type( $h{type} );
        $h{used_by} = used_by( $h{id}, $b, $s );
        $h{problem} = _legacy_problem($_) if length _legacy_problem($_);
        \%h;
    } @$all;
    # Every form and the handlers it calls - the unbound ones included, which
    # used_by cannot show - so a page binding forms needs this one read.
    return { ok => 1, handlers => \@out, types => types(), forms => $b };
}

# A record the conversion has not reached yet, said on the listing so it is
# not a silent non-delivery.
sub _legacy_problem {
    my ($h) = @_;
    my $t = $h->{type} // '';
    return '' if $TYPES{$t};
    return "a '$t' handler no longer delivers - run lazysite-handlers.pl convert (SM842)"
        if $t =~ /\A(?:webhook|api|db)\z/;
    return "unknown type '$t'";
}

sub action_handler_save {
    my ( $in, %who ) = @_;
    my ( $h, $why, $field ) = validate_handler($in);
    return { ok => 0, kind => 'invalid', field => $field, error => $why } unless $h;

    my $all = read_handlers();
    return { ok => 0, error => _unreadable('handlers.conf') . '; nothing was written' }
        unless defined $all;
    my $old = find_handler( $all, $h->{id} );

    # Editing needs authority over what the handler does NOW as well as over
    # what it will do - turning an email handler into a table handler is a
    # change to both destinations.
    my $deny = _may( \%who, cap_for_type( $h->{type} ), "a $h->{type} handler" );
    $deny ||= _may( \%who, cap_for_type( $old->{type} ), "the existing $old->{type} handler '$h->{id}'" )
        if $old && cap_for_type( $old->{type} ) && ( $old->{type} ne $h->{type} );
    return { ok => 0, kind => 'forbidden', error => $deny } if length $deny;

    my $problem = _destination_problem($h);
    return { ok => 0, kind => 'invalid', field => ( $problem =~ /\A(\w+):/ )[0], error => $problem }
        if length $problem;

    if ($old) { %$old = %$h }
    else      { push @$all, $h }
    my ( $ok, $err ) = write_handlers($all);
    return { ok => 0, error => $err } unless $ok;
    log_event( 'INFO', 'handlers', ( $old ? 'handler updated' : 'handler created' ),
        handler => $h->{id}, type => $h->{type} );
    return { ok => 1, id => $h->{id}, handler => $h, created => ( $old ? 0 : 1 ) };
}

sub action_handler_delete {
    my ( $id, %who ) = @_;
    return { ok => 0, kind => 'invalid', field => 'id', error => 'id is required' }
        unless defined $id && length $id;
    my $all = read_handlers();
    return { ok => 0, error => _unreadable('handlers.conf') . '; nothing was deleted' }
        unless defined $all;
    my $h = find_handler( $all, $id )
        or return { ok => 0, kind => 'not-found', error => "no handler '$id'" };
    my $cap  = cap_for_type( $h->{type} ) // 'manage_forms';
    my $deny = _may( \%who, $cap, "deleting a $h->{type} handler" );
    return { ok => 0, kind => 'forbidden', error => $deny } if length $deny;

    # A FUNCTION IN USE IS NOT DELETED. Removing it would leave each form that
    # names it refusing every submission, and each schedule entry failing every
    # interval - both silently until somebody reads the log. Say which.
    my $b = bindings();
    my $s = read_schedule();
    return { ok => 0, error => 'cannot tell whether the handler is in use - a form config or the '
            . 'schedule could not be read; nothing was deleted' }
        unless defined $b && defined $s;
    my $u = used_by( $id, $b, $s );
    if ( @{ $u->{forms} } || @{ $u->{schedule} } ) {
        return { ok => 0, kind => 'in-use', used_by => $u,
            error => "handler '$id' is in use - "
                . join( '; ',
                ( @{ $u->{forms} } ? 'forms: ' . join( ', ', @{ $u->{forms} } ) : () ),
                ( @{ $u->{schedule} } ? 'schedule entries: ' . join( ', ', @{ $u->{schedule} } ) : () ) )
                . '. Unbind or remove those first.' };
    }
    my ( $ok, $err ) = write_handlers( [ grep { $_->{id} ne $id } @$all ] );
    return { ok => 0, error => $err } unless $ok;
    log_event( 'INFO', 'handlers', 'handler deleted', handler => $id );
    return { ok => 1, id => $id, deleted => $id };
}

sub action_form_targets_read {
    my ($form) = @_;
    return { ok => 0, kind => 'invalid', field => 'form', error => 'form is required' }
        unless defined $form && length $form;
    return { ok => 0, kind => 'invalid', field => 'form', error => "invalid form name '$form'" }
        unless valid_form_name($form);
    my $text = _slurp( form_file($form), "forms/$form.conf" );
    return { ok => 0, error => _unreadable("$form.conf") } unless defined $text;
    my ( $ids, $inline ) = parse_form_conf($text);
    return { ok => 1, form => $form, targets => [ map { { handler => $_ } } @$ids ],
        handlers => $ids,
        ( @$inline ? ( problem => 'this form has inline targets that no longer deliver - run '
                    . 'lazysite-handlers.pl convert (SM842)' ) : () ) };
}

# Bind a form to handlers by id, replacing its targets. manage_forms is the
# caller's gate; every id must name a handler that exists, and a connector
# handler must be one a form can use.
sub action_form_targets_save {
    my ( $form, $ids ) = @_;
    return { ok => 0, kind => 'invalid', field => 'form', error => 'form is required' }
        unless defined $form && length $form;
    return { ok => 0, kind => 'invalid', field => 'form',
        error => "invalid form name '$form'"
            . ( $RESERVED_FORM{$form} ? " - $form.conf is not a form" : '' ) }
        unless valid_form_name($form);
    return { ok => 0, kind => 'invalid', field => 'handlers',
        error => 'handlers must be a list of handler ids' }
        unless ref $ids eq 'ARRAY';
    my @want;
    my %seen;
    for my $t (@$ids) {
        my $id = ref $t eq 'HASH' ? $t->{handler} : $t;
        return { ok => 0, kind => 'invalid', field => 'handlers',
            error => 'a target names a handler by id - inline targets were removed in 0.13.13 '
                . '(SM842): create a handler and bind that' }
            if ref $t eq 'HASH' && !defined $t->{handler};
        return { ok => 0, kind => 'invalid', field => 'handlers', error => 'a handler id is empty' }
            unless defined $id && length $id;
        push @want, $id unless $seen{$id}++;
    }

    my $all = read_handlers();
    return { ok => 0, error => _unreadable('handlers.conf') . '; nothing was written' }
        unless defined $all;
    for my $id (@want) {
        my $h = find_handler( $all, $id )
            or return { ok => 0, kind => 'not-found', field => 'handlers',
            error => "no handler '$id' - the configured handlers are: "
                . ( join( ', ', map { $_->{id} } @$all ) || 'none' ) };
        my $p = _form_use_problem($h);
        return { ok => 0, kind => 'invalid', field => 'handlers', error => $p } if length $p;
    }

    my $path = form_file($form);
    my $text = _slurp( $path, "forms/$form.conf" );
    return { ok => 0, error => _unreadable("$form.conf") . '; nothing was written' }
        unless defined $text;
    my ( undef, undef, $other ) = parse_form_conf($text);
    my ( $ok, $err ) = _write_text( $path, render_form_conf( \@want, $other ) );
    return { ok => 0, error => $err } unless $ok;
    log_event( 'INFO', 'handlers', 'form bound', form => $form, handlers => join( ',', @want ) );
    return { ok => 1, form => $form, handlers => \@want, path => "/lazysite/forms/$form.conf" };
}

# Why a form cannot use this handler, or ''. A connector that refuses public
# invocation would refuse every submission, so the binding is refused instead,
# at the moment of the mistake.
sub _form_use_problem {
    my ($h) = @_;
    my $t = $h->{type} // '';
    return "handler '$h->{id}' is a '$t' handler, which no longer delivers - run "
        . 'lazysite-handlers.pl convert (SM842)'
        unless $TYPES{$t};
    if ( $t eq 'connector' ) {
        my $all = _connector_store();
        my $c   = defined $all ? $all->{ $h->{connector} // '' } : undef;
        return "handler '$h->{id}' sends through connector '$h->{connector}', which does not "
            . 'permit public invocation, so it would refuse every submission - set modes.public '
            . 'on the connector first'
            if $c && !( $c->{modes} || {} )->{public};
    }
    return '';
}

sub action_schedule_list {
    my $s = read_schedule();
    return { ok => 0, error => _unreadable('schedule.conf') } unless defined $s;
    my $all = read_handlers() // [];
    my @out = map {
        my %e = %$_;
        my $h = find_handler( $all, $e{handler} // '' );
        $e{enabled}      = enabled($_) ? JSON::PP::true             : JSON::PP::false;
        $e{handler_type} = $h          ? $h->{type}                 : undef;
        $e{cap}          = $h          ? cap_for_type( $h->{type} ) : undef;
        $e{problem}      = "no handler '$e{handler}'" unless $h;
        \%e;
    } @$s;
    return { ok => 1, schedule => \@out, floor => $SCHEDULE_FLOOR };
}

sub action_schedule_save {
    my ( $in, %who ) = @_;
    return { ok => 0, kind => 'invalid', error => 'a schedule entry is required' }
        unless ref $in eq 'HASH';
    my $id = $in->{id};
    return { ok => 0, kind => 'invalid', field => 'id', error => 'id is required' }
        unless defined $id && length $id;
    return { ok => 0, kind => 'invalid', field => 'id',
        error => "id '$id' must be letters, digits, - or _ (at most 64)" }
        unless valid_id($id);
    my $hid = $in->{handler};
    return { ok => 0, kind => 'invalid', field => 'handler', error => 'handler is required' }
        unless defined $hid && length $hid;
    my $every = $in->{every};
    return { ok => 0, kind => 'invalid', field => 'every', error => 'every is required (seconds)' }
        unless defined $every && length $every;
    return { ok => 0, kind => 'invalid', field => 'every',
        error => "every must be a whole number of seconds, at least $SCHEDULE_FLOOR" }
        unless $every =~ /\A\d+\z/ && $every >= $SCHEDULE_FLOOR;
    my $payload = $in->{payload} // {};
    if ( !ref $payload && length $payload ) {
        $payload = eval { JSON::PP::decode_json($payload) };
        return { ok => 0, kind => 'invalid', field => 'payload',
            error => 'payload must be a JSON object of fields' }
            unless ref $payload eq 'HASH';
    }
    return { ok => 0, kind => 'invalid', field => 'payload', error => 'payload must be an object of fields' }
        unless ref $payload eq 'HASH';
    return { ok => 0, kind => 'invalid', field => 'payload', error => 'payload names more than 64 fields' }
        if keys %$payload > 64;
    for my $k ( keys %$payload ) {
        return { ok => 0, kind => 'invalid', field => 'payload', error => "payload: '$k' is not a field name" }
            unless $k =~ /\A[A-Za-z][A-Za-z0-9_.-]{0,63}\z/;
        return { ok => 0, kind => 'invalid', field => 'payload',
            error => "payload: '$k' must be text or a number - a scheduled call carries fixed values only" }
            if ref $payload->{$k};
        $payload->{$k} = defined $payload->{$k} ? "$payload->{$k}" : '';
    }

    my $all = read_handlers();
    return { ok => 0, error => _unreadable('handlers.conf') } unless defined $all;
    my $h = find_handler( $all, $hid )
        or return { ok => 0, kind => 'not-found', field => 'handler',
        error => "no handler '$hid' - the configured handlers are: "
            . ( join( ', ', map { $_->{id} } @$all ) || 'none' ) };
    my $cap = cap_for_type( $h->{type} )
        or return { ok => 0, kind => 'invalid', field => 'handler', error => _form_use_problem($h) };
    my $deny = _may( \%who, $cap, "scheduling a $h->{type} handler" );
    return { ok => 0, kind => 'forbidden', error => $deny } if length $deny;
    if ( $h->{type} eq 'connector' ) {
        my $cs = _connector_store();
        my $c  = defined $cs ? $cs->{ $h->{connector} // '' } : undef;
        return { ok => 0, kind => 'invalid', field => 'handler',
            error => "handler '$hid' sends through connector '$h->{connector}', which does not permit "
                . 'scheduled invocation, so the timer would be refused every time - set '
                . 'modes.scheduled on the connector first' }
            if $c && !( $c->{modes} || {} )->{scheduled};
    }

    my $s = read_schedule();
    return { ok => 0, error => _unreadable('schedule.conf') . '; nothing was written' }
        unless defined $s;
    my ($old) = grep { $_->{id} eq $id } @$s;
    if ( $old && ( my $oh = find_handler( $all, $old->{handler} // '' ) ) ) {
        my $d2 = _may( \%who, cap_for_type( $oh->{type} ), "changing an entry that schedules a $oh->{type} handler" );
        return { ok => 0, kind => 'forbidden', error => $d2 } if length $d2;
    }
    my %e = ( id => $id, handler => $hid, every => 0 + $every,
        enabled => _bool( $in->{enabled} // 'true' ), payload => $payload );
    if ($old) { %$old = %e }
    else      { push @$s, \%e }
    my ( $ok, $err ) = write_schedule($s);
    return { ok => 0, error => $err } unless $ok;
    log_event( 'INFO', 'handlers', ( $old ? 'schedule entry updated' : 'schedule entry created' ),
        entry => $id, handler => $hid, every => $every );
    return { ok => 1, id => $id, entry => \%e, created => ( $old ? 0 : 1 ) };
}

sub action_schedule_delete {
    my ( $id, %who ) = @_;
    return { ok => 0, kind => 'invalid', field => 'id', error => 'id is required' }
        unless defined $id && length $id;
    my $s = read_schedule();
    return { ok => 0, error => _unreadable('schedule.conf') . '; nothing was deleted' }
        unless defined $s;
    my ($e) = grep { $_->{id} eq $id } @$s;
    return { ok => 0, kind => 'not-found', error => "no schedule entry '$id'" } unless $e;
    my $all = read_handlers() // [];
    my $h   = find_handler( $all, $e->{handler} // '' );
    my $cap = $h ? cap_for_type( $h->{type} ) : undef;
    # An entry naming a handler that is gone is anybody's to clear who may reach
    # the schedule at all - there is no destination left to decide.
    if ($cap) {
        my $deny = _may( \%who, $cap, "removing an entry that schedules a $h->{type} handler" );
        return { ok => 0, kind => 'forbidden', error => $deny } if length $deny;
    }
    my ( $ok, $err ) = write_schedule( [ grep { $_->{id} ne $id } @$s ] );
    return { ok => 0, error => $err } unless $ok;
    log_event( 'INFO', 'handlers', 'schedule entry deleted', entry => $id );
    return { ok => 1, id => $id, deleted => $id };
}

# --- delivery ----------------------------------------------------------------
#
# deliver( $handler_id, \%fields, %ctx ) calls one handler. %ctx:
#
#   origin   'form' or 'timer' - the audit origin, and what the connector is
#            told it is (a form is public invocation, the timer scheduled)
#   source   'form:<name>' or 'timer:<entry>' - named on every record
#   store    the name a file handler files under (<store>.jsonl): the form's
#            name, or the schedule entry's id
#   ip       the submitter's address, when there is one
#   actor    the account the call runs as - blank for a public form, the job
#            account for the timer
#   files    uploads, from a form only
#   quarantined, spam_reason   SM216's flag, carried onto the stored copy
#   handlers a list already read, so a form with three targets reads the file once
#
# Returns { ok, handler, type, why }. Every call is one audit line naming the
# source, the handler and the outcome - never the fields.
sub deliver {
    my ( $id, $fields, %ctx ) = @_;
    $ctx{origin} //= 'form';
    $ctx{source} //= $ctx{origin};
    my $all = $ctx{handlers} // read_handlers();
    my $r;
    if ( !defined $all ) {
        $r = { ok => 0, why => 'handlers.conf could not be read' };
    }
    elsif ( my $h = find_handler( $all, $id ) ) {
        $r = _deliver_one( $h, $fields || {}, \%ctx );
        $r->{type} = $h->{type};
    }
    else {
        $r = { ok => 0, why => "no handler '$id'" };
    }
    $r->{handler} = $id;
    _audit_delivery( $id, $r, \%ctx );
    log_event( ( $r->{ok} ? 'INFO' : 'WARN' ), 'handlers',
        ( $r->{ok} ? 'delivered' : 'not delivered' ),
        handler => $id, source => $ctx{source}, ( $r->{ok} ? () : ( why => $r->{why} // '' ) ) );
    return $r;
}

sub _deliver_one {
    my ( $h, $fields, $ctx ) = @_;
    return { ok => 0, why => "handler '$h->{id}' is switched off" } unless enabled($h);
    my $t = $h->{type} // '';
    return _to_file( $h, $fields, $ctx )      if $t eq 'file';
    return _to_table( $h, $fields, $ctx )     if $t eq 'table';
    return _to_smtp( $h, $fields, $ctx )      if $t eq 'smtp';
    return _to_connector( $h, $fields, $ctx ) if $t eq 'connector';
    return { ok => 0, why => _legacy_problem($h) };
}

sub _audit_delivery {
    my ( $id, $r, $ctx ) = @_;
    eval {
        require Lazysite::Audit;
        no warnings 'once';
        local $Lazysite::Audit::LAZYSITE_DIR = _lz();
        Lazysite::Audit::audit_log( $ctx->{actor} // '', 'deliver', "$ctx->{source} -> $id",
            $ctx->{ip} // '', ( $r->{ok} ? 'ok' : 'failed' ), $ctx->{origin},
            ( $r->{ok} ? '' : $r->{why} // '' ) );
        1;
    };
    return;
}

sub _visible {
    my ($f) = @_;
    return map { ( $_ => $f->{$_} ) } grep { !/\A_/ } sort keys %$f;
}

sub _store_name {
    my ($ctx) = @_;
    ( my $n = $ctx->{store} // 'unknown' ) =~ s/[^A-Za-z0-9_-]//g;
    return length $n ? $n : 'unknown';
}

sub _to_file {
    my ( $h, $fields, $ctx, $extra ) = @_;
    my $dir = store_path( $h->{path} );
    eval { make_path($dir) unless -d $dir; 1 }
        or return { ok => 0, why => "cannot create the store directory: $@" };
    my $name = _store_name($ctx);
    my %rec  = _visible($fields);
    $rec{_submitted} = strftime( '%Y-%m-%dT%H:%M:%S', localtime );
    $rec{_ip}        = $ctx->{ip} // '';
    $rec{_form}      = $name;
    $rec{_source}    = $ctx->{source} if ( $ctx->{origin} // '' ) ne 'form';
    if ( $ctx->{quarantined} ) {
        $rec{_quarantined} = JSON::PP::true;
        $rec{_spam_reason} = $ctx->{spam_reason} // '';
    }
    $rec{_row_refused} = JSON::PP::true if $extra && $extra->{row_refused};
    if ( ref $ctx->{files} eq 'ARRAY' && @{ $ctx->{files} } ) {
        my $sid = strftime( '%Y%m%dT%H%M%S', localtime ) . '-' . sprintf( '%04x', int rand 65536 );
        my ( $saved, $rel ) = _save_uploads( $ctx->{files}, $dir, $name, $sid );
        if (@$saved) { $rec{_files} = $saved; $rec{_files_dir} = $rel }
    }
    my $path = "$dir/$name.jsonl";
    open my $fh, '>>:utf8', $path or return { ok => 0, why => "cannot open the store: $!" };
    flock $fh, LOCK_EX;
    my $wrote = print {$fh} JSON::PP->new->canonical->encode( \%rec ) . "\n";
    flock $fh, LOCK_UN;
    # SM020: a failed print surfaces at close. Without the check a disk-full
    # submission was acknowledged while the record never landed.
    return { ok => 0, why => "the store write did not complete: $!" } unless close($fh) && $wrote;
    return { ok => 1 };
}

sub _safe_filename {
    my ($n) = @_;
    $n =~ s{.*[\\/]}{};
    $n =~ s/[^A-Za-z0-9._-]/_/g;
    $n =~ s/\A\.+//;
    $n = 'file' unless length $n;
    return substr( $n, 0, 100 );
}

sub _save_uploads {
    my ( $files, $dir, $name, $sid ) = @_;
    my $rel  = "$name.files/$sid";
    my $fdir = "$dir/$rel";
    make_path($fdir) unless -d $fdir;
    my ( @saved, $i );
    for my $f (@$files) {
        $i++;
        my $safe = _safe_filename( $f->{filename} // '' );
        $safe = "$i-$safe" if -e "$fdir/$safe";
        open my $w, '>:raw', "$fdir/$safe" or next;
        print {$w} $f->{data} // '';
        close $w;
        push @saved, $safe;
    }
    return ( \@saved, $rel );
}

# DP-4 and SM569 in one type. THIS IS THE ANONYMOUS WRITE PATH TO A TABLE, and
# the only one: the handler decides everything structural - which table, which
# columns - and the caller decides values and nothing else. The row goes
# through the same coercion as any other write, so a form cannot put into the
# store anything the API could not.
sub _to_table {
    my ( $h, $fields, $ctx ) = @_;
    my $stored = _table_row( $h, $fields, $ctx );
    return $stored unless _bool( $h->{keep_copy} // 'true' ) eq 'true';
    my $filed = _to_file( { path => 'lazysite/forms/submissions' }, $fields, $ctx,
        { row_refused => !$stored->{ok} } );
    return { ok => 0, why => ( $stored->{why} // '' ) . '; the submissions copy was not kept either' }
        if !$stored->{ok} && !$filed->{ok};
    return { ok => 1, why => 'the row was stored; the submissions copy was not: ' . ( $filed->{why} // '' ) }
        if $stored->{ok} && !$filed->{ok};
    return $stored;
}

sub _table_row {
    my ( $h, $fields, $ctx ) = @_;
    my $table = $h->{table} // '';
    return { ok => 0, why => "no usable table name ('$table')" } unless $table =~ /\A[a-z][a-z0-9_]*\z/;
    my ( $map, $why ) = parse_fields( $h->{fields} );
    return { ok => 0, why => $why } unless $map;
    my $ok = eval {
        require Lazysite::Data::Tables;
        require Lazysite::Manager::Plugins;
        1;
    };
    return { ok => 0, why => 'the data modules could not be loaded: ' . ( $@ || 'unknown' ) } unless $ok;
    {
        # SM409: off means off - a table handler writing into a store whose
        # extension an operator switched off would be the extension still
        # running after being turned off.
        no warnings 'once';
        local $Lazysite::Manager::Plugins::DOCROOT = $DOCROOT;
        return { ok => 0, why => 'the Data tables extension is disabled, so no row can be stored' }
            unless Lazysite::Manager::Plugins::plugin_enabled('plugins/data.pl');
    }
    my %row;
    for my $from ( sort keys %$map ) {
        next                                     if $from =~ /\A_/;
        $row{ $map->{$from} } = $fields->{$from} if exists $fields->{$from};
    }
    return { ok => 0, why => "no mapped field was given, so nothing was stored in '$table'" } unless %row;
    my $r = eval {
        Lazysite::Data::Tables::insert_row( $DOCROOT, $table, \%row,
            ( length( $ctx->{actor} // '' ) ? ( actor => $ctx->{actor} ) : () ) );
    };
    return { ok => 0, why => "the row could not be stored in '$table': " . ( $@ || 'unknown' ) } if $@;
    return { ok => 0, why => "the row could not be stored in '$table': " . ( $r->{error} // 'unknown' ) }
        unless $r && $r->{ok};
    return { ok => 1, key => $r->{key} };
}

# The email goes out through the Form SMTP extension's script, which owns the
# transport; the handler contributes its addresses, prefix and attach setting.
sub _to_smtp {
    my ( $h, $fields, $ctx ) = @_;
    my $script = _find_script('form-smtp.pl')
        or return { ok => 0, why => 'the Form SMTP extension\'s script was not found' };
    my %payload = ( config => {%$h}, form => { _visible($fields) } );
    if ( _bool( $h->{attach_files} // 'false' ) eq 'true'
        && ref $ctx->{files} eq 'ARRAY' && @{ $ctx->{files} } )
    {
        require MIME::Base64;
        $payload{files} = [ map {
                { filename => $_->{filename}, type => $_->{type},
                    size => length( $_->{data}                      // '' ),
                    data => MIME::Base64::encode_base64( $_->{data} // '' ) }
        } @{ $ctx->{files} } ];
    }
    require IPC::Open2;
    local $ENV{DOCUMENT_ROOT} = $DOCROOT;
    my ( $out, $in );
    my $pid = eval { IPC::Open2::open2( $out, $in, $^X, $script, '--pipe' ) }
        or return { ok => 0, why => "cannot run the Form SMTP script: $@" };
    print {$in} JSON::PP::encode_json( \%payload );
    close $in;
    my $res = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my $r = eval { JSON::PP::decode_json( $res // '' ) } // {};
    return $r->{ok} ? { ok => 1 } : { ok => 0, why => 'the mail was not sent: ' . ( $r->{error} // 'no answer' ) };
}

sub _find_script {
    my ($name) = @_;
    require Cwd;
    my $here = dirname( Cwd::abs_path(__FILE__) // __FILE__ );
    for my $p ( "$here/../../plugins/$name", "$DOCROOT/../plugins/$name",
        "$DOCROOT/../cgi-bin/$name", '/usr/share/lazysite/plugins/' . $name )
    {
        return $p if -f $p;
    }
    return undef;
}

# SM579: the connector decides - its modes (a form is public invocation, the
# timer scheduled), its rate cap, its credential, its record.
sub _to_connector {
    my ( $h, $fields, $ctx ) = @_;
    require Lazysite::Manager::Connectors;
    no warnings 'once';
    local $Lazysite::Manager::Connectors::DOCROOT = $DOCROOT;
    my $r = Lazysite::Manager::Connectors::call( $h->{connector} // '', { _visible($fields) },
        mode    => ( ( $ctx->{origin} // '' ) eq 'timer' ? 'scheduled' : 'public' ),
        actor   => $ctx->{actor} // '',
        trigger => $ctx->{source} );
    return { ok => 1, call_id => $r->{call_id} } if $r->{ok};
    return { ok => 0, why => 'the connector did not deliver: ' . ( $r->{error} // $r->{state} // 'failed' ) };
}

# --- the timer's half --------------------------------------------------------

# Which entries are due, given each one's last run. $runs is { entry => {last_run} }.
sub due_entries {
    my ( $schedule, $runs, $now ) = @_;
    my @due;
    for my $e (@$schedule) {
        next unless enabled($e)                        && !$e->{invalid};
        next unless ( $e->{every} // '' ) =~ /\A\d+\z/ && $e->{every} >= $SCHEDULE_FLOOR;
        my $last = ( ref $runs->{ $e->{id} } eq 'HASH' ? $runs->{ $e->{id} }{last_run} : 0 ) // 0;
        $last = 0 if $last !~ /\A\d+(?:\.\d+)?\z/ || $last > $now;
        push @due, $e if $now - $last >= $e->{every};
    }
    return \@due;
}

# --- the conversion (SM842, run once on upgrade) -----------------------------
#
# Brings a site written for the old shapes to the one shape, and says what it
# did. Idempotent: a second run finds nothing to change and says so.
#
#   1. `type: db` handlers become `type: table` with keep_copy: false.
#   2. `type: webhook` / `type: api` handlers become connectors (public mode, no
#      rate cap - the webhook had none - and the same JSON or Slack body), and
#      the handler becomes a connector handler naming it. A plain http:// URL to
#      another host cannot be a connector, which sends over https only: that
#      handler is left as it is and reported, and delivers nothing until it is
#      changed.
#   3. A form whose targets are INLINE (no `- handler:` at all) gets a named
#      handler per inline target - reusing an existing handler that delivers to
#      the same place - and its targets become references. Inline targets in a
#      form that ALSO names handlers never delivered (the old reader ignored
#      them), so they are dropped rather than woken up, and reported.
#   4. A connector with schedule_every becomes a schedule entry calling a
#      connector handler for it, and the connector loses the two keys.
#
# Returns { ok, changed => [sentences], left => [sentences] }.
sub convert {
    my (%o) = @_;
    my ( @changed, @left );
    my $handlers = read_handlers();
    return { ok => 0, error => _unreadable('handlers.conf') . '; nothing was converted' }
        unless defined $handlers;
    my $schedule = read_schedule();
    return { ok => 0, error => _unreadable('schedule.conf') . '; nothing was converted' }
        unless defined $schedule;
    my $names = form_names();
    return { ok => 0, error => 'the forms directory could not be read; nothing was converted' }
        unless defined $names;

    require Lazysite::Manager::Connectors;
    no warnings 'once';
    local $Lazysite::Manager::Connectors::DOCROOT = $DOCROOT;
    my $conns = Lazysite::Manager::Connectors::connectors();
    return { ok => 0, error => 'the connector store could not be read; nothing was converted' }
        unless defined $conns;
    my ( $h_dirty, $c_dirty, $s_dirty ) = ( 0, 0, 0 );
    my %form_text;

    my $new_connector = sub {
        my ( $want, $url, $format, $from ) = @_;
        return ( undef, "$from: a connector sends over https (or http to this host) only, and "
                . "'$url' is neither - change it to https:// and convert again" )
            unless $url =~ m{\Ahttps://[^\s/]+} || $url =~ m{\Ahttp://(?:127\.0\.0\.1|localhost)(?::\d+)?(?:/|\z)};
        for my $cid ( sort keys %$conns ) {    # the same destination already exists
            my $c = $conns->{$cid};
            return ( $cid, '' )
                if ( $c->{url} // '' ) eq $url && ( $c->{format} // 'json' ) eq $format
                && ( $c->{modes} || {} )->{public};
        }
        ( my $base = lc $want ) =~ s/[^a-z0-9_-]+/-/g;
        $base =~ s/\A[^a-z0-9]+//;
        $base = 'webhook' unless length $base;
        $base = substr( $base, 0, 56 );
        my ( $cid, $n ) = ( $base, 1 );
        $cid = $base . '-' . ++$n while exists $conns->{$cid};
        my ( $c, $err ) = Lazysite::Manager::Connectors::normalise( {
                name          => "$want (converted from a webhook)",
                url           => $url,
                format        => $format,
                modes         => { public => 1, authenticated => 0, scheduled => 0 },
                rate_per_hour => 0,
        } );
        return ( undef, "$from: $err" ) unless $c;
        $conns->{$cid} = $c;
        $c_dirty = 1;
        return ( $cid, '' );
    };
    my $handler_for = sub {
        my ( $want_id, %rec ) = @_;
        for my $h (@$handlers) {    # reuse one that already delivers there
            next unless ( $h->{type} // '' ) eq $rec{type};
            next if grep { ( $h->{$_} // '' ) ne ( $rec{$_} // '' ) } grep { $_ ne 'name' } keys %rec;
            return $h->{id};
        }
        ( my $base = $want_id ) =~ s/[^A-Za-z0-9_-]+/-/g;
        my ( $id, $n ) = ( $base, 1 );
        $id = $base . '-' . ++$n while find_handler( $handlers, $id );
        push @$handlers, { id => $id, enabled => 'true', %rec };
        $h_dirty = 1;
        return $id;
    };

    # 1 and 2: the handlers themselves.
    for my $h (@$handlers) {
        my $t = $h->{type} // '';
        if ( $t eq 'db' ) {
            $h->{type}      = 'table';
            $h->{keep_copy} = 'false';
            $h_dirty        = 1;
            push @changed, "handler '$h->{id}': db -> table (keep_copy: false)";
        }
        elsif ( $t eq 'webhook' || $t eq 'api' ) {
            my $fmt = ( $h->{format} // 'json' ) eq 'slack' ? 'slack' : 'json';
            my ( $cid, $why ) = $new_connector->( $h->{id}, $h->{url} // '', $fmt, "handler '$h->{id}'" );
            unless ($cid) { push @left, $why; next }
            delete @$h{qw(url format method)};
            $h->{type}      = 'connector';
            $h->{connector} = $cid;
            $h_dirty        = 1;
            push @changed, "handler '$h->{id}': $t -> connector '$cid' (public, no rate cap, $fmt body)";
        }
    }

    # 3: inline form targets.
    for my $f (@$names) {
        my $text = _slurp( form_file($f), "forms/$f.conf" );
        return { ok => 0, error => _unreadable("$f.conf") . '; nothing was converted' } unless defined $text;
        my ( $ids, $inline, $other ) = parse_form_conf($text);
        next unless @$inline;
        my @new = @$ids;
        if (@$ids) {
            push @changed, "form '$f': dropped " . scalar(@$inline) . ' inline target(s) that never delivered '
                . '(the form names handlers, and the old reader ignored inline targets beside them)';
        }
        else {
            for my $t (@$inline) {
                my $type = lc( $t->{type} // '' );
                if ( $type eq 'file' ) {
                    my $p   = $t->{path} // 'lazysite/forms/submissions';
                    my $why = _check_path($p);
                    if ( length $why ) { push @left, "form '$f': inline file target: $why"; next }
                    my $id = $handler_for->( "$f-file", type => 'file', name => "$f submissions", path => $p );
                    push @new,     $id;
                    push @changed, "form '$f': inline file target -> handler '$id'";
                }
                elsif ( $type eq 'webhook' || $type eq 'api' ) {
                    my $fmt = ( $t->{format} // 'json' ) eq 'slack' ? 'slack' : 'json';
                    my ( $cid, $why ) = $new_connector->( "$f-$type", $t->{url} // '', $fmt, "form '$f'" );
                    unless ($cid) { push @left, $why; next }
                    my $id = $handler_for->( "$f-$type", type => 'connector', name => "$f to $cid", connector => $cid );
                    push @new, $id;
                    push @changed, "form '$f': inline $type target -> connector '$cid' and handler '$id'";
                }
                else {
                    push @changed, "form '$f': dropped an inline '$type' target, which could not deliver "
                        . '(an inline target carried no configuration beyond url, format and path)';
                }
            }
        }
        $form_text{$f} = render_form_conf( \@new, $other );
    }

    # 4: connector schedules.
    for my $cid ( sort keys %$conns ) {
        my $c = $conns->{$cid};
        next unless exists $c->{schedule_every} || exists $c->{schedule_payload};
        my $every   = delete $c->{schedule_every}   // 0;
        my $payload = delete $c->{schedule_payload} // {};
        $c_dirty = 1;
        next unless $every;
        my $hid = $handler_for->( $cid, type => 'connector', name => "$cid on a timer", connector => $cid );
        my $eid = $cid;
        my $n   = 1;
        $eid = $cid . '-' . ++$n while grep { $_->{id} eq $eid } @$schedule;
        push @$schedule, { id => $eid, handler => $hid, every => $every < $SCHEDULE_FLOOR ? $SCHEDULE_FLOOR : $every,
            enabled => ( ( $c->{modes} || {} )->{scheduled} ? 'true'   : 'false' ),
            payload => ( ref $payload eq 'HASH'             ? $payload : {} ) };
        $s_dirty = 1;
        push @changed, "connector '$cid': schedule_every $every -> schedule entry '$eid' calling handler '$hid'";
    }

    return { ok => 1, changed => \@changed, left => \@left, dry_run => 1 } if $o{dry_run};

    # Connectors first, then handlers, then forms, then the schedule: each
    # write leaves the site consistent if a later one fails, because nothing
    # names a connector or handler before it exists.
    if ($c_dirty) {
        my ( $ok, $err ) = Lazysite::Manager::Connectors::write_store($conns);
        return { ok => 0, error => $err, changed => [], left => \@left } unless $ok;
    }
    if ($h_dirty) {
        my ( $ok, $err ) = write_handlers($handlers);
        return { ok => 0, error => $err, changed => [], left => \@left } unless $ok;
    }
    for my $f ( sort keys %form_text ) {
        my ( $ok, $err ) = _write_text( form_file($f), $form_text{$f} );
        return { ok => 0, error => $err, changed => [], left => \@left } unless $ok;
    }
    if ($s_dirty) {
        my ( $ok, $err ) = write_schedule($schedule);
        return { ok => 0, error => $err, changed => [], left => \@left } unless $ok;
    }
    log_event( 'INFO', 'handlers', 'converted to the handler contract (SM842)',
        changed => scalar @changed, left => scalar @left ) if @changed || @left;
    return { ok => 1, changed => \@changed, left => \@left };
}

1;
