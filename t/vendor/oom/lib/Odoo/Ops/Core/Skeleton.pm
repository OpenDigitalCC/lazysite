package Odoo::Ops::Core::Skeleton;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Portable;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Skeleton - a Source mapping to start from, written from a model's fields

=head1 SYNOPSIS

    oom-ops mapping-skeleton --conf site.conf --set model=res.partner > partners.mapping.yaml
    oom-ops mapping-skeleton --conf site.conf --set model=lead --set pack=crm

=head1 DESCRIPTION

C<core.skeleton> reads C<fields_get> of C<model> and reports
C<< { mapping => $text } >>: a L<Odoo::Ops::Source> mapping with the
reader, C<target> and C<fields:> in place and every stored, writable
field of the model written as a commented-out entry in the mapping's
field shape,

    # name  char (portable text)  REQUIRED
    # name: { from: SOURCE_COLUMN }
    # country_id  many2one -> res.country  (value names a record by name; core.import lookup: {"country_id":"name"})
    # country_id: { from: SOURCE_COLUMN }
    # type  selection (portable enum)  values: contact | invoice | delivery
    # type: { from: SOURCE_COLUMN }

Required fields come first, then the rest by name. Left out: C<id> and
the magic columns (create/write user and date, display name), read-only
and unstored fields (Odoo computes them), and one2many fields (load the
related model with its own import; the names are listed at the foot).
Uncomment what the load will use and name the source columns; with at
least one field uncommented the file is a mapping L<Odoo::Ops::Source>
accepts. It does not guess a reader: the C<csv> lines are the part to
replace.

With C<pack> the model may be a logical name of the pack's profile (or
its physical name), the fields are written under their logical names, and
only the profile's fields are listed - a pack is the set of fields its
operations accept. The C<target> is then the logical model.

A read operation; nothing is written. The C<oom-ops mapping-skeleton>
subcommand is C<run core.skeleton> that prints the text.

=cut

sub op_name ($class) { 'core.skeleton' }
sub summary ($class) { 'Write a commented Source mapping for a model from its fields' }
sub pack    ($class) { undef }    # the pack, when given, is a parameter
sub params ($class) {
    {   model => { type => 'str', required => 1, help => 'physical model, e.g. res.partner (a logical name with pack)' },
        pack  => { type => 'str', help => 'a profile pack (e.g. crm): logical field names instead of physical' },
    };
}
sub read_scope ($class) { {} }    # fields_get is always allowed

my %MAGIC = map { $_ => 1 } qw(id create_uid create_date write_uid write_date display_name __last_update);

sub report ($self) {
    my $given = $self->param('model');
    my ( $physical, $target, $names );    # $names: physical => logical, when a pack is given
    if ( defined( my $pack = $self->param('pack') ) ) {
        my $prof = $self->ctx->profile($pack);
        my ($lm) = $given =~ /\./
            ? ( grep { $prof->model_name($_) eq $given } $prof->models )
            : ( grep { $_ eq $given } $prof->models );
        Odoo::Error->throw( kind => 'usage',
            message => "core.skeleton: pack '$pack' has no model '$given' (its models: " . join( ', ', $prof->models ) . ')' )
            if !defined $lm;
        $physical = $prof->model_name($lm);
        $target   = $lm;
        $names    = { reverse %{ $prof->fields($lm) } };
    }
    else {
        Odoo::Error->throw( kind => 'usage', message => "core.skeleton: model must be a physical model name (with a dot), got '$given'" )
            if $given !~ /\./;
        ( $physical, $target ) = ( $given, $given );
    }
    my $f = eval { $self->client->model($physical)->fields }
        or Odoo::Error->throw( kind => 'usage', message => "core.skeleton: Odoo cannot describe model '$physical' (not installed, or no access)" );

    my ( @listed, @x2many );
    for my $pf ( sort keys %$f ) {
        my $d = $f->{$pf};
        next if $MAGIC{$pf};
        next if exists $d->{store} && !$d->{store};
        next if $d->{readonly};
        if ( ( $d->{type} // '' ) eq 'one2many' ) { push @x2many, $pf; next }
        if ($names) { next if !defined $names->{$pf} }
        push @listed, $pf;
    }
    my %comodel_fields;
    my $has = sub ($model, $field) {
        my $cf = $comodel_fields{$model} //= eval { $self->client->model($model)->fields } // {};
        return exists $cf->{$field};
    };
    my $lookup_for = sub ($d) { return $has->( $d->{relation}, 'name' ) ? 'name' : $has->( $d->{relation}, 'code' ) ? 'code' : 'id' };

    my $label = sub ($pf) { $names ? $names->{$pf} : $pf };
    my @sorted = ( ( grep { $f->{$_}{required} } @listed ), ( grep { !$f->{$_}{required} } @listed ) );

    my $series = eval { $self->client->server_series } // '?';
    my $out = "# Mapping skeleton for $physical on Odoo $series, from oom-ops mapping-skeleton.\n"
        . "# Every stored, writable field is listed below, commented out: uncomment the ones\n"
        . "# the load will use and name the source column in 'from'. Replace the reader.\n"
        . "# Run it:  oom-ops run core.import --conf CONF --set mapping=THIS-FILE\n";
    $out .= "#            --set 'lookup={...}'   (a relational value names a record; see each field)\n" if !$names;
    $out .= "source: $target-import        # a name for reports and plans\n"
        . "target: $target\n"
        . "reader:\n"
        . "  kind: csv                    # csv | jsonl | json-dir | dbi\n"
        . "  path: input.csv\n"
        . "  key: ID                      # the source column that identifies a row\n"
        . "# match:\n"
        . "#   keys: [FIELD]              # the field(s) that identify a record on a re-run (core.import)\n"
        . "fields:\n";
    for my $pf (@sorted) {
        my $d  = $f->{$pf};
        my $lf = $label->($pf);
        my %pt = Odoo::Portable::describe($d);
        my $line = "  # $lf  $d->{type}" . ( $pt{portable_type} ? " (portable $pt{portable_type})" : '' );
        $line .= '  REQUIRED' if $d->{required};
        if ( ( $d->{type} // '' ) =~ /^many2(one|many)\z/ && $d->{relation} ) {
            $line =~ s/  REQUIRED\z//;
            $line .= " -> $d->{relation}";
            $line .= $names ? '  (a value names a record of it)' : '  (a value names a record by ' . $lookup_for->($d) . "; core.import lookup: {\"$pf\":\"" . $lookup_for->($d) . '"})';
            $line .= $d->{required} ? '  REQUIRED' : '';
        }
        if ( $pt{values} ) {
            $line .= '  values: ' . join( ' | ', @{ $pt{values} } );
        }
        elsif ( ( $d->{type} // '' ) eq 'selection' && ref $d->{selection} eq 'ARRAY' ) {
            $line .= '  values: ' . join( ' | ', map { $_->[0] } @{ $d->{selection} } );
        }
        $out .= "$line\n  # $lf: { from: SOURCE_COLUMN }\n";
    }
    $out .= "  # not listed (load " . join( ', ', map { $f->{$_}{relation} // $_ } @x2many ) . " with its own import): " . join( ', ', @x2many ) . "\n"
        if @x2many;
    return { mapping => $out };
}

1;
