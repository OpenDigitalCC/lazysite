package Odoo::Ops::Core::Read;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::Modules;
use Odoo::Ops;
use Odoo::Portable;
use Odoo::Ops::Core::OneRecord;

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
inactive records. The report's C<fields> block (C<--schema>) describes the
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
        order    => { type => 'str',  help => 'Odoo order string, e.g. "id desc"' },
        archived => { type => 'bool', default => 0, help => 'include inactive (archived) records' },
    };
}
sub read_scope ($class) { {} }    # built per run: the model's search_read

sub fields ($class) {
    return [
        { name => 'model',         meaning => 'The model read' },
        { name => 'count',         meaning => 'Rows returned' },
        { name => 'limit_reached', meaning => 'Present when count equals limit: there may be more records' },
        { name => 'rows',          meaning => 'The records, one object each; a many2one is its id under the field name and its label under <field>_name' },
        { name => 'fields',        meaning => 'The fields asked: type, portable_type, string, and relation or values where they apply (--schema prints it)' },
    ];
}

sub scope_for ($self, $phase) {
    my $m = $self->param('model');
    return defined $m ? { $m => ['search_read'] } : {};
}

sub report ($self) {
    my $model = $self->param('model');
    Odoo::Error->throw( kind => 'usage', message => "core.read: model must be a physical model name (with a dot), got '$model'",
        fix => 'oom-ops describe core.read lists the parameters' ) if $model !~ /\./;
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

    my $rows = $m->search_read( \@domain, [@want], limit => $limit,
        ( defined $self->param('order') ? ( order => $self->param('order') ) : () ),
        ( $self->param('archived') ? ( context => { active_test => JSON::PP::false } ) : () ) );

    my ( $out, $schema ) = Odoo::Ops::Core::OneRecord->rows_and_schema( $f, \@want, $rows );
    my @out = @$out;
    return {
        model => $model, count => scalar @out, rows => \@out, fields => $schema,
        ( @out == $limit ? ( limit_reached => JSON::PP::true ) : () ),
    };
}

1;
