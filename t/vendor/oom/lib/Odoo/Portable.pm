package Odoo::Portable;

use v5.36;
use strict;
use warnings;

our $VERSION = '0.09';

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

=head2 is_portable_type($name)

True for a member of the vocabulary.

=cut

sub is_portable_type ($name) {
    my %ok = map { $_ => 1 } portable_types();
    return !!$ok{ $name // '' };
}

1;
