package LazysiteTest::OdooCustom::Rename;

# Test pack (SM1170): a WRITE operation whose one change is `custom`, so the
# Runner has to find this class again by name at apply (Registry->new, with no
# arguments). It lives in its own namespace, named by odoo_packs only in the
# test that wants it, so no other test's operation list changes.
use strict;
use warnings;
use parent -norequire, 'Odoo::Ops::Operation';
BEGIN { eval { require Odoo::Ops::Operation; 1 } }    # absent: the file still compiles

sub op_name { 'shopc.rename' }
sub summary { 'Rename a product, as a custom change' }
sub params  { return { id => { type => 'int', required => 1 }, name => { type => 'str', required => 1 } } }
sub read_scope  { return { 'x.product' => ['search_read'] } }
sub write_scope { return { 'x.product' => ['write'] } }

sub plan {
    my ($self) = @_;
    my $id   = $self->param('id');
    my $plan = $self->new_plan( input_count => 1 );
    my $have = $self->model('x.product')->search_read( [ [ 'id', '=', $id ] ], ['name'] );
    return $plan unless @$have;
    $plan->add( bucket => 'renamed', action => 'custom', handler => $self->op_name, kind => 'rename',
        model => 'x.product', id => $id, before => { name => $have->[0]{name} },
        vals  => { name => $self->param('name') }, line => "rename product $id" );
    return $plan;
}

sub apply_custom {
    my ( $class, $client, $c ) = @_;
    $client->model('x.product')->write( [ $c->{id} ], { name => $c->{vals}{name} } );
    return { id => $c->{id}, reported => 'write', after => { id => $c->{id}, name => $c->{vals}{name} } };
}

sub undo_custom {
    my ( $class, $e ) = @_;
    return ( { name => $e->{before}{name} }, undef );
}

1;
