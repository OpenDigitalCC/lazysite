package LazysiteTest::OdooOps::Notes;

# Test pack (SM1224): a list of notes whose `body` key declares its own max (5000,
# OOM 0.38), beside a `title` that does not. A WRITE operation: each row makes one
# basket line whose qty is the length of its body, so a test sees what arrived.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name { 'shop.notes' }
sub summary { 'Add notes, each with a long body' }

sub params {
    return {
        notes => { type => 'rows', max => 3,
            row => { title => 'str', body => { type => 'str?', max => 5000 } } },
        # one long text, for the request-size budget
        memo => { type => 'rows', max => 1, row => { text => { type => 'str', max => 200_000 } } },
    };
}
sub read_scope  { return { 'x.basket' => ['search_read'] } }
sub write_scope { return { 'x.basket' => [ 'create', 'write' ] } }

sub plan {
    my ($self) = @_;
    my $plan = $self->new_plan( input_count => scalar( @{ $self->param('notes') || [] } ) + scalar( @{ $self->param('memo') || [] } ) );
    for my $n ( @{ $self->param('notes') || [] } ) {
        $plan->add( bucket => 'new-note', action => 'create', model => 'x.basket',
            vals => { basket_key => $n->{title}, qty => length( $n->{body} // '' ) } );
    }
    for my $m ( @{ $self->param('memo') || [] } ) {
        $plan->add( bucket => 'new-note', action => 'create', model => 'x.basket',
            vals => { basket_key => 'memo', qty => length $m->{text} } );
    }
    return $plan;
}

1;
