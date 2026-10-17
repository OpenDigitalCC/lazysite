package Odoo::Ops::Rows;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Text::CSV_XS ();

use Odoo::Error;
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

1;
