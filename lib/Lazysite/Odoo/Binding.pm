package Lazysite::Odoo::Binding;

# SM747 CU: A BINDING - WHICH NAMED OPERATION A PAGE, A FORM OR THE SCHEDULE MAY
# RUN, WHAT IT MAY BE GIVEN, AND BY WHOM.
#
# A binding is a handler of type `odoo` (Lazysite::Handlers), so it is made,
# listed, gated and deleted where every other destination is. This module turns
# the stored record into the shape the engine runs, and decides the one thing
# that makes an anonymous write path safe to have: WHAT A REQUEST MAY SET.
#
# THE PARAMETERS COME FROM THREE PLACES, AND ONLY ONE OF THEM IS THE REQUEST:
#
#   params         `field=parameter` - the request's field, renamed. Only these
#                  may come from outside, and only into a parameter the
#                  operation declares as a plain value (str, int, bool). A json,
#                  list or path parameter is a domain, a set or a file on this
#                  server: it can be FIXED by the operator and never fed by a
#                  visitor. That is the parameter-injection line. ONE more type
#                  may be fed (SM1166): `rows`, OOM 0.32's declared list of
#                  small rows of plain values with a cap - no row value is
#                  anything but a plain value, so it cannot hold a domain.
#   file_params    `field=parameter` (SM1162) - a request FILE field, from a
#                  multipart request, into a parameter the operation declares as
#                  a file (OOM 0.34: `file`, or `files` for a list) or into a
#                  `set.<field>` (a binary field, which OOM checks at plan). The
#                  bytes are not a request value: they are never a plain value,
#                  never in `params`, and the binding must say how large one may
#                  be (`file_max_kb`) and may say which types (`file_types`).
#   fixed          `parameter=value` - the operator's, and the request cannot
#                  override one.
#   visitor_param  the parameter that receives the visitor's key - minted by
#                  the server (Lazysite::Odoo::Visitor), never read from input.
#                  This is what keeps a visitor to their own basket.
#
# A name in two of the three is refused at save: the order of precedence would
# otherwise be a security property nobody wrote down.
use strict;
use warnings;

our @MODES = qw(scheduled authenticated public);

my $FIELD = qr/\A[A-Za-z][A-Za-z0-9_.-]{0,127}\z/;
my $PARAM = qr/\A[a-z][a-z0-9_]{0,63}\z/;

# SM1164 D0: core.set and core.make take one `set.<field>` parameter per field
# (OOM 0.29), the field part named as Odoo names fields. The operation declares
# the family once, as 'set.<field>', so a name of this shape is checked against
# that declaration. Only this shape: every other name keeps $PARAM.
my $SET_PARAM = qr/\Aset\.[a-z][a-z0-9_]{0,63}\z/;
my $ANY_PARAM = qr/\A(?:[a-z][a-z0-9_]{0,63}|set\.[a-z][a-z0-9_]{0,63})\z/;

# The operation's declaration of a parameter name: its own, or for a set.<field>
# the family's.
sub param_decl {
    my ( $spec, $p ) = @_;
    return $spec->{$p}            if $spec->{$p};
    return $spec->{'set.<field>'} if $p =~ $SET_PARAM;
    return undef;
}
my $GROUP = qr/\A[a-z0-9][a-z0-9_-]{0,63}\z/;
# SM1178 (lazysite-sites agent, 2026-10-18): OOM names a pack with lower-case
# letters, digits and hyphens (Odoo::Ops::Pack) and an operation <pack>.<op>
# (Registry), so `crm-page.leads` is a name, as is core's `stock.link-stranded`.
# A segment may hold a hyphen BETWEEN its characters; one that leads, trails or
# doubles is not accepted (OOM's own pack-name pattern is looser at the end, and
# nothing here needs the looser reading). Nothing here turns the name into a path
# or a query key, so the hyphen touches no other rule.
my $SEG = qr/[a-z][a-z0-9_]*(?:-[a-z0-9_]+)*/;
my $OP  = qr/\A$SEG(?:\.$SEG)+\z/;

# The types a request may feed. Everything else is the operator's to fix.
our %FROM_INPUT = map { $_ => 1 } qw(str int bool);

# SM1166: the type a request may feed as a LIST, checked row by row.
our $ROWS = 'rows';

# SM1162: the types a request file feeds, and the hard ceiling on one file
# whatever a binding or an operation allows. A request is held in memory while it
# is parsed, so the ceiling is the endpoint's, not the operation's (OOM's own
# default is 25 MB).
our %FILE_TYPE         = ( file => 1, files => 1 );
our $FILE_CEILING_KB   = 20 * 1024;
our $MAX_FILES         = 10;    # OOM's own cap on a list of files (Odoo::Ops::File)
our $DEFAULT_MAX_BYTES = 25 * 1024 * 1024;
my $MIME = qr{\A[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*\z};


# How long a plain value from a request may be. A basket line is a few
# characters; this bounds what a script can push through one parameter.
our $MAX_VALUE = 1000;

# SM1224: a rows key an operation declares with its own `max` (OOM 0.38,
# `note => { type => 'str?', max => 5000 }`, up to 1,048,576) raises the cap for
# THAT key and no other; every other value keeps $MAX_VALUE.
our $MAX_KEY = 1_048_576;

# The most characters a rows key may hold: its declared `max`, never less than the
# plain-value cap. $row is the operation's `row` declaration, $k the key.
sub key_limit {
    my ( $row, $k ) = @_;
    my $d = ref $row eq 'HASH' ? $row->{$k} : undef;
    return $MAX_VALUE
        unless ref $d eq 'HASH' && defined $d->{max} && !ref $d->{max} && $d->{max} =~ /\A[1-9][0-9]*\z/;
    return $d->{max} > $MAX_KEY ? $MAX_KEY : $d->{max} > $MAX_VALUE ? 0 + $d->{max} : $MAX_VALUE;
}

# SM1224: the most bytes a JSON request for this binding may weigh. A request is
# held to 64 KB ($JSON_BASE) unless one of its rows parameters declares a key with
# a larger `max`; then the budget is the base plus the most the list can hold: its
# rows (the operation's max, lowered by the binding's rows_max) times the bytes of
# one row at each key's limit, a character costing at most six bytes (a \uXXXX
# escape) and a key's name and quotes counting too. Never above the endpoint's own
# ceiling for a request ($FILE_CEILING_KB). $spec is the operation's parameters.
our $JSON_BASE = 64 * 1024;

sub json_budget {
    my ( $b, $spec ) = @_;
    my $need = 0;
    for my $field ( keys %{ $b->{params} || {} } ) {
        my $decl = param_decl( $spec, $b->{params}{$field} ) or next;
        next unless ( $decl->{type} // '' ) eq $ROWS && ref $decl->{row} eq 'HASH' && defined $decl->{max};
        next unless grep { key_limit( $decl->{row}, $_ ) > $MAX_VALUE } keys %{ $decl->{row} };
        my $rows = $decl->{max};
        $rows = $b->{rows_max} if defined $b->{rows_max} && $b->{rows_max} < $rows;
        my $one = 0;
        $one += 6 * key_limit( $decl->{row}, $_ ) + length($_) + 8 for keys %{ $decl->{row} };
        $need += $rows * $one;
    }
    my $budget  = $JSON_BASE + $need;
    my $ceiling = $FILE_CEILING_KB * 1024;
    return $budget > $ceiling ? $ceiling : $budget;
}

sub _pairs {
    my ( $text, $what, $left, $right ) = @_;
    my %m;
    for my $pair ( split /\s*,\s*/, ( $text // '' ) ) {
        next unless length $pair;
        my ( $k, $v ) = split /\s*=\s*/, $pair, 2;
        return ( undef, "$what: '$pair' is not name=value" )
            unless defined $v && length $k && length $v;
        return ( undef, "$what: '$k' is not $left" ) unless $k =~ $right->[0];
        return ( undef, "$what: '$v' is not $right->[2]" )
            unless !defined $right->[1] || $v =~ $right->[1];
        return ( undef, "$what: '$k' is named twice" ) if exists $m{$k};
        $m{$k} = $v;
    }
    return ( \%m, '' );
}

# parse( \%handler ) -> ( \%binding, '' ) or ( undef, why, field )
#
# The SHAPE only - no OOM needed. Whether the operation exists and declares the
# parameters is check_against(), which needs the registry.
# SM1173: the default caps, per hour. A scanning page is a read and needs
# thousands an hour (OOM Lab L-14); a write keeps the small ceiling that
# stands between a script and Odoo's data. Ruled 2026-10-18.
our %WRITE_RATE = ( rate_per_visitor_hour => 20,   rate_per_hour => 200 );
our %READ_RATE  = ( rate_per_visitor_hour => 2000, rate_per_hour => 20000 );

# rate_limits( \%binding, $writes ) -> ( per_visitor_hour, per_hour )
#
# The binding's own number where it said one, else the default for a read or a
# write. $writes is the operation's own answer ($class->writes).
sub rate_limits {
    my ( $b, $writes ) = @_;
    my $d = $writes ? \%WRITE_RATE : \%READ_RATE;
    return map { $b->{rate_set}{$_} ? $b->{$_} : $d->{$_} } qw(rate_per_visitor_hour rate_per_hour);
}

sub parse {
    my ($h) = @_;
    return ( undef, 'a binding is required', 'id' ) unless ref $h eq 'HASH';
    my %b = ( id => $h->{id} // '' );

    my $op = $h->{operation} // '';
    return ( undef, 'operation is required - the name of an OOM operation, such as pack.action',
        'operation' )
        unless length $op;
    return ( undef, "operation '$op' is not an operation name (dotted, lower case, a hyphen only inside a part)", 'operation' )
        unless $op =~ $OP;
    $b{operation} = $op;

    my ( $in, $why ) = _pairs( $h->{params}, 'params', 'a field name', [ $FIELD, $ANY_PARAM, 'a parameter name' ] );
    return ( undef, $why, 'params' ) unless $in;
    $b{params} = $in;    # field => parameter

    my ( $fixed, $fwhy ) = _pairs( $h->{fixed}, 'fixed', 'a parameter name', [ $ANY_PARAM, undef ] );
    return ( undef, $fwhy, 'fixed' ) unless $fixed;
    $b{fixed} = $fixed;    # parameter => value

    # SM1162: files from a multipart request, each into a file parameter.
    my ( $fin, $fiwhy ) = _pairs( $h->{file_params}, 'file_params', 'a request file field',
        [ $FIELD, $ANY_PARAM, 'a parameter name' ] );
    return ( undef, $fiwhy, 'file_params' ) unless $fin;
    $b{file_params} = $fin;    # field => parameter

    my $vp = $h->{visitor_param} // '';
    return ( undef, "visitor_param '$vp' is not a parameter name", 'visitor_param' )
        if length $vp && $vp !~ $PARAM;
    $b{visitor_param} = $vp;

    # SM1051's domain, carried so the gate can hold a run to it (E-Q1).
    $b{domain} = lc( $h->{domain} // '' );

    # ONE SOURCE PER PARAMETER.
    my %src;
    push @{ $src{$_} },  'params'      for values %$in;
    push @{ $src{$_} },  'fixed'       for keys %$fixed;
    push @{ $src{$_} },  'file_params' for values %$fin;
    push @{ $src{$vp} }, 'visitor_param' if length $vp;
    for my $p ( sort keys %src ) {
        return ( undef, "parameter '$p' is set by " . join( ' and ', @{ $src{$p} } )
                . ' - each parameter has one source', 'params' )
            if @{ $src{$p} } > 1;
    }

    my %modes = map { $_ => 0 } @MODES;
    for my $m ( grep { length } split /\s*,\s*/, ( $h->{modes} // 'authenticated' ) ) {
        return ( undef, "modes: '$m' is not one of " . join( ', ', @MODES ), 'modes' )
            unless exists $modes{$m};
        $modes{$m} = 1;
    }
    return ( undef, 'modes must name at least one of ' . join( ', ', @MODES ), 'modes' )
        unless grep { $_ } values %modes;
    $b{modes} = \%modes;

    my @callers = grep { length } split /\s*,\s*/, ( $h->{callers} // '' );
    for (@callers) { return ( undef, "callers: '$_' is not a group name", 'callers' ) unless $_ =~ $GROUP }
    $b{callers} = \@callers;

    my $apply = $h->{apply} // 'confirm';
    $apply = 'confirm' unless length $apply;
    return ( undef, "apply must be confirm or immediate (got '$apply')", 'apply' )
        unless $apply =~ /\A(?:confirm|immediate)\z/;
    $b{apply} = $apply;

    # B: WHOSE CREDENTIAL RUNS IT. `connection` (the default) is the connection
    # user; `session` is the person signed in to Odoo through the page, whose
    # own session carries the call. A person's session exists only in a request
    # from that person's browser, so a session binding is authenticated mode
    # and nothing else - no public, no schedule - and who may run it is decided
    # by Odoo for that person, so it names no callers and no visitor key.
    my $cred = $h->{credential};
    $cred = 'connection' unless defined $cred && length $cred;
    return ( undef, "credential must be connection or session (got '$cred')", 'credential' )
        unless $cred =~ /\A(?:connection|session)\z/;
    $b{credential} = $cred;
    if ( $cred eq 'session' ) {
        return ( undef, 'a session binding runs as the person signed in to Odoo: public and '
                . 'scheduled have no such person', 'modes' )
            if $modes{public} || $modes{scheduled};
        return ( undef, 'a session binding takes no callers - Odoo decides, for the person signed in', 'callers' )
            if @callers;
        return ( undef, 'a session binding has no visitor key - it runs as a person', 'visitor_param' )
            if length $vp;
    }

    # SM1159 (L2): a session binding may carry its own sign-in address limit, names of
    # address lists (SM1138), which can only narrow the site's `signin_addresses`.
    # Held on the binding's calls (the sign-in itself names no binding). Meaning
    # nothing on a connection binding, it is refused there rather than ignored.
    for my $k (qw(signin_addresses signin_addresses_deny)) {
        my $v = $h->{$k};
        my @n = ref $v eq 'ARRAY' ? @$v : split /\s*,\s*/, ( $v // '' );
        @n = grep { defined && length } map { s/\A\s+|\s+\z//gr } @n;
        next unless @n;
        return ( undef, "$k limits sign-in through a session binding; a connection binding has no sign-in", $k )
            unless $cred eq 'session';
        for (@n) { return ( undef, "$k: '$_' is not an address list name", $k ) unless /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/ }
        $b{$k} = \@n;
    }

    # SM1166: the binding's own cap on a rows parameter, which can only LOWER the
    # one the operation declares. Unset: the operation's cap stands.
    my $rm = $h->{rows_max};
    if ( defined $rm && length $rm ) {
        return ( undef, 'rows_max must be a whole number of at least 1', 'rows_max' )
            unless $rm =~ /\A[1-9][0-9]{0,5}\z/;
        $b{rows_max} = 0 + $rm;
    }

    # SM1162: the cap on one file, REQUIRED when a file is mapped (as SM1166's R2
    # asks a rows parameter for its max): nothing else bounds what a visitor may
    # push at the endpoint. Never above the ceiling; never above the operation's
    # own max_bytes (that one is checked against the registry, check_against).
    my $fk      = $h->{file_max_kb};
    my $fk_said = defined $fk && length $fk;
    if (%$fin) {
        return ( undef, 'file_max_kb is required when file_params maps a file: a whole number of '
                . "KB, at most $FILE_CEILING_KB (the endpoint's ceiling)", 'file_max_kb' )
            unless $fk_said;
        return ( undef, 'file_max_kb must be a whole number of at least 1', 'file_max_kb' )
            unless $fk =~ /\A[1-9][0-9]{0,8}\z/;
        return ( undef, "file_max_kb $fk is above the endpoint's ceiling of $FILE_CEILING_KB KB for one file",
            'file_max_kb' )
            if $fk > $FILE_CEILING_KB;
        $b{file_max_kb} = 0 + $fk;
    }
    elsif ($fk_said) {
        return ( undef, 'file_max_kb caps a file the binding maps with file_params; it maps none', 'file_max_kb' );
    }
    my @ft = grep { length } map { s/\A\s+|\s+\z//gr } split /,/, ( $h->{file_types} // '' );
    if (@ft) {
        return ( undef, 'file_types limits the files file_params maps; it maps none', 'file_types' ) unless %$fin;
        for (@ft) {
            return ( undef, "file_types: '$_' is not a type/subtype name (such as image/png; no wildcard)", 'file_types' )
                unless $_ eq lc $_ && $_ =~ $MIME;
        }
        $b{file_types} = \@ft;
    }

    # SM1173 (OOM Lab L-14): the caps. What the binding says stands, above or
    # below the default, for a read as for a write (no ceiling). What it leaves
    # out is the default for WHAT IT DOES - decided at the call, where the
    # operation is known (rate_limits) - so `rate_set` records which were said,
    # and rate_* holds the write default for a caller that does not ask.
    for my $k (qw(rate_per_visitor_hour rate_per_hour)) {
        my $v    = $h->{$k};
        my $said = defined $v && length $v;
        $v = $WRITE_RATE{$k} unless $said;
        return ( undef, "$k must be a whole number", $k ) unless $v =~ /\A[0-9]+\z/;
        $b{$k} = 0 + $v;
        $b{rate_set}{$k} = 1 if $said;
    }

    # A visitor key exists only where a visitor does: a scheduled run has none.
    return ( undef, 'a binding with a visitor_param cannot be scheduled - there is no '
            . 'visitor on the timer', 'modes' )
        if length $vp && $modes{scheduled};
    return ( \%b, '' );
}

# check_against( \%binding, $op_class ) -> '' or why
#
# The binding against the operation's OWN declaration, when the registry can be
# read: every parameter it names is one the operation declares, a parameter fed
# from the request is a plain value, nothing names a path, and every required
# parameter has a source. Run at save, so a binding that cannot work is refused
# when it is made rather than at a visitor's request (SM807).
sub check_against {
    my ( $b, $class ) = @_;
    my $spec = $class->params || {};
    for my $p ( sort( values %{ $b->{params} } ), sort( keys %{ $b->{fixed} } ), sort( values %{ $b->{file_params} || {} } ),
        ( length $b->{visitor_param} ? $b->{visitor_param} : () ) )
    {
        my $d = param_decl( $spec, $p );
        return "parameter '$p' is not one $b->{operation} declares (it takes: "
            . ( join( ', ', sort keys %$spec ) || 'none' ) . ')'
            unless $d;
        return "parameter '$p' names a file on this server; a binding cannot set one"
            if ( $d->{type} // 'str' ) eq 'path';
    }
    for my $p ( sort values %{ $b->{params} } ) {
        my $d = param_decl( $spec, $p );
        my $t = $d->{type} // 'str';
        if ( $t eq $ROWS ) {

            # SM1166 R2: a list a request fills must say how long it may be, and
            # which keys a row has - or there is nothing to hold it to.
            return "parameter '$p' is rows and declares no max - a request may feed a list only "
                . 'when the operation caps it (a whole number of at least 1)'
                unless defined $d->{max} && !ref $d->{max} && $d->{max} =~ /\A[1-9][0-9]*\z/;
            return "parameter '$p' is rows whose row keys are not known until the change is "
                . 'planned (the operation describes them in words) - a request cannot be checked '
                . 'against them, so only the operator may fix it with fixed: instead'
                unless ref $d->{row} eq 'HASH' && %{ $d->{row} };
            next;
        }
        return "parameter '$p' is a file - a request file field reaches it through file_params "
            . '(a multipart request), never through params'
            if $FILE_TYPE{$t};
        return "parameter '$p' is $t - a request may feed only a plain value (str, int, bool) "
            . 'or a declared list of rows; fix it with fixed: instead'
            unless $FROM_INPUT{$t};
    }
    # SM1162: a request file field goes only into a file (or files) parameter, or a
    # set.<field> (a binary field: OOM refuses a field that is not one, at plan),
    # and the binding's cap on one file cannot exceed what the operation allows.
    for my $p ( sort values %{ $b->{file_params} || {} } ) {
        my $d   = param_decl( $spec, $p );
        my $t   = $d->{type} // 'str';
        my $set = $p =~ $SET_PARAM && !$spec->{$p};
        return "parameter '$p' is $t, not a file - file_params maps a request file field only to a "
            . 'file or files parameter (or a set.<field> of a binary field)'
            unless $FILE_TYPE{$t} || $set;
        my $max = $d->{max_bytes} // $DEFAULT_MAX_BYTES;
        return "file_max_kb $b->{file_max_kb} is above the $max bytes parameter '$p' of $b->{operation} "
            . 'declares (max_bytes)'
            if $b->{file_max_kb} * 1024 > $max;
    }
    my %covered = map { $_ => 1 } values %{ $b->{params} }, keys %{ $b->{fixed} }, values %{ $b->{file_params} || {} },
        ( length $b->{visitor_param} ? $b->{visitor_param} : () );
    for my $p ( sort keys %$spec ) {
        return "$b->{operation} requires '$p' and the binding gives it no source"
            if $spec->{$p}{required} && !defined $spec->{$p}{default} && !$covered{$p};
    }
    return "$b->{operation} writes, and a scheduled run has nobody to confirm its plan - set "
        . 'apply: immediate (Q1), or take scheduled off the modes'
        if $class->writes && $b->{modes}{scheduled} && $b->{apply} ne 'immediate';
    if ( length $b->{visitor_param} ) {
        my $t = $spec->{ $b->{visitor_param} }{type} // 'str';
        return "visitor_param '$b->{visitor_param}' is $t - the visitor key is text (str)"
            unless $t eq 'str';
    }
    return '';
}

# assemble( \%binding, $op_class, \%input, %o ) -> ( \%params, '' ) or ( undef, why )
#
#   visitor  the visitor key, for the visitor parameter
#   strict   refuse an input field the binding does not map (the endpoint);
#            without it unmapped fields are dropped (a form, which posts
#            every field it has)
#
# Every value from the request is checked against the operation's declared type
# HERE, before OOM is called, so a refusal names the field the visitor sent
# rather than an operation parameter they have never heard of.
# The plain-value rule, once: the length limit and no control character. Returns
# the complaint without the field's name, or ''.
sub _plain_problem {
    my ( $v, $max ) = @_;
    $max = $MAX_VALUE unless defined $max && $max > $MAX_VALUE; # SM1224: a key's declared max raises it
    return "is longer than $max characters" if length $v > $max;
    return 'contains a control character' if $v =~ /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/;
    return '';
}

# SM1166: a request's list of rows for parameter $p, as ( \@rows, '' ) or
# ( undef, why ). OOM's rows check first (count, keys, types, nesting - and it
# names the row and the key), then the plain-value rule on every value OOM
# passed, so a row value is held to what a single request value is. Any failure
# refuses the whole call.
sub _rows {
    my ( $b, $class, $decl, $field, $v ) = @_;
    return ( undef, "'$field' must be a list of rows (a JSON array of objects)" ) unless ref $v eq 'ARRAY';
    my %d = %$decl;
    $d{max} = $b->{rows_max} if defined $b->{rows_max} && $b->{rows_max} < $d{max};
    # SM1198: OOM 0.36's Odoo::Ops::Rows->check, the same rules and errors as the
    # operation class's check_rows but loading only Odoo::Error, Odoo::JSON and
    # Odoo::Ops - so a request that feeds a rows parameter no longer loads the
    # registry (SM1180 left it as the one thing the stored declaration could not
    # answer). Before 0.36 the check lives on the operation's own class.
    my $light = eval { require Odoo::Ops::Rows; 1 };
    my $rows = eval { $light ? Odoo::Ops::Rows->check( \%d, $v, "'$field'" ) : $class->check_rows( \%d, $v, "'$field'" ) };
    unless ($rows) {
        my $e = $@;
        return ( undef, ref $e && $e->can('message') ? $e->message : "'$field' is not a valid list of rows" );
    }
    my $n = 0;
    for my $r (@$v) {
        $n++;
        for my $k ( sort keys %$r ) {
            next if !defined $r->{$k} || ref $r->{$k};
            my $why = _plain_problem( $r->{$k}, key_limit( $d{row}, $k ) );
            return ( undef, "'$field' row $n: '$k' $why" ) if length $why;
        }
    }
    return ( $rows, '' );
}

# SM1162: ONE FILE OF A REQUEST, as the value the operation takes - { name, bytes,
# mimetype } - or ( undef, why, kind ). `kind` is set where it is not plain
# `invalid` (too-large). In this order, each step refusing the whole call:
#   1. the file is not empty and is within THIS binding's cap (file_max_kb);
#   2. its type is read from its BYTES (OOM's sniff), never from the browser;
#   3. the binding's file_types, when it names any, hold that type;
#   4. a type the browser claimed that the bytes contradict is refused (a PDF
#      sent as image/jpeg), a claim the bytes cannot confirm is ignored;
#   5. OOM's own rule for a file value (a plain name, the operation's max_bytes).
# `$f` = { name, bytes, claimed }. Nothing here returns or logs the bytes.
my %SNIFFED = map { $_ => 1 } qw(image/jpeg image/png image/gif image/webp application/pdf);

sub _file_value {
    my ( $b, $class, $decl, $field, $f, $label ) = @_;
    my $bytes = $f->{bytes};
    return ( undef, "$label is empty" ) unless defined $bytes && length $bytes;
    my $cap = ( $b->{file_max_kb} // 0 ) * 1024;
    return ( undef, "$label is " . length($bytes) . " bytes; this binding takes at most $b->{file_max_kb} KB "
            . 'for one file (file_max_kb)', 'too-large' )
        if length $bytes > $cap;

    return ( undef, 'this OOM has no file parameters (0.34 or later)' ) unless eval { require Odoo::Ops::File; 1 };
    my $sniffed = Odoo::Ops::File->sniff($bytes);
    my @types   = @{ $b->{file_types} || [] };
    return ( undef, "$label is $sniffed (read from its bytes); this binding accepts " . join( ', ', @types ) )
        if @types && !grep { $_ eq $sniffed } @types;
    my $claimed = lc( $f->{claimed} // '' );
    $claimed =~ s/\s*;.*//s;
    $claimed = 'image/jpeg' if $claimed =~ m{\Aimage/(?:jpg|pjpeg)\z};
    return ( undef, "$label claims $claimed but its bytes are $sniffed" )
        if $SNIFFED{$claimed} && $claimed ne $sniffed;

    my $name = defined $f->{name} ? $f->{name} : '';
    $name =~ s{.*[/\\]}{};
    $name =~ s/[\x00-\x1f\x7f]//g;
    my %d = %$decl;
    $d{max_bytes} = $DEFAULT_MAX_BYTES unless defined $d{max_bytes};
    ( my $plain = $label ) =~ s/'//g;
    my $v = eval { Odoo::Ops::File->check( $b->{operation}, $plain, { name => $name, bytes => $bytes, mimetype => $sniffed }, \%d ) };
    unless ($v) {
        my $e = $@;
        return ( undef, ( ref $e && $e->can('message') ? $e->message : "$label is not a usable file" ),
            ( ref $e && $e->can('code') && ( $e->code // '' ) eq 'too-large' ? 'too-large' : () ) );
    }
    return ($v);
}

# SM1162: the request's files for field $field -> ( value, '' ) or ( undef, why, kind ).
# A `file` parameter takes one; a `files` parameter takes a list of at most the
# operation's own `max` (and OOM's ten); a set.<field> takes one.
sub _files {
    my ( $b, $class, $decl, $field, $list ) = @_;
    my $t = $decl->{type} // 'str';
    if ( $t ne 'files' ) {
        return ( undef, "'$field' takes one file, and the request sent " . scalar(@$list) ) if @$list > 1;
        my ( $v, $why, $kind ) = _file_value( $b, $class, $decl, $field, $list->[0], "'$field'" );
        return ( undef, $why, $kind ) unless $v;
        return ( $v, '' );
    }
    my $max = defined $decl->{max} && $decl->{max} =~ /\A[0-9]+\z/ ? $decl->{max} : $MAX_FILES;
    $max = $MAX_FILES if $max > $MAX_FILES;
    return ( undef, "'$field' takes at most $max files, and the request sent " . scalar(@$list) ) if @$list > $max;
    my @out;
    my $n = 0;
    for my $f (@$list) {
        $n++;
        my ( $v, $why, $kind ) = _file_value( $b, $class, $decl, $field, $f, "'$field' file $n" );
        return ( undef, $why, $kind ) unless $v;
        push @out, $v;
    }
    return ( \@out, '' );
}

sub assemble {
    my ( $b, $class, $input, %o ) = @_;
    $input = {} unless ref $input eq 'HASH';
    my $spec = $class->params || {};
    my %out;

    my @unmapped = sort grep { !/\A_/ && !exists $b->{params}{$_} } keys %$input;
    return ( undef, 'this binding does not take: ' . join( ', ', @unmapped )
            . ( %{ $b->{params} } ? '. It takes: ' . join( ', ', sort keys %{ $b->{params} } ) : '' ) )
        if $o{strict} && @unmapped;

    for my $field ( sort keys %{ $b->{params} } ) {
        next unless exists $input->{$field};
        my $v    = $input->{$field};
        my $p    = $b->{params}{$field};
        my $decl = param_decl( $spec, $p ) || {};
        my $t    = $decl->{type} // 'str';
        if ( $t eq $ROWS ) {
            next unless defined $v;
            return ( undef, "'$field' cannot be given by a request" )
                unless ref $decl->{row} eq 'HASH' && defined $decl->{max};
            my ( $rows, $rwhy ) = _rows( $b, $class, $decl, $field, $v );
            return ( undef, $rwhy ) unless $rows;
            $out{$p} = $rows;
            next;
        }
        return ( undef, "'$field' must be a single value" ) if ref $v;
        next unless defined $v;
        my $plain = _plain_problem($v);
        return ( undef, "'$field' $plain" )                 if length $plain;
        return ( undef, "'$field' must be a whole number" ) if $t eq 'int' && $v !~ /\A-?[0-9]{1,15}\z/;
        return ( undef, "'$field' must be yes or no" )
            if $t eq 'bool' && $v !~ /\A(?:1|0|yes|no|true|false)\z/i;
        return ( undef, "'$field' cannot be given by a request" ) unless $FROM_INPUT{$t};
        $out{$p} = "$v";
    }
    # SM1162: the files of a multipart request. A file the binding does not map, or a
    # request with files to a binding that maps none, is refused by name.
    if ( my $files = $o{files} ) {
        my @loose = sort grep { !exists $b->{file_params}{$_} } keys %$files;
        return ( undef, "this binding takes no file named '$loose[0]'" . ( %{ $b->{file_params} }
                ? '. It takes: ' . join( ', ', sort keys %{ $b->{file_params} } ) : ' - it takes no file at all' ) )
            if @loose;
        for my $field ( sort keys %{ $b->{file_params} } ) {
            next unless $files->{$field} && @{ $files->{$field} };
            my $p    = $b->{file_params}{$field};
            my $decl = param_decl( $spec, $p ) || {};
            my ( $v, $why, $kind ) = _files( $b, $class, $decl, $field, $files->{$field} );
            return ( undef, $why, $kind ) unless defined $v;
            $out{$p} = $v;
        }
    }
    $out{$_} = $b->{fixed}{$_} for keys %{ $b->{fixed} };
    if ( length $b->{visitor_param} ) {
        return ( undef, 'this binding works for a visitor, and the request carries no visitor '
                . 'key - fetch a token from the Odoo endpoint first' )
            unless defined $o{visitor} && length $o{visitor};
        $out{ $b->{visitor_param} } = $o{visitor};
    }
    for my $p ( sort keys %$spec ) {
        next if exists $out{$p} || defined $spec->{$p}{default};
        my ($field) = grep { $b->{params}{$_} eq $p } keys %{ $b->{params} };
        ($field) = grep { $b->{file_params}{$_} eq $p } keys %{ $b->{file_params} } unless defined $field;
        return ( undef, ( defined $field ? "'$field' is required" : "the operation's '$p' is required" ) )
            if $spec->{$p}{required};
    }
    return ( \%out, '' );
}

1;
