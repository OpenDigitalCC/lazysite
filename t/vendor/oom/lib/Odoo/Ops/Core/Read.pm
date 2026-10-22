package Odoo::Ops::Core::Read;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Cache::Data;
use Odoo::Error;
use Odoo::Ops::Modules;
use Odoo::Ops;
use Odoo::Portable;
use Odoo::Ops::Core::OneRecord;
use Odoo::Ops::Core::ReadContext;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Read - read records of any model back

=head1 SYNOPSIS

    oom-ops run core.read --conf ops.conf --set model=sale.order --set 'domain=[["name","=","S00134"]]'
    oom-ops run core.read --conf ops.conf --set model=account.move --set ids=54 --set fields=name,state,amount_total
    oom-ops run core.read --conf ops.conf --set model=res.partner --set archived=1 --schema

=head1 DESCRIPTION

C<core.read> is the plain read: C<search_read> on any model, rows as Odoo
returns them, nothing written. It is not the C<--check> of an import
(C<core.import --check> compares a file with Odoo; it reads nothing back for
its own sake). Use it to look at an order, an invoice or a line, or to see
what a run made.

C<fields> is a comma-separated list; the default is C<id,display_name> and
the model's C<state> when it has one. A many2one comes back as two keys,
the id under the field's name and the label under C<E<lt>fieldE<gt>_name>
(both null when empty); other values are as Odoo returns them. C<domain>
is a JSON domain (default C<[]>), C<ids> narrows to those ids, C<limit>
defaults to 80 (C<limit_reached> says the rows ran out of limit, not of
records), C<order> is Odoo's order string, and C<archived> includes
inactive records. C<offset> skips that many matching rows (in the order asked) so a
caller can page through a queue larger than one answer; C<total> (or any C<offset>
above 0) adds C<total> to the answer, the number of records the whole domain matches
now (Odoo's C<search_count>, read live, never from the data cache), so the last page
is the one where C<offset> plus C<count> reaches C<total>. C<count> stays the rows in
this answer. Page on an order that ends in C<id> so rows do not move between pages.
C<context> is a JSON object of Odoo context keys from a short
list (L<Odoo::Ops::Core::ReadContext>): C<warehouse>, C<location> and C<lot_id> make
the stock quantities (C<free_qty>, C<qty_available>) those of one warehouse, location or lot. The report's C<fields> block (C<--schema>) describes the
fields asked: type, portable type, label, comodel, selection values.

An unknown model or field is a usage error naming it. The read scope is the
model's C<search_read> and C<fields_get>, nothing else.

=cut

sub op_name ($class) { 'core.read' }
sub summary ($class) { 'Read records of any model back (search_read): the plain read; an import\'s --check is not' }
sub pack    ($class) { undef }
sub params ($class) {
    {   model    => { type => 'str',  required => 1, help => 'physical model, e.g. sale.order' },
        domain   => { type => 'json', default => '[]', help => 'a JSON domain, e.g. [["name","=","S00134"]]' },
        fields   => { type => 'str',  help => 'comma-separated fields (default id,display_name and state when the model has one)' },
        ids      => { type => 'list', help => 'comma-separated record ids (added to the domain)' },
        limit    => { type => 'int',  default => 80, help => 'most rows returned' },
        order    => { type => 'str',  help => 'Odoo order string, e.g. "id desc"; end it with id when paging' },
        offset   => { type => 'int',  default => 0, help => 'rows to skip, to page through a larger result (with limit); adds total to the answer' },
        total    => { type => 'bool', default => 0, help => 'add total, the number of records the whole domain matches (search_count)' },
        archived => { type => 'bool', default => 0, help => 'include inactive (archived) records' },
        max_age  => { type => 'int',  help => 'seconds the answer may be old: with data_cache = 1 in the config it may come from the data cache while Odoo\'s signal for the model holds; 0 or absent: live' },
        pricelist => { type => 'int', help => 'the pricelist (id) Odoo prices the read with; part of the data cache key; the same as context.pricelist' },
        context  => { type => 'json', help => 'Odoo context keys for the read (warehouse, location, lot_id, pricelist, partner_id, quantity, lang, tz, active_test, to_date, from_date), e.g. {"warehouse": 2}; part of the data cache key' },
    };
}
sub read_scope ($class) { {} }    # built per run: the model's search_read

sub fields ($class) {
    return [
        { name => 'model',         meaning => 'The model read' },
        { name => 'count',         meaning => 'Rows returned' },
        { name => 'limit_reached', meaning => 'Present when count equals limit: there may be more records' },
        { name => 'offset',        meaning => 'Present when offset was given above 0: the rows skipped' },
        { name => 'total',         meaning => 'Present with total=1 or an offset: how many records the whole domain matches (search_count), not the rows of this answer' },
        { name => 'rows',          meaning => 'The records, one object each; a many2one is its id under the field name and its label under <field>_name' },
        { name => 'fields',        meaning => 'The fields asked: type, portable_type, string, and relation or values where they apply (--schema prints it)' },
        { name => 'cached',        meaning => '1 when the rows came from the data cache, else 0' },
        { name => 'age',           meaning => 'Present when cached: seconds since the cached rows were read from Odoo' },
        { name => 'checked',       meaning => 'Present when cached: signal (the model\'s newest write_date and record count were the ones the rows were read under)' },
        { name => 'live',          meaning => 'required when the model or a field is never cached (stock, reservations, pickings, order state), whatever max_age says' },
    ];
}

sub scope_for ($self, $phase) {
    my $m = $self->param('model');
    return {} if !defined $m;
    my @counts = $self->_wants_total ? ('search_count') : ();
    return { $m => [ 'search_read', @counts ] } if !$self->param('max_age');
    # the signal of the model (and, for a priced read, of the pricelist rules) is a read_group
    return { $m => [ 'search_read', @counts, 'read_group' ], ( $self->param('pricelist') ? ( map { $_ => ['read_group'] } Odoo::Cache::Data->pricelist_models ) : () ) };
}

sub _wants_total ($self) { return $self->param('total') || ( $self->param('offset') // 0 ) > 0 ? 1 : 0 }

sub report ($self) {
    my $model = $self->param('model');
    Odoo::Error->throw( kind => 'usage', message => "core.read: model must be a model name such as res.partner or website, got '$model'",
        fix => 'oom-ops describe core.read lists the parameters' ) if !$self->is_model_name($model);
    my $m = $self->client->model($model);
    my $f = eval { $m->fields } || Odoo::Ops::Modules->absent_model( $self->ctx, 'core.read', $model, $@ );

    my @want = defined $self->param('fields') ? grep { length } map { s/^\s+|\s+\z//gr } split /,/, $self->param('fields')
        : ( 'id', 'display_name', ( $f->{state} ? ('state') : () ) );
    Odoo::Error->throw( kind => 'usage', message => 'core.read: fields is empty', fix => 'oom-ops describe core.read lists the parameters' ) if !@want;
    my @unknown = grep { !$f->{$_} } @want;
    Odoo::Error->throw( kind => 'usage', message => "core.read: $model has no field '$unknown[0]'",
        fix => "oom-ops describe core.read lists the parameters; fields_get of $model lists its fields (oom-ops run core.skeleton --conf <conf> --set model=$model shows the stored, writable ones)" ) if @unknown;

    unshift @want, 'id' if !grep { $_ eq 'id' } @want;    # search_read always returns it
    my $dom = $self->param('domain');
    Odoo::Error->throw( kind => 'usage', message => 'core.read: domain must be a JSON list, e.g. [["name","=","S00134"]]',
        fix => 'oom-ops describe core.read lists the parameters' ) if ref $dom ne 'ARRAY';
    my @domain = @$dom;
    if ( my $ids = $self->param('ids') ) {
        if (@$ids) {
            my @bad = grep { !/^\d+\z/ } @$ids;
            Odoo::Error->throw( kind => 'usage', message => "core.read: ids must be whole numbers, got '$bad[0]'" ) if @bad;
            push @domain, [ 'id', 'in', [ map { 0 + $_ } @$ids ] ];
        }
    }
    my $limit = $self->param('limit');
    Odoo::Error->throw( kind => 'usage', message => 'core.read: limit must be a whole number above 0' ) if !defined $limit || $limit < 1;

    my $offset = $self->param('offset') // 0;
    Odoo::Error->throw( kind => 'usage', message => 'core.read: offset must be 0 or a whole number above 0', fix => 'oom-ops describe core.read lists the parameters' )
        if $offset !~ /\A\d+\z/;
    my $ma = $self->param('max_age');
    Odoo::Error->throw( kind => 'usage', message => 'core.read: max_age must be 0 or more seconds', fix => 'oom-ops describe core.read lists the parameters' )
        if defined $ma && $ma < 0;
    my ( $send, $pl, $keyed ) = Odoo::Ops::Core::ReadContext->resolve( 'core.read', context => $self->param('context'), pricelist => $self->param('pricelist'), archived => $self->param('archived') );
    my $got = $self->ctx->data_cache->read(
        model => $model, domain => \@domain, fields => \@want, order => $self->param('order'), limit => $limit,
        archived => $self->param('archived'), pricelist => $pl, context => $keyed, max_age => $ma, offset => $offset,
        ( $pl ? ( also => [ Odoo::Cache::Data->pricelist_models ] ) : () ),
        fetch => sub {
            $m->search_read( \@domain, [@want], limit => $limit, ( $offset ? ( offset => $offset ) : () ),
                ( defined $self->param('order') ? ( order => $self->param('order') ) : () ),
                ( %$send ? ( context => $send ) : () ) );
        } );
    my $rows = $got->{rows};
    $self->{cache_note} = { Odoo::Cache::Data->says($got) };

    my ( $out, $schema ) = Odoo::Ops::Core::OneRecord->rows_and_schema( $f, \@want, $rows );
    my @out = @$out;
    # the whole domain's size, read live: a page served from the data cache still says how many match now
    my $total = $self->_wants_total ? $m->search_count( \@domain, ( %$send ? ( context => $send ) : () ) ) : undef;
    return {
        model => $model, count => scalar @out, rows => \@out, fields => $schema, Odoo::Cache::Data->says($got),
        ( $offset ? ( offset => 0 + $offset ) : () ),
        ( defined $total ? ( total => 0 + $total ) : () ),
        ( @out == $limit ? ( limit_reached => JSON::PP::true ) : () ),
    };
}

1;
