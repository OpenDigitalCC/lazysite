package Odoo::RecordSet;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;

=head1 NAME

Odoo::RecordSet - an ordered set of records of one model

=head1 SYNOPSIS

    my $kids = $partner->child_ids;          # from traversal
    my $open = $so->search_rs([['state', '=', 'sale']]);

    say $kids->count;                        # no RPC - it knows its ids
    for my $rec ($kids->records) { ... }     # one read() for the lot
    while (my $rec = $open->next) { ... }
    my $first = $open->first;

=head1 DESCRIPTION

Holds a model handle and an ordered list of ids. Construction is
free; the first touch of any record's data loads B<every> row in the
set with a single C<read> call - the N+1 query problem does not
exist here. C<count>, C<ids> and C<is_empty> never trigger an RPC.

=cut

sub new ($class, %args) {
    Odoo::Error->throw(kind => 'config', message => 'model required')
        if !$args{model};
    my $ids = $args{ids} // [];
    Odoo::Error->throw(kind => 'usage', message => 'ids must be an arrayref')
        if ref $ids ne 'ARRAY';
    return bless {
        model  => $args{model},
        ids    => [@$ids],
        fields => $args{fields},
        pos    => 0,
    }, $class;
}

sub model    ($self) { $self->{model} }
sub ids      ($self) { [ @{ $self->{ids} } ] }
sub count    ($self) { scalar @{ $self->{ids} } }
sub is_empty ($self) { !@{ $self->{ids} } }

sub _load ($self) {
    return $self->{records} if $self->{records};
    my $rows = @{ $self->{ids} }
        ? $self->{model}->read( $self->{ids},
            $self->{fields} // $self->{model}->default_fields )
        : [];
    $self->{records} =
        [ map { $self->{model}->record_from_row($_) } @$rows ];
    return $self->{records};
}

sub records ($self) { return @{ $self->_load } }

sub first ($self) {
    return undef if $self->is_empty;
    return $self->_load->[0];
}

=head2 next / reset

A stateful iterator over the loaded records; C<next> returns undef
past the end, C<reset> rewinds.

=cut

sub next ($self) {
    my $records = $self->_load;
    return undef if $self->{pos} >= @$records;
    return $records->[ $self->{pos}++ ];
}

sub reset ($self) {
    $self->{pos} = 0;
    return $self;
}

sub each ($self, $cb) {
    $cb->($_) for @{ $self->_load };
    return $self;
}

=head2 refresh

Drops the cached rows (and the iterator position); the ids are kept.

=cut

sub refresh ($self) {
    delete $self->{records};
    $self->{pos} = 0;
    return $self;
}

1;
