package LazysiteTest::OdooOps::PhotoPost;

# Test pack (SM1162): a WRITE that takes a file. It makes one x.basket record
# whose key is "<name>|<sha256 of the bytes it saw>" and whose qty is the size,
# so a test reads back from the fake Odoo exactly what reached the operation.
use strict;
use warnings;
use Digest::SHA ();
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }

sub op_name { 'shop.photo_post' }
sub summary { 'Keep a photo' }

sub params { return { photo => { type => 'file', required => 1, max_bytes => 5000 } } }
sub read_scope  { return { 'x.basket' => ['search_read'] } }
sub write_scope { return { 'x.basket' => [ 'create', 'write' ] } }

sub plan {
    my ($self) = @_;
    my $f    = $self->param('photo');
    my $plan = $self->new_plan( input_count => 1 );
    $plan->add( bucket => 'new-photo', action => 'create', model => 'x.basket',
        vals => { basket_key => "$f->{name}|" . Digest::SHA::sha256_hex( $f->{bytes} ), qty => length $f->{bytes} } );
    return $plan;
}

1;
