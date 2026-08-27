package Lazysite::Data::Export;

# SM447: the canonical typed-JSON serialiser, hoisted because DP-6 needs it in
# two places - site_backup AND site packages - and a second implementation
# would drift from the first.
#
# WHY NOT JUST DUMP THE ROWS. JSON has fewer types than the store does, and the
# gaps are exactly where this store's promises live:
#
#   DECIMAL MUST BE A JSON STRING. Measured, not assumed: encoding 10.50 as a
#   JSON number and decoding it returns 10.5. The trailing zero is gone,
#   because it went through a double - which is the precise bug the decimal
#   type exists to prevent. Exporting money as a number would reintroduce it at
#   the one moment the data is most vulnerable, during a restore, and the
#   result would look plausible.
#
#   BOOLEAN IS true/false, not 0/1. SQLite stores 0/1 because it has no
#   boolean; JSON has one, and using it means a human reading a backup sees
#   what the column means rather than its storage.
#
#   NULL AND EMPTY STRING ARE DIFFERENT, and stay different. A store that
#   collapses them loses the distinction between "not answered" and "answered
#   with nothing", which is the whole reason Value.pm treats them separately.
#
# CANONICAL, so two exports of the same data are byte-identical: sorted keys,
# and rows ordered by their key. A backup nobody can diff is a backup nobody
# checks, and "did anything change" is the question a sysop actually asks.
#
# THE SHAPE TRAVELS WITH THE DATA. The export carries the field types as they
# were at export time, and an import REFUSES a file whose shape differs from
# the descriptor it is being restored into. Coercing across a shape change
# would be a migration performed silently, by the one operation a sysop
# runs when something has already gone wrong.

use strict;
use warnings;
use Exporter              qw(import);
use JSON::PP              ();
use Lazysite::Data::Value qw(coerce_row);

our @EXPORT_OK = qw(export_table import_table to_json FORMAT_VERSION);

# A sub rather than `use constant`, which perlcritic refuses at severity 4
# (PBP p55). Call sites use parens so the parse is not in question.
sub FORMAT_VERSION { return 1 }

# The declared shape, reduced to what a restore has to agree about. Not the
# whole descriptor: `title`, `widget` and `writable_by` are presentation and
# access, and a backup that refused to restore because somebody retitled a
# table would be useless for the job it exists to do.
sub _shape {
    my ($d) = @_;
    my %shape;
    for my $f ( sort keys %{ $d->{fields} } ) {
        my $spec = $d->{fields}{$f};
        my %s    = ( type => $spec->{type} );
        # The parts that change what a VALUE means, and nothing else.
        $s{values} = [ sort @{ $spec->{values} } ] if $spec->{type} eq 'enum';
        if ( $spec->{type} eq 'decimal' ) {
            $s{digits} = 0 + $spec->{digits};
            $s{places} = 0 + $spec->{places};
        }
        $shape{$f} = \%s;
    }
    return \%shape;
}

# One value, as JSON should carry it.
sub _out {
    my ( $spec, $v ) = @_;
    return undef unless defined $v;
    my $t = $spec->{type};
    return ( $v ? JSON::PP::true() : JSON::PP::false() ) if $t eq 'boolean';
    return 0 + $v                                        if $t eq 'integer';
    # Everything else, decimal INCLUDED and deliberately, is a string.
    return "$v";
}

# Rows as fetched from the store, to a canonical structure.
#
# Takes rows rather than a handle: the caller has already selected them, and
# threading a database handle through here would make this module care about an
# engine it has no other reason to know about.
sub export_table {
    my ( $d, $rows ) = @_;
    die 'export_table needs a loaded descriptor' unless ref $d eq 'HASH' && $d->{ok};
    $rows ||= [];

    my $fields = $d->{fields};
    my @out;
    for my $r ( @{$rows} ) {
        my %row;
        for my $f ( sort keys %{$fields} ) {
            $row{$f} = _out( $fields->{$f}, $r->{$f} );
        }
        # An auto key IS data for a restore - the rows may reference each other
        # by it - so it travels, even though a caller may not supply one.
        $row{ $d->{key} } = _out( { type => 'integer' }, $r->{ $d->{key} } )
            if $d->{auto_key} && exists $r->{ $d->{key} };
        push @out, \%row;
    }

    # Ordered by key so two exports of the same data compare equal. Rows with
    # no key sort last rather than crashing the comparison.
    my $k = $d->{key};
    @out = sort {
        my ( $x, $y ) = ( $a->{$k}, $b->{$k} );
        return 1  if !defined $x;
        return -1 if !defined $y;
        return "$x" cmp "$y";
    } @out;

    return {
        lazysite_data => FORMAT_VERSION(),
        table         => $d->{table},
        key           => $d->{key},
        fields        => _shape($d),
        rows          => \@out,
    };
}

sub to_json {
    my ($data) = @_;
    return JSON::PP->new->canonical->pretty->encode($data);
}

# A decoded export, back into rows ready to insert.
#
# REFUSES rather than adapts. Every check here is a case where continuing would
# put data into a column that means something different from where it came, and
# the caller is mid-restore - the moment when a plausible-looking wrong answer
# does the most damage and is least likely to be noticed.
sub import_table {
    my ( $d, $data ) = @_;
    return { ok => 0, error => 'a loaded descriptor is required' }
        unless ref $d eq 'HASH' && $d->{ok};
    return { ok => 0, error => 'not a lazysite data export' }
        unless ref $data eq 'HASH' && defined $data->{lazysite_data};
    return { ok => 0,
        error => "export format $data->{lazysite_data} is newer than this "
            . 'release understands (' . FORMAT_VERSION() . ')' }
        if $data->{lazysite_data} > FORMAT_VERSION();
    return { ok => 0,
        error => "this export is of '$data->{table}', not '$d->{table}'" }
        unless ( $data->{table} // '' ) eq $d->{table};

    # THE SHAPE MUST MATCH. A restore into a changed table is a migration, and
    # it should be done by migrating and then restoring - not by this function
    # guessing which column the old values belonged in.
    my $want = _shape($d);
    my $have = $data->{fields} || {};
    my $enc  = JSON::PP->new->canonical;
    for my $f ( sort keys %{$want} ) {
        return { ok => 0, field => $f,
            error => "the export has no '$f'; migrate the table first" }
            unless exists $have->{$f};
        return { ok => 0, field => $f,
            error => "'$f' is $have->{$f}{type} in the export and "
                . "$want->{$f}{type} in the table" }
            unless $enc->encode( $have->{$f} ) eq $enc->encode( $want->{$f} );
    }
    for my $f ( sort keys %{$have} ) {
        return { ok => 0, field => $f,
            error => "the export carries '$f', which the table no longer has" }
            unless exists $want->{$f};
    }

    my @rows;
    my $n = 0;
    for my $r ( @{ $data->{rows} || [] } ) {
        $n++;
        return { ok => 0, error => "row $n is not a mapping" }
            unless ref $r eq 'HASH';

        # JSON::PP booleans stringify to 1/0, which Value.pm accepts; every
        # other value arrives as the string or number it was written as. The
        # SAME coercion runs as for a live write, so a restore cannot put
        # anything into the store that a write could not.
        my %in = map { $_ => ( ref $r->{$_} ? ( $r->{$_} ? 1 : 0 ) : $r->{$_} ) }
            grep { defined $r->{$_} } keys %{$r};

        my $c = coerce_row( $d, \%in );
        return { ok => 0, row => $n, field => $c->{field},
            error => "row $n: $c->{error}" }
            unless $c->{ok};
        push @rows, $c->{values};
    }

    return { ok => 1, rows => \@rows };
}

1;
