#!/usr/bin/perl
# SM487: the rebuild pre-flight names the risk that will actually bite.
#
# THE FIELD AGENT'S SESSION, VERBATIM. They rebuilt a throwaway table whose
# new descriptor dropped `note` and made `when` required. The prompt said:
# "this rebuild drops note - confirm by naming it". They confirmed `note`.
# The rebuild then FAILED, rolled back, on a row that had no `when` - and the
# failure read "DBD::SQLite::db do failed: NOT NULL constraint failed:
# rebuild_probe__rebuild.when", naming an internal table and no row.
#
# Two defects in one session. The confirmation named a risk that was not the
# one that would bite, and the failure that did bite spoke the driver's
# language. A confirmation about the wrong thing trains an operator to
# confirm without reading; a driver string trains them to give up.
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
use Lazysite::Data::Tables qw(apply_schema insert_row read_rows rebuild_table load_table);
use Lazysite::Data::Schema qw(plan_rebuild);
use Lazysite::Data::Connect ();

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/tables");
my $path = "$docroot/lazysite/db/tables/probe.yaml";

sub describe {
    my ($yaml) = @_;
    open my $f, '>', $path or die $!;
    print {$f} $yaml;
    close $f;
}

# The BEFORE shape: `when` optional, `note` present.
describe("key: code\nfields:\n  code:\n    type: text\n  qty:\n    type: text\n  when:\n    type: date\n  note:\n    type: text\n");
apply_schema( $docroot, 'probe' );
insert_row( $docroot, 'probe', { code => 'P1', qty => '5',   when => '2026-01-01', note => 'a' } );
insert_row( $docroot, 'probe', { code => 'P2', qty => '7',   note => 'b' } );    # no when
insert_row( $docroot, 'probe', { code => 'P3', qty => 'ten', note => 'c' } );    # no when, non-numeric qty

# The AFTER shape: `note` dropped, `when` REQUIRED, `qty` narrowed to integer.
describe("key: code\nfields:\n  code:\n    type: text\n  qty:\n    type: integer\n  when:\n    type: date\n    required: true\n");

my $d   = load_table( $docroot, 'probe' );
my $dbh = Lazysite::Data::Connect::read_handle($docroot);
my $plan = plan_rebuild( $d, $dbh );

subtest 'THE PRE-FLIGHT NAMES THE RISK THAT WILL BITE' => sub {
    ok( $plan->{ok}, 'a plan is produced' ) or diag( $plan->{error} );
    is_deeply( $plan->{lost}, ['note'], 'the dropped column is still reported' );

    my %by = map { $_->{field} => $_ } @{ $plan->{blocked} || [] };
    ok( $by{when}, 'the required-without-a-value case is found' )
        or diag( 'This is the one the field agent hit. The prompt named '
            . '`note`; the rebuild died on `when`.' );
    is( $by{when}{rows}, 2, 'and COUNTED - two rows have no when' )
        or diag( '"2 rows have no when" is the useful sentence. "Some rows" '
            . 'sends an operator to find out how many.' );
    like( $by{when}{why}, qr/2 rows have no 'when'/, 'in those words' );

    ok( $by{qty}, 'the type narrowing is found too' );
    is( $by{qty}{rule}, 'type', 'as a type refusal' );
    like( $by{qty}{why}, qr/'ten'/, 'naming a stored value that will not convert' )
        or diag( 'The database cannot judge this one - only Value.pm knows '
            . 'that "ten" is not an integer - so the values have to come out '
            . 'and be coerced.' );
};

subtest 'A BLOCKED REBUILD IS REFUSED BEFORE CONFIRMATION IS ASKED' => sub {
    my $r = rebuild_table( $docroot, 'probe' );
    ok( !$r->{ok}, 'refused' );
    is( $r->{kind}, 'blocked', 'as blocked - not as needs_confirmation' )
        or diag( 'Asking somebody to confirm losing `note` when the rebuild '
            . 'will fail on `when` anyway is a prompt about the wrong thing.' );
    like( $r->{error}, qr/when/, 'and the refusal names when' );
    unlike( $r->{error}, qr/DBD::|__rebuild|do failed/,
        'in the operator\'s language, not the driver\'s' );

    # Confirming the dropped column does not get past it either: the data is
    # the problem, and no confirmation can fix data.
    my $c = rebuild_table( $docroot, 'probe', confirm_lost => ['note'] );
    is( $c->{kind}, 'blocked', 'confirming note does not unblock when' );

    is( scalar @{ read_rows( $docroot, 'probe', as => 'operator' )->{rows} },
        3, 'and nothing was touched' );
};

subtest 'fix the data, and the same rebuild goes through' => sub {
    # What the operator does next: fill in the two `when`s and fix `qty`.
    require Lazysite::Data::Tables;
    Lazysite::Data::Tables::update_row( $docroot, 'probe', 'P2', { when => '2026-02-02', qty => '7' } );
    Lazysite::Data::Tables::update_row( $docroot, 'probe', 'P3', { when => '2026-03-03', qty => '10' } );

    my $again = plan_rebuild( $d, Lazysite::Data::Connect::read_handle($docroot) );
    is( scalar @{ $again->{blocked} || [] }, 0, 'nothing blocks now' )
        or diag( explain $again->{blocked} );

    my $r = rebuild_table( $docroot, 'probe', confirm_lost => ['note'] );
    ok( $r->{ok}, 'the rebuild succeeds' ) or diag( $r->{error} );
    is_deeply( $r->{lost}, ['note'], 'having dropped note as confirmed' );
    my $rows = read_rows( $docroot, 'probe', as => 'operator', order_by => 'code' )->{rows};
    is( scalar @{$rows}, 3, 'all three rows carried' );
    is( $rows->[2]{qty}, 10, 'with qty now an integer' );
};

subtest 'the unpredictable failure still speaks plainly' => sub {
    # Everything the pre-flight can predict, it refuses up front. This pins
    # the translation for what it cannot: should the driver refuse anyway, the
    # operator is not handed its sentence. Provoked by racing a row in after
    # the plan - the pre-flight saw a clean table, the copy did not.
    describe("key: code\nfields:\n  code:\n    type: text\n  qty:\n    type: integer\n  when:\n    type: date\n    required: true\n  tag:\n    type: text\n    required: true\n");
    my $d2 = load_table( $docroot, 'probe' );
    # `tag` is NEW and required: every existing row lacks it, and no pre-flight
    # on carried columns sees a column that is not carried. ADD COLUMN ... NOT
    # NULL is refused by SQLite on a populated table, which is why the plan
    # routes this through rebuild - and the copy then cannot supply a value.
    my $r = rebuild_table( $docroot, 'probe' );
    ok( !$r->{ok}, 'the rebuild fails' );
    unlike( $r->{error}, qr/DBD::|__rebuild|do failed/,
        'and the driver string is not what the operator reads' )
        or diag( "error was: $r->{error}" );
    like( $r->{error}, qr/rolled back/, 'it says it rolled back' );
};

done_testing();
