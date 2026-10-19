package LazysiteTest::OdooOps::PhotoBlob;

# Test pack (SM1162): a WRITE that holds a file in its plan as OOM does for an
# attachment (Plan->blob_value: the bytes in the run folder's blobs/, the plan
# showing a reference), on OOM's CLI fake's res.partner so the real oomd can run it.
use strict;
use warnings;
use MIME::Base64 ();
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }

sub op_name { 'shop.photo_blob' }
sub summary { 'Keep a photo on a partner' }

sub params { return { photo => { type => 'file', required => 1, max_bytes => 5000 } } }
sub read_scope  { return { 'res.partner' => ['search_read'] } }
sub write_scope { return { 'res.partner' => ['write'] } }

sub plan {
    my ($self) = @_;
    my $f    = $self->param('photo');
    my $plan = $self->new_plan( input_count => 1 );
    $plan->add( bucket => 'photo', action => 'write', model => 'res.partner', id => 1,
        vals => { ref => $plan->blob_value( MIME::Base64::encode_base64( $f->{bytes}, '' ) ) },
        reason => "keeps $f->{name}" );
    return $plan;
}

1;
