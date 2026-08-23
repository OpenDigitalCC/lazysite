#!/usr/bin/perl
# DM-4: a CSV import validates everything, shows the plan, then commits - or
# writes nothing at all.
#
# THE RULE IS THE BRIEF'S: "a reject in any row aborts the whole import". A
# partial import that stopped at row 40 of 200 leaves a table half one thing
# and half another, with no way to tell which rows landed - and the operator
# who re-runs the file then double-inserts the first 39. All-or-nothing is the
# only shape an operator can reason about.
#
# THREE PROPERTIES, and each has a sabotage that only it catches:
#
#   1. a PLAN writes nothing, however valid the rows are;
#   2. ONE bad row refuses the file, naming its ROW NUMBER and field;
#   3. a COMMIT is one transaction - a failure mid-way leaves the store as it
#      was, not half-updated.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Tables qw(apply_schema insert_row read_rows import_rows);
use Lazysite::Data::Csv    qw(from_csv to_csv);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/tables");
open my $f, '>', "$docroot/lazysite/db/tables/stock.yaml" or die $!;
print {$f} <<'YAML';
key: sku
fields:
  sku:
    type: text
    required: true
  qty:
    type: integer
    min: 0
    default: 0
  price:
    type: decimal
    digits: 8
    places: 2
  note:
    type: text
YAML
close $f;
apply_schema( $docroot, 'stock' );
insert_row( $docroot, 'stock', { sku => 'A1', qty => 5, price => '1.00', note => 'original' } );

sub rows  { read_rows( $docroot, 'stock', as => 'operator', order_by => 'sku' )->{rows} }
sub by    { my ($k) = @_; ( grep { $_->{sku} eq $k } @{ rows() } )[0] }
sub csv   { my ($t) = @_; my ( $h, $r, $e ) = from_csv($t); die $e if $e; return ( $h, $r ) }
sub plan  { import_rows( $docroot, 'stock', csv( $_[0] ) ) }
sub apply { import_rows( $docroot, 'stock', csv( $_[0] ), apply => 1 ) }

subtest 'A PLAN CLASSIFIES AND WRITES NOTHING' => sub {
    my $p = plan("sku,qty,price\r\nA1,9,2.50\r\nB2,1,3.00\r\n");
    ok( $p->{ok}, 'the plan is accepted' ) or diag( $p->{error} );
    is( $p->{updates}, 1, 'A1 exists, so it is an update' );
    is( $p->{inserts}, 1, 'B2 does not, so it is an insert' );
    ok( !$p->{applied}, 'and it says it applied nothing' );

    is( by('A1')->{qty}, 5, 'A1 is untouched after a plan' )
        or diag( 'A plan that writes is a commit with a misleading name.' );
    ok( !by('B2'), 'and B2 was not inserted' );
};

subtest 'ONE BAD ROW REFUSES THE FILE, BY ROW NUMBER' => sub {
    # Row 3 of the file (line 3, counting the header as line 1 - the number
    # the operator sees in their spreadsheet) has a word where an integer goes.
    my $p = plan("sku,qty\r\nA1,9\r\nB2,lots\r\nC3,1\r\n");
    ok( !$p->{ok}, 'the import is refused' );
    is( $p->{row},   3,     'naming the row as the spreadsheet numbers it' )
        or diag( 'An operator told "row 2" opens their spreadsheet and looks '
            . 'at the header.' );
    is( $p->{field}, 'qty', 'and the field' );
    is( $p->{kind},  'validation', 'as a validation refusal' );

    # AND NOTHING LANDED - not the good rows before it, not the ones after.
    is( by('A1')->{qty}, 5, 'the valid row before it was not applied' )
        or diag( 'Applying rows up to the failure is the partial import this '
            . 'exists to prevent.' );
    ok( !by('C3'), 'nor the valid row after it' );
};

subtest 'A COMMIT APPLIES EVERYTHING, AS ONE' => sub {
    my $r = apply("sku,qty,price,note\r\nA1,9,2.50,\r\nB2,1,3.00,new\r\n");
    ok( $r->{ok} && $r->{applied}, 'the commit applies' ) or diag( $r->{error} );
    is( $r->{updates}, 1, 'one update' );
    is( $r->{inserts}, 1, 'one insert' );

    is( by('A1')->{qty},   9,      'A1 updated' );
    is( by('A1')->{price}, '2.50', 'with the decimal intact to two places' )
        or diag( 'A decimal that lost its trailing zero on the way through '
            . 'a spreadsheet is the bug the type exists to prevent.' );
    is( by('A1')->{note}, 'original',
        'AN EMPTY CELL IS NOT SENT, so the stored note survives' )
        or diag( 'If this is empty or undef, a blank cell overwrote a stored '
            . 'value - which would make every export-edit-import cycle erase '
            . 'whatever the spreadsheet left blank.' );
    is( by('B2')->{note}, 'new', 'B2 inserted with its note' );
    is( by('B2')->{qty},  1,     'and its qty' );
};

subtest 'a column the table does not have is refused, not ignored' => sub {
    my $p = plan("sku,qty,colour\r\nA1,1,red\r\n");
    ok( !$p->{ok}, 'refused' );
    is( $p->{field}, 'colour', 'naming the stray column' )
        or diag( 'A spreadsheet that grew a column is telling you something. '
            . 'Importing around it loses that column in silence.' );
    like( $p->{error}, qr/add the field to the descriptor/, 'and what to do' );
};

subtest 'THE KEY IS NEVER RE-WRITTEN ON AN UPDATE' => sub {
    # An export carries the key column; an edited export does too. On an
    # update the key is the ADDRESS and must be dropped from the values, or
    # coerce_row's key_immutable refusal fires on every single update in
    # every import - making the round trip impossible.
    my $r = apply("sku,qty\r\nA1,4\r\n");
    ok( $r->{ok}, 'an update that carries its own key column is accepted' )
        or diag( $r->{error} );
    is( by('A1')->{qty}, 4, 'and applied' );
};

subtest 'the round trip holds: export, edit nothing, import' => sub {
    # What the feature is FOR. A file that came out of to_csv must go back in
    # through from_csv and import_rows as a no-op on the data.
    my $d   = Lazysite::Data::Tables::load_table( $docroot, 'stock' );
    my ($csv) = to_csv( $d, rows() );
    my $before = join '|', map { "$_->{sku}/$_->{qty}/$_->{price}/" . ( $_->{note} // '~' ) } @{ rows() };
    my $r = apply($csv);
    ok( $r->{ok}, 'the exported file imports' ) or diag( $r->{error} );
    is( $r->{inserts}, 0, 'as zero inserts' );
    my $after = join '|', map { "$_->{sku}/$_->{qty}/$_->{price}/" . ( $_->{note} // '~' ) } @{ rows() };
    is( $after, $before, 'and the data is byte-identical afterwards' )
        or diag( 'An export-import cycle that changes data is a cycle nobody '
            . 'can trust with a real table.' );
};

subtest 'A GUARDED CELL COMES BACK UNGUARDED' => sub {
    # to_csv prefixes =, +, -, @ cells with an apostrophe so a spreadsheet will
    # not run them. A round trip that did not take it off again would grow one
    # apostrophe per cycle, and the value the operator stored would drift away
    # from the value they see. The guard is a TRANSPORT property, not data.
    my $r = apply("sku,note\r\nG1,'=SUM(A1)\r\n");
    ok( $r->{ok}, 'the guarded cell imports' ) or diag( $r->{error} );
    is( by('G1')->{note}, '=SUM(A1)', 'stored WITHOUT the apostrophe' )
        or diag( 'If this still has the apostrophe, every export-import cycle '
            . 'adds another.' );

    # But an apostrophe that was never a guard is data, and stays.
    my $r2 = apply("sku,note\r\nG2,'tis\r\n");
    ok( $r2->{ok}, 'a plain leading apostrophe imports' );
    is( by('G2')->{note}, "'tis", 'and is kept - it was never a guard' );
};

subtest 'A FAILURE MID-COMMIT ROLLS BACK EVERYTHING' => sub {
    # Provoked with a UNIQUE clash the validator cannot see: two rows in one
    # file inserting the same new key. Each row is valid on its own; the
    # second insert fails at the database. The first must not survive.
    my $r = apply("sku,qty\r\nZ9,1\r\nZ9,2\r\n");
    ok( !$r->{ok}, 'the commit fails' );
    like( $r->{error}, qr/rolled back/, 'and says it rolled back' );
    ok( !by('Z9'), 'and the first Z9 did not survive the second failing' )
        or diag( 'A half-applied import reported as a failure is a store the '
            . 'operator has to repair by hand before they can retry.' );
};

done_testing();
