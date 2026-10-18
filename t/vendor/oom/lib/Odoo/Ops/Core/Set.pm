package Odoo::Ops::Core::Set;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::Modules;
use Odoo::Ops::Runner;
use Odoo::Ops::Core::Import;
use Odoo::Ops::Core::OneRecord;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Set - write fields of one record, typed from fields_get

=head1 SYNOPSIS

    oom-ops run core.set --conf ops.conf --set model=crm.lead --set id=12 --set set.stage_id=3 --set set.priority=2
    oom-ops apply --conf ops.conf --plan <run>/plan.json

=head1 DESCRIPTION

C<core.set> writes some fields of one record. The parameters are C<model>,
C<id> and one C<set.E<lt>fieldE<gt>> per field, every one a string or an
integer, so a page binding can feed them from a request. Each value is typed
from the model's C<fields_get>: integer and many2one_reference (a whole number),
float and monetary (a number),
boolean (C<1 0 true false yes no>), date (C<YYYY-MM-DD>), datetime
(C<YYYY-MM-DD HH:MM:SS>), selection (the key), many2one (an id), char, text and
html. An empty value clears a char, text, html, date, datetime, selection or
many2one field.

The plan holds one C<write> change with the values and the before-image of
the same fields, and a line per field with its before and after (a value over
40 characters is cut for the line; the plan holds it whole). A field already
holding the value is left out; when every field already holds its value the
record is skipped C<unchanged>. The apply is checked against the before-image
(a record changed since is C<stale>), reads the fields back and journals the
change, so C<revert> restores it.

A usage error names the field and carries a fix line: a field the model does not
have, a value that is not the field's type, a one2many or many2many field (a
later piece) or a binary, reference, json or properties field (not set here). Held:

    unknown-record   no record has that id
    state-field      the pair sets the state of a model whose state Odoo changes through its own action; the operation is named

Odoo's own rules (a required field, a constraint) are Odoo's to refuse.

=cut

sub op_name ($class) { 'core.set' }
sub summary ($class) { 'Plan writing fields of one record, each set.<field> typed from fields_get; the plan shows before and after' }
sub pack    ($class) { undef }
sub params ($class) {
    {   model         => { type => 'str', required => 1, help => 'physical model, e.g. crm.lead' },
        id            => { type => 'int', required => 1, help => 'the record id' },
        'set.<field>' => { type => 'str', help => 'one per field to write: --set set.stage_id=3 --set set.priority=2 (the value is typed from fields_get)' },
    };
}
sub check_params ($class, $raw) {
    my $set  = Odoo::Ops::Core::OneRecord->set_params( $class->op_name, $raw );
    my %rest = map { $_ => $raw->{$_} } grep { !/\Aset\./ } keys %$raw;
    my $out  = $class->SUPER::check_params( \%rest );
    $out->{"set.$_"} = $set->{$_} for keys %$set;
    return $out;
}
sub buckets ($class) {
    [   { name => 'set',       meaning => 'the record is written with the fields that differ' },
        { name => 'unchanged', meaning => 'every field already holds the value' },
    ];
}
sub holds ($class) {
    [   { name => 'unknown-record', meaning => 'no record has that id' },
        { name => 'state-field',    meaning => 'the pair sets the state of a model whose state Odoo changes through its own action; the operation that does it is named' },
    ];
}
sub read_scope  ($class) { {} }    # built per run from the model
sub write_scope ($class) { {} }
sub writes      ($class) { 1 }

sub scope_for ($self, $phase) {
    my $m = $self->param('model');
    return {} if !defined $m;
    return { $m => $phase eq 'apply' ? [qw(read search_read write)] : ['search_read'] };
}

sub _sets ($self) {
    my $all = $self->all_params;
    return { map { substr( $_, 4 ) => $all->{$_} } grep { /\Aset\./ } keys %$all };
}

sub plan ($self) {
    my ( $model, $id ) = ( $self->param('model'), $self->param('id') );
    Odoo::Error->throw( kind => 'usage', message => "core.set: model must be a physical model name (with a dot), got '$model'" ) if $model !~ /\./;
    Odoo::Error->throw( kind => 'usage', message => 'core.set: id must be a whole number above 0' ) if $id < 1;
    my $set = $self->_sets;
    Odoo::Error->throw( kind => 'usage', message => 'core.set: no field to set', fix => 'give one or more --set set.<field>=<value>' ) if !%$set;

    my $m = $self->client->model($model);
    my $f = eval { $m->fields } || Odoo::Ops::Modules->absent_model( $self->ctx, 'core.set', $model, $@ );
    my $vals = Odoo::Ops::Core::OneRecord->typed_values( 'core.set', $model, $f, $set );

    my $plan = $self->new_plan( input_count => 1 );
    my $key  = "$model:$id";
    if ( my $why = Odoo::Ops::Core::OneRecord->state_hold( $self->ctx, $model, $vals ) ) {
        $plan->add( bucket => 'state-field', action => 'hold', key => $key, model => $model, id => $id, reason => $why );
        return $plan;
    }
    my @names = sort keys %$vals;
    my ($row) = @{ $m->search_read( [ [ 'id', '=', $id ] ], [ 'id', @names ], limit => 1, context => { active_test => JSON::PP::false } ) };
    if ( !$row ) {
        $plan->add( bucket => 'unknown-record', action => 'hold', key => $key, model => $model, id => $id, reason => "core.set: $model has no record with id $id" );
        return $plan;
    }
    my ( %new, %before, @line );
    for my $n (@names) {
        my $d = $f->{$n};
        # an html field is compared as the text it shows: Odoo re-writes the markup
        my $type = $d->{type} // '';
        my $same = $type eq 'html'    ? Odoo::Ops::Core::Import::_text( $row->{$n} ) eq Odoo::Ops::Core::Import::_text( $vals->{$n} )
                 : $type eq 'boolean' ? ( $row->{$n} ? 1 : 0 ) == ( $vals->{$n} ? 1 : 0 )
                 :                      !Odoo::Ops::Runner::_diffs( { $n => $vals->{$n} }, $row );
        next if $same;
        $new{$n}    = $vals->{$n};
        $before{$n} = $row->{$n};
        push @line, "$n " . Odoo::Ops::Core::OneRecord->shown( $row->{$n} ) . ' -> ' . Odoo::Ops::Core::OneRecord->shown( $vals->{$n} );
    }
    if ( !%new ) {
        $plan->add( bucket => 'unchanged', action => 'skip', key => $key, model => $model, id => $id, reason => "$model $id already holds every value" );
        return $plan;
    }
    $plan->add(
        bucket => 'set', action => 'write', key => $key, model => $model, id => $id, vals => \%new, before => \%before,
        line   => "$model $id: " . join( '; ', @line ), reason => "$model $id: " . join( ', ', sort keys %new ),
    );
    return $plan;
}

1;
