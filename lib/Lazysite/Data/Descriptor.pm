package Lazysite::Data::Descriptor;

# SM447: field descriptors - load, validate, REJECT.
#
# The data layer's central claim is that an agent can persist and recall data
# without seeing SQL, and that typing is strict BECAUSE agents do the work.
# Everything downstream - the generated DDL, the bound-parameter DML, the
# migration diff, the form generation - reads its identifiers and its types
# from here. So this file is the boundary, and it has two jobs that must not
# be confused:
#
#   1. TYPING. A mistyped datum is corruption, not a cosmetic fault. This
#      deliberately inverts the theme layer's warn-only philosophy: a missing
#      theme token falls back gracefully; a wrong type does not.
#
#   2. IDENTIFIER SAFETY. Values reach SQL only as bound parameters, but
#      identifiers - table and column names - CANNOT be bound. They are
#      interpolated into generated statements. So the only thing standing
#      between a descriptor and an injected identifier is this validation,
#      and it runs at LOAD, once, rather than at query time, repeatedly.
#      Rejecting here means nothing downstream has to remember to escape.
#
# Errors follow the connector convention so an agent can act on them without
# parsing prose: { ok => 0, kind => 'descriptor'|'validation', error, field,
# rule }. `descriptor` faults are in the FILE; `validation` faults are in a
# VALUE offered against a loaded descriptor.
#
# YAML (pure Perl) rather than YAML::XS: the SBOM posture prefers a declared
# dependency without a compiled one, and descriptors are read once and cached,
# so parse speed decides nothing here.

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(load_descriptor load_all validate_row TYPES);

# The v1 type set, kept deliberately tight - extended later only with cause.
# A type is present here or it is rejected; there is no permissive default,
# because a default is how an unknown type becomes a silent text column.
my %TYPE = map { $_ => 1 } qw(text integer decimal boolean date datetime enum);

sub TYPES { return sort keys %TYPE }

# Identifiers: [a-z][a-z0-9_]* and nothing else.
#
# Not a style rule. These are interpolated into generated SQL because SQL
# cannot bind an identifier, so this pattern is the whole defence. It is
# deliberately narrower than any engine would accept - no quotes, no dots, no
# spaces, no capitals, no leading digit - so that a name which passes here
# needs no quoting or escaping in any dialect we generate for.
my $IDENT = qr/\A[a-z][a-z0-9_]*\z/;

# Reserved because the plugin owns them: `timestamps: true` creates them, and
# a descriptor declaring its own would collide with the ones we maintain.
my %RESERVED = map { $_ => 1 } qw(created_at updated_at);

sub _err {
    my ( $kind, $error, %extra ) = @_;
    return { ok => 0, kind => $kind, error => $error, %extra };
}

sub _bad_ident {
    my ($name) = @_;
    return 'a name is required' unless defined $name && length $name;
    return "'$name' must be lower-case letters, digits and underscores, "
        . 'starting with a letter'
        unless $name =~ $IDENT;
    return undef;
}

# --- field-level descriptor checks -----------------------------------------
#
# Each returns an error string, or undef. Split per type so a new type adds
# one branch rather than editing a conditional nobody can read.
sub _check_field {
    my ( $name, $spec ) = @_;

    return "field '$name': must be a mapping of properties"
        unless ref $spec eq 'HASH';

    my $type = $spec->{type};
    return "field '$name': no type given (one of: " . join( ', ', TYPES() ) . ')'
        unless defined $type && length $type;
    return "field '$name': unknown type '$type' (one of: "
        . join( ', ', TYPES() ) . ')'
        unless $TYPE{$type};

    if ( $type eq 'enum' ) {
        my $v = $spec->{values};
        return "field '$name': enum needs a values list"
            unless ref $v eq 'ARRAY' && @{$v};
        for my $val ( @{$v} ) {
            return "field '$name': enum values must be simple scalars"
                if ref $val;
            return "field '$name': enum values cannot be empty"
                unless defined $val && length $val;
        }
        my %seen;
        for my $val ( @{$v} ) {
            return "field '$name': duplicate enum value '$val'" if $seen{$val}++;
        }
        if ( defined $spec->{default} ) {
            return "field '$name': default '$spec->{default}' is not one of "
                . 'its enum values'
                unless grep { $_ eq $spec->{default} } @{$v};
        }
    }
    elsif ( $type eq 'decimal' ) {
        # Declared precision, because money must never be a float. Both parts
        # are required: a decimal without them is a float wearing a name.
        for my $k (qw(digits places)) {
            return "field '$name': decimal needs '$k'"
                unless defined $spec->{$k};
            return "field '$name': '$k' must be a non-negative whole number"
                unless $spec->{$k} =~ /\A\d+\z/;
        }
        return "field '$name': places ($spec->{places}) cannot exceed "
            . "digits ($spec->{digits})"
            if $spec->{places} > $spec->{digits};
    }
    elsif ( $type eq 'text' ) {
        if ( defined $spec->{max} ) {
            return "field '$name': max must be a positive whole number"
                unless $spec->{max} =~ /\A\d+\z/ && $spec->{max} > 0;
        }
        if ( defined $spec->{widget} ) {
            return "field '$name': widget must be 'input' or 'textarea'"
                unless $spec->{widget} =~ /\A(?:input|textarea)\z/;
        }
    }
    elsif ( $type eq 'integer' ) {
        for my $k (qw(min max)) {
            next unless defined $spec->{$k};
            return "field '$name': $k must be a whole number"
                unless $spec->{$k} =~ /\A-?\d+\z/;
        }
        return "field '$name': min cannot exceed max"
            if defined $spec->{min}
            && defined $spec->{max}
            && $spec->{min} > $spec->{max};
    }

    # `values` on a non-enum is almost certainly a mistake rather than
    # harmless surplus - it reads as a constraint and enforces nothing.
    return "field '$name': 'values' only applies to enum"
        if $type ne 'enum' && defined $spec->{values};

    return undef;
}

# --- whole-descriptor load --------------------------------------------------

sub load_descriptor {
    my ( $name, $raw ) = @_;

    if ( my $why = _bad_ident($name) ) {
        return _err( 'descriptor', "table name: $why", field => $name );
    }
    return _err( 'descriptor', "table '$name': descriptor must be a mapping" )
        unless ref $raw eq 'HASH';

    my $fields = $raw->{fields};
    return _err( 'descriptor', "table '$name': no fields declared" )
        unless ref $fields eq 'HASH' && %{$fields};

    for my $f ( sort keys %{$fields} ) {
        if ( my $why = _bad_ident($f) ) {
            return _err( 'descriptor', "table '$name': field name: $why",
                field => $f, rule => 'identifier' );
        }
        return _err( 'descriptor',
            "table '$name': '$f' is maintained by the plugin "
                . '(set timestamps: true to have it)',
            field => $f, rule => 'reserved' )
            if $RESERVED{$f};

        if ( my $why = _check_field( $f, $fields->{$f} ) ) {
            return _err( 'descriptor', "table '$name': $why",
                field => $f, rule => 'type' );
        }
    }

    # The key: 'id' means an auto integer the plugin owns and no field may
    # shadow. Anything else must name a declared field.
    my $key = defined $raw->{key} ? $raw->{key} : 'id';
    if ( my $why = _bad_ident($key) ) {
        return _err( 'descriptor', "table '$name': key: $why", rule => 'key' );
    }
    if ( $key eq 'id' ) {
        return _err( 'descriptor',
            "table '$name': 'id' is the automatic key and cannot also be a field",
            field => 'id', rule => 'key' )
            if $fields->{id};
    }
    else {
        return _err( 'descriptor',
            "table '$name': key '$key' is not one of its fields",
            field => $key, rule => 'key' )
            unless $fields->{$key};
        # A natural key carries required+unique by implication, and saying so
        # here means the DDL generator does not have to infer it.
        return _err( 'descriptor',
            "table '$name': key '$key' must be type text",
            field => $key, rule => 'key' )
            unless ( $fields->{$key}{type} // '' ) eq 'text';
    }

    # Indexes name declared fields, in order.
    my $indexes = $raw->{indexes} // [];
    return _err( 'descriptor', "table '$name': indexes must be a list" )
        unless ref $indexes eq 'ARRAY';
    for my $ix ( @{$indexes} ) {
        return _err( 'descriptor',
            "table '$name': each index must be a list of field names",
            rule => 'index' )
            unless ref $ix eq 'ARRAY' && @{$ix};
        for my $f ( @{$ix} ) {
            next if $fields->{$f};
            next if $key ne 'id' && $f eq $key;
            return _err( 'descriptor',
                "table '$name': index names '$f', which is not a field",
                field => $f, rule => 'index' );
        }
    }

    my $wb = $raw->{writable_by} // [];
    return _err( 'descriptor', "table '$name': writable_by must be a list" )
        unless ref $wb eq 'ARRAY';
    for my $g ( @{$wb} ) {
        return _err( 'descriptor',
            "table '$name': writable_by group names must be plain names",
            rule => 'writable_by' )
            unless defined $g && !ref $g && $g =~ /\A[A-Za-z0-9_-]+\z/;
    }

    return {
        ok          => 1,
        table       => $name,
        title       => $raw->{title} // $name,
        key         => $key,
        auto_key    => ( $key eq 'id' ? 1 : 0 ),
        fields      => $fields,
        indexes     => $indexes,
        writable_by => $wb,
        timestamps  => ( $raw->{timestamps} ? 1 : 0 ),
    };
}

1;
