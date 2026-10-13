package Lazysite::Odoo::Fields;

# SM747 R (ruled R4 and Q3, 2026-10-12): ODOO'S FIELD DESCRIPTORS IN THE DATA
# EXTENSION'S TERMS - THROUGH A PORTABLE TYPE, NEVER A GUESS.
#
# R4 ruled that Odoo field descriptors share lazysite's data-table rendering.
# That rendering knows seven types (Lazysite::Data::Descriptor): text, integer,
# decimal, boolean, date, datetime, enum. Odoo knows more, several with no single
# reading, and choosing a reading is Odoo knowledge - which the boundary rule
# (t/lint/240) keeps out of lazysite. Q3 put the mapping to OOM ("maybe put
# options to oom inbox"; filed 2026-10-12) and asked that R be built against an
# interface that takes the PORTABLE type from OOM if present, else refuses to
# render the field.
#
# THIS IS THAT INTERFACE. Per field it reads exactly:
#
#   portable_type   one of the seven, or the field is REFUSED by name - Odoo's
#                   own `type` is never read, so there is nothing to guess from
#   values          for enum
#   digits places   for decimal (the data extension requires both: a decimal
#                   without them is a float wearing a name)
#   string          the label
#   required        as Odoo says it
#
# and validates the result with the data extension's OWN descriptor check, so a
# field drawn from Odoo is exactly as well-formed as one a site declares - one
# definition of a field, not two that could disagree about what a decimal is.
#
# The key name is one constant: OOM may choose another (the options paper asks),
# and this is where lazysite follows.
use strict;
use warnings;
use Lazysite::Data::Descriptor qw(load_descriptor TYPES);

our $TYPE_KEY = 'portable_type';

my %TYPE = map { $_ => 1 } TYPES();

# The operation's parameter types (OOM's vocabulary, not Odoo's) that a request
# may feed, as the data extension draws them. The rest are never a form field:
# Lazysite::Odoo::Binding refuses them as request input.
my %PARAM_TYPE = ( str => 'text', int => 'integer', bool => 'boolean' );

# descriptor_fields( \%descriptors ) -> ( \%fields, \@refused )
#
# %fields is a data-extension `fields` hash, drawable as a table's columns;
# @refused is { field, why } for every field that could not be drawn, so a page
# or an operator can be told which and why rather than see a column vanish.
sub descriptor_fields {
    my ($odoo) = @_;
    my ( %fields, @refused );
    return ( \%fields, [ { field => '', why => 'the descriptors are not a mapping' } ] )
        unless ref $odoo eq 'HASH';
    for my $name ( sort keys %$odoo ) {
        my ( $spec, $why ) = _one( $name, $odoo->{$name} );
        if ($spec) { $fields{$name} = $spec }
        else       { push @refused, { field => $name, why => $why } }
    }
    return ( \%fields, \@refused );
}

sub _one {
    my ( $name, $d ) = @_;
    return ( undef, 'not a field name lazysite can draw' ) unless $name =~ /\A[a-z][a-z0-9_]*\z/;
    return ( undef, 'its descriptor is not a mapping' ) unless ref $d eq 'HASH';
    my $t = $d->{$TYPE_KEY};
    return ( undef, "it has no $TYPE_KEY, and lazysite does not guess one from Odoo's type" )
        unless defined $t && length $t;
    return ( undef, "its $TYPE_KEY '$t' is not one of: " . join( ', ', sort keys %TYPE ) )
        if ref $t || !$TYPE{$t};

    my %spec = ( type => $t );
    $spec{title} = "$d->{string}" if defined $d->{string} && !ref $d->{string} && length $d->{string};
    $spec{required} = $d->{required} ? 'true' : 'false';
    if ( $t eq 'enum' ) {
        return ( undef, 'an enum needs its values' ) unless ref $d->{values} eq 'ARRAY' && @{ $d->{values} };
        $spec{values} = [ @{ $d->{values} } ];
    }
    if ( $t eq 'decimal' ) {
        for my $k (qw(digits places)) {
            return ( undef, "a decimal needs $k, and lazysite does not guess the precision of money" )
                unless defined $d->{$k};
            $spec{$k} = $d->{$k};
        }
    }

    # The data extension's own check. The name is set aside - an Odoo `id` is a
    # row's key, which a site's descriptor reserves - so what is checked is the
    # SPEC, under a name the check accepts.
    my $r = load_descriptor( 'odoo_field', { fields => { field => {%spec} } } );
    return ( undef, ( $r->{error} // 'it is not a field the data extension can draw' ) =~ s/table 'odoo_field': //r )
        if ref $r eq 'HASH' && exists $r->{ok} && !$r->{ok};
    return ( \%spec, '' );
}

# present( $report ) -> ( \%fields, \@refused ), or () when the report carries
# no descriptors to draw.
#
# OOM agreed (0.02, answering R-Q1) that a display read returns `rows` beside
# `fields`: the descriptors, keyed as the rows are, each with its portable type.
# A report whose `fields` is anything else - a list of names, as before 0.02, or
# nothing - is not a display read, and every door hands it over as it always
# did. The Odoo key name is not read here either: descriptor_fields reads only
# the portable type.
sub present {
    my ($report) = @_;
    return () unless ref $report eq 'HASH' && ref $report->{fields} eq 'HASH';
    return descriptor_fields( $report->{fields} );
}

# page_report( $report ) -> $report for a template
#
# What a PAGE is handed: the report with `fields` drawn, `refused` named, and the
# rows cut to the drawn columns - a value of a field lazysite refused to draw is
# never put on a page, which is the point of refusing it. A report with no
# descriptors comes back as it is.
sub page_report {
    my ($report) = @_;
    my ( $fields, $refused ) = present($report);
    return $report unless $fields;
    my %out = %$report;
    $out{fields}  = $fields;
    $out{refused} = $refused;
    if ( ref $report->{rows} eq 'ARRAY' ) {
        $out{rows} = [
            map {
                my $row = $_;
                ref $row eq q{HASH}
                    ? { map { ( $_ => $row->{$_} ) } grep { exists $fields->{$_} } keys %$row }
                    : $row
            } @{ $report->{rows} }
        ];
    }
    return \%out;
}

# form_fields( \%binding, $op_class ) -> \%fields
#
# The parameter form: one field per name the binding lets a request set, typed
# from the operation's declaration (OOM's str, int, bool), required where the
# operation requires it and gives no default. The field is named by the
# REQUEST's name, so a form drawn from this posts what the binding maps.
sub form_fields {
    my ( $b, $class ) = @_;
    my $spec = $class->params || {};
    my %fields;
    for my $field ( sort keys %{ $b->{params} || {} } ) {
        my $p = $spec->{ $b->{params}{$field} }    or next;
        my $t = $PARAM_TYPE{ $p->{type} // 'str' } or next;
        $fields{$field} = {
            type => $t,
            required => ( $p->{required} && !defined $p->{default} ) ? 'true' : 'false',
            ( defined $p->{help} && length $p->{help} ? ( title => "$p->{help}" ) : () ),
            ( defined $p->{default} && !ref $p->{default} ? ( default => "$p->{default}" ) : () ),
        };
    }
    return \%fields;
}

1;
