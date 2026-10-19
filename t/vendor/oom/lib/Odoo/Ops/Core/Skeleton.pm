package Odoo::Ops::Core::Skeleton;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Fcntl qw(O_WRONLY O_CREAT O_EXCL O_TRUNC);

use Odoo::Error;
use Odoo::Ops::Modules;
use Odoo::Portable;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Skeleton - a Source mapping to start from, written from a model's fields

=head1 SYNOPSIS

    oom-ops skeleton --conf site.conf --set model=res.partner --set out=partners.mapping.yaml
    oom-ops skeleton --conf site.conf --set model=res.partner > partners.mapping.yaml
    oom-ops skeleton --conf site.conf --set model=lead --set pack=crm

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

A field is marked C<REQUIRED> when Odoo requires it and has no default for
it (C<fields_get> C<required>, and C<default_get> names no value); a required
field Odoo fills itself (C<state>, C<company_id>) is listed unmarked. Those
fields come first, then the rest by name. Left out: C<id> and
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

A read operation; no Odoo record is written. With C<out> the mapping is written
to that file (mode 0600, the directory made when absent); a file already
there is refused (C<refused/exists>, fix C<--set overwrite=1>) unless
C<overwrite> is on, and the report is C<{ out, bytes }> instead of the
C<mapping>. Without C<out> the C<oom-ops skeleton> command (and C<oom-ops
run core.skeleton>) prints the mapping as plain text, JSON only with
C<--json>. C<oom-ops mapping-skeleton> is the old name of C<skeleton>, still
accepted and no longer listed.

=cut

sub op_name ($class) { 'core.skeleton' }
sub summary ($class) { 'Write a commented Source mapping for a model from its fields' }
sub pack    ($class) { undef }    # the pack, when given, is a parameter
sub params ($class) {
    {   model => { type => 'str', required => 1, help => 'physical model, e.g. res.partner (a logical name with pack)' },
        pack  => { type => 'str', help => 'a profile pack (e.g. crm): logical field names instead of physical' },
        out       => { type => 'path', help => 'write the mapping to this file (mode 0600) instead of leaving it to the caller' },
        overwrite => { type => 'bool', default => 0, help => 'replace the file out names when it exists' },
    };
}
sub read_scope ($class) { {} }    # fields_get is always allowed

# default_get of the model, to tell a required field Odoo fills itself from one the load must supply
sub scope_for ($self, $phase) {
    my $given = $self->param('model');
    return {} if !defined $given;
    my $physical = $given;
    if ( defined $self->param('pack') ) {
        my $prof = eval { $self->ctx->profile( $self->param('pack') ) };
        $physical = $prof && eval { $prof->model_name($given) } // $given;
    }
    return $self->is_model_name($physical) ? { $physical => ['default_get'] } : {};
}

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
        Odoo::Error->throw( kind => 'usage', message => "core.skeleton: model must be a model name such as res.partner or website, got '$given'" )
            if !$self->is_model_name($given);
        ( $physical, $target ) = ( $given, $given );
    }
    my $f = eval { $self->client->model($physical)->fields }
        || Odoo::Ops::Modules->absent_model( $self->ctx, 'core.skeleton', $physical, $@ );

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

    # REQUIRED is Odoo's requirement that the load must meet: the field is required and Odoo gives
    # it no default of its own (default_get). When the defaults cannot be read, a required field is
    # marked as such and the line says the defaults were not known.
    my @required = grep { $f->{$_}{required} } @listed;
    my $defaults = @required ? eval { $self->client->model($physical)->default_get( \@required ) } : {};
    my $needs = sub ($pf) { $f->{$pf}{required} && ( ref $defaults ne 'HASH' || !exists $defaults->{$pf} ) };

    my $label = sub ($pf) { $names ? $names->{$pf} : $pf };
    my @sorted = ( ( grep { $needs->($_) } @listed ), ( grep { !$needs->($_) } @listed ) );

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
        $line .= '  REQUIRED' . ( ref $defaults eq 'HASH' ? '' : ' (its default could not be read)' ) if $needs->($pf);
        if ( ( $d->{type} // '' ) =~ /^many2(one|many)\z/ && $d->{relation} ) {
            $line =~ s/  REQUIRED( \(its default could not be read\))?\z//;
            $line .= " -> $d->{relation}";
            $line .= $names ? '  (a value names a record of it)' : '  (a value names a record by ' . $lookup_for->($d) . "; core.import lookup: {\"$pf\":\"" . $lookup_for->($d) . '"})';
            $line .= '  REQUIRED' . ( ref $defaults eq 'HASH' ? '' : ' (its default could not be read)' ) if $needs->($pf);
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
    return { mapping => $out } if !defined $self->param('out');
    my $path = $self->param('out');
    Odoo::Error->throw( kind => 'refused', code => 'exists', message => "cannot write $path: it exists; overwrite=1 replaces it", fix => 'pass --set overwrite=1' )
        if -e $path && !$self->param('overwrite');
    sysopen( my $fh, $path, O_WRONLY | O_CREAT | ( $self->param('overwrite') ? O_TRUNC : O_EXCL ), 0600 )
        or Odoo::Error->throw( -e $path
            ? ( kind => 'refused', code => 'exists', message => "cannot write $path: it exists; overwrite=1 replaces it", fix => 'pass --set overwrite=1' )
            : ( kind => 'usage', message => "cannot write $path: $!", fix => 'give a path in a directory this user can write' ) );
    binmode $fh, ':utf8';
    print {$fh} $out;
    close $fh or Odoo::Error->throw( kind => 'usage', message => "cannot write $path: $!", fix => 'give a path in a directory this user can write' );
    chmod 0600, $path;
    return { out => $path, bytes => -s $path };
}

1;
