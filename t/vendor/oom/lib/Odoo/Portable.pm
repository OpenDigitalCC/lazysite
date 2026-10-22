package Odoo::Portable;

use v5.36;
use strict;
use warnings;
use Scalar::Util ();
use Odoo::JSON ();
use builtin qw(is_bool created_as_number);
no warnings 'experimental::builtin';

our $VERSION = '0.42';

=head1 NAME

Odoo::Portable - a portable reading of Odoo field metadata

=head1 SYNOPSIS

    use Odoo::Portable;
    my %p = Odoo::Portable::describe($fields_get_entry);
    # ( portable_type => 'enum', values => [...], labels => {...} )
    # or () when the Odoo type has no single portable reading

=head1 DESCRIPTION

Consumers that render or collect values without knowing Odoo (a page,
a form, a CLI table) need one small type vocabulary. This module maps
an Odoo C<fields_get> entry onto it, in one place, so no consumer has
to hold Odoo's type names:

    text integer decimal boolean date datetime enum

A C<many2one_reference> (the C<res_id> of a C<res_model>/C<res_id> pair) is
C<integer>.

The mapping is deliberately conservative. A type with more than one
sensible reading gets none: C<many2one> (an id or a display name?),
C<html>, C<binary>, the x2many types, C<reference>, C<json>,
C<properties>. A profile may override per field (see
L<Odoo::Ops::Profile>), for example a C<many2one> that a page should
show as its label becomes C<text>.

Extras travel beside the type when the server states them: C<values>
and C<labels> for an enum (the selection keys and their labels),
C<places> for a decimal (from C<digits>), C<digits> itself.

=cut

my %TYPE = (
    char      => 'text',
    text      => 'text',
    integer   => 'integer',
    many2one_reference => 'integer',    # the id half of a res_model/res_id pair
    float     => 'decimal',
    monetary  => 'decimal',
    boolean   => 'boolean',
    date      => 'date',
    datetime  => 'datetime',
    selection => 'enum',
);

=head2 portable_types

The vocabulary, as a sorted list.

=cut

sub portable_types () { return qw(boolean date datetime decimal enum integer text) }

=head2 describe($fields_get_entry)

Returns a (possibly empty) list of key/value pairs to merge into a
descriptor.

=cut

sub describe ($d) {
    my $pt = $TYPE{ $d->{type} // '' } or return ();
    my %out = ( portable_type => $pt );
    if ( $pt eq 'enum' && ref $d->{selection} eq 'ARRAY' ) {
        $out{values} = [ map { $_->[0] } @{ $d->{selection} } ];
        $out{labels} = { map { $_->[0] => $_->[1] } @{ $d->{selection} } };
    }
    if ( $pt eq 'decimal' && ref $d->{digits} eq 'ARRAY' ) {
        $out{digits} = $d->{digits}[0];
        $out{places} = $d->{digits}[1];
    }
    return %out;
}

=head2 empty_is_false($type)

True for the Odoo field types whose empty value Odoo sends as C<false>:
char, text, html, date, datetime, selection, binary, reference and
many2one. The transports decode C<false> as C<0>, so for these types a
C<0> that arrives from the server is an empty value, not a number. The
decision is by the field's type from C<fields_get>, never by the value.

=cut

my %EMPTY_IS_FALSE = map { $_ => 1 } qw(char text html date datetime selection binary reference many2one);

sub empty_is_false ($type) { return !!$EMPTY_IS_FALSE{ $type // '' } }

=head2 is_false_value($v)

True for what a decoded Odoo C<false> looks like: undef, a false boolean
object, or the number 0. The string C<"0"> is a value.

=cut

sub is_false_value ($v) {
    return 1 if !defined $v;
    if ( ref $v ) {
        return Odoo::JSON::is_bool($v) && !$v ? 1 : 0;
    }
    return 1 if builtin::is_bool($v) && !$v;
    return builtin::created_as_number($v) && $v == 0 ? 1 : 0;
}

=head2 empty_value($type, $v)

The value as the caller sees it: undef (JSON C<null>) when C<$type> is
one whose empty Odoo sends as C<false> and C<$v> is that C<false>;
otherwise C<$v> unchanged. A boolean, a number and a real string
C<"0"> pass through.

=cut

sub empty_value ($type, $v) {
    return $v if !empty_is_false($type);
    return is_false_value($v) ? undef : $v;
}

=head2 empty_row($fields, $row)

A row read from Odoo with every empty value of the types above set to
undef. C<$fields> is the model's C<fields_get>. The row is changed in
place and returned; keys with no known type are left alone.

=cut

sub empty_row ($fields, $row) {
    return $row if ref $row ne 'HASH';
    for my $k ( keys %$row ) {
        my $t = $fields->{$k} && $fields->{$k}{type};
        next if !defined $t || !empty_is_false($t);
        $row->{$k} = undef if is_false_value( $row->{$k} );
    }
    return $row;
}

=head2 is_portable_type($name)

True for a member of the vocabulary.

=cut

sub is_portable_type ($name) {
    my %ok = map { $_ => 1 } portable_types();
    return !!$ok{ $name // '' };
}

1;
