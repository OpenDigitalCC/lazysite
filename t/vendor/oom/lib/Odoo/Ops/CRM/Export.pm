package Odoo::Ops::CRM::Export;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Spec;
use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::CRM::Export - snapshot leads as JSON lines

=head1 DESCRIPTION

C<crm.export>: writes one JSON object per lead, under the profile's
logical names, to C<export.jsonl> in the run directory (or C<out>).
Many2one values become C<{id, name}>; tags become their names. The
report says how many rows went where - never what was in them.

Take one before the first write to an instance, and whenever a record
of the CRM as it stood is wanted.

Params: C<domain> (JSON, physical field names, default all),
C<fields> (comma list of logical lead fields, default every mapped
stored field), C<archived> (include archived leads), C<out> (path).

=cut

sub op_name ($class) { 'crm.export' }
sub summary ($class) { 'Snapshot leads (logical names) to JSON lines' }
sub pack    ($class) { 'crm' }
sub params ($class) {
    {   domain   => { type => 'json', default => '[]', help => 'Odoo domain on crm.lead' },
        fields   => { type => 'list', help => 'logical lead fields (default: all mapped, stored)' },
        archived => { type => 'bool', default => 0, help => 'include archived leads' },
        out      => { type => 'path', help => 'output file (default: run dir export.jsonl)' },
        inline   => { type => 'bool', default => 0, help => 'also return the rows in the report (for display)' },
    };
}
sub read_scope ($class) {
    {   lead => ['search_read'],
        tag  => ['read'],
    };
}

sub report ($self) {
    my $p = $self->profile;
    my $v = $p->validate( $self->client );
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'profile',
        message => 'crm profile does not match this server: ' . join( '; ', @{ $v->{missing} } ),
    ) if !$v->{ok};

    my @lf = $self->param('fields') ? @{ $self->param('fields') } : $self->_default_fields;
    my %pf = map { $_ => $p->field( lead => $_ ) } @lf;
    for (@lf) {
        Odoo::Error->throw( kind => 'usage', message => "lead.$_ is not available on this series" )
            if !defined $pf{$_};
    }

    my @domain = @{ $self->param('domain') };
    push @domain, [ $p->field( lead => 'active' ), 'in', [ JSON::PP::true, JSON::PP::false ] ]
        if $self->param('archived');
    my $rows = $self->model('lead')->all( \@domain, [ sort values %pf ] );

    my $tag_names = $pf{tags} ? $self->_tag_names($rows, $pf{tags}) : {};
    my $out = $self->param('out')
        // File::Spec->catfile( $self->ctx->run_dir( $self->op_name ), 'export.jsonl' );
    open my $fh, '>', $out
        or Odoo::Error->throw( kind => 'config', message => "cannot write $out: $!" );
    my @inline;
    for my $row (@$rows) {
        my %rec = ( id => $row->{id} );
        for my $lf (@lf) {
            my $v    = $row->{ $pf{$lf} };
            my $type = $p->descriptor( lead => $lf )->{type} // '';
            if ( $type eq 'many2one' ) {
                $v = ref $v eq 'ARRAY' ? { id => $v->[0], name => $v->[1] } : undef;
            }
            elsif ( $lf eq 'tags' ) {
                $v = [ map { $tag_names->{$_} // "#$_" } @{ $v // [] } ];
            }
            elsif ( $type ne 'boolean' && defined $v && !ref $v && $v eq '0' && $type !~ /^(integer|float|monetary)\z/ ) {
                $v = undef;    # Odoo's false-for-empty
            }
            $rec{$lf} = $v;
        }
        print {$fh} Odoo::Ops::json()->encode( \%rec ), "\n";
        push @inline, \%rec if $self->param('inline');
    }
    close $fh or Odoo::Error->throw( kind => 'config', message => "cannot write $out: $!" );
    # the display shape: rows (when inline) beside their descriptors
    return {
        count             => scalar @$rows,
        file              => $out,
        fields            => $self->fields_for( lead => @lf ),
        archived_included => $self->param('archived'),
        ( $self->param('inline') ? ( rows => \@inline ) : () ),
    };
}

sub _default_fields ($self) {
    my $p = $self->profile;
    my $f = $p->fields('lead');
    return sort grep {
        my $d = $p->descriptor( lead => $_ );
        $d && $d->{store} && ( $d->{type} // '' ) ne 'binary';
    } keys %$f;
}

sub _tag_names ($self, $rows, $pf) {
    my %ids;
    $ids{$_} = 1 for map { @{ $_->{$pf} // [] } } @$rows;
    return {} if !%ids;
    my $name = $self->profile->field( tag => 'name' );
    my $tags = $self->model('tag')->read( [ sort { $a <=> $b } keys %ids ], [$name] );
    return { map { $_->{id} => $_->{$name} } @$tags };
}

1;
