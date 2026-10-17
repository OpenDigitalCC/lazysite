package Odoo::Ops::Core::Reports;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Reports - the reports an instance has for a model

=head1 SYNOPSIS

    oom-ops run core.reports --conf C --set model=sale.order
    oom-ops run core.reports --conf C --set name=quotation

=head1 DESCRIPTION

C<core.reports> lists the C<ir.actions.report> records of an instance:
those for one C<model>, or those whose name or C<report_name> contains
C<name> (case-insensitive), or both. It is what an agent runs to learn
the C<report> value L<Odoo::Ops::Core::Report> takes.

Each row has C<id>, C<name>, C<report_name> (the one the report route
takes), C<report_type> (C<qweb-pdf>, C<qweb-html>, C<qweb-text>),
C<model>, C<attachment> (the expression Odoo holds, or null),
C<attachment_use> (as Odoo holds it; null on a series that has no such
field), C<print_report_name> and C<binding> (the report is bound to its
model's print menu). A read; nothing is written.

=cut

sub op_name ($class) { 'core.reports' }
sub summary ($class) { 'The reports an instance has for a model (the report name core.report takes)' }
sub pack    ($class) { undef }
sub params ($class) {
    {   model => { type => 'str', help => 'physical model whose reports to list, e.g. sale.order' },
        name  => { type => 'str', help => 'a substring of the report name or report_name (case-insensitive)' },
    };
}

sub read_scope ($class) { { 'ir.actions.report' => ['search_read'] } }

sub fields ($class) {
    return [
        { name => 'id',                meaning => 'Id of the report action' },
        { name => 'name',              meaning => 'Report name as the print menu shows it' },
        { name => 'report_name',       meaning => 'The technical name: what core.report takes as report and the route carries' },
        { name => 'report_type',       meaning => 'qweb-pdf, qweb-html or qweb-text' },
        { name => 'model',             meaning => 'The model the report prints' },
        { name => 'attachment',        meaning => 'The attachment name expression as Odoo holds it, or null' },
        { name => 'attachment_use',    meaning => 'attachment_use as Odoo holds it (null where the series has no such field)' },
        { name => 'print_report_name', meaning => 'The expression Odoo names a printed file with' },
        { name => 'binding',           meaning => 'Bound to the model\'s print menu' },
    ];
}

my @READ = qw(name report_name report_type model attachment print_report_name binding_model_id);

sub report ($self) {
    my ( $model, $name ) = ( $self->param('model'), $self->param('name') );
    Odoo::Error->throw( kind => 'usage', message => 'core.reports: give model, or name, or both' )
        if !defined $model && !defined $name;
    my @dom;
    push @dom, [ 'model', '=', $model ] if defined $model;
    push @dom, '|', [ 'name', 'ilike', $name ], [ 'report_name', 'ilike', $name ] if defined $name;
    my $types = $self->model('ir.actions.report')->fields;
    my $use   = $types->{attachment_use} ? 1 : 0;
    my $rows  = $self->model('ir.actions.report')->search_read( \@dom, [ @READ, ( $use ? ('attachment_use') : () ) ] );
    my @out = map {
        my $r = $_;
        +{  id                => $r->{id},
            name              => _text( $r->{name} ),
            report_name       => _text( $r->{report_name} ),
            report_type       => _text( $r->{report_type} ),
            model             => _text( $r->{model} ),
            attachment        => length _text( $r->{attachment} ) ? _text( $r->{attachment} ) : undef,
            attachment_use    => $use ? ( $r->{attachment_use} ? JSON::PP::true : JSON::PP::false ) : undef,
            print_report_name => _text( $r->{print_report_name} ),
            binding           => ( _set( $r->{binding_model_id} ) ? JSON::PP::true : JSON::PP::false ),
        };
    } sort { lc( _text( $a->{model} ) ) cmp lc( _text( $b->{model} ) ) || lc( _text( $a->{name} ) ) cmp lc( _text( $b->{name} ) ) || $a->{id} <=> $b->{id} } @$rows;
    my $text = sub ($s) { { portable_type => 'text', string => $s } };
    return {
        count  => scalar @out,
        rows   => \@out,
        fields => {
            id => { portable_type => 'integer', string => 'Id of the report action' },
            map { $_->{name} eq 'id' ? () : ( $_->{name} => $text->( $_->{meaning} ) ) } @{ $self->fields },
        },
    };
}

# Odoo answers false for an empty char
sub _text ($v) { return ( !defined $v || ref $v || $v eq '' || $v eq '0' ) ? '' : "$v" }
sub _set ($v) { return ref $v eq 'ARRAY' ? scalar(@$v) : ( $v && !ref $v ) }

1;
