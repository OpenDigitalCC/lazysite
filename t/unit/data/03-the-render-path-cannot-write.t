#!/usr/bin/perl
# SM447: the read-only handle is read-only because the DRIVER says so.
#
# A page render is the least trusted place in this system to hold a writable
# database handle: it runs per request, anonymous visitors reach it, and its
# inputs are content. Every other protection in this plugin is a check that can
# be got wrong once. A read-only connection is a PROPERTY that stays true even
# when a check is wrong.
#
# So this does not assert that we remember to be careful. It asserts that a
# write through the read handle FAILS, refused by SQLite, and that the row
# count is unchanged afterwards - because "the call errored" and "nothing was
# written" are different claims and only the second one matters.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; 1 }
        or plan skip_all => 'DBI/DBD::SQLite not available';
}
use Lazysite::Data::Connect qw(read_handle write_handle store_path ensure_store);

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite");

subtest 'a read handle on a store that does not exist yet is nothing, not a death'
    => sub {
    # A site that has never used the feature renders pages that show no rows.
    # Dying here would take out every page on it.
    is( read_handle($d), undef, 'undef, so the caller can say "no data"' )
        or diag( 'A site with no tables must still render.' );
    ok( !-e store_path($d), 'and no store FILE was created by asking' );
    # The directory too. A sabotage that called ensure_store on the read path
    # passed the file assertion cleanly - DBI creates the file on connect, and
    # the early return meant it never connected - so only the directory showed
    # the difference. A read must bring NOTHING into being.
    ( my $dir = store_path($d) ) =~ s{/[^/]+\z}{};
    ok( !-d $dir, 'and no store DIRECTORY either' )
        or diag( 'A read that provisions anything makes every page render a '
            . 'writer, on a site that may never use the feature.' );
};

subtest 'the write handle creates the store and can write' => sub {
    my $w = write_handle($d);
    ok( $w, 'connected' ) or BAIL_OUT('cannot open a write handle');
    $w->do('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    $w->do( 'INSERT INTO t (v) VALUES (?)', undef, 'one' );
    is( $w->selectrow_array('SELECT COUNT(*) FROM t'), 1, 'a row went in' );
    $w->disconnect;
};

subtest 'THE POINT: a write through the READ handle is refused' => sub {
    my $r = read_handle($d);
    ok( $r, 'the read handle opens on an existing store' );

    for my $sql (
        "INSERT INTO t (v) VALUES ('two')",
        "UPDATE t SET v = 'changed'",
        'DELETE FROM t',
        'CREATE TABLE sneak (x TEXT)',
        'DROP TABLE t',
        )
    {
        my $ok = eval { $r->do($sql); 1 };
        ok( !$ok, "refused: $sql" )
            or diag( 'The render path holds this handle. If it can write, a '
                . 'bug anywhere upstream becomes a database change made by an '
                . 'anonymous page view.' );
    }
    $r->disconnect;
};

subtest 'and NOTHING was written - the claim that actually matters' => sub {
    # "The call errored" and "the data is unchanged" are different statements.
    # Only the second is the guarantee.
    my $r = read_handle($d);
    is( $r->selectrow_array('SELECT COUNT(*) FROM t'), 1, 'still one row' );
    is( $r->selectrow_array('SELECT v FROM t'), 'one', 'and unchanged' );
    my ($sneak) = $r->selectrow_array(
        "SELECT COUNT(*) FROM sqlite_master WHERE name = 'sneak'");
    is( $sneak, 0, 'no table was created either' );
    $r->disconnect;
};

subtest 'reads still work through the read handle' => sub {
    # Without this, a handle that refused EVERYTHING would pass the subtest
    # above and be useless.
    my $r = read_handle($d);
    my $rows = $r->selectall_arrayref( 'SELECT v FROM t', { Slice => {} } );
    is( scalar @{$rows}, 1, 'a select returns rows' );
    is( $rows->[0]{v},   'one', 'with the right value' );
    $r->disconnect;
};

subtest 'errors are raised, not swallowed' => sub {
    # A silent failure in a data layer is a wrong page. RaiseError is on so a
    # caller cannot mistake "no rows" for "the query was malformed".
    my $r = read_handle($d);
    my $ok = eval { $r->selectall_arrayref('SELECT * FROM no_such_table'); 1 };
    ok( !$ok, 'a bad query dies rather than returning empty' )
        or diag( 'Returning undef here would let a broken query render as an '
            . 'empty list, which looks exactly like a table with no rows.' );
    $r->disconnect;
};

done_testing();
