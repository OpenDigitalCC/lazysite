#!/usr/bin/perl
# SM447: the layer the surfaces call.
#
# WHY IT EXISTS. Three surfaces will ask the same questions - the control API,
# MCP, and page bindings. If each assembles Descriptor + Connect + Schema +
# Value + SQLite for itself, they will assemble them slightly differently, and
# two channels will come to disagree about the same question. That is not
# speculation: it is SM353, it is SM442, and it is why t/lint/57 exists.
#
# THE READ/WRITE SPLIT IS THE SECURITY PROPERTY. Connect hands out two handles
# and the render path holds the one that cannot write - because a page binding
# runs in the processor, the one surface where a bug becomes a write triggered
# by an anonymous visitor. This asserts that the read path really is read-only,
# through the handle rather than by inspection.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}

use Lazysite::Data::Tables
    qw(list_tables load_table read_rows apply_schema insert_row update_row delete_row);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/tables");

sub write_descriptor {
    my ( $name, $yaml ) = @_;
    open my $fh, '>', "$docroot/lazysite/db/tables/$name.yaml" or die $!;
    print {$fh} $yaml;
    close $fh;
    return;
}

write_descriptor( 'products', <<'YAML' );
title: Products
key: code
fields:
  code:
    type: text
    required: true
    max: 20
  name:
    type: text
  price:
    type: decimal
    digits: 8
    places: 2
  active:
    type: boolean
    default: true
YAML

subtest 'declared tables come from filenames, validated' => sub {
    write_descriptor( 'Bad-Name', "fields:\n  x:\n    type: text\n" );
    is_deeply( list_tables($docroot), ['products'],
        'a filename that is not a legal table name is not listed' )
        or diag( 'The name is interpolated into SQL by the adapter. The '
            . 'filesystem is not a validator.' );
    unlink "$docroot/lazysite/db/tables/Bad-Name.yaml";
};

subtest 'a table nobody declared says so, rather than reading empty' => sub {
    my $r = read_rows( $docroot, 'nosuch' );
    ok( !$r->{ok}, 'it is an error' );
    is( $r->{kind}, 'no_such_table', 'of a nameable kind' );
    like( $r->{error}, qr/no table 'nosuch' is declared/, 'and says which' )
        or diag( 'An empty list alone is what SM460 was: a page that rendered '
            . 'fine and listed nothing, so the author blamed their pattern.' );
};

subtest 'declared but not yet migrated reads empty, and admits it' => sub {
    my $r = read_rows( $docroot, 'products' );
    ok( $r->{ok}, 'reading is not an error' )
        or diag( 'Declaring a table and not yet migrating is an ordinary '
            . 'state - the descriptor is content and arrives first.' );
    is_deeply( $r->{rows}, [], 'no rows' );
    ok( $r->{pending_schema}, 'and the caller can tell WHY it is empty' );
};

subtest 'apply_schema reports what it did and what it refused' => sub {
    my $r = apply_schema( $docroot, 'products' );
    ok( $r->{ok}, 'the schema applies' ) or diag( $r->{error} );
    ok( scalar @{ $r->{applied} },  'it says what it did' );
    is_deeply( $r->{blocked}, [], 'and nothing was refused on a fresh table' );

    my $again = apply_schema( $docroot, 'products' );
    is_deeply( $again->{applied}, [], 're-applying does nothing' );
};

subtest 'the write path, through one implementation' => sub {
    my $r = insert_row( $docroot, 'products',
        { code => 'A1', name => q{Bob's "widget"}, price => '9.99' } );
    ok( $r->{ok}, 'insert' ) or diag( $r->{error} );
    is( $r->{key}, 'A1', 'and it reports the key' );

    my $rows = read_rows( $docroot, 'products' )->{rows};
    is( scalar @{$rows}, 1, 'one row' );
    is( $rows->[0]{name}, q{Bob's "widget"}, 'the awkward name survives' );
    is( $rows->[0]{active}, 1, 'the descriptor default was applied' );

    ok( !insert_row( $docroot, 'products', { code => 'A2', price => 'lots' } )->{ok},
        'a bad value is refused here too - the same coercion' );

    ok( update_row( $docroot, 'products', 'A1', { name => 'renamed' } )->{ok},
        'update' );

    # 0 rows changed is neither an error nobody sees nor a success.
    my $miss = update_row( $docroot, 'products', 'NOPE', { name => 'x' } );
    ok( !$miss->{ok}, 'updating a row that is not there is refused' )
        or diag( 'Reporting ok would let a UI say "saved" for a row that does '
            . 'not exist.' );
    is( $miss->{kind}, 'no_such_row', 'with a kind the caller can act on' );

    ok( delete_row( $docroot, 'products', 'A1' )->{ok}, 'delete' );
    ok( !delete_row( $docroot, 'products', 'A1' )->{ok},
        'and deleting it twice is refused, not silently fine' );
};

subtest 'the READ PATH takes the read handle' => sub {
    # ASSERTING THE HANDLE'S PROPERTY IS NOT ASSERTING THE PATH USES IT, and
    # the first version of this file only did the former: swapping read_handle
    # for write_handle inside read_rows passed the whole suite. Testing that a
    # lock works is not testing that the door is locked.
    #
    # A CHMOD OF THE STORE DIRECTORY WAS THE FIRST ATTEMPT AND IS THE WRONG
    # TOOL, for a reason worth keeping: the store runs in WAL mode, and a
    # reader needs to create a -shm file beside the database, so a read-only
    # DIRECTORY breaks reading too - silently, returning zero rows rather than
    # failing. It is not a discriminator, and finding that out was worth more
    # than the test would have been.
    #
    # So: make write_handle unavailable and see whether reading still works.
    # That asks exactly the question, and nothing else.
    insert_row( $docroot, 'products', { code => 'C1', name => 'before' } );

    # OVERRIDDEN IN Tables::, NOT IN Connect::, and the difference is the
    # whole test. Tables imports these subs, so the import installs an ALIAS in
    # Tables:: at compile time and a later override of Connect::write_handle
    # changes a symbol nothing calls. The first version did exactly that and
    # the sabotage sailed through - the check was looking at the wrong package.
    my $took_write = 0;
    {
        no warnings 'redefine';
        my $real = \&Lazysite::Data::Tables::write_handle;
        local *Lazysite::Data::Tables::write_handle = sub {
            $took_write++;
            return $real->(@_);
        };
        my $r = read_rows( $docroot, 'products' );
        ok( $r->{ok}, 'reading works' ) or diag( $r->{error} // '' );
        ok( ( grep { $_->{code} eq 'C1' } @{ $r->{rows} || [] } ),
            'and returns the row it was asked for' );
    }
    is( $took_write, 0, 'and it never asked for a write handle' )
        or diag( 'A page binding runs in the processor - the one surface '
            . 'where a bug becomes a write triggered by an anonymous '
            . 'visitor. The read path must not be able to write even by '
            . 'accident.' );
};

subtest 'and the read handle itself refuses writes' => sub {
    insert_row( $docroot, 'products', { code => 'B1', name => 'kept' } );

    require Lazysite::Data::Connect;
    my $ro = Lazysite::Data::Connect::read_handle($docroot);
    ok( $ro, 'a read handle opens' );

    my $wrote = eval {
        $ro->do( 'DELETE FROM products' );
        1;
    };
    ok( !$wrote, 'a write through it fails' )
        or diag( 'A page binding runs in the processor - the one surface '
            . 'where a bug becomes a write triggered by an anonymous '
            . 'visitor.' );

    my $rows = read_rows( $docroot, 'products' )->{rows};
    ok( ( grep { $_->{code} eq 'B1' } @{ $rows || [] } ),
        'and the row the DELETE would have removed is still there' );
};

done_testing();
