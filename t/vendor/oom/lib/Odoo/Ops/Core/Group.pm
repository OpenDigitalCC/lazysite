package Odoo::Ops::Core::Group;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::Modules;
use Odoo::Ops::Core::ReadContext;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Group - grouped reads of any model (Odoo's read_group)

=head1 SYNOPSIS

    oom-ops run core.group --conf ops.conf --set model=account.move.line \
        --set 'domain=[["parent_state","=","posted"]]' \
        --set groupby=partner_id,date:month --set fields=balance:sum,id:count
    oom-ops run core.group --conf ops.conf --set model=res.partner --set groupby=country_id --set orderby='country_id_count desc'

=head1 DESCRIPTION

C<core.group> is the grouped read: Odoo's C<read_group> on any model, one row per
group, nothing written. Use it for the questions a list of records answers badly:
how many, how much, per what. Each row is as Odoo returns it, with C<__domain>, the
domain that selects exactly the group's records, so a caller can drill in with
L<core.read|Odoo::Ops::Core::Read> by passing that domain on.

C<groupby> is a comma-separated list of fields, each optionally with Odoo's date
granularity (C<date:month>, C<day>, C<week>, C<quarter>, C<year>); every level is
grouped at once (C<lazy> is off), so two fields give one row per pair. C<fields> is
a comma-separated list of aggregates written C<field:aggregate>
(C<balance:sum>, C<amount:avg>, C<id:count>, C<partner_id:count_distinct>; also C<min>, C<max>);
a row carries each under the field's name, plus C<__count>, the size of the group. C<orderby> is Odoo's order
string for the groups (C<partner_id>, C<__count desc>, C<balance desc>); C<limit> defaults to 80 groups and
C<offset> skips groups. C<domain> is a JSON domain (default C<[]>), C<archived> includes inactive records, and
C<context> is a JSON object of the Odoo context keys of L<core.read|Odoo::Ops::Core::Read>.

An unknown model, a field the model lacks or an aggregate that is not one of Odoo's is a usage
error naming it. Everything else is Odoo's: a field it cannot group by (a field that is not stored)
or aggregate comes back as Odoo's own refusal. The read scope is the model's C<read_group> and C<fields_get>.

The answer holds C<count> (the groups returned), C<rows> and, when C<count> equals C<limit>,
C<limit_reached>.

=head2 What differs by series

The syntax is the same on 16 and 18 and the rows carry the same keys (the groupby fields, the
aggregates, C<__count>, C<__domain>, and for a date field C<__range>). With no C<fields> the rows carry
the size of the group and nothing else on both (Odoo 16 would otherwise sum every numeric field of the
model). C<id:count> is C<id> on 18 and absent on 16, where C<__count> is the size of the group: read
C<__count>. See C<docs/MAPPER-SPEC.md> section 9.

=cut

sub op_name ($class) { 'core.group' }
sub summary ($class) { 'Grouped read of any model (read_group): counts and sums per group, with the domain of each group' }
sub pack    ($class) { undef }
sub params ($class) {
    {   model    => { type => 'str',  required => 1, help => 'physical model, e.g. account.move.line' },
        domain   => { type => 'json', default => '[]', help => 'a JSON domain, e.g. [["parent_state","=","posted"]]' },
        groupby  => { type => 'list', required => 1, help => 'comma-separated fields to group by, each with an optional granularity for dates: partner_id,date:month' },
        fields   => { type => 'list', help => 'comma-separated aggregates, field:aggregate, e.g. balance:sum,id:count (every group also carries __count)' },
        orderby  => { type => 'str',  help => 'Odoo order string for the groups, e.g. "balance desc" or "__count desc"' },
        limit    => { type => 'int',  default => 80, help => 'most groups returned' },
        offset   => { type => 'int',  default => 0, help => 'groups to skip' },
        archived => { type => 'bool', default => 0, help => 'include inactive (archived) records' },
        context  => { type => 'json', help => 'Odoo context keys for the read (the keys of core.read), e.g. {"to_date": "2026-09-30"}' },
    };
}
sub read_scope ($class) { {} }    # built per run: the model's read_group

sub fields ($class) {
    return [
        { name => 'model',         meaning => 'The model read' },
        { name => 'groupby',       meaning => 'The grouping asked, in order' },
        { name => 'aggregates',    meaning => 'The aggregates asked, as field:aggregate' },
        { name => 'count',         meaning => 'Groups returned' },
        { name => 'limit_reached', meaning => 'Present when count equals limit: there may be more groups' },
        { name => 'rows',          meaning => 'One object per group, as Odoo returns it: the groupby values (a many2one as [id, label]), the aggregates, __count and __domain' },
    ];
}

sub scope_for ($self, $phase) {
    my $m = $self->param('model');
    return {} if !defined $m;
    return { $m => ['read_group'] };
}

my %AGG = map { $_ => 1 } qw(sum avg min max count count_distinct array_agg bool_and bool_or);
my %GRAN = map { $_ => 1 } qw(day week month quarter year);

sub _names ($list) { return grep { length } map { s/^\s+|\s+\z//gr } @{ $list // [] } }

sub report ($self) {
    my $model = $self->param('model');
    my $bad = sub ($why) { Odoo::Error->throw( kind => 'usage', message => "core.group: $why", fix => 'oom-ops describe core.group lists the parameters' ) };
    $bad->("model must be a model name such as res.partner or website, got '$model'") if !$self->is_model_name($model);
    my $m = $self->client->model($model);
    my $f = eval { $m->fields } || Odoo::Ops::Modules->absent_model( $self->ctx, 'core.group', $model, $@ );

    my @groupby = _names( $self->param('groupby') );
    $bad->('groupby is empty: give at least one field, such as partner_id or date:month') if !@groupby;
    for my $g (@groupby) {
        my ( $fname, $gran, @more ) = split /:/, $g;
        $bad->("groupby '$g' is not field or field:granularity") if @more || !defined $fname || $fname !~ /\A\w+\z/;
        $bad->("$model has no field '$fname'") if !$f->{$fname};
        $bad->("groupby '$g': the granularity is one of " . join( ', ', sort keys %GRAN ) . " (for a date or datetime field)") if defined $gran && !$GRAN{$gran};
        $bad->("groupby '$g': $fname is a $f->{$fname}{type} field, which has no granularity") if defined $gran && ( $f->{$fname}{type} // '' ) !~ /\Adate(?:time)?\z/;
    }
    my @agg = _names( $self->param('fields') );
    for my $a (@agg) {
        my ( $fname, $fn, @more ) = split /:/, $a;
        $bad->("fields entry '$a' is not field:aggregate, e.g. balance:sum") if @more || !defined $fname || !defined $fn || $fname !~ /\A\w+\z/;
        $bad->("$model has no field '$fname'") if !$f->{$fname};
        $bad->("fields entry '$a': the aggregate is one of " . join( ', ', sort keys %AGG ) ) if !$AGG{$fn};
    }
    my $dom = $self->param('domain');
    $bad->('domain must be a JSON list, e.g. [["parent_state","=","posted"]]') if ref $dom ne 'ARRAY';
    my $limit = $self->param('limit');
    $bad->('limit must be a whole number above 0') if !defined $limit || $limit !~ /\A\d+\z/ || $limit < 1;
    my $offset = $self->param('offset') // 0;
    $bad->('offset must be 0 or a whole number above 0') if $offset !~ /\A\d+\z/;

    my ( $send ) = Odoo::Ops::Core::ReadContext->resolve( 'core.group', context => $self->param('context'), archived => $self->param('archived') );
    # lazy is off: every level in one call, the same row shape on 16 and 18. With no aggregate asked, 16 sums every
    # numeric field of the model (18 sums none); asking for __count alone gives both the group size and nothing else
    my $rows = $m->read_group( $dom, [ @agg ? @agg : ('__count') ], \@groupby,
        limit => $limit, ( $offset ? ( offset => $offset ) : () ), lazy => JSON::PP::false,
        ( defined $self->param('orderby') && length $self->param('orderby') ? ( orderby => $self->param('orderby') ) : () ),
        ( %$send ? ( context => $send ) : () ) );
    $rows = [] if ref $rows ne 'ARRAY';
    return {
        model => $model, groupby => \@groupby, aggregates => \@agg, count => scalar @$rows, rows => $rows,
        ( @$rows == $limit ? ( limit_reached => JSON::PP::true ) : () ),
    };
}

1;
