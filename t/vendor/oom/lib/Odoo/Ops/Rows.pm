package Odoo::Ops::Rows;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::JSON ();
use Odoo::Ops;

=head1 NAME

Odoo::Ops::Rows - the rows an operation is given: in-process records or a file

=head1 SYNOPSIS

    my $rows = Odoo::Ops::Rows->load( 'core.user', records => $p->{records} );
    my $rows = Odoo::Ops::Rows->load( 'core.user', rows    => $p->{rows} );
    for my $r (@$rows) { ... $r->{key}, $r->{values}, $r->{held}, $r->{error} }

=head1 DESCRIPTION

The input shape L<Odoo::Ops::Core::Import> established, kept in one
place for the operations that take a list of rows: C<records> (an
in-process list - the middleware case) or C<rows> (a file: C<.jsonl>,
C<.json> holding a list, or C<.csv> with field names as the header
row). Every row comes back as the envelope C<< { key, values, held?,
error? } >>; a flat C<< { field => value } >> row is accepted too
(C<_key> names it, otherwise its position does).

The operation name prefixes every error, so a refusal says which
operation read the rows.

This module loads only L<Odoo::Error>, L<Odoo::Ops> and L<Odoo::JSON> (and
L<Text::CSV_XS> when a C<.csv> file is read), so C<check> runs in a caller
outside OOM without the registry or the operations.

=head2 load($who, records => ... | rows => ...)

The envelopes from whichever of C<records> and C<rows> is given.

=head2 envelope($record, $n, $who)

One record as given -> C<< { key, values, held?, error? } >>.

=head2 read_file($path, $who)

The envelopes of a C<.jsonl>, C<.json> or C<.csv> file.

=cut

sub load ( $class, $who, %in ) {
    if ( defined( my $recs = $in{records} ) ) {
        Odoo::Error->throw( kind => 'usage', message => "$who: records must be a list" ) if ref $recs ne 'ARRAY';
        return [ map { envelope( $recs->[$_], $_ + 1, $who ) } 0 .. $#$recs ];
    }
    return read_file( $in{rows}, $who ) if defined $in{rows};
    Odoo::Error->throw( kind => 'usage', message => "$who: give records or rows" );
}

sub envelope ( $rec, $n, $who ) {
    Odoo::Error->throw( kind => 'usage', message => "$who: record #$n is not a map" ) if ref $rec ne 'HASH';
    if ( ref $rec->{values} eq 'HASH' ) {
        my %e = ( key => $rec->{key} // "row$n", values => $rec->{values} );
        $e{held}  = $rec->{held}  if defined $rec->{held};
        $e{error} = $rec->{error} if defined $rec->{error};
        return \%e;
    }
    my %v = %$rec;
    my $key = delete $v{_key};
    return { key => $key // "row$n", values => \%v };
}

sub read_file ( $path, $who ) {
    Odoo::Error->throw( kind => 'usage', message => "$who: cannot read $path", fix => 'check the path exists and this user can read it' ) if !-r $path;
    if ( $path =~ /\.jsonl\z/i ) {
        open my $fh, '<:raw', $path or Odoo::Error->throw( kind => 'usage', message => "cannot read $path: $!", fix => 'check the path exists and this user can read it' );
        my @out;
        while ( my $line = <$fh> ) {
            next if $line !~ /\S/;
            my $doc = eval { Odoo::Ops::json()->decode($line) }
                // Odoo::Error->throw( kind => 'usage', message => "$path line $.: not JSON", fix => 'correct the file; oom-ops describe <op> shows what it holds' );
            push @out, envelope( $doc, $., $who );
        }
        close $fh;
        return \@out;
    }
    if ( $path =~ /\.json\z/i ) {
        open my $fh, '<:raw', $path or Odoo::Error->throw( kind => 'usage', message => "cannot read $path: $!", fix => 'check the path exists and this user can read it' );
        my $raw = do { local $/; <$fh> };
        close $fh;
        my $docs = eval { Odoo::Ops::json()->decode($raw) }
            // Odoo::Error->throw( kind => 'usage', message => "$path is not valid JSON", fix => 'correct the file; oom-ops describe <op> shows what it holds' );
        Odoo::Error->throw( kind => 'usage', message => "$path must hold a list of records", fix => 'correct the file; oom-ops describe <op> shows what it holds' ) if ref $docs ne 'ARRAY';
        return [ map { envelope( $docs->[$_], $_ + 1, $who ) } 0 .. $#$docs ];
    }
    if ( $path =~ /\.csv\z/i ) {
        require Text::CSV_XS;
        my $csv = Text::CSV_XS->new( { binary => 1, auto_diag => 0 } );
        open my $fh, '<:encoding(UTF-8)', $path or Odoo::Error->throw( kind => 'usage', message => "cannot read $path: $!", fix => 'check the path exists and this user can read it' );
        my $head = $csv->getline($fh) or Odoo::Error->throw( kind => 'usage', message => "$path has no header row", fix => 'correct the file; oom-ops describe <op> shows what it holds' );
        s/^\x{FEFF}// for $head->[0];
        my ( @out, $n );
        while ( my $cells = $csv->getline($fh) ) {
            $n++;
            next if !grep { defined && /\S/ } @$cells;
            my %rec;
            @rec{@$head} = @$cells;
            push @out, envelope( \%rec, $n, $who );
        }
        Odoo::Error->throw( kind => 'usage', message => "$path: " . ( $csv->error_diag )[1], fix => 'correct the parameter or the file the message names, then plan again' ) if !$csv->eof;
        close $fh;
        return \@out;
    }
    Odoo::Error->throw( kind => 'usage', message => "$who: rows file must be .jsonl, .json or .csv, got $path", fix => 'correct the file; oom-ops describe <op> shows what it holds' );
}

=head2 check($decl, $value, $label = 'rows')

Class method: the value of a C<rows> parameter checked against its
declaration, as C<check_params> checks it, so a caller can run the same rule
before it sends. C<$decl> is the parameter's declaration:

    lines => { type => 'rows', max => 50, required => 1,
               row => { product_id => 'int', qty => 'int', discount => 'int?' } }

Each row field is C<str>, C<int> or C<bool>, with C<?> for an optional key;
C<max> is required. C<$value> is an array of hashes, or the text of a JSON
array of flat objects. It must hold at most C<max> rows, each a hash with
only the declared keys, every required key present and each value of its
type with no nesting: an C<int> is a whole number (JSON number or digits), a
C<bool> is true or false (C<1 0 yes no true false>), a C<str> is a plain
value of at most 4096 characters holding no control character. A C<null>
leaves an optional key out. Returns the rows (a new array of new hashes,
values typed). A breach is C<usage>, naming the row number (from 1) and the
key; C<$label> (default C<rows>) leads the message.

=cut

sub check ($class, $decl, $value, $label = 'rows') {
    my $bad = sub ($why, $kind = 'usage') {
        Odoo::Error->throw( kind => $kind, message => "$label$why", fix => 'oom-ops describe <op> shows the rows each parameter takes' );
    };
    ref $decl eq 'HASH' && ( $decl->{type} // '' ) eq 'rows' or $bad->( ' is not declared as rows', 'config' );
    my $max = $decl->{max};
    defined $max && !ref $max && $max =~ /\A[1-9]\d*\z/ or $bad->( ' declares no max (a whole number of at least 1)', 'config' );
    my $row = $decl->{row};
    ref $row eq 'HASH' && %$row or $bad->( ' declares no row fields', 'config' );
    my ( %type, %optional );
    for my $k ( sort keys %$row ) {
        my ( $ty, $q ) = ( $row->{$k} // '' ) =~ /\A(str|int|bool)(\?)?\z/
            or $bad->( " declares row key '$k' as '" . ( $row->{$k} // '' ) . "' (str, int or bool, with ? for optional)", 'config' );
        $type{$k}     = $ty;
        $optional{$k} = 1 if $q;
    }

    my $rows = $value;
    $rows = eval { Odoo::Ops::json()->decode( $value // '' ) } if !ref $rows;
    ref $rows eq 'ARRAY' or $bad->( " must be a list of at most $max rows (a JSON array of objects)" );
    $bad->( ' has ' . scalar(@$rows) . " rows; at most $max are allowed" ) if @$rows > $max;

    my @out;
    my $n = 0;
    for my $r (@$rows) {
        $n++;
        ref $r eq 'HASH' or $bad->( " row $n must be an object of " . join( ', ', sort keys %type ) );
        for my $k ( sort keys %$r ) {
            $bad->( " row $n: key '$k' is not declared (the row takes " . join( ', ', sort keys %type ) . ')' ) if !$type{$k};
        }
        my %o;
        for my $k ( sort keys %type ) {
            my $v = $r->{$k};
            if ( !defined $v ) {
                $bad->( " row $n: key '$k' is required" ) if !$optional{$k};
                next;
            }
            my $ty = $type{$k};
            if ( ref $v ) {
                # a JSON true or false is a bool; any other reference is nesting
                $bad->( " row $n: key '$k' must be a plain $ty, not a nested value" )
                    if $ty ne 'bool' || !Odoo::JSON::is_bool($v);
                $o{$k} = $v ? 1 : 0;
                next;
            }
            if ( $ty eq 'int' ) {
                $v =~ /\A-?\d+\z/ or $bad->( " row $n: key '$k' must be int" );
                $o{$k} = 0 + $v;
            }
            elsif ( $ty eq 'bool' ) {
                $v =~ /\A(?:1|0|yes|no|true|false)\z/i or $bad->( " row $n: key '$k' must be bool" );
                $o{$k} = $v =~ /\A(?:1|yes|true)\z/i ? 1 : 0;
            }
            else {
                $bad->( " row $n: key '$k' must be at most 4096 characters" ) if length $v > 4096;
                $bad->( " row $n: key '$k' must not hold a control character" ) if $v =~ /[\x00-\x1f\x7f]/;
                $o{$k} = "$v";
            }
        }
        push @out, \%o;
    }
    return \@out;
}

1;
