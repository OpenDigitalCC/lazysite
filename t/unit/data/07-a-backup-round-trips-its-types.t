#!/usr/bin/perl
# SM447: the canonical typed-JSON export, hoisted for DP-6.
#
# THE MEASUREMENT THAT DECIDES THE FORMAT, asserted here so it cannot rot into
# a comment somebody trims: encoding 10.50 as a JSON NUMBER and decoding it
# returns 10.5. The trailing zero is gone, because it went through a double -
# the precise bug the decimal type exists to prevent. So decimal is exported as
# a STRING, and a restore is the moment that matters most: it happens when
# something has already gone wrong, and a plausible-looking wrong answer is
# least likely to be questioned.
#
# THE REAL TEST IS THE ROUND TRIP THROUGH TWO SEPARATE DATABASES, because
# DP-6's actual requirement is that a site restored from a package arrives with
# its data intact - not that a hash survives a function call.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/../../../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; 1 }
        or plan skip_all => 'DBD::SQLite not available';
}

use Lazysite::Data::Descriptor qw(load_descriptor);
use Lazysite::Data::Export qw(export_table import_table);
use Lazysite::Data::Schema qw(plan_migration);
use Lazysite::Data::SQLite qw(insert_sql select_sql);
use Lazysite::Data::Value qw(coerce_row);

my $d = load_descriptor(
    'orders',
    {   key    => 'ref',
        fields => {
            ref   => { type => 'text', required => 1, max => 40 },
            note  => { type => 'text' },
            qty   => { type => 'integer' },
            total => { type => 'decimal', digits => 8, places => 2 },
            paid  => { type => 'boolean' },
            due   => { type => 'date' },
            state => { type => 'enum', values => [qw(new done)] },
        },
    }
);
ok( $d->{ok}, 'fixture descriptor loads' ) or BAIL_OUT( $d->{error} );

subtest 'the measurement the format exists for' => sub {
    my $j = JSON::PP->new;
    is( $j->decode( $j->encode( { m => 10.50 } ) )->{m},
        10.5, 'a JSON NUMBER loses the trailing zero' )
        or diag( 'If this ever stops being true the format could be '
            . 'simplified. While it is true, money must not be a number.' );

    my $e = export_table( $d, [ { ref => 'A', total => '10.50' } ] );
    my $text = JSON::PP->new->canonical->encode($e);
    like( $text, qr/"total":"10\.50"/, 'so the export carries it as a STRING' );
    unlike( $text, qr/"total":10/, 'and never as a number' );
};

subtest 'the types JSON does have are used properly' => sub {
    my $e = export_table( $d,
        [ { ref => 'A', paid => 1, qty => 7, note => '', due => undef } ] );
    my $text = JSON::PP->new->canonical->encode($e);
    like( $text, qr/"paid":true/, 'boolean is true/false, not 0/1' )
        or diag( 'A human reading a backup should see what the column means, '
            . 'not how SQLite happens to store it.' );
    like( $text, qr/"qty":7/,     'an integer is a number' );
    like( $text, qr/"note":""/,   'an empty string stays an empty string' );
    like( $text, qr/"due":null/,  'and a NULL stays null' )
        or diag( 'Collapsing these loses the difference between "not '
            . 'answered" and "answered with nothing".' );
};

subtest 'two exports of the same data are byte-identical' => sub {
    my @rows = ( { ref => 'B', qty => 2 }, { ref => 'A', qty => 1 } );
    my $one = JSON::PP->new->canonical->encode( export_table( $d, \@rows ) );
    my $two = JSON::PP->new->canonical->encode(
        export_table( $d, [ reverse @rows ] ) );
    is( $one, $two, 'row order in equals nothing - they sort by key' )
        or diag( 'A backup nobody can diff is a backup nobody checks, and '
            . '"did anything change" is what an operator actually asks.' );
};

subtest 'a restore into a CHANGED table is refused, not adapted' => sub {
    my $e = export_table( $d, [ { ref => 'A' } ] );

    my $narrower = load_descriptor( 'orders',
        { key => 'ref', fields => { ref => { type => 'text' } } } );
    my $r = import_table( $narrower, $e );
    ok( !$r->{ok}, 'an export carrying columns the table lost is refused' );
    like( $r->{error}, qr/no longer has/, 'and says which' );

    my $retyped = load_descriptor( 'orders',
        { key => 'ref',
          fields => { %{ $d->{fields} }, qty => { type => 'text' } } } );
    $r = import_table( $retyped, $e );
    ok( !$r->{ok}, 'a changed TYPE is refused' )
        or diag( 'Coercing across a shape change would be a migration '
            . 'performed silently, by the operation an operator runs when '
            . 'something has already gone wrong.' );
    like( $r->{error}, qr/integer in the export and text in the table/,
        'naming both sides' );

    $r = import_table( $d, { %{$e}, table => 'other' } );
    ok( !$r->{ok}, 'an export of a DIFFERENT table is refused' );

    $r = import_table( $d, { %{$e}, lazysite_data => 99 } );
    ok( !$r->{ok}, 'and a format from the future is refused rather than guessed' );
};

subtest 'a bad value in an export cannot get in' => sub {
    my $e = export_table( $d, [ { ref => 'A' } ] );
    $e->{rows}[0]{total} = '1.234';
    my $r = import_table( $d, $e );
    ok( !$r->{ok}, 'the same coercion runs as for a live write' )
        or diag( 'A restore must not be able to put anything into the store '
            . 'that a write could not.' );
    like( $r->{error}, qr/row 1/, 'and the row is identified' );
};

subtest 'DP-6: two separate databases, and the data arrives intact' => sub {
    my $dir = tempdir( CLEANUP => 1 );
    my @conn = ( '', '', { RaiseError => 1, PrintError => 0, sqlite_unicode => 1 } );
    my $src = DBI->connect( "dbi:SQLite:dbname=$dir/src.sqlite", @conn );
    my $dst = DBI->connect( "dbi:SQLite:dbname=$dir/dst.sqlite", @conn );

    for my $h ( $src, $dst ) {
        my $p = plan_migration( $d, $h );
        $h->do($_) for @{ $p->{create} };
    }

    my @input = (
        { ref => 'A-1', note => qq{quote " and '\nnewline}, qty => 3,
          total => '10.50', paid => 1, due => '2025-06-01', state => 'new' },
        { ref => 'B-2', note => '', qty => 0, total => '0.00', paid => 0 },
    );
    for my $in (@input) {
        my $c = coerce_row( $d, $in );
        ok( $c->{ok}, "row $in->{ref} coerces" ) or diag( $c->{error} );
        my ( $sql, $binds ) = insert_sql( $d, $c->{values} );
        $src->do( $sql, undef, @{$binds} );
    }

    my ( $ssql, $sbinds ) = select_sql($d);
    my $rows = $src->selectall_arrayref( $ssql, { Slice => {} }, @{$sbinds} );

    # Through actual JSON text, not the in-memory structure - a serialiser
    # tested without its serialisation is not tested.
    my $text = JSON::PP->new->canonical->encode( export_table( $d, $rows ) );
    my $imp  = import_table( $d, JSON::PP->new->decode($text) );
    ok( $imp->{ok}, 'the export imports' ) or diag( $imp->{error} );

    for my $r ( @{ $imp->{rows} } ) {
        my ( $sql, $binds ) = insert_sql( $d, $r );
        $dst->do( $sql, undef, @{$binds} );
    }

    my $out = $dst->selectall_arrayref( $ssql, { Slice => {} }, @{$sbinds} );
    is( scalar @{$out}, 2, 'both rows arrive' );
    is( $out->[0]{note}, $input[0]{note}, 'the awkward text is byte-identical' );
    is( $out->[0]{total}, '10.50', 'and the money kept its trailing zero' )
        or diag( 'This is the whole reason decimal is a string in the file.' );
    is( $out->[0]{paid}, 1, 'the boolean came back as 0/1 storage' );
    is( $out->[1]{qty},  0, 'a zero is a zero, not a missing value' );
    is( $out->[1]{note}, '', 'and an empty string is still not NULL' );

    # The exports of source and destination must now be identical - which is
    # the property a restore actually promises.
    my $src_json = JSON::PP->new->canonical->encode( export_table( $d, $rows ) );
    my $dst_json = JSON::PP->new->canonical->encode( export_table( $d, $out ) );
    is( $dst_json, $src_json, 'and the two stores export identically' );
};

done_testing();
