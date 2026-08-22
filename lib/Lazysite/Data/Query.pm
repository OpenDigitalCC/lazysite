package Lazysite::Data::Query;

# DP-2: the generated-query grammar - what a page may ask a table for.
#
# THE GRAMMAR IS SMALL ON PURPOSE, and the reason is not taste. Every query
# here is written by an author in front matter, runs on a visitor's request,
# and cannot be reviewed before it runs. So it may express exactly the shapes
# that are cheap and safe against any table, and nothing else:
#
#     items:    db:products                          whole table, declared order
#     open:     db:tasks(done=false,order=due)       filtered and ordered
#     featured: db:products(featured=true,limit=4)
#     total:    db:tasks.count(done=false)           a scalar
#     price:    db:products.field(price,key=SKU1)    one value from one row
#
# AN UNINDEXED FILTER OR ORDER IS ALLOWED, AND REPORTED. It was refused at
# first, on the reasoning that a scan "works on twelve test rows and stops
# working at fifty thousand". That was asserted rather than measured, and the
# measurement does not support it. At 100,000 rows, best of five, warm:
#
#     filter, common value ....  0.04 ms   (LIMIT stops the scan early)
#     filter, rare or absent ..  4.38 ms
#     order by, limit 10 ......  5.63 ms
#     any of them, indexed ....  0.03 ms
#
# So the worst case is about five milliseconds at a hundred thousand rows -
# noise beside forking a Perl CGI - and these tables hold SITE state: a product
# list, an events calendar, a directory. Refusing would have made every author
# of a thirty-row table declare an index and run a migration in order to sort
# by name, demanding database expertise from a system whose premise is that
# authors do not need it, to save about a hundredth of a millisecond. A refusal
# people routinely work around also teaches them to work around refusals.
#
# AND THE ANSWER TO A TABLE BIG ENOUGH TO HURT IS A DIFFERENT ENGINE, not a
# smaller grammar. SQLite is the default because it is one file and no
# administration; a site whose data has outgrown that has outgrown SQLite, and
# DP-7's adapters are where that goes. Restricting what a page may ask would
# not have made such a site work - it would have made it fail differently.
#
# What survives is the DIAGNOSIS: the parser records which fields would scan,
# and a read that actually turns out slow says so in the log - naming the page,
# the binding, the elapsed time and the index that would fix it. A warning that
# fires on real observed cost beats a rule that fires on a guess about it.
#
# ANYTHING BEYOND THIS GRAMMAR IS NOT A GAP TO BE FILLED HERE. Joins,
# subqueries, ranges and OR belong in a named query file that a human reviews,
# which is the escape hatch the brief describes. Growing this grammar until it
# is SQL would put an unreviewed query language in front matter, and the reason
# to have a grammar at all is that front matter is not a place for one.
#
# VALUES ARE VALIDATED AGAINST THE FIELD'S DECLARED TYPE before they go
# anywhere, and then they are BOUND. The binding is what makes them safe; the
# validation is what makes the ERROR good - `done=maybe` on a boolean should
# say so, not return zero rows and let an author conclude the table is empty.

use strict;
use warnings;
use Exporter 'import';
use Lazysite::Data::Value ();

our @EXPORT_OK = qw(parse_binding ROW_CAP);

# The ceiling a page may ask for. select_sql caps again on its own account;
# this one exists so that an author asking for 5000 is TOLD, rather than
# quietly served 1000 and left to wonder where the rest went.
sub ROW_CAP { return 500 }

sub _err { return { ok => 0, error => $_[0] } }

# Would filtering or ordering on this field scan the table? Not a refusal (see
# the header) - the answer travels with the parsed query so that a read which
# turns out slow can say what to index.
#
# A compound index helps its FIRST column and nothing else: SQLite cannot enter
# an index part-way, so an index on (area, street) does nothing for `street=`.
sub _cheap_field {
    my ( $d, $f ) = @_;
    return 1 if $f eq $d->{key};
    return 1 if $d->{timestamps} && $f =~ /\A(?:created_at|updated_at)\z/;
    my $spec = $d->{fields}{$f} or return 0;
    return 1 if ( $spec->{type} // '' ) =~ /\A(?:enum|boolean)\z/;
    for my $ix ( @{ $d->{indexes} // [] } ) {
        return 1 if @{$ix} && $ix->[0] eq $f;
    }
    return 0;
}

# NAMING A FIELD THAT DOES NOT EXIST IS STILL AN ERROR, and it is a different
# kind from an expensive one: it can never work, at any table size, so there is
# nothing to diagnose and nothing to weigh.
sub _is_field {
    my ( $d, $f ) = @_;
    return 1 if exists $d->{fields}{$f} || $f eq $d->{key};
    return 1 if $d->{timestamps} && $f =~ /\A(?:created_at|updated_at)\z/;
    return 0;
}

sub _not_a_field {
    my ( $d, $f, $what ) = @_;
    return "cannot $what by '$f': it is not a field of '$d->{table}'";
}

# `db:table(...)` or `db:table.count(...)`, plus space-separated modifiers.
#
# THE SPACE FORM IS STILL ACCEPTED - `db:products sort=name asc limit=20` -
# because it shipped in 0.10.24 and pages use it. It means exactly what the
# parenthesised form means; there is one code path underneath, so the two
# cannot drift into disagreeing.
sub parse_binding {
    my ( $spec, $d ) = @_;
    $spec = '' unless defined $spec;
    $spec =~ s/\A\s+|\s+\z//g;

    # The `db:` prefix is optional here. The processor strips it before
    # dispatching on it - that is how it knows to call this at all - but the
    # grammar an author writes and every example in the docs includes it, so a
    # parser that refused the documented form would be a trap for every other
    # caller: a test, the manager showing what a binding resolves to, or the
    # next surface to bind a table.
    $spec =~ s/\Adb://;

    # THE PARENTHESISED GROUP COMES OUT FIRST, before anything splits on
    # whitespace. Splitting first meant `db:tasks(title=Fix the roof)` was torn
    # into three pieces and the table name came out as `tasks(title=Fix` - so
    # ANY filter value containing a space was refused, with an error about the
    # table name that pointed nowhere near the problem. A filter value with a
    # space in it is not an edge case; it is a title, a name or an address.
    #
    # First `(` to LAST `)`, so a value may contain a bracket.
    my $args = '';
    if ( $spec =~ s/\((.*)\)//s ) { $args = $1 }

    my ( $head, @mods ) = split /\s+/, $spec;
    return _err('a db: binding needs a table name')
        unless defined $head && length $head;

    my ( $table, $scalar ) = split /\./, $head, 2;
    return _err("'$table' is not a valid table name")
        unless defined $table && $table =~ /\A[a-z][a-z0-9_]*\z/;
    if ( defined $scalar && $scalar !~ /\A(?:count|field)\z/ ) {
        return _err( "'$scalar' is not a scalar - the two are .count(...) "
                . 'and .field(column,key=...)' );
    }

    my %out = ( ok => 1, table => $table, filters => {}, mode => 'snapshot' );
    $out{scalar} = $scalar if defined $scalar;

    # `.field(column,key=K)`: the column is positional and comes first, which
    # is the one place this grammar is not name=value. It reads better at the
    # call site and there is exactly one of it.
    my @parts = grep { length } split /\s*,\s*/, $args;
    if ( ( $out{scalar} // '' ) eq 'field' ) {
        my $col = shift @parts;
        return _err('.field needs a column: db:table.field(column,key=...)')
            unless defined $col && $col =~ /\A[a-z][a-z0-9_]*\z/;
        $out{column} = $col;
    }

    for my $p ( @parts, @mods ) {
        # The space form's bare direction word.
        if ( $p =~ /\A(asc|desc)\z/i ) { $out{order} = lc $1; next }

        my ( $k, $v ) = split /=/, $p, 2;
        next    unless defined $k && length $k;
        $v = '' unless defined $v;

        if ( $k eq 'order' || $k eq 'sort' ) {
            # order=-field is descending. The space form spells the direction
            # as a separate word, so both arrive here and mean one thing.
            if ( $v =~ s/\A-// ) { $out{order} = 'desc' }
            $out{order_by} = $v;
        }
        elsif ( $k eq 'limit' || $k eq 'offset' ) {
            return _err("$k must be a whole number") unless $v =~ /\A\d+\z/;
            return _err( "limit is capped at " . ROW_CAP()
                    . " - ask for fewer rows, or page through them with offset" )
                if $k eq 'limit' && $v > ROW_CAP();
            $out{$k} = $v + 0;
        }
        elsif ( $k eq 'mode' ) {
            return _err("'$v' is not a mode - they are snapshot, live and client")
                unless $v =~ /\A(?:snapshot|live|client)\z/;
            $out{mode} = $v;
        }
        elsif ( $k eq 'writable' ) {
            # Presentation only, and lazysite-data.pl says so at length: the
            # endpoint cannot see which page called it, so this can never gate
            # a write. Carried through for the page's own script to read.
            $out{writable} = [ grep { length } split /\s*\|\s*/, $v ];
        }
        else {
            $out{filters}{$k} = $v;
        }
    }

    return \%out unless ref $d eq 'HASH' && $d->{ok};
    return _validate( \%out, $d );
}

# Everything above is shape. This is the part that needs the descriptor, and it
# is separate so that a caller with no descriptor - the manager showing an
# author what their binding parsed to - still gets the shape.
sub _validate {
    my ( $q, $d ) = @_;

    if ( ( $q->{scalar} // '' ) eq 'field' ) {
        return _err("'$q->{column}' is not a field of '$d->{table}'")
            unless exists $d->{fields}{ $q->{column} };
    }

    $q->{scans} = [];
    for my $f ( sort keys %{ $q->{filters} } ) {
        return _err( _not_a_field( $d, $f, 'filter' ) )
            unless _is_field( $d, $f );
        push @{ $q->{scans} }, $f unless _cheap_field( $d, $f );

        # THE VALUE IS CHECKED AGAINST ITS DECLARED TYPE, and the reason is the
        # error rather than the safety - the value is bound either way.
        # `done=maybe` against a boolean has to SAY so; returning no rows would
        # read as an empty table and send the author looking at their data.
        # coerce_field answers a LIST - ( $error, $value ) - where the error
        # is a string or undef. Taking it in scalar context yields the value
        # and silently discards the error, which is how a rejected filter
        # became the string "0" and blew up two frames later.
        my $spec = $d->{fields}{$f};
        if ($spec) {
            my ( $why, $val )
                = Lazysite::Data::Value::coerce_field( $f, $spec,
                $q->{filters}{$f} );
            return _err($why) if defined $why;
            $q->{filters}{$f} = $val;
        }
    }

    # F-1: THE ORDER THE SITE MEANS, when the binding does not say. A gallery
    # is an ordered list - somebody chose the sequence - and without this a
    # bare `db:gallery` returns rows in whatever order the store hands back,
    # which is insertion order right up until it is not. The binding still
    # wins: this fills a gap, it does not override an author.
    if ( !( defined $q->{order_by} && length $q->{order_by} )
        && defined $d->{default_order} )
    {
        $q->{order_by} = $d->{default_order};
        $q->{order}    = $d->{default_order_dir} // 'asc'
            unless defined $q->{order};
    }

    if ( defined $q->{order_by} && length $q->{order_by} ) {
        return _err( _not_a_field( $d, $q->{order_by}, 'order' ) )
            unless _is_field( $d, $q->{order_by} );

        # ORDER BY IS THE EXPENSIVE ONE, and the one case LIMIT does not
        # rescue: ten rows cannot be chosen without examining every row first.
        # A filter on a common value stops early; this never does.
        push @{ $q->{scans} }, $q->{order_by}
            unless _cheap_field( $d, $q->{order_by} );
    }

    return $q;
}

1;
