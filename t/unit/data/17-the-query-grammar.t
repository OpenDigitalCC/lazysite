#!/usr/bin/perl
# DP-2: what a page may ask a table for, and what it may not.
#
# THE RULE WORTH TESTING HARDEST is the one that refuses reasonable-looking
# queries: a filter or an order on an unindexed text column is a full table
# scan. It WORKS on the twelve rows an author tested with and stops working at
# fifty thousand, by which time the query is in a published page and whoever
# wrote it has moved on. Refusing at parse time costs one line in a log and one
# index in a descriptor; not refusing costs a production incident with no
# obvious cause.
#
# Enum and boolean are exempt because their cardinality is bounded by the
# declaration. The key is exempt because it is already unique.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";

BEGIN {
    eval { require YAML::PP; 1 } or plan skip_all => 'YAML::PP not available';
}
use Lazysite::Data::Query      qw(parse_binding ROW_CAP);
use Lazysite::Data::Descriptor qw(load_descriptor);

my $d = load_descriptor(
    'tasks',
    { key => 'code',
        indexes => [ ['due'], [ 'area', 'street' ] ],
        fields  => {
            code   => { type => 'text' },
            area   => { type => 'text' },
            street => { type => 'text' },
            title  => { type => 'text' },
            due    => { type => 'date' },
            done   => { type => 'boolean' },
            state  => { type => 'enum', values => [qw(new open shut)] },
        },
    }
);
ok( $d->{ok}, 'the fixture descriptor loads' ) or BAIL_OUT( $d->{error} );

subtest 'the shapes an author writes' => sub {
    my $q = parse_binding( 'db:tasks', $d );
    is( $q->{table}, 'tasks',    'a bare table' );
    is( $q->{mode},  'snapshot', 'and snapshot is the default mode' )
        or diag( 'Live-by-default makes every bound page cost a database read '
            . 'per visitor, which nobody opted into.' );

    $q = parse_binding( 'db:tasks(done=false,order=due,limit=4)', $d );
    is_deeply( $q->{filters}, { done => 0 }, 'a filter, coerced to storage form' );
    is( $q->{order_by}, 'due', 'an order' );
    is( $q->{limit},    4,     'and a limit' );

    $q = parse_binding( 'db:tasks(order=-due)', $d );
    is( $q->{order_by}, 'due',  'order=-field names the field' );
    is( $q->{order},    'desc', 'and reverses it' );
};

subtest 'the space form still means what it meant' => sub {
    # It shipped in 0.10.24 and pages use it. Both forms go through one parser,
    # so they cannot drift into disagreeing.
    my $a = parse_binding( 'db:tasks sort=due desc limit=5', $d );
    my $b = parse_binding( 'db:tasks(order=-due,limit=5)',   $d );
    is( $a->{order_by}, $b->{order_by}, 'same field' );
    is( $a->{order},    $b->{order},    'same direction' );
    is( $a->{limit},    $b->{limit},    'same limit' );
};

subtest 'AN UNINDEXED FIELD IS ALLOWED, AND RECORDED AS A SCAN' => sub {
    # This subtest used to assert a refusal. The refusal came from a guess
    # about cost; the measurement says the worst case is about 5 ms at 100,000
    # rows, and these tables hold site state. So the query runs, and what the
    # parser reports is which fields would scan - so a read that ACTUALLY turns
    # out slow can name the index that would fix it.
    my $q = parse_binding( 'db:tasks(title=Fix the roof)', $d );
    ok( $q->{ok}, 'filtering an unindexed text field is allowed' )
        or diag( $q->{error} );
    is_deeply( $q->{scans}, ['title'], 'and recorded as a scan' );

    # A FILTER VALUE WITH SPACES IN IT. Parsing used to split on whitespace
    # before honouring the brackets, so this became the table name
    # `tasks(title=Fix`. A value with a space is a title, a name or an address.
    is_deeply( $q->{filters}, { title => 'Fix the roof' },
        'and the value keeps its spaces' );

    $q = parse_binding( 'db:tasks(order=title)', $d );
    ok( $q->{ok}, 'ordering by one is allowed too' );
    is_deeply( $q->{scans}, ['title'], 'and recorded' )
        or diag( 'ORDER BY is the case LIMIT does not rescue: ten rows cannot '
            . 'be chosen without examining every row.' );

    for my $ok ( 'due=2026-01-01', 'done=true', 'state=open', 'code=T1' ) {
        my $r = parse_binding( "db:tasks($ok)", $d );
        is_deeply( $r->{scans}, [], "$ok does not scan" ) or diag( $r->{error} );
    }

    # A COMPOUND INDEX HELPS ITS FIRST COLUMN AND NOTHING ELSE. SQLite cannot
    # enter an index part-way, so (area, street) does nothing for `street=`.
    is_deeply( parse_binding( 'db:tasks(area=Fife)', $d )->{scans}, [],
        'the first column of a compound index is indexed' );
    is_deeply( parse_binding( 'db:tasks(street=High St)', $d )->{scans},
        ['street'], 'a later column of one is not' );

    # NAMING SOMETHING THAT IS NOT A FIELD IS STILL AN ERROR, and a different
    # kind: it cannot work at any table size, so there is nothing to weigh.
    my $bad = parse_binding( 'db:tasks(nosuch=1)', $d );
    ok( !$bad->{ok}, 'a field that does not exist is refused' );
    like( $bad->{error}, qr/not a field/, 'saying so' );
    ok( !parse_binding( 'db:tasks(order=nosuch)', $d )->{ok},
        'and ordering by one is refused' );
};

subtest 'a value is checked against its declared type' => sub {
    my $q = parse_binding( 'db:tasks(done=maybe)', $d );
    ok( !$q->{ok}, 'a non-boolean for a boolean is refused' )
        or diag( 'Binding it would be SAFE and return no rows, which reads as '
            . '"the table is empty" and sends the author to look at their '
            . 'data instead of their query.' );
    like( $q->{error}, qr/\bdone\b/, 'naming the field' );

    ok( !parse_binding( 'db:tasks(state=elsewhere)', $d )->{ok},
        'a value outside an enum is refused' );
    ok( !parse_binding( 'db:tasks(due=32nd)', $d )->{ok},
        'and a date that is not one' );
};

subtest 'scalars' => sub {
    my $q = parse_binding( 'db:tasks.count(done=false)', $d );
    ok( $q->{ok}, 'a count parses' ) or diag( $q->{error} );
    is( $q->{scalar}, 'count', 'as a scalar' );

    $q = parse_binding( 'db:tasks.field(title,code=T1)', $d );
    ok( $q->{ok}, 'a field lookup parses' ) or diag( $q->{error} );
    is( $q->{column}, 'title', 'naming the column' );
    is_deeply( $q->{filters}, { code => 'T1' }, 'and the row it comes from' );

    # THE COLUMN IS NOT A FILTER, so it is not subject to the index rule - it
    # is being SELECTed, not searched on. `title` is unindexed and that is
    # fine; `code=T1` is the lookup and the key is always allowed.

    ok( !parse_binding( 'db:tasks.field(nosuch,code=T1)', $d )->{ok},
        'but the column has to exist' );
    ok( !parse_binding( 'db:tasks.total()', $d )->{ok},
        'and an invented scalar is refused' );
};

subtest 'the ceiling is stated, not silently applied' => sub {
    # SM511: this used to REFUSE an over-cap limit, and the refusal was right
    # in principle and invisible in practice - a parse error never reaches a
    # rendered page, so limit=501 on a 9-row table rendered ZERO rows with
    # nothing anywhere to explain it. Now it clamps, and the warning rides
    # the parse for the processor to log.
    my $q = parse_binding( 'db:tasks(limit=' . ( ROW_CAP() + 1 ) . ')', $d );
    ok( $q->{ok}, 'asking for more than the cap parses' ) or diag explain $q;
    is( $q->{limit}, ROW_CAP(), 'clamped to the cap, not refused to zero' );
    like( join( ' ', @{ $q->{warnings} || [] } ),
        qr/offset/, 'and the warning points at paging' );

    my $at = parse_binding( 'db:tasks(limit=' . ROW_CAP() . ')', $d );
    ok( $at->{ok},        'the cap itself is allowed' );
    ok( !$at->{warnings}, 'without a warning - asking for the cap is fine' );
    ok( !parse_binding( 'db:tasks(limit=lots)', $d )->{ok},
        'a limit that is not a number is refused' );
};

subtest 'a mode has to be one of the three' => sub {
    is( parse_binding( 'db:tasks(mode=live)',   $d )->{mode}, 'live',   'live' );
    is( parse_binding( 'db:tasks(mode=client)', $d )->{mode}, 'client', 'client' );
    my $q = parse_binding( 'db:tasks(mode=turbo)', $d );
    ok( !$q->{ok}, 'and anything else is refused' );
    like( $q->{error}, qr/snapshot, live and client/, 'listing the three' );
};

subtest 'a table name is a table name' => sub {
    ok( !parse_binding( 'db:../../etc/passwd',    $d )->{ok}, 'no traversal' );
    ok( !parse_binding( 'db:Tasks',               $d )->{ok}, 'no capitals' );
    ok( !parse_binding( 'db:tasks; DROP TABLE x', $d )->{ok}, 'no SQL' );
};

done_testing();
