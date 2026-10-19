package Odoo::Ops::Core::Get;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Cache::Data;
use Odoo::Error;
use Odoo::Ops::Modules;
use Odoo::Ops::Core::OneRecord;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Get - one record of any model by id, with plain parameters

=head1 SYNOPSIS

    oom-ops run core.get --conf ops.conf --set model=crm.lead --set id=12 --set fields=name,stage_id,expected_revenue

=head1 DESCRIPTION

C<core.get> reads one record by its id. Its three parameters are a string, an
integer and a string, so a page binding can feed them from a request. The
row has each field asked: a many2one gives its id under the field's name and
its label under C<E<lt>fieldE<gt>_name> (both null when empty), and the
report's C<fields> block gives every field its type and portable type (the
label is C<text>, a many2one's id C<integer>).

C<fields> is a comma-separated list; the default is C<id,display_name> and the
model's C<state> when it has one. An archived record is read too. An id no
record has is C<refused/missing>, naming the model and the id.

Nothing is written. C<core.read> reads many records by domain.

=cut

sub op_name ($class) { 'core.get' }
sub summary ($class) { 'Read one record of any model by id; plain parameters, a many2one as id and label, every field with its portable type' }
sub pack    ($class) { undef }
sub params ($class) {
    {   model  => { type => 'str', required => 1, help => 'physical model, e.g. crm.lead' },
        id     => { type => 'int', required => 1, help => 'the record id' },
        fields => { type => 'str', help => 'comma-separated fields (default id,display_name and state when the model has one)' },
        max_age => { type => 'int', help => 'seconds the answer may be old: with data_cache = 1 in the config it may come from the data cache while Odoo\'s signal for the model holds; 0 or absent: live' },
        pricelist => { type => 'int', help => 'the pricelist (id) Odoo prices the read with; part of the data cache key' },
    };
}
sub read_scope ($class) { {} }    # built per run: the model's search_read

sub fields ($class) {
    return [
        { name => 'model',  meaning => 'The model read' },
        { name => 'id',     meaning => 'The record id' },
        { name => 'count',  meaning => 'Always 1: the record is rows[0]' },
        { name => 'rows',   meaning => 'One object: the fields asked; a many2one is its id under the field name and its label under <field>_name' },
        { name => 'fields', meaning => 'The fields asked: type, portable_type, string, and relation or values where they apply' },
        { name => 'cached', meaning => '1 when the row came from the data cache, else 0' },
        { name => 'age',    meaning => 'Present when cached: seconds since the cached row was read from Odoo' },
        { name => 'checked', meaning => 'Present when cached: signal' },
        { name => 'live',   meaning => 'required when the model or a field is never cached (stock, reservations, pickings, order state), whatever max_age says' },
    ];
}

sub scope_for ($self, $phase) {
    my $m = $self->param('model');
    return {} if !defined $m;
    return { $m => ['search_read'] } if !$self->param('max_age');
    return { $m => [ 'search_read', 'read_group' ], ( $self->param('pricelist') ? ( map { $_ => ['read_group'] } Odoo::Cache::Data->pricelist_models ) : () ) };
}

sub report ($self) {
    my ( $model, $id ) = ( $self->param('model'), $self->param('id') );
    Odoo::Error->throw( kind => 'usage', message => "core.get: model must be a physical model name (with a dot), got '$model'",
        fix => 'oom-ops describe core.get lists the parameters' ) if $model !~ /\./;
    Odoo::Error->throw( kind => 'usage', message => 'core.get: id must be a whole number above 0',
        fix => 'oom-ops describe core.get lists the parameters' ) if $id < 1;
    my $m = $self->client->model($model);
    my $f = eval { $m->fields } || Odoo::Ops::Modules->absent_model( $self->ctx, 'core.get', $model, $@ );

    my @want = defined $self->param('fields') ? grep { length } map { s/^\s+|\s+\z//gr } split /,/, $self->param('fields')
        : ( 'id', 'display_name', ( $f->{state} ? ('state') : () ) );
    Odoo::Error->throw( kind => 'usage', message => 'core.get: fields is empty', fix => 'oom-ops describe core.get lists the parameters' ) if !@want;
    my @unknown = grep { !$f->{$_} } @want;
    Odoo::Error->throw( kind => 'usage', message => "core.get: $model has no field '$unknown[0]'",
        fix => "fields_get of $model lists its fields (oom-ops run core.skeleton --conf <conf> --set model=$model shows the stored, writable ones)" ) if @unknown;
    unshift @want, 'id' if !grep { $_ eq 'id' } @want;

    my $ma = $self->param('max_age');
    Odoo::Error->throw( kind => 'usage', message => 'core.get: max_age must be 0 or more seconds', fix => 'oom-ops describe core.get lists the parameters' )
        if defined $ma && $ma < 0;
    my $pl = $self->param('pricelist');
    my $got = $self->ctx->data_cache->read(
        model => $model, domain => [ [ 'id', '=', $id ] ], fields => \@want, limit => 1, archived => 1, pricelist => $pl, max_age => $ma,
        ( $pl ? ( also => [ Odoo::Cache::Data->pricelist_models ] ) : () ),
        fetch => sub {
            $m->search_read( [ [ 'id', '=', $id ] ], [@want], limit => 1,
                context => { active_test => JSON::PP::false, ( $pl ? ( pricelist => $pl ) : () ) } );
        } );
    my $rows = $got->{rows};
    $self->{cache_note} = { Odoo::Cache::Data->says($got) };
    Odoo::Error->throw( kind => 'refused', code => 'missing', message => "core.get: $model has no record with id $id",
        fix => 'give the id of a record that exists; core.read finds records by a domain' ) if !@$rows;

    my ( $out, $schema ) = Odoo::Ops::Core::OneRecord->rows_and_schema( $f, \@want, $rows );
    return { model => $model, id => $id, count => 1, rows => $out, fields => $schema, Odoo::Cache::Data->says($got) };
}

1;
