package Odoo::Record;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Scalar::Util qw(blessed looks_like_number);
use Time::Piece ();

use Odoo::Error;
use Odoo::Commands qw(x2m_set);

=head1 NAME

Odoo::Record - one Odoo record with schema-driven accessors

=head1 SYNOPSIS

    my $partner = $odoo->model('res.partner')->browse($id);

    say $partner->name;                  # field accessor, from live schema
    my $parent = $partner->parent_id;    # many2one -> Odoo::Record (or undef)
    my $kids   = $partner->child_ids;    # x2many   -> Odoo::RecordSet

    $partner->name('New name');          # accessors write too...
    $partner->parent_id($other);         # ...taking a Record or an id
    $partner->child_ids([ 42, 43 ]);     # ids collapse to x2m_set
    say for $partner->dirty;
    $partner->save;                      # writes only what changed

    $partner->update({ ref => 'X1' });   # set + save in one step
    $partner->delete;

=head1 DESCRIPTION

A record is lazy twice over: C<browse> costs no RPC, the row loads on
first access (the model's C<default_fields> unless C<fields> narrowed
it, with binary/x2many/non-stored fields fetched individually on
demand), and relation traversal builds records and sets that are lazy
in turn. Accessors are not generated ahead of time - AUTOLOAD consults
the model's cached C<fields_get> metadata, so any field the server
knows is an accessor already.

Real methods always win over field names: a field that collides with
a method here (or in a behaviour overlay) is still reachable through
C<get>/C<set>. Local writes are visible to C<get> immediately
(read-your-writes) and reach the server only on C<save>.

=head1 METHODS

Beyond the per-field accessors: C<id>, C<model> (the handle),
C<model_name>, C<get($field)>, C<set(%field_values)>, C<dirty>,
C<save>, C<update(\%vals)>, C<delete>, C<refresh>, C<exists>,
C<has_field($name)>, C<dt($field)> (Time::Piece in UTC, or undef),
C<to_hash>.

=cut

sub new ($class, %args) {
    for my $req (qw(model id)) {
        Odoo::Error->throw(kind => 'config', message => "$req required")
            if !defined $args{$req};
    }
    my $self = bless {
        model   => $args{model},
        id      => $args{id},
        data    => $args{data} // {},
        loaded  => $args{data} ? 1 : 0,
        fields  => $args{fields},
        changes => {},
    }, $class;
    return $self;
}

sub id         ($self) { $self->{id} }
sub model      ($self) { $self->{model} }
sub model_name ($self) { $self->{model}->name }
sub dirty      ($self) { sort keys %{ $self->{changes} } }
sub has_field  ($self, $name) { exists $self->{model}->fields->{$name} }

sub _load ($self) {
    return $self if $self->{loaded};
    my $row = $self->{model}->read_one( $self->{id},
        $self->{fields} // $self->{model}->default_fields );
    Odoo::Error->throw(
        kind    => 'fault',
        message => $self->model_name . " record $self->{id} does not exist",
    ) if !$row;
    $self->{data}   = $row;
    $self->{loaded} = 1;
    return $self;
}

sub exists ($self) {
    return 1 if $self->{loaded};
    return $self->{model}->count( [ [ 'id', '=', $self->{id} ] ] ) ? 1 : 0;
}

sub refresh ($self) {
    $self->{loaded}  = 0;
    $self->{changes} = {};
    return $self->_load;
}

=head2 get($field)

The value as read: many2one comes back as C<[id, display_name]> or
undef when empty, x2many as an arrayref of ids; an empty char, text,
html, date, datetime, selection or binary field is undef. Pending local changes shadow the
stored value. A field outside the loaded set (binary, x2many,
non-stored - see C<default_fields> in L<Odoo::Model>) is fetched on
demand with a single-field read and cached.

=cut

sub get ($self, $field) {
    $self->{model}->describe($field);    # dies on unknown field
    return $self->{changes}{$field} if exists $self->{changes}{$field};
    return $self->_stored($field);
}

sub _stored ($self, $field) {
    $self->_load;
    if ( !exists $self->{data}{$field} ) {
        my $row = $self->{model}->read_one( $self->{id}, [$field] );
        Odoo::Error->throw(
            kind    => 'fault',
            message => $self->model_name . " record $self->{id} does not exist",
        ) if !$row;
        $self->{data}{$field} = $row->{$field};
    }
    return $self->{data}{$field};
}

sub set ($self, %vals) {
    for my $field ( keys %vals ) {
        my $meta = $self->{model}->describe($field);
        $self->{changes}{$field} =
            _collapse_for_write( $meta, $vals{$field} );
    }
    return $self;
}

# Turn friendly accessor values into wire values: Records become ids,
# a list of ids/Records on an x2many becomes one x2m_set, command
# triplets pass through untouched.
sub _collapse_for_write ($meta, $val) {
    my $type = $meta->{type} // '';
    if ( $type eq 'many2one' ) {
        return $val if !$val;
        return $val->id if blessed($val) && $val->isa('Odoo::Record');
        return $val if !ref $val;
        Odoo::Error->throw(
            kind    => 'usage',
            message => 'many2one takes a record id, an Odoo::Record, or false',
        );
    }
    if ( $type eq 'one2many' || $type eq 'many2many' ) {
        Odoo::Error->throw(
            kind    => 'usage',
            message => "$type takes an arrayref of ids, Odoo::Records, or command triplets",
        ) if ref $val ne 'ARRAY';
        my ( @ids, @commands );
        for my $item (@$val) {
            if ( ref $item eq 'ARRAY' ) { push @commands, $item; next }
            if ( blessed($item) && $item->isa('Odoo::Record') ) {
                push @ids, $item->id;
                next;
            }
            if ( !ref $item && looks_like_number($item) ) {
                push @ids, int $item;
                next;
            }
            Odoo::Error->throw(
                kind    => 'usage',
                message => 'x2many element must be an id, an Odoo::Record, or a command triplet',
            );
        }
        Odoo::Error->throw(
            kind    => 'usage',
            message => 'mix of plain ids and command triplets is ambiguous - use x2m_link/x2m_set explicitly',
        ) if @ids && @commands;
        return \@commands if @commands;
        return [ x2m_set( \@ids ) ];
    }
    return $val;
}

=head2 save

Writes the dirty fields in one C<write> call; a clean record makes no
RPC at all. Scalar values merge into the local row; a changed
relation invalidates the cached row so the next read refetches the
server's view of it.

=cut

sub save ($self, %opts) {
    return $self if !%{ $self->{changes} };
    my %changes = %{ $self->{changes} };
    $self->{model}->write( $self->{id}, {%changes}, %opts );
    my $relations = $self->{model}->relations;
    if ( grep { $relations->{$_} } keys %changes ) {
        $self->{loaded} = 0;
        $self->{data}   = {};
    }
    elsif ( $self->{loaded} ) {
        @{ $self->{data} }{ keys %changes } = values %changes;
    }
    $self->{changes} = {};
    return $self;
}

sub update ($self, $vals, %opts) {
    Odoo::Error->throw(
        kind    => 'usage',
        message => 'update takes a hashref of values',
    ) if ref $vals ne 'HASH';
    return $self->set(%$vals)->save(%opts);
}

sub delete ($self, %opts) {
    return $self->{model}->unlink( $self->{id}, %opts );
}

=head2 dt($field)

The field's value as a L<Time::Piece> in UTC (Odoo sends timestamps
in UTC), or undef when the field is empty.

=cut

sub dt ($self, $field) {
    my $v = $self->get($field);
    return undef if !$v;
    for my $fmt ( '%Y-%m-%d %H:%M:%S', '%Y-%m-%d' ) {
        my $t = eval { Time::Piece->strptime( $v, $fmt ) };
        return $t if $t;
    }
    Odoo::Error->throw(
        kind    => 'usage',
        message => "field '$field' value '$v' is not an Odoo date or datetime",
    );
}

sub to_hash ($self) {
    $self->_load;
    return { %{ $self->{data} }, %{ $self->{changes} } };
}

#--- field accessors ----------------------------------------------------------

our $AUTOLOAD;

sub AUTOLOAD {
    my $self = shift;
    my ($name) = $AUTOLOAD =~ /([^:]+)\z/;
    return if $name eq 'DESTROY';
    Odoo::Error->throw(
        kind    => 'usage',
        message => "no method or field '$name' on " . ( ref($self) || $self ),
    ) if !blessed($self) || !$self->has_field($name);

    return $self->set( $name => $_[0] ) if @_;

    my $meta = $self->{model}->describe($name);
    my $type = $meta->{type} // '';
    my $raw  = $self->get($name);

    if ( $type eq 'many2one' ) {
        my $id = ref $raw eq 'ARRAY' ? $raw->[0] : $raw;
        return undef if !$id;
        return $self->{model}->client->model( $meta->{relation} )->browse($id);
    }
    if ( $type eq 'one2many' || $type eq 'many2many' ) {
        # Traversal reflects the server's state: pending x2many changes
        # are command triplets, which only mean something after save().
        my $stored = $self->_stored($name);
        return $self->{model}->client->model( $meta->{relation} )
            ->browse( ref $stored eq 'ARRAY' ? $stored : [] );
    }
    return $raw;
}

1;
