package Odoo::Commands;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Exporter qw(import);
use Scalar::Util qw(looks_like_number);

use Odoo::Error;

our @EXPORT_OK = qw(
    x2m_create x2m_update x2m_delete x2m_unlink x2m_link x2m_clear x2m_set
);
our %EXPORT_TAGS = ( all => \@EXPORT_OK );

=head1 NAME

Odoo::Commands - the x2many write-command grammar, spelled out

=head1 SYNOPSIS

    use Odoo::Commands qw(:all);

    $partner->create({
        name      => 'ACME',
        child_ids => [
            x2m_create({ name => 'Billing', type => 'invoice' }),
            x2m_link(42),
        ],
    });

    $partner->write($id, {
        child_ids => [ x2m_set([ 42, 43 ]) ],
        category_id => [ x2m_clear() ],
    });

=head1 DESCRIPTION

Writing to a one2many or many2many field in Odoo takes a list of
command triplets - C<[0, 0, {vals}]> to create, C<[6, 0, [ids]]> to
replace the set, and so on. The bare numbers are the single most
error-prone part of the raw RPC surface, so this module gives each
one a name and validates its arguments before anything reaches the
wire. The output is plain data; the Model write methods pass it
through untouched.

    x2m_create(\%vals)       [0, 0, vals]   create and link a new record
    x2m_update($id, \%vals)  [1, id, vals]  update a linked record
    x2m_delete($id)          [2, id, 0]     delete the record outright
    x2m_unlink($id)          [3, id, 0]     drop the link, keep the record
    x2m_link($id)            [4, id, 0]     link an existing record
    x2m_clear()              [5, 0, 0]      drop every link
    x2m_set(\@ids)           [6, 0, ids]    replace the set of links

C<x2m_delete>/C<x2m_unlink> differ only for many2many; on a one2many
the record is deleted either way.

=cut

sub _int ($fn, $id) {
    Odoo::Error->throw(
        kind    => 'usage',
        message => "$fn needs an integer record id, got " . ($id // 'undef'),
    ) if !defined $id || ref $id || !looks_like_number($id) || $id != int($id);
    return int($id);
}

sub _vals ($fn, $vals) {
    Odoo::Error->throw(
        kind    => 'usage',
        message => "$fn needs a hashref of values",
    ) if ref $vals ne 'HASH';
    return $vals;
}

sub x2m_create ($vals)      { [ 0, 0, _vals( x2m_create => $vals ) ] }
sub x2m_update ($id, $vals) { [ 1, _int( x2m_update => $id ), _vals( x2m_update => $vals ) ] }
sub x2m_delete ($id)        { [ 2, _int( x2m_delete => $id ), 0 ] }
sub x2m_unlink ($id)        { [ 3, _int( x2m_unlink => $id ), 0 ] }
sub x2m_link   ($id)        { [ 4, _int( x2m_link   => $id ), 0 ] }
sub x2m_clear  ()           { [ 5, 0, 0 ] }

sub x2m_set ($ids) {
    Odoo::Error->throw(
        kind    => 'usage',
        message => 'x2m_set needs an arrayref of record ids',
    ) if ref $ids ne 'ARRAY';
    return [ 6, 0, [ map { _int( x2m_set => $_ ) } @$ids ] ];
}

1;
