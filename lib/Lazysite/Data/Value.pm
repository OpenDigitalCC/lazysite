package Lazysite::Data::Value;

# SM447: the write-side validation and coercion layer.
#
# THE OTHER HALF OF THE INVARIANT. SQLite.pm's header says values are bound,
# always, so a value containing SQL metacharacters is stored and returned
# verbatim because it never reaches the parser as syntax. Binding is what makes
# a value SAFE; it does nothing to make it CORRECT. This file is where a value
# becomes correct, and it is the only place that decides.
#
# ONE IMPLEMENTATION, NOT ONE PER ENGINE. Every type promise the adapter makes
# in a comment is kept here rather than in generated DDL:
#
#   decimal  -> a canonical string, because SQLite's REAL is a double and money
#               in a double is the bug the type exists to prevent.
#   boolean  -> 0/1, normalised, because SQLite has no boolean and accepting
#               'true' into a TEXT column makes the round-trip depend on how it
#               was written.
#   date     -> ISO 8601, calendar-checked.
#   enum     -> membership.
#   defaults -> applied when a write OMITS the field.
#
# Doing any of that in DDL would put each engine's dialect in charge of a
# decision that must not vary between them, and would put values into generated
# SQL text - which the invariant above forbids.
#
# REJECT, DO NOT REPAIR. A value that does not fit its declared type is
# refused with the field named, not coerced into something plausible. The
# sharpest case is decimal: 12.345 into a places=2 column is REFUSED rather
# than rounded, because a store that silently rounds money is worse than one
# that will not take it - the caller learns nothing, and the difference
# surfaces later as an unexplained discrepancy in a total.
#
# ERRORS ARE RETURNED, NOT THROWN, in the same shape Descriptor.pm uses. Every
# caller is a surface with a person on the other end - the manager grid, a CSV
# import, a form post - and each of them needs to say WHICH field and WHY.

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(coerce_row coerce_field);

my %RESERVED = map { $_ => 1 } qw(created_at updated_at);

sub _err {
    my ( $error, %extra ) = @_;
    return { ok => 0, kind => 'value', error => $error, %extra };
}

# Days in month, with the leap rule spelled out rather than delegated to a
# module the render path may not load. A date column whose value is 2025-02-30
# is a date column in name only.
sub _valid_ymd {
    my ( $y, $m, $d ) = @_;
    return 0 if $m < 1 || $m > 12 || $d < 1;
    my @len = ( 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 );
    my $max = $len[ $m - 1 ];
    $max = 29 if $m == 2 && ( ( $y % 4 == 0 && $y % 100 != 0 ) || $y % 400 == 0 );
    return $d <= $max;
}

# A single value against a single field spec. Returns (undef, $value) on
# success or ($error_string) on failure - the caller decorates with the field
# name, so the messages here read the same wherever they surface.
sub coerce_field {
    my ( $name, $spec, $v ) = @_;
    my $type = $spec->{type} // '';

    # A JSON BOOLEAN IS A SCALAR WEARING AN OBJECT.
    #
    # `ref $v` is true for JSON::PP::Boolean, so `{"live": false}` - the one
    # representation a JSON client naturally sends - was refused as "a list or
    # mapping" while the strings "true"/"false", the integers 1/0 and even
    # "yes" were all accepted. Reported from the field, who noted the giveaway:
    # the coercion itself was correct, nothing stored was inverted, so the
    # fault was in the guard rather than the conversion.
    #
    # Unwrapped to 1/0 before anything else looks at it, so every type below
    # sees a plain scalar - a boolean field then normalises it as usual, and a
    # boolean sent to a text field is a type error with the right message
    # rather than a shape error with the wrong one.
    if ( ref $v eq 'JSON::PP::Boolean' ) { $v = $v ? 1 : 0 }

    return "field '$name': a value cannot be a list or mapping" if ref $v;

    # An empty string is ABSENCE, not a value, for every type except text.
    # A number field given "" means the operator cleared it; storing 0 there
    # would be inventing data, and storing "" would break the type's own
    # round-trip. text keeps it, because an empty string is a legitimate
    # thing to write into a text column and is distinguishable from NULL.
    if ( !defined $v || ( $type ne 'text' && $v eq '' ) ) {
        return ( undef, undef );
    }

    if ( $type eq 'text' ) {
        my $max = $spec->{max};
        return "field '$name': longer than the declared maximum of $max "
            . 'characters'
            if defined $max && length($v) > $max;
        return ( undef, $v );
    }

    if ( $type eq 'integer' ) {
        return "field '$name': '$v' is not a whole number"
            unless $v =~ /\A-?\d+\z/;
        return "field '$name': $v is below the declared minimum of "
            . $spec->{min}
            if defined $spec->{min} && $v < $spec->{min};
        return "field '$name': $v is above the declared maximum of "
            . $spec->{max}
            if defined $spec->{max} && $v > $spec->{max};
        return ( undef, 0 + $v );
    }

    if ( $type eq 'boolean' ) {
        # Accepted spellings are fixed and small. A wider set (on/off, y/n, -1)
        # would make the store's answer depend on which surface wrote the row.
        return ( undef, 1 ) if $v =~ /\A(?:1|true|yes)\z/i;
        return ( undef, 0 ) if $v =~ /\A(?:0|false|no)\z/i;
        return "field '$name': '$v' is not a yes/no value "
            . '(1/0, true/false, yes/no)';
    }

    if ( $type eq 'decimal' ) {
        my ( $digits, $places ) = ( $spec->{digits}, $spec->{places} );
        return "field '$name': '$v' is not a decimal number"
            unless $v =~ /\A(-?)(\d+)(?:\.(\d+))?\z/;
        my ( $sign, $int, $frac ) = ( $1, $2, $3 // '' );

        # REFUSED, NOT ROUNDED. See the header: a store that quietly rounds
        # money is worse than one that will not take it.
        return "field '$name': '$v' has more than $places decimal place"
            . ( $places == 1 ? '' : 's' )
            if length($frac) > $places;

        $int =~ s/\A0+(?=\d)//;    # canonical: no leading zeros
        my $whole = $digits - $places;
        return "field '$name': '$v' has more than $whole digit"
            . ( $whole == 1 ? '' : 's' )
            . ' before the decimal point'
            if length($int) > $whole;

        $frac .= '0' x ( $places - length $frac );
        my $out = $sign . $int . ( $places ? ".$frac" : '' );
        # -0 and -0.00 are the same number as 0, and two spellings of one
        # value in a key or a comparison is a defect waiting for a report.
        $out =~ s/\A-(?=0(?:\.0*)?\z)//;
        return ( undef, $out );
    }

    if ( $type eq 'date' ) {
        return "field '$name': '$v' is not a date (YYYY-MM-DD)"
            unless $v =~ /\A(\d{4})-(\d{2})-(\d{2})\z/;
        return "field '$name': '$v' is not a real date"
            unless _valid_ymd( $1, $2, $3 );
        return ( undef, $v );
    }

    if ( $type eq 'datetime' ) {
        # UTC, and normalised to one spelling. A space separator and a missing
        # Z are both common enough to accept from a form or a CSV; storing
        # them as written would make string comparison - which is how these
        # sort and filter - disagree with chronology.
        return "field '$name': '$v' is not a date and time "
            . '(YYYY-MM-DD HH:MM:SS, UTC)'
            unless $v =~ /\A(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})Z?\z/;
        my ( $y, $mo, $d, $h, $mi, $s ) = ( $1, $2, $3, $4, $5, $6 );
        return "field '$name': '$v' is not a real date" unless _valid_ymd( $y, $mo, $d );
        return "field '$name': '$v' is not a real time"
            if $h > 23 || $mi > 59 || $s > 59;
        return ( undef, "$y-$mo-${d}T$h:$mi:${s}Z" );
    }

    if ( $type eq 'enum' ) {
        my @values = @{ $spec->{values} || [] };
        return ( undef, $v ) if grep { $_ eq $v } @values;
        return "field '$name': '$v' is not one of its declared values ("
            . join( ', ', @values ) . ')';
    }

    # Unreachable through a loaded descriptor, which refuses unknown types.
    return "field '$name': no validation rule for type '$type'";
}

# A whole row against a loaded descriptor.
#
# partial => 1 for an UPDATE: absent means "leave alone", so defaults are not
# applied and required is not enforced. Applying a default on update would
# silently rewrite a field the caller never mentioned, which is the one thing
# a partial update must not do.
sub coerce_row {
    my ( $d, $input, %opt ) = @_;
    return _err('a loaded descriptor is required')
        unless ref $d eq 'HASH' && $d->{ok};
    return _err('a row must be a mapping of fields')
        unless ref $input eq 'HASH';

    my $partial = $opt{partial} ? 1 : 0;
    my $fields  = $d->{fields};
    my %out;

    # THE AUTO KEY IS CHECKED FIRST, and the order is the whole point.
    #
    # An auto key is not listed in `fields` - it is implicit - so the unknown-
    # field loop below reaches it first and says "'id' is not a field of
    # 'notes'". That is refused for the right reason and reported for the
    # wrong one: `id` IS the key, and an operator told it does not exist will
    # go looking for what they mis-spelled instead of learning that the store
    # assigns it.
    if ( $d->{auto_key} && exists $input->{ $d->{key} } && !$partial ) {
        return _err(
            "'$d->{key}' is assigned by the store and cannot be supplied",
            field => $d->{key}, rule => 'auto_key' );
    }

    # DM-3: THE KEY CANNOT BE CHANGED BY AN UPDATE, and that used to be
    # enforced by dropping it. update_sql deleted the key from the SET list -
    # its comment says why, correctly - and the update then reported ok with
    # the row unmoved. So a caller who asked to re-key a row got success and
    # did not get what they asked for, which is SM479's shape: every signal
    # says it worked, and it did not.
    #
    # A key is the row's ADDRESS. Changing it is a delete-and-insert wearing
    # the name of an edit, and the honest answer is to say so. Refused for
    # both kinds of key: an auto id on a partial write was already silently
    # discarded by the same delete, and a natural key is the case the row
    # editor renders read-only - the server has to agree, or that attribute
    # is decoration a client can remove.
    if ( $partial && exists $input->{ $d->{key} } ) {
        return _err(
            "'$d->{key}' is the row's key and cannot be changed by an update. "
                . 'To move a row to a new key, delete it and add it again.',
            field => $d->{key}, rule => 'key_immutable' );
    }

    # UNKNOWN FIELDS ARE REFUSED, matching Descriptor.pm's stance. Ignoring
    # them would let a typo in a column name look like a successful write and
    # lose the value - the operator sees "saved" and the data is not there.
    for my $f ( sort keys %{$input} ) {
        return _err( "'$f' is maintained by the plugin and cannot be written",
            field => $f, rule => 'reserved' )
            if $RESERVED{$f};
        return _err( "'$f' is not a field of '$d->{table}'",
            field => $f, rule => 'unknown' )
            unless exists $fields->{$f};
    }

    for my $f ( sort keys %{$fields} ) {
        my $spec = $fields->{$f};

        if ( !exists $input->{$f} ) {
            next if $partial;
            if ( defined $spec->{default} ) {
                # The default goes through the SAME coercion as a supplied
                # value. A descriptor default is author-written text and has
                # no more claim to being well-formed than a form field does.
                my ( $why, $value ) = coerce_field( $f, $spec, $spec->{default} );
                return _err( "default for $why", field => $f, rule => 'default' )
                    if defined $why;
                $out{$f} = $value;
                next;
            }
            return _err( "'$f' is required", field => $f, rule => 'required' )
                if $spec->{required};
            next;
        }

        my ( $why, $value ) = coerce_field( $f, $spec, $input->{$f} );
        return _err( $why, field => $f, rule => 'type' ) if defined $why;

        # Required means present AND not empty. A required text field given ""
        # has been left blank, whatever the transport called it.
        return _err( "'$f' is required", field => $f, rule => 'required' )
            if $spec->{required}
            && ( !defined $value || ( !ref $value && $value eq '' ) );

        $out{$f} = $value;
    }

    # The key must resolve to something on a full write, or the row has no
    # identity. Checked after coercion so the message is about the value.
    if ( !$d->{auto_key} && !$partial ) {
        my $k = $d->{key};
        return _err( "'$k' identifies the row and is required",
            field => $k, rule => 'key' )
            unless defined $out{$k} && length $out{$k};
    }

    return { ok => 1, values => \%out };
}

1;
