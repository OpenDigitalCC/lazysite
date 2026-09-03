#!/usr/bin/perl
# SM742: a constraint failure answers in OUR words, and names the column.
#
# SM713 stopped these errors carrying a path or the driver's prefix, and did.
# What survived was still SQLite's own sentence - "UNIQUE constraint failed:
# t.code" - which is not a leak (the table and column are the caller's own) but
# is a dependency talking directly to a caller. Anything built against that
# wording is parsing text we do not control.
#
# THE FALLBACK IS THE PART TO PROTECT. A translator that handles four shapes
# and mangles the fifth is worse than one that handles none: the fifth is the
# case nobody anticipated, and it would now be unreadable as well as
# unexpected. So the unrecognised cases are asserted as carefully as the
# recognised ones.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Data::Tables ();

# The real strings, as SQLite emits them through DBD - with the path and line
# noise SM713 strips, so this exercises the whole cleaner and not just the new
# half.
my $AT = ' at /home/ispadmin/web/site/cgi-bin/../lib/Lazysite/Data/Tables.pm line 572.';

sub clean { return Lazysite::Data::Tables::_clean_db_error( $_[0] ) }
sub field {
    my %f = Lazysite::Data::Tables::_constraint_field( $_[0] );
    return $f{field};
}

subtest 'UNIQUE reads as a sentence and names the column' => sub {
    my $e = "DBD::SQLite::db do failed: UNIQUE constraint failed: products.code$AT";
    is( clean($e), 'a row with this code already exists',
        'our sentence, not the driver\'s' );
    is( field($e), 'code', 'and the column comes back as data, not prose' );

    unlike( clean($e), qr/UNIQUE|constraint|SQLite|DBD/i,
        'no trace of the driver\'s vocabulary' );
    unlike( clean($e), qr{/home/|line \d+},
        'and SM713\'s guarantee still holds' );
};

subtest 'a composite key says so rather than naming one column' => sub {
    # Naming only the first column of a two-column key would send an author to
    # fix a field that is not, on its own, the problem.
    my $e = "UNIQUE constraint failed: stock.product, stock.location$AT";
    is( clean($e),
        'a row with this combination of product and location already exists',
        'the sentence says the COMBINATION is what collided' );
    is( field($e), 'product',
        'the field is the first, as somewhere for a form to focus' );
};

subtest 'NOT NULL' => sub {
    my $e = "NOT NULL constraint failed: orders.customer$AT";
    is( clean($e), 'customer is required', 'plain, and in the imperative' );
    is( field($e), 'customer',             'named' );
};

subtest 'FOREIGN KEY names no column, and does not invent one' => sub {
    # SQLite does not say which key failed. A guess pointed at a field is worse
    # than no field: an author would edit the wrong input and see the same
    # error again.
    my $e = "FOREIGN KEY constraint failed$AT";
    is( clean($e), 'this refers to a row that does not exist', 'the sentence' );
    is( field($e), undef, 'and NO field is claimed, because none is known' );
};

subtest 'CHECK, both shapes' => sub {
    my $col = "CHECK constraint failed: items.quantity$AT";
    is( clean($col), 'quantity is outside the values this table allows',
        'when it names a column' );
    is( field($col), 'quantity', 'the column is usable' );

    # A CHECK is often named for the constraint, not a column. Reporting that
    # as a field would point a form at an input that does not exist.
    my $named = "CHECK constraint failed: positive_total$AT";
    like( clean($named), qr/breaks the table's 'positive_total' rule/,
        'when it names the CONSTRAINT, it is quoted as a rule' );
    is( field($named), undef, 'and it is not offered as a field' );
};

subtest 'anything unrecognised falls through UNCHANGED to SM713' => sub {
    # The case that matters most. These must keep the behaviour they had.
    my $missing = "DBD::SQLite::db do failed: no such table: widgets$AT";
    is( clean($missing), 'no such table: widgets',
        'a missing table is still the clean prose 11T-04 reported' );

    my $locked = "DBD::SQLite::db do failed: database is locked$AT";
    is( clean($locked), 'database is locked', 'and so is anything else' );

    is( field($missing), undef, 'with no field invented for it' );

    is( clean(undef), 'the database refused the operation',
        'undef still answers something a caller can show' );
    is( clean(''), 'the database refused the operation', 'and so does empty' );
};

subtest 'a constraint word in ordinary text is not mistaken for one' => sub {
    # The mapping keys on the driver's exact phrasing. A row whose CONTENT
    # mentions a constraint must not be rewritten as though it failed one.
    my $e = "DBD::SQLite::db do failed: no such column: unique_constraint$AT";
    is( clean($e), 'no such column: unique_constraint',
        'passed through - it is not a constraint failure' );
};

done_testing();
